//
//  ScreenCapture+HostingStream.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3
//

import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MenuBarModel
import os.lock
@preconcurrency import ScreenCaptureKit

// A persistent ScreenCaptureKit stream on the macOS 27 MenuBarAgent hosting
// window.
//
// The one-shot `SCScreenshotManager.captureImage` path pays a full capture +
// GPU readback on every refresh tick, which storms the CPU at the live-refresh
// cadence and, on a fresh stream, occasionally returns an incomplete first
// frame. A recorder-style persistent stream instead keeps one stream alive and
// reads its most-recently delivered frame: `SCStream` only emits a frame when
// the window's content actually changes, so between changes the buffered frame
// is both current *and* free to read. Bound only while the live-refresh loop is
// active (see ``ScreenCapture/beginMenuBarHostingStreaming()``); one-shot
// callers outside that window transparently fall back to the screenshot path.

/// Continuously-updated sink holding the latest complete frame from a hosting
/// window stream. Frame delivery happens on ``FrameCaptor/sampleHandlerQueue``,
/// so all shared state is guarded by an unfair lock.
@available(macOS 27, *)
final class LatestFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct State {
        var image: CGImage?
        var stopped: Bool
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State(image: nil, stopped: false))

    /// The most recent complete frame, or `nil` if none has arrived yet or the
    /// stream has stopped (a stopped stream's frame is stale, so it is dropped
    /// to force a rebind).
    var latest: CGImage? {
        state.withLock { $0.stopped ? nil : $0.image }
    }

    /// Whether the stream reported that it stopped (window torn down, error).
    var isStopped: Bool {
        state.withLock { $0.stopped }
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
              as? [[SCStreamFrameInfo: Any]],
              let statusInt = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusInt),
              status == .complete,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = FrameCaptor.sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }
        state.withLock { $0.image = cgImage }
    }

    func stream(_: SCStream, didStopWithError _: any Error) {
        state.withLock { $0.stopped = true }
    }
}

/// Owns the persistent hosting-window stream. Serialized as an actor so bind /
/// teardown / read never race.
@available(macOS 27, *)
actor MenuBarHostingWindowStreamer {
    static let shared = MenuBarHostingWindowStreamer()

    /// Whether the caller wants a warm stream maintained. Kept `false` for
    /// one-shot callers so they never spin up (or leak) a persistent stream.
    private var active = false

    private var stream: SCStream?
    private var sink: LatestFrameSink?
    private var boundWindowID: CGWindowID?
    private var boundDisplayID: CGDirectDisplayID?
    private var boundWindowFrame: CGRect = .zero
    private var boundScale: CGFloat = 1

    /// Last time the hosting window was re-resolved. The window's ID churns on
    /// macOS 27, so the binding is refreshed on an interval to follow it; the
    /// window's *frame* (display top-left, full width, fixed height) is stable,
    /// so serving the buffered frame with the last-known frame stays correct in
    /// between.
    private var lastResolve: Date = .distantPast
    private let reresolveInterval: TimeInterval = 1.0

    /// Marks the stream as wanted. The stream itself is created lazily on the
    /// first ``warmCapture(displayID:)`` so no capture starts until a frame is
    /// actually requested.
    func begin() {
        active = true
    }

    /// Stops and releases the stream. Call when the live-refresh loop ends so
    /// the screen-recording indicator clears and resources are freed.
    func end() async {
        active = false
        await teardown()
    }

    /// Returns the latest buffered frame if a warm stream is bound to the
    /// current display and has delivered at least one frame; otherwise `nil`
    /// (the caller falls back to the one-shot screenshot). Rebinds when cold,
    /// when the display changed, when the stream stopped, or on the re-resolve
    /// interval.
    func warmCapture(displayID: CGDirectDisplayID) async -> ScreenCapture.MenuBarHostingCapture? {
        guard active else {
            if stream != nil {
                await teardown()
            }
            return nil
        }

        let needsBind = stream == nil
            || boundDisplayID != displayID
            || (sink?.isStopped ?? true)
            || Date().timeIntervalSince(lastResolve) > reresolveInterval
        if needsBind {
            await bind(displayID: displayID)
        }

        guard let image = sink?.latest else {
            return nil
        }
        return ScreenCapture.MenuBarHostingCapture(
            image: image,
            windowFrame: boundWindowFrame,
            scale: boundScale
        )
    }

    // MARK: Private

    private func bind(displayID: CGDirectDisplayID) async {
        let content: SCShareableContent
        do {
            content = try await ScreenCapture.getShareableContent()
        } catch {
            await teardown()
            return
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let window = ScreenCapture.menuBarHostingWindowCandidates(
                  in: content,
                  displayFrame: display.frame
              ).max(by: { $0.windowID < $1.windowID })
        else {
            await teardown()
            return
        }

        lastResolve = Date()

        // Reuse a healthy stream already bound to this same window.
        if stream != nil,
           boundWindowID == window.windowID,
           boundDisplayID == displayID,
           !(sink?.isStopped ?? true)
        {
            boundWindowFrame = window.frame
            return
        }

        await teardown()

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        // Cap the stream's render rate: a menu-bar preview needs no more than a
        // handful of updates per second, and a lower ceiling is exactly the CPU
        // saving this path exists for. Animated glyphs still update; they just
        // do not flood.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let sink = LatestFrameSink()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: FrameCaptor.sampleHandlerQueue)
            try await stream.startCapture()
        } catch {
            ScreenCapture.diagLog.error(
                "MenuBarHostingWindowStreamer: startCapture failed: \(error.localizedDescription)"
            )
            try? await stream.stopCapture()
            return
        }

        self.stream = stream
        self.sink = sink
        boundWindowID = window.windowID
        boundDisplayID = displayID
        boundWindowFrame = window.frame
        boundScale = scale
        ScreenCapture.diagLog.debug(
            "MenuBarHostingWindowStreamer: bound wid=\(window.windowID) display=\(displayID) " +
                "\(Int(configuration.width))×\(Int(configuration.height))"
        )
    }

    private func teardown() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        sink = nil
        boundWindowID = nil
        boundDisplayID = nil
    }
}

@available(macOS 27, *)
public extension ScreenCapture {
    /// Begins maintaining a warm hosting-window stream. Call when the
    /// live-refresh loop starts so subsequent
    /// ``captureMenuBarHostingWindowAsync(displayID:)`` calls can return
    /// buffered frames instead of full one-shot captures.
    static func beginMenuBarHostingStreaming() async {
        await MenuBarHostingWindowStreamer.shared.begin()
    }

    /// Stops the warm hosting-window stream. Call when the live-refresh loop
    /// ends so the stream, and its screen-recording indicator, are released.
    static func endMenuBarHostingStreaming() async {
        await MenuBarHostingWindowStreamer.shared.end()
    }
}
