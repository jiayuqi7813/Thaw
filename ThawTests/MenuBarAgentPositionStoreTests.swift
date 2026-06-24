//
//  MenuBarAgentPositionStoreTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

@available(macOS 27, *)
@MainActor
final class MenuBarAgentPositionStoreTests: XCTestCase {
    // MARK: - midpointPosition

    func testMidpointReturnsValueBetweenNeighbors() {
        XCTAssertEqual(MenuBarAgentPositionStore.midpointPosition(between: 100, and: 200), 150)
    }

    func testMidpointIsOrderAgnostic() {
        // Same result regardless of which bound is larger.
        XCTAssertEqual(
            MenuBarAgentPositionStore.midpointPosition(between: 200, and: 100),
            MenuBarAgentPositionStore.midpointPosition(between: 100, and: 200)
        )
    }

    func testMidpointNilWhenNoIntegerGap() {
        XCTAssertNil(MenuBarAgentPositionStore.midpointPosition(between: 100, and: 101))
        XCTAssertNil(MenuBarAgentPositionStore.midpointPosition(between: 100, and: 100))
    }

    // MARK: - resolveKey

    func testResolveModuleKey() {
        let item = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .menuBarAgent, title: "WiFi"),
            windowID: 1
        )
        XCTAssertEqual(
            MenuBarAgentPositionStore.resolveKey(for: item, existingKeys: ["module:WiFi", "module:Clock"]),
            "module:WiFi"
        )
    }

    func testResolveStatusKeyByBundleIDForm() {
        // The common form is status:<bundleID>::<itemID>, and the bundleID is
        // the item's namespace. Many apps share the generic "Item-0" title, so
        // the exact bundle-ID key must win over the ambiguous suffix match.
        let item = MenuBarItem.fixture(
            tag: .appItem(bundleID: "notion.id", title: "Item-0"),
            windowID: 2
        )
        XCTAssertEqual(
            MenuBarAgentPositionStore.resolveKey(
                for: item,
                existingKeys: [
                    "status:notion.id::Item-0",
                    "status:cc.ffitch.shottr::Item-0",
                    "status:com.anthropic.claudefordesktop::Item-0",
                ]
            ),
            "status:notion.id::Item-0"
        )
    }

    func testResolveStatusKeyBySuffix() {
        let item = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.foo.Bar", title: "Item-0"),
            windowID: 2
        )
        XCTAssertEqual(
            MenuBarAgentPositionStore.resolveKey(
                for: item,
                existingKeys: ["status:Bar::Item-0", "status:Other::Item-9"]
            ),
            "status:Bar::Item-0"
        )
    }

    func testResolveReturnsNilWhenAbsent() {
        let item = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.foo.Bar", title: "Ghost"),
            windowID: 3
        )
        XCTAssertNil(
            MenuBarAgentPositionStore.resolveKey(for: item, existingKeys: ["status:Bar::Item-0"])
        )
    }

    // MARK: - neighborItems

    func testRightOfItemBracketsAnchorAndRightNeighbor() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let c = item("C", x: 60)
        let result = MenuBarAgentPositionStore.neighborItems(
            forMoving: a,
            to: .rightOfItem(target),
            liveItems: [a, target, c]
        )
        XCTAssertEqual(result?.anchor.tag.title, "T")
        XCTAssertEqual(result?.far?.tag.title, "C")
    }

    func testLeftOfItemFarNeighborNilAtRunStart() {
        // Anchor is leftmost after the moved item is removed → no far neighbor.
        let moved = item("M", x: 90)
        let target = item("T", x: 0)
        let c = item("C", x: 30)
        let result = MenuBarAgentPositionStore.neighborItems(
            forMoving: moved,
            to: .leftOfItem(target),
            liveItems: [target, c, moved]
        )
        XCTAssertEqual(result?.anchor.tag.title, "T")
        XCTAssertNil(result?.far)
    }

    // MARK: - move orchestration

    func testMoveWritesMidpointAndNudges() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let c = item("C", x: 60)

        var written: [String: Int]?
        var nudged = false
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:A::A": 50, "status:A::T": 100, "status:A::C": 200] },
            writePositions: { written = $0 },
            nudgeAgent: { nudged = true }
        )

        let applied = MenuBarAgentPositionStore.move(
            item: a,
            to: .rightOfItem(target),
            liveItems: [a, target, c],
            environment: env
        )

        XCTAssertTrue(applied)
        XCTAssertTrue(nudged)
        // A is placed between T (100) and C (200).
        XCTAssertEqual(written?["status:A::A"], 150)
        // Other weights are untouched.
        XCTAssertEqual(written?["status:A::T"], 100)
        XCTAssertEqual(written?["status:A::C"], 200)
    }

    func testMoveDefersWhenKeyUnresolved() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:A::T": 100] }, // no key for A
            writePositions: { _ in XCTFail("should not write") },
            nudgeAgent: { XCTFail("should not nudge") }
        )
        XCTAssertFalse(
            MenuBarAgentPositionStore.move(
                item: a,
                to: .rightOfItem(target),
                liveItems: [a, target],
                environment: env
            )
        )
    }

    func testMoveDefersWhenNoGap() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let c = item("C", x: 60)
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:A::A": 50, "status:A::T": 100, "status:A::C": 101] },
            writePositions: { _ in XCTFail("should not write") },
            nudgeAgent: { XCTFail("should not nudge") }
        )
        XCTAssertFalse(
            MenuBarAgentPositionStore.move(
                item: a,
                to: .rightOfItem(target),
                liveItems: [a, target, c],
                environment: env
            )
        )
    }

    // MARK: - Helpers

    /// A movable third-party status item under the "A" app at the given x.
    private func item(_ title: String, x: CGFloat) -> MenuBarItem {
        MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: title),
            windowID: CGWindowID(abs(x.hashValue % 100_000) + 10),
            bounds: CGRect(x: x, y: 0, width: 24, height: 22)
        )
    }
}
