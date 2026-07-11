//
//  ScreenCapture+Internal.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import os.lock
@preconcurrency import ScreenCaptureKit

extension ScreenCapture {
    /// - Returns: The captured image, or nil if capture failed.
    public static func captureScreenBelowWindow(
        excludingWindowID windowID: CGWindowID,
        screenBounds: CGRect,
        displayID: CGDirectDisplayID
    ) async throws -> CGImage? {
        // Get shareable content (displays and windows)
        let content = try await getShareableContent()

        // Find the target display
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            diagLog.warning("captureScreenBelowWindow: display not found for ID=\(displayID)")
            return nil
        }

        // Find the window to exclude
        let excludedWindow = content.windows.first { $0.windowID == windowID }

        if excludedWindow == nil {
            diagLog.debug("captureScreenBelowWindow: window not found for ID=\(windowID), capturing full display")
        }

        // Create filter: include display, exclude the specified window
        let filter = if let excludedWindow {
            SCContentFilter(
                display: display,
                excludingWindows: [excludedWindow]
            )
        } else {
            SCContentFilter(display: display, excludingWindows: [])
        }

        // Configure stream for single frame capture.
        // sourceRect is in display-local points; width/height are in pixels.
        let displayFrame = display.frame
        let scale = Double(filter.pointPixelScale)

        let localSourceRect = CGRect(
            x: screenBounds.origin.x - displayFrame.origin.x,
            y: screenBounds.origin.y - displayFrame.origin.y,
            width: screenBounds.width,
            height: screenBounds.height
        )

        let configuration = SCStreamConfiguration()
        // captureResolution is not used here; explicit width/height below take precedence.
        configuration.showsCursor = false
        // Pin the pixel format so the buffer is deterministic across SDR/EDR
        // displays. Left unset, an HDR display can hand back a 10-bit buffer that
        // the CIImage → CGImage conversion renders subtly differently, an
        // intermittent display-dependent color glitch. 32BGRA is the historical
        // default and what the crop/compare path expects. Do NOT set
        // `colorSpaceName` — it triggers an internal CoreGraphics tone-mapping
        // pass that destructively clips color (learned from BetterCapture).
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.width = Int((screenBounds.width * scale).rounded())
        configuration.height = Int((screenBounds.height * scale).rounded())
        configuration.sourceRect = localSourceRect

