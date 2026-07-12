//
//  AssessmentStateMonitorTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

@MainActor
final class AssessmentStateMonitorTests: XCTestCase {
    func testStateChangeRequestsReconciliation() async {
        let expectation = expectation(description: "reconcile requested")
        let center = DistributedNotificationCenter()
        let monitor = AssessmentStateMonitor(center: center) {
            expectation.fulfill()
        }
        monitor.start()

        center.postNotificationName(
            AssessmentStateMonitor.stateChangedNotification,
            object: nil,
            deliverImmediately: true
        )

        await fulfillment(of: [expectation], timeout: 1)
        monitor.stop()
    }

    func testSelfChangeSuppressesWholeBurst() async {
        // A single recovery re-apply posts more than one `stateChanged`. All of
        // them must be swallowed inside the self-change window — consuming only
        // the first would let the second re-enter recovery and loop.
        let reconcile = expectation(description: "reconcile requested")
        reconcile.isInverted = true
        let center = DistributedNotificationCenter()
        let monitor = AssessmentStateMonitor(center: center) {
            reconcile.fulfill()
        }
        monitor.start()

        monitor.noteSelfChange()
        for _ in 0 ..< 4 {
            center.postNotificationName(
                AssessmentStateMonitor.stateChangedNotification,
                object: nil,
                deliverImmediately: true
            )
        }

        await fulfillment(of: [reconcile], timeout: 0.8)
        monitor.stop()
    }

    func testSelfChangeArmedBeforeMutationSuppressesImmediateNotification() async {
        let reconcile = expectation(description: "reconcile requested")
        reconcile.isInverted = true
        let center = DistributedNotificationCenter()
        let monitor = AssessmentStateMonitor(center: center) {
            reconcile.fulfill()
        }
        monitor.start()

        monitor.noteSelfChange()
        center.postNotificationName(
            AssessmentStateMonitor.stateChangedNotification,
            object: nil,
            deliverImmediately: true
        )

        await fulfillment(of: [reconcile], timeout: 0.8)
        monitor.stop()
    }
}
