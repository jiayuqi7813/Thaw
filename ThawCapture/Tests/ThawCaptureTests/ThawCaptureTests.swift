//
//  ThawCaptureTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
@testable import ThawCapture
import XCTest

final class ThawCaptureTests: XCTestCase {
    func testScreenCapturePermissionChecksAllEligibleWindows() {
        XCTAssertTrue(
            ScreenCapture.permissionGranted(
                windowTitles: [nil, "Clock"],
                preflightResult: false
            )
        )
    }

    func testScreenCapturePermissionUsesPreflightFallback() {
        XCTAssertTrue(
            ScreenCapture.permissionGranted(
                windowTitles: [nil],
                preflightResult: true
            )
        )
    }

    func testScreenCapturePermissionRejectsUntitledWindowsWithoutPreflight() {
        XCTAssertFalse(
            ScreenCapture.permissionGranted(
                windowTitles: [nil, nil],
                preflightResult: false
            )
        )
    }

    func testScreenCapturePermissionPromptTemporarilyUsesRegularActivationPolicy() {
        var appliedPolicies = [NSApplication.ActivationPolicy]()
        var didActivate = false
        let restore = ScreenCapture.restoreActivationPolicyAfterScreenCapturePrompt(
            currentPolicy: .accessory,
            setActivationPolicy: { policy in
                appliedPolicies.append(policy)
                return true
            },
            activate: { didActivate = true }
        )
        XCTAssertEqual(appliedPolicies, [.regular])
        XCTAssertTrue(didActivate)
        restore?()
        XCTAssertEqual(appliedPolicies, [.regular, .accessory])
    }

    func testScreenCapturePermissionPromptDoesNotRestoreAlreadyRegularApp() {
        var appliedPolicies = [NSApplication.ActivationPolicy]()
        var didActivate = false
        let restore = ScreenCapture.restoreActivationPolicyAfterScreenCapturePrompt(
            currentPolicy: .regular,
            setActivationPolicy: { policy in
                appliedPolicies.append(policy)
                return true
            },
            activate: { didActivate = true }
        )
        XCTAssertTrue(appliedPolicies.isEmpty)
        XCTAssertTrue(didActivate)
        XCTAssertNil(restore)
    }

    func testProbeLoggingDefaultsToDisabled() {
        XCTAssertFalse(ScreenCapture.isProbeLoggingEnabled())
    }

    @available(macOS 27, *)
    func testHostingStreamRebindsWithoutAStream() {
        XCTAssertTrue(shouldRebind(hasStream: false))
    }

    @available(macOS 27, *)
    func testHostingStreamRebindsForADifferentDisplay() {
        XCTAssertTrue(shouldRebind(boundDisplayID: 2))
    }

    @available(macOS 27, *)
    func testHostingStreamRebindsWhenSinkStopped() {
        XCTAssertTrue(shouldRebind(sinkStopped: true))
    }

    @available(macOS 27, *)
    func testHostingStreamRebindsAfterResolveInterval() {
        XCTAssertTrue(shouldRebind(timeSinceLastResolve: 1.1))
    }

    @available(macOS 27, *)
    func testHostingStreamKeepsHealthyCurrentBinding() {
        XCTAssertFalse(shouldRebind())
    }

    @available(macOS 27, *)
    func testHostingStreamUsesLowFrameRateAndAmortizedResolution() {
        XCTAssertEqual(MenuBarHostingWindowStreamer.targetFrameRate, 8)
        XCTAssertEqual(MenuBarHostingWindowStreamer.defaultReresolveInterval, 5)
    }

    @available(macOS 27, *)
    func testReleasingOldLeaseDoesNotDeactivateNewConsumer() async {
        let streamer = MenuBarHostingWindowStreamer()
        let oldLease = await streamer.begin()
        let newLease = await streamer.begin()

        await streamer.end(oldLease)
        let countAfterOldConsumerEnds = await streamer.activeLeaseCount
        XCTAssertEqual(countAfterOldConsumerEnds, 1)

        await streamer.end(newLease)
        let finalCount = await streamer.activeLeaseCount
        XCTAssertEqual(finalCount, 0)
    }

    @available(macOS 27, *)
    private func shouldRebind(
        hasStream: Bool = true,
        boundDisplayID: CGDirectDisplayID? = 1,
        sinkStopped: Bool = false,
        timeSinceLastResolve: TimeInterval = 0.9
    ) -> Bool {
        MenuBarHostingWindowStreamer.shouldRebind(
            hasStream: hasStream,
            boundDisplayID: boundDisplayID,
            requestedDisplayID: 1,
            sinkStopped: sinkStopped,
            timeSinceLastResolve: timeSinceLastResolve,
            reresolveInterval: 1
        )
    }
}
