//
//  RuntimeSessionControllerTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import PlatformRuntimeKit
import XCTest

@MainActor
final class RuntimeSessionControllerTests: XCTestCase {
    func testResolveConcealmentHidesBundleWhenNoSiblingVisible() {
        let result = RuntimeSessionController.resolveConcealment(
            sectionAssignment: ["hidden-item": .hidden],
            allItems: [],
            knownBundleIDs: ["hidden-item": "com.example.hidden"],
            knownSystemItemIDs: [:]
        )

        XCTAssertEqual(result.concealedBundleIDs, ["com.example.hidden"])
    }

    func testResolveConcealmentKeepsBundleWhenSiblingVisible() {
        let visible = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.example.app", title: "Visible"),
            windowID: 1
        )

        let result = RuntimeSessionController.resolveConcealment(
            sectionAssignment: ["hidden-item": .hidden],
            allItems: [visible],
            knownBundleIDs: [
                "hidden-item": "com.example.app",
                visible.uniqueIdentifier: "com.example.app",
            ],
            knownSystemItemIDs: [:]
        )

        XCTAssertFalse(result.concealedBundleIDs.contains("com.example.app"))
    }

    func testResolveConcealmentNeverConcealsProtectedBundle() {
        let protected = RuntimeSessionController.protectedBundleIDs.first ?? "com.stonerl.Thaw"

        let result = RuntimeSessionController.resolveConcealment(
            sectionAssignment: ["hidden-item": .hidden],
            allItems: [],
            knownBundleIDs: ["hidden-item": protected],
            knownSystemItemIDs: [:],
            protectedBundleIDs: [protected]
        )

        XCTAssertTrue(result.concealedBundleIDs.isEmpty)
    }

    func testResolveConcealmentNeverConcealsDenylistedBundle() {
        let result = RuntimeSessionController.resolveConcealment(
            sectionAssignment: ["hidden-item": .hidden],
            allItems: [],
            knownBundleIDs: ["hidden-item": "com.example.denylisted"],
            knownSystemItemIDs: [:],
            hidingUnsupportedBundleIDs: ["com.example.denylisted"]
        )

        XCTAssertTrue(result.concealedBundleIDs.isEmpty)
    }

    func testShouldReactivateFirstActivation() {
        XCTAssertTrue(
            RuntimeSessionController.shouldReactivate(
                handleIsNil: true,
                concealedChanged: false,
                systemItemsChanged: false,
                newlyAppeared: false,
                desiredAllowed: ["com.example.allowed"],
                desiredSystemItems: RuntimeSessionController.allSystemItems,
                desiredConcealed: ["com.example.hidden"],
                previousConfig: nil,
                lastFailed: nil,
                antiFlapWindow: .seconds(3),
                now: ContinuousClock.now
            )
        )
    }

    func testShouldReactivateNoChangeSteadyState() {
        XCTAssertFalse(
            RuntimeSessionController.shouldReactivate(
                handleIsNil: false,
                concealedChanged: false,
                systemItemsChanged: false,
                newlyAppeared: false,
                desiredAllowed: ["com.example.allowed"],
                desiredSystemItems: RuntimeSessionController.allSystemItems,
                desiredConcealed: ["com.example.hidden"],
                previousConfig: nil,
                lastFailed: nil,
                antiFlapWindow: .seconds(3),
                now: ContinuousClock.now
            )
        )
    }

    func testShouldReactivateSuppressesFlapWithinWindow() {
        let now = ContinuousClock.now

        XCTAssertFalse(
            RuntimeSessionController.shouldReactivate(
                handleIsNil: false,
                concealedChanged: true,
                systemItemsChanged: false,
                newlyAppeared: false,
                desiredAllowed: ["com.example.allowed"],
                desiredSystemItems: RuntimeSessionController.allSystemItems,
                desiredConcealed: ["com.example.hidden"],
                previousConfig: (
                    allowed: ["com.example.allowed"],
                    systemItems: RuntimeSessionController.allSystemItems,
                    concealed: ["com.example.hidden"],
                    at: now - .seconds(1)
                ),
                lastFailed: nil,
                antiFlapWindow: .seconds(3),
                now: now
            )
        )
    }

    func testShouldReactivateRetriesAfterGenuineChange() {
        XCTAssertTrue(
            RuntimeSessionController.shouldReactivate(
                handleIsNil: false,
                concealedChanged: true,
                systemItemsChanged: false,
                newlyAppeared: false,
                desiredAllowed: ["com.example.allowed"],
                desiredSystemItems: RuntimeSessionController.allSystemItems,
                desiredConcealed: ["com.example.hidden"],
                previousConfig: nil,
                lastFailed: (
                    allowed: ["com.example.allowed"],
                    systemItems: RuntimeSessionController.allSystemItems.subtracting([0])
                ),
                antiFlapWindow: .seconds(3),
                now: ContinuousClock.now
            )
        )
    }

    func testShouldReactivateSuppressesIdenticalFailedConfig() {
        XCTAssertFalse(
            RuntimeSessionController.shouldReactivate(
                handleIsNil: false,
                concealedChanged: true,
                systemItemsChanged: false,
                newlyAppeared: false,
                desiredAllowed: ["com.example.allowed"],
                desiredSystemItems: RuntimeSessionController.allSystemItems,
                desiredConcealed: ["com.example.hidden"],
                previousConfig: nil,
                lastFailed: (
                    allowed: ["com.example.allowed"],
                    systemItems: RuntimeSessionController.allSystemItems
                ),
                antiFlapWindow: .seconds(3),
                now: ContinuousClock.now
            )
        )
    }

    func testIsHidingAvailableMirrorsIsAvailableAtInit() {
        let backend = RuntimeSessionController()

        XCTAssertEqual(backend.isHidingAvailable, RuntimeSessionController.isAvailable)
    }

    func testRefreshAvailabilityReturnsCurrentIsAvailable() {
        let backend = RuntimeSessionController()

        let refreshed = backend.refreshAvailability()

        XCTAssertEqual(refreshed, RuntimeSessionController.isAvailable)
        XCTAssertEqual(backend.isHidingAvailable, RuntimeSessionController.isAvailable)
    }
}
