//
//  MenuBarItemImageCacheFreshBoundsTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

final class MenuBarItemImageCacheFreshBoundsTests: XCTestCase {
    private let cachedBounds = CGRect(x: 100, y: 0, width: 24, height: 22)
    private let liveBounds = CGRect(x: 200, y: 0, width: 24, height: 22)

    func testCachedBoundsAreUsedWhenFreshBoundsAreDisabled() {
        let item = makeItem()

        let captures = MenuBarItemImageCache.captureBounds(
            for: [item],
            freshBounds: false,
            liveBoundsByID: [item.uniqueIdentifier: liveBounds],
            screenFrame: nil
        )

        XCTAssertEqual(captures.first?.bounds, cachedBounds)
    }

    func testLiveBoundsAreUsedWhenFreshBoundsAreEnabled() {
        let item = makeItem()

        let captures = MenuBarItemImageCache.captureBounds(
            for: [item],
            freshBounds: true,
            liveBoundsByID: [item.uniqueIdentifier: liveBounds],
            screenFrame: nil
        )

        XCTAssertEqual(captures.first?.bounds, liveBounds)
    }

    func testVerticallyArrangedDisplayDoesNotRejectCGCoordinates() {
        let item = makeItem(bounds: CGRect(x: 200, y: -40, width: 24, height: 22))

        let captures = MenuBarItemImageCache.captureBounds(
            for: [item],
            freshBounds: false,
            liveBoundsByID: [:],
            screenFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        )

        XCTAssertEqual(captures.count, 1)
    }

    func testBoundsOutsideDisplayHorizontalRangeAreRejected() {
        let item = makeItem(bounds: CGRect(x: -200, y: 0, width: 24, height: 22))

        let captures = MenuBarItemImageCache.captureBounds(
            for: [item],
            freshBounds: false,
            liveBoundsByID: [:],
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        XCTAssertTrue(captures.isEmpty)
    }

    private func makeItem(bounds: CGRect? = nil) -> MenuBarItem {
        MenuBarItem(
            tag: .appItem(bundleID: "com.test.capture", title: "Capture"),
            windowID: 42,
            ownerPID: 100,
            sourcePID: 100,
            bounds: bounds ?? cachedBounds,
            title: "Capture",
            isOnScreen: true
        )
    }
}
