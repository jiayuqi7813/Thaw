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

    func testSelfChangeConsumesOnlyOneNotificationFromBurst() async {
        let expectation = expectation(description: "external reconcile requested")
        let center = DistributedNotificationCenter()
        let monitor = AssessmentStateMonitor(center: center) {
            expectation.fulfill()
        }
        monitor.start()

        monitor.noteSelfChange()
        center.postNotificationName(
            AssessmentStateMonitor.stateChangedNotification,
            object: nil,
            deliverImmediately: true
        )
        center.postNotificationName(
            AssessmentStateMonitor.stateChangedNotification,
            object: nil,
            deliverImmediately: true
        )

        await fulfillment(of: [expectation], timeout: 1)
        monitor.stop()
    }
}
