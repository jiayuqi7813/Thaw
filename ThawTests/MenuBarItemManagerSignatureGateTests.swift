//
//  MenuBarItemManagerSignatureGateTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

/// Verifies the two-observation stability gate that keeps a transient menu-bar
/// enumeration blip from triggering a full recache + assertion re-apply (the
/// macOS 27 main-thread recache storm that dropped clicks).
@MainActor
final class MenuBarItemManagerSignatureGateTests: XCTestCase {
    private let cached = ["A", "B"]

    func testUnchangedSignatureNeverRecachesAndClearsPending() {
        let decision = MenuBarItemManager.signatureRecacheDecision(
            cached: cached,
            current: cached,
            pending: ["A", "B", "C"] // a stale candidate
        )
        XCTAssertFalse(decision.recache)
        XCTAssertNil(decision.newPending)
    }

    func testFirstDifferenceDefersAndRemembersCandidate() {
        let current = ["A", "B", "C"]
        let decision = MenuBarItemManager.signatureRecacheDecision(
            cached: cached,
            current: current,
            pending: nil
        )
        XCTAssertFalse(decision.recache, "A single-pass difference must not recache")
        XCTAssertEqual(decision.newPending, current)
    }

    func testSecondMatchingDifferenceConfirmsAndRecaches() {
        let current = ["A", "B", "C"]
        let decision = MenuBarItemManager.signatureRecacheDecision(
            cached: cached,
            current: current,
            pending: current // same difference seen last check
        )
        XCTAssertTrue(decision.recache)
        XCTAssertNil(decision.newPending, "Gate resets after confirming")
    }

    func testFlickeringDifferenceKeepsDeferring() {
        // First an extra item, then a different extra item: the difference
        // itself keeps changing, so it never confirms — exactly the transient
        // flicker we want to swallow.
        let first = MenuBarItemManager.signatureRecacheDecision(
            cached: cached,
            current: ["A", "B", "C"],
            pending: nil
        )
        XCTAssertFalse(first.recache)

        let second = MenuBarItemManager.signatureRecacheDecision(
            cached: cached,
            current: ["A", "B", "D"],
            pending: first.newPending
        )
        XCTAssertFalse(second.recache, "A changed difference must re-defer, not recache")
        XCTAssertEqual(second.newPending, ["A", "B", "D"])
    }
}
