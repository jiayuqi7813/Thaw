//
//  OverflowFallbackIconTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
@testable import Thaw
import XCTest

@MainActor
final class OverflowFallbackIconTests: XCTestCase {
    func testSupportsMissingCaptureFallbackOnMacOS27ForAnySection() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("App-icon fallback is macOS 27-specific")
        }

        XCTAssertTrue(OverflowFallbackIcon.supportsMissingCaptureFallback(for: .hidden))
        XCTAssertTrue(OverflowFallbackIcon.supportsMissingCaptureFallback(for: .alwaysHidden))
        XCTAssertTrue(OverflowFallbackIcon.supportsMissingCaptureFallback(for: .visible))
        XCTAssertFalse(OverflowFallbackIcon.supportsMissingCaptureFallback(for: nil))
    }

    func testShouldPreferAppIconOnlyWhenCaptureMissing() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("App-icon fallback is macOS 27-specific")
        }

        let originalValue = Defaults.object(forKey: .alwaysUseAppIconForMenuBarItems)
        defer {
            if let originalValue {
                Defaults.set(originalValue, forKey: .alwaysUseAppIconForMenuBarItems)
            } else {
                Defaults.removeObject(forKey: .alwaysUseAppIconForMenuBarItems)
            }
        }

        let appState = AppState()
        appState.settings.advanced.alwaysUseAppIconForMenuBarItems = false

        XCTAssertTrue(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: .alwaysHidden,
                appState: appState,
                cachedImage: nil
            )
        )
        XCTAssertTrue(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: .visible,
                appState: appState,
                cachedImage: nil
            )
        )
        XCTAssertFalse(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: .alwaysHidden,
                appState: appState,
                cachedImage: NSImage(size: NSSize(width: 16, height: 16))
            )
        )
    }

    func testShouldPreferAppIconWithCachedCaptureWhenOverrideEnabled() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("App-icon fallback is macOS 27-specific")
        }

        let originalValue = Defaults.object(forKey: .alwaysUseAppIconForMenuBarItems)
        defer {
            if let originalValue {
                Defaults.set(originalValue, forKey: .alwaysUseAppIconForMenuBarItems)
            } else {
                Defaults.removeObject(forKey: .alwaysUseAppIconForMenuBarItems)
            }
        }

        let appState = AppState()
        appState.settings.advanced.alwaysUseAppIconForMenuBarItems = true

        XCTAssertTrue(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: .visible,
                appState: appState,
                cachedImage: NSImage(size: NSSize(width: 16, height: 16))
            )
        )
        XCTAssertFalse(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: nil,
                appState: appState,
                cachedImage: NSImage(size: NSSize(width: 16, height: 16))
            )
        )
    }
}