        // Create stream and capture frame
        // Note: Caller owns the stream and is responsible for stopCapture().
        let frameCaptor = FrameCaptor()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: frameCaptor)

        // Register FrameCaptor to receive sample buffers using shared serial queue
        try stream.addStreamOutput(frameCaptor, type: .screen, sampleHandlerQueue: FrameCaptor.sampleHandlerQueue)

        try await stream.startCapture()

        // Wait for frame with timeout, ensuring stopCapture() always called
        let image: CGImage?
        do {
            image = try await Task<CGImage?, any Error>.withTimeout(.seconds(5), tolerance: nil, clock: .continuous) {
                await frameCaptor.waitForFrame()
            }
            try? await stream.stopCapture()
        } catch {
            try? await stream.stopCapture()
            throw error
        }

        if let image {
            diagLog.debug("captureScreenBelowWindow: captured below windowID=\(windowID) → \(image.width)×\(image.height)px")
        } else {
            diagLog.warning("captureScreenBelowWindow: failed to capture image below windowID=\(windowID)")
        }

        return image
    }

    /// Helper to get shareable content using async wrapper
    static func getShareableContent() async throws -> SCShareableContent {
        let box = ContinuationBox<SCShareableContent, any Error>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.setContinuation(continuation)
                SCShareableContent.getWithCompletionHandler(makeShareableContentCompletion(box: box))
            }
        } onCancel: {
            // Resume with cancellation error if still pending
            if let continuation = box.takeContinuation() {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Creates a completion handler for SCShareableContent request
    private static func makeShareableContentCompletion(
        box: ContinuationBox<SCShareableContent, any Error>
    ) -> @Sendable (SCShareableContent?, Error?) -> Void {
        { content, error in
            guard let continuation = box.takeContinuation() else { return }
            if let error {
                continuation.resume(throwing: error)
            } else if let content {
                continuation.resume(returning: content)
            } else {
                continuation.resume(throwing: ScreenCaptureError.noContent)
            }
        }
    }
}

// MARK: - Helper Types

enum ScreenCaptureError: Error {
    case noContent
}

final class ContinuationBox<T, E: Error>: Sendable {
    private let lock = OSAllocatedUnfairLock<CheckedContinuation<T, E>?>(initialState: nil)

    func setContinuation(_ cont: CheckedContinuation<T, E>) {
        lock.withLock { $0 = cont }
    }

    func takeContinuation() -> CheckedContinuation<T, E>? {
        lock.withLock { $0.take() }
    }
}

final class FrameCaptor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Shared serial queue for all SCStream sample buffer handlers.
    static let sampleHandlerQueue = DispatchQueue(label: "com.stonerl.Thaw.screencapture")

    /// Process-wide `CIContext`, shared across every capture. A `CIContext`
    /// allocates a Metal device and command queue; `FrameCaptor` is created per
    /// capture, so a per-instance context paid that GPU/Metal setup on every
    /// single capture. One shared context amortizes it across the whole app.
    static let sharedCIContext = CIContext()

    private var ciContext: CIContext { FrameCaptor.sharedCIContext }

    private let lock = OSAllocatedUnfairLock<(continuation: CheckedContinuation<CGImage?, Never>?, bufferedImage: CGImage?)>(initialState: (nil, nil))

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusInt = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let frameStatus = SCFrameStatus(rawValue: statusInt),
              frameStatus == .complete
        else {
            return
        }

        guard let imageBuffer = sampleBuffer.imageBuffer else {
            resumeOrBuffer(with: nil)
            return
        }

        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            resumeOrBuffer(with: nil)
            return
        }

        resumeOrBuffer(with: cgImage)
    }

    func stream(_: SCStream, didStopWithError _: Error) {
        resumeOrBuffer(with: nil)
    }

    private func resumeOrBuffer(with image: CGImage?) {
        let cont = lock.withLock { state -> CheckedContinuation<CGImage?, Never>? in
            if let c = state.continuation {
                state.continuation = nil
                return c
            }
            state.bufferedImage = image
            return nil
        }
        if let cont {
            cont.resume(returning: image)
        }
    }

    func waitForFrame() async -> CGImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                claimOrRegister(cont: cont)
            }
        } onCancel: { [weak self] in
            self?.cancelPendingWait()
        }
    }

    private func claimOrRegister(cont: CheckedContinuation<CGImage?, Never>) {
        let (image, shouldResume) = lock.withLock { state -> (CGImage?, Bool) in
            if let image = state.bufferedImage {
                state.bufferedImage = nil
                return (image, true)
            }
            if Task.isCancelled {
                return (nil, true)
            }
            state.continuation = cont
            return (nil, false)
        }
        if shouldResume {
            cont.resume(returning: image)
        }
    }

    private func cancelPendingWait() {
        let cont = lock.withLock { state -> CheckedContinuation<CGImage?, Never>? in
            let c = state.continuation
            state.continuation = nil
            return c
        }
        cont?.resume(returning: nil)
    }
}

// MARK: - Task Timeout

/// An error indicates task timed out.
struct TaskTimeoutError: CustomStringConvertible, LocalizedError {
    let description = "Task timed out before completion"

    var errorDescription: String? {
        description
    }
}

extension Task {
    static func withTimeout<C: Clock>(
        _ timeout: C.Instant.Duration,
        tolerance: C.Instant.Duration? = nil,
        clock: C = .continuous,
        operation: @escaping @Sendable () async throws -> Success
    ) async throws -> Success {
        try await withThrowingTaskGroup(of: Success.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await _Concurrency.Task.sleep(for: timeout, tolerance: tolerance, clock: clock)
                throw TaskTimeoutError()
            }
            guard let success = try await group.next() else {
                throw _Concurrency.CancellationError()
            }
            group.cancelAll()
            return success
        }
    }
}
