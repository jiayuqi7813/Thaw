//
//  ScreenCapture+Legacy.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import MenuBarModel

public extension ScreenCapture {
    // MARK: Capture Window(s)

    // NOTE: The synchronous captureWindows / captureWindow below intentionally
    // route through the deprecated SkyLight private API
    // (SLWindowListCreateImageFromArray) for the menu-bar refresh path. On
    // macOS 26 SCShareableContent.excludingDesktopWindows(_: onScreenWindowsOnly:
    // false) *does* enumerate offscreen menu-bar overflow items, but SCK
    // capture rejects them: SCContentFilter(display: including:) returns error
    // -3812 (sourceRect outside display bounds) and SCContentFilter(
    // desktopIndependentWindow:) returns -3811 (stream start failure). SkyLight
    // is the only public API on macOS 26 that can capture status-item windows
    // positioned at large negative x. It leaks one CFMutableDictionary per
    // call inside SLSWindowListCreateImageFromArrayProxying; that's a system
    // bug awaiting an Apple fix.
    //
    // The async captureWindowsAsync / captureWindowAsync below route through
    // ScreenCaptureKit and are leak-free. Use those for any capture whose
    // windows fit within display bounds (the menu-bar item cache paths
    // pre-filter offscreen items and use the async path).

    /// Captures a composite image of an array of windows.
    ///
    /// The windows are composited from front to back, according to the order
    /// of the `windowIDs` parameter.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify which parts of the windows are captured.
    static func captureWindows(with windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        // Use SkyLight's private API (SLWindowListCreateImageFromArray) instead of
        // the deprecated CGWindowListCreateImageFromArray, which is unavailable
        // when targeting macOS 26+. ScreenCaptureKit still doesn't support
        // capturing offscreen menu bar items or windows in other Spaces.
        return Bridging.captureWindowsImage(windowIDs: windowIDs, screenBounds: screenBounds, options: option)
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture, specified in screen coordinates.
    ///     Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify which parts of the window are captured.
    static func captureWindow(with windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows(with: [windowID], screenBounds: screenBounds, option: option)
    }

    // MARK: Capture Window(s) via ScreenCaptureKit

    /// Async, ScreenCaptureKit-backed equivalent of captureWindows. Leak-free,
    /// but the underlying SCK filter is display-bounded; use captureWindows
    /// (SkyLight) for windows positioned off-display.
    static func captureWindowsAsync(with windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) async -> CGImage? {
        await Bridging.captureWindowsImageSCK(windowIDs: windowIDs, screenBounds: screenBounds, options: option)
    }

    /// Async, ScreenCaptureKit-backed equivalent of captureWindow.
    static func captureWindowAsync(with windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) async -> CGImage? {
        await captureWindowsAsync(with: [windowID], screenBounds: screenBounds, option: option)
    }
}
