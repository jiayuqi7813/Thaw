//
//  HIDEventManagerBoundsLookupTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import CoreGraphics
import XCTest

final class HIDEventManagerBoundsLookupTests: XCTestCase {
    func testBoundsLookupTrustsCachedBoundsOnMacOS27Path() {
        let syntheticWindowID: CGWindowID = 9_000_001
        let clockBounds = CGRect(x: 1180, y: 0, width: 140, height: 22)
        let entries = [(windowID: syntheticWindowID, bounds: clockBounds)]
        let clickPoint = CGPoint(x: clockBounds.midX, y: clockBounds.midY)

        XCTAssertTrue(
            HIDEventManager.menuBarBoundsLookupContains(
                clickPoint,
                entries: entries,
                trustCachedBoundsWithoutLiveWindowVerification: true,
                liveWindowBounds: { _ in nil }
            )
        )
    }

    func testBoundsLookupRequiresLiveWindowBoundsOnLegacyPath() {
        let windowID: CGWindowID = 42
        let bounds = CGRect(x: 100, y: 0, width: 24, height: 22)
        let entries = [(windowID: windowID, bounds: bounds)]
        let clickPoint = CGPoint(x: bounds.midX, y: bounds.midY)

        XCTAssertFalse(
            HIDEventManager.menuBarBoundsLookupContains(
                clickPoint,
                entries: entries,
                trustCachedBoundsWithoutLiveWindowVerification: false,
                liveWindowBounds: { _ in nil }
            )
        )

        XCTAssertTrue(
            HIDEventManager.menuBarBoundsLookupContains(
                clickPoint,
                entries: entries,
                trustCachedBoundsWithoutLiveWindowVerification: false,
                liveWindowBounds: { id in
                    id == windowID ? bounds : nil
                }
            )
        )
    }

    func testShouldIncludeClockInVisibleSection() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("MenuBarAgent bounds policy is macOS 27-specific")
        }

        let clock = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .menuBarAgent, title: "com.apple.menuextra.clock"),
            windowID: 9_000_002,
            bounds: CGRect(x: 1180, y: 0, width: 140, height: 22)
        )

        XCTAssertTrue(
            HIDEventManager.shouldIncludeItemInMenuBarBoundsLookup(clock, section: .visible)
        )
    }

    func testShouldExcludeNativeOverflowPlaceholder() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("Native overflow placeholders are macOS 27-specific")
        }

        let overflow = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .menuBarAgent, title: "<<"),
            windowID: 9_000_003,
            bounds: CGRect(x: 900, y: 0, width: 18, height: 22)
        )

        XCTAssertFalse(
            HIDEventManager.shouldIncludeItemInMenuBarBoundsLookup(overflow, section: .visible)
        )
    }

    func testShouldExcludeConcealedHiddenItemsButKeepClock() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("MenuBarAgent bounds policy is macOS 27-specific")
        }

        let hiddenApp = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.example.app", title: "Status"),
            windowID: 9_000_004,
            bounds: CGRect(x: 500, y: 0, width: 24, height: 22)
        )
        let clock = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .menuBarAgent, title: "com.apple.menuextra.clock"),
            windowID: 9_000_005,
            bounds: CGRect(x: 1180, y: 0, width: 140, height: 22)
        )

        XCTAssertFalse(
            HIDEventManager.shouldIncludeItemInMenuBarBoundsLookup(hiddenApp, section: .hidden)
        )
        XCTAssertTrue(
            HIDEventManager.shouldIncludeItemInMenuBarBoundsLookup(clock, section: .visible)
        )
    }

    func testShouldExcludePhantomFramesBelowMenuBar() {
        let phantom = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.example.app", title: "Status"),
            windowID: 9_000_006,
            bounds: CGRect(x: 500, y: 1400, width: 24, height: 22)
        )

        XCTAssertFalse(
            HIDEventManager.shouldIncludeItemInMenuBarBoundsLookup(phantom, section: .visible)
        )
    }
}
