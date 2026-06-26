//
//  SpotlightMenuItemManagerTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

// MARK: - SpotlightMenuItemManager Tests

/// Covers identifier matching and state transitions through an in-memory
/// environment. Tests never mutate the live Spotlight preference or restart the
/// Campo process.
@MainActor
final class SpotlightMenuItemManagerTests: XCTestCase {
    // MARK: isGovernable(itemIdentifier:)

    func testSpotlightIdentifierIsGovernable() {
        XCTAssertTrue(SpotlightMenuItemManager.isGovernable(
            itemIdentifier: "com.apple.campo:Spotlight"
        ))
    }

    func testNonSpotlightIdentifiersAreNotGovernable() {
        // Another campo item, a CC module, and a third-party item.
        XCTAssertFalse(SpotlightMenuItemManager.isGovernable(itemIdentifier: "com.apple.campo:Other"))
        XCTAssertFalse(SpotlightMenuItemManager.isGovernable(
            itemIdentifier: "com.apple.MenuBarAgent:com.apple.menuextra.airdrop"
        ))
        XCTAssertFalse(SpotlightMenuItemManager.isGovernable(itemIdentifier: "cc.ffitch.shottr:Item-0"))
        // A foreign item that merely ends in "Spotlight" must not match — the
        // owner must be campo.
        XCTAssertFalse(SpotlightMenuItemManager.isGovernable(itemIdentifier: "com.example.app:Spotlight"))
    }

    // MARK: Preference state transitions

    func testApplyHidesShownSpotlightAndRepeatedApplyIsNoOp() {
        let harness = makeHarness(hidden: false)

        XCTAssertTrue(harness.manager.apply(hidden: true))
        XCTAssertEqual(harness.store.hidden, true)
        XCTAssertEqual(harness.store.writes, [true])
        XCTAssertEqual(harness.store.synchronizeCount, 1)
        XCTAssertEqual(harness.store.restartCount, 1)

        XCTAssertFalse(harness.manager.apply(hidden: true))
        XCTAssertEqual(harness.store.writes.count, 1)
        XCTAssertEqual(harness.store.synchronizeCount, 1)
        XCTAssertEqual(harness.store.restartCount, 1)
    }

    func testRestoreReinstatesOriginalShownPreference() {
        let harness = makeHarness(hidden: false)

        XCTAssertTrue(harness.manager.apply(hidden: true))
        XCTAssertTrue(harness.manager.apply(hidden: false))

        XCTAssertEqual(harness.store.hidden, false)
        XCTAssertEqual(harness.store.writes, [true, false])
        XCTAssertEqual(harness.store.synchronizeCount, 2)
        XCTAssertEqual(harness.store.restartCount, 2)
    }

    func testMissingPreferenceIsRemovedOnRestore() {
        let harness = makeHarness(hidden: nil)

        XCTAssertTrue(harness.manager.apply(hidden: true))
        XCTAssertTrue(harness.manager.apply(hidden: false))

        // The key Thaw added should be removed again (back to absent).
        XCTAssertNil(harness.store.hidden)
        XCTAssertEqual(harness.store.writes, [true, nil])
    }

    func testInitiallyHiddenSpotlightRemainsHiddenWithNoRestart() {
        // If the user already had Spotlight hidden, hiding it is a no-op and a
        // later restore keeps it hidden (we never restart Campo needlessly).
        let harness = makeHarness(hidden: true)

        XCTAssertFalse(harness.manager.apply(hidden: true))
        XCTAssertEqual(harness.store.hidden, true)
        XCTAssertTrue(harness.store.writes.isEmpty)
        XCTAssertEqual(harness.store.synchronizeCount, 0)
        XCTAssertEqual(harness.store.restartCount, 0)
    }

    func testTerminationNotificationRestoresSpotlight() {
        let notificationCenter = NotificationCenter()
        let harness = makeHarness(hidden: false, notificationCenter: notificationCenter)
        XCTAssertTrue(harness.manager.apply(hidden: true))

        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(harness.store.hidden, false)
        XCTAssertEqual(harness.store.synchronizeCount, 2)
        XCTAssertEqual(harness.store.restartCount, 2)
    }

    private func makeHarness(
        hidden: Bool?,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> Harness {
        let store = InMemoryEnvironment(hidden: hidden)
        let environment = SpotlightMenuItemManager.Environment(
            readHidden: { store.hidden },
            writeHidden: { store.writeHidden($0) },
            synchronize: { store.synchronizeCount += 1 },
            restartCampo: { store.restartCount += 1 }
        )
        return Harness(
            manager: SpotlightMenuItemManager(
                environment: environment,
                notificationCenter: notificationCenter
            ),
            store: store
        )
    }

    private struct Harness {
        let manager: SpotlightMenuItemManager
        let store: InMemoryEnvironment
    }

    private final class InMemoryEnvironment {
        var hidden: Bool?
        var writes: [Bool?] = []
        var synchronizeCount = 0
        var restartCount = 0

        init(hidden: Bool?) {
            self.hidden = hidden
        }

        func writeHidden(_ value: Bool?) -> Bool {
            guard hidden != value else {
                return false
            }
            writes.append(value)
            hidden = value
            return true
        }
    }
}
