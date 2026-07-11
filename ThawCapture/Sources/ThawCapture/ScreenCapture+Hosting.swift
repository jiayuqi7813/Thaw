//
//  ScreenCapture+Hosting.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import CoreGraphics
import MenuBarModel
@preconcurrency import ScreenCaptureKit

public extension ScreenCapture {
    // MARK: - ScreenCaptureKit Implementation

    /// The result of capturing `MenuBarAgent`'s menu bar hosting window.
    @available(macOS 27, *)
    // `@unchecked Sendable`: the only reference-type member is `CGImage`, which
    // is immutable and safe to read from any thread. Marking it lets the warm
    // hosting-window stream return a buffered frame across the actor boundary.
    struct MenuBarHostingCapture: @unchecked Sendable {
        /// The captured image of the whole menu bar (every status item
        /// composited on a transparent background, at `scale`).
        public let image: CGImage
        /// The hosting window's frame in global screen coordinates
        /// (Y-down). Subtract this origin from an item's frame to map it
        /// into the image, then multiply by `scale`.
        public let windowFrame: CGRect
        /// The pixel scale the image was captured at.
        public let scale: CGFloat
    }

    @available(macOS 27, *)
    static func menuBarHostingWindowCandidates(
        in content: SCShareableContent,
        displayFrame: CGRect
    ) -> [SCWindow] {
        content.windows.filter { w in
            w.owningApplication?.bundleIdentifier == SharedConstants.menuBarHostingBundleID
                && w.frame.height <= 40
                && w.frame.width > displayFrame.width * 0.8
                && abs(w.frame.minX - displayFrame.minX) < 2
                && abs(w.frame.minY - displayFrame.minY) < 2
        }
    }

    @available(macOS 27, *)
    private static func captureMenuBarDisplayStripAsync(
        display: SCDisplay
    ) async -> MenuBarHostingCapture? {
        let displayFrame = display.frame
        let stripHeight = min(CGFloat(40), displayFrame.height)
        let stripFrame = CGRect(
            x: displayFrame.minX,
            y: displayFrame.minY,
            width: displayFrame.width,
            height: stripHeight
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        configuration.width = Int((stripFrame.width * scale).rounded())
        configuration.height = Int((stripFrame.height * scale).rounded())
        configuration.sourceRect = CGRect(
            x: stripFrame.minX - displayFrame.minX,
            y: stripFrame.minY - displayFrame.minY,
            width: stripFrame.width,
            height: stripFrame.height
        )

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            diagLog.debug(
                "captureMenuBarHostingWindowAsync: captured fallback display strip " +
                    "\(image.width)×\(image.height)px displayID=\(display.displayID)"
            )
            return MenuBarHostingCapture(image: image, windowFrame: stripFrame, scale: scale)
        } catch {
            diagLog.error(
                "captureMenuBarHostingWindowAsync: fallback display strip failed: \(error)"
            )
            return nil
        }
    }

    @available(macOS 27, *)
    static func logMenuBarHostingWindowCandidates(
        displayID: CGDirectDisplayID,
        reason: String
    ) async {
        guard isProbeLoggingEnabled() else {
            return
        }

        let content: SCShareableContent
        do {
            content = try await getShareableContent()
        } catch {
            diagLog.error("hostingCandidates[\(reason)]: SCShareableContent failed: \(error)")
            return
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            diagLog.warning("hostingCandidates[\(reason)]: display \(displayID) not found")
            return
        }

        let candidates = menuBarHostingWindowCandidates(in: content, displayFrame: display.frame)
        let descriptions = candidates
            .sorted { $0.windowID < $1.windowID }
            .map { window in
                "wid=\(window.windowID) frame=\(NSStringFromRect(window.frame))"
            }
        diagLog.info(
            "hostingCandidates[\(reason)]: displayID=\(displayID) " +
                "count=\(candidates.count) \(descriptions.joined(separator: " | "))"
        )
    }

    /// Captures `MenuBarAgent`'s menu bar hosting window for a display.
    ///
    /// On macOS 27 every status item is composited as a subitem inside a single
    /// full-width window owned by `MenuBarAgent`. Capturing *that window*
    /// (rather than a display region) yields the icon glyphs on a fully
    /// transparent background — no menu bar fill and no wallpaper bleeding
    /// through the bar's translucency — which is a far cleaner source for
    /// per-item thumbnails. The caller crops each item out of the returned
    /// image using the item's AX frame and ``MenuBarHostingCapture/windowFrame``.
    ///
    /// - Parameter displayID: The display whose menu bar to capture.
    /// - Returns: The capture, or `nil` if the hosting window can't be found
    ///   or captured.
    @available(macOS 27, *)
    static func captureMenuBarHostingWindowAsync(
        displayID: CGDirectDisplayID
    ) async -> MenuBarHostingCapture? {
        // Fast path: while the live-refresh loop keeps a warm hosting-window
        // stream running, its most-recently delivered frame is the current
        // truth (SCStream only emits a frame when the window's content changes),
        // so it can be returned without a fresh capture + GPU readback. When no
        // stream is warm — one-shot callers, or none has delivered a first frame
        // yet — this returns nil and we fall through to the one-shot screenshot.
        if let warm = await MenuBarHostingWindowStreamer.shared.warmCapture(displayID: displayID) {
            return warm
        }

        let content: SCShareableContent
        do {
            content = try await getShareableContent()
        } catch {
            diagLog.error("captureMenuBarHostingWindowAsync: SCShareableContent failed: \(error)")
            return nil
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            diagLog.warning("captureMenuBarHostingWindowAsync: display \(displayID) not found")
            return nil
        }
        let displayFrame = display.frame

        // The hosting window: owned by MenuBarAgent, spanning the display's
        // menu bar (full width, ~menu-bar height, anchored at the display's
        // top-left). Note: `isOnScreen` is deliberately NOT checked — SCK
        // reports these composited menu bar windows as off-screen even though
        // they hold the live, rendered icons. Filtering on the MenuBarAgent
        // bundle ID excludes the per-app status-item proxy windows (which are
        // also full-width and off-screen). Prefer the highest windowID (most
        // recently realized) when more than one matches the display.
        let window = menuBarHostingWindowCandidates(in: content, displayFrame: displayFrame)
            .max { $0.windowID < $1.windowID }

        guard let window else {
            diagLog.warning("captureMenuBarHostingWindowAsync: no MenuBarAgent hosting window on display \(displayID)")
            return await captureMenuBarDisplayStripAsync(display: display)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureDynamicRange = .SDR
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            diagLog.debug(
                "captureMenuBarHostingWindowAsync: captured \(image.width)×\(image.height)px " +
                    "(wid=\(window.windowID)) for displayID=\(displayID)"
            )
            return MenuBarHostingCapture(image: image, windowFrame: window.frame, scale: scale)
        } catch {
            diagLog.error("captureMenuBarHostingWindowAsync: SCScreenshotManager.captureImage failed: \(error)")
            return await captureMenuBarDisplayStripAsync(display: display)
        }
    }

    // Captures a composite image of all windows below the specified window using ScreenCaptureKit.
    //
    // - Parameters:
    //   - windowID: The identifier of the window to exclude (capture everything below it).
    //   - screenBounds: The bounds to capture, specified in screen coordinates.
    //   - displayID: The display to capture from.
}
