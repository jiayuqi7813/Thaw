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

    @available(macOS 27, *)
    func testPixelBackedWindowFrameDoesNotDoubleScaleCaptureSize() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let pixelWindowFrame = CGRect(x: 0, y: 0, width: 3024, height: 74)
        XCTAssertTrue(
            ScreenCapture.windowFrameAppearsPixelBacked(pixelWindowFrame, displayFrame: displayFrame)
        )
        let size = ScreenCapture.hostingCapturePixelSize(
            windowFrame: pixelWindowFrame,
            displayFrame: displayFrame,
            reportedScale: 2
        )
        XCTAssertEqual(size.width, 3024)
        XCTAssertEqual(size.height, 74)
    }

    @available(macOS 27, *)
    func testPointSpaceWindowFrameMultipliesByReportedScale() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let pointWindowFrame = CGRect(x: 0, y: 0, width: 1512, height: 37)
        XCTAssertFalse(
            ScreenCapture.windowFrameAppearsPixelBacked(pointWindowFrame, displayFrame: displayFrame)
        )
        let size = ScreenCapture.hostingCapturePixelSize(
            windowFrame: pointWindowFrame,
            displayFrame: displayFrame,
            reportedScale: 2
        )
        XCTAssertEqual(size.width, 3024)
        XCTAssertEqual(size.height, 74)
    }

    @available(macOS 27, *)
    func testNormalizedHostingCaptureRewritesPixelBackedFrameToPoints() throws {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let pixelWindowFrame = CGRect(x: 0, y: 0, width: 3024, height: 74)
        let image = try XCTUnwrap(makeTestImage(width: 3024, height: 74))

        let normalized = try XCTUnwrap(
            ScreenCapture.normalizedHostingCapture(
                image: image,
                windowFrame: pixelWindowFrame,
                displayFrame: displayFrame,
                reportedScale: 2
            )
        )
        XCTAssertEqual(normalized.scale, 2, accuracy: 0.001)
        XCTAssertEqual(normalized.windowFrame.width, 1512, accuracy: 0.001)
        XCTAssertEqual(normalized.windowFrame.height, 37, accuracy: 0.001)
        XCTAssertEqual(normalized.windowFrame.origin, displayFrame.origin)
    }

    @available(macOS 27, *)
    func testNormalizedHostingCaptureDerivesScaleFromBitmapForPointFrames() throws {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let pointWindowFrame = CGRect(x: 0, y: 0, width: 1512, height: 37)
        let image = try XCTUnwrap(makeTestImage(width: 3024, height: 74))

        let normalized = try XCTUnwrap(
            ScreenCapture.normalizedHostingCapture(
                image: image,
                windowFrame: pointWindowFrame,
                displayFrame: displayFrame,
                reportedScale: 1 // deliberately wrong — bitmap says 2×
            )
        )
        XCTAssertEqual(normalized.scale, 2, accuracy: 0.001)
        XCTAssertEqual(normalized.windowFrame, pointWindowFrame)
    }

    @available(macOS 27, *)
    func testWindowMatchesMenuBarStripGeometryAcceptsPointAndPixelFrames() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertTrue(
            ScreenCapture.windowMatchesMenuBarStripGeometry(
                CGRect(x: 0, y: 0, width: 1512, height: 37),
                displayFrame: displayFrame
            )
        )
        XCTAssertTrue(
            ScreenCapture.windowMatchesMenuBarStripGeometry(
                CGRect(x: 0, y: 0, width: 3024, height: 74),
                displayFrame: displayFrame
            )
        )
        XCTAssertFalse(
            ScreenCapture.windowMatchesMenuBarStripGeometry(
                CGRect(x: 0, y: 0, width: 200, height: 24),
                displayFrame: displayFrame
            )
        )
    }

    @available(macOS 27, *)
    func testMenuBarDisplayStripFramePinsToDisplayTop() {
        let displayFrame = CGRect(x: 100, y: 50, width: 1512, height: 982)
        let strip = ScreenCapture.menuBarDisplayStripFrame(displayFrame: displayFrame, height: 40)
        XCTAssertEqual(strip.origin, displayFrame.origin)
        XCTAssertEqual(strip.width, displayFrame.width)
        XCTAssertEqual(strip.height, 40)
    }

    @available(macOS 27, *)
    func testMenuBarDisplayStripFrameClampsToDisplayHeight() {
        let displayFrame = CGRect(x: 0, y: 0, width: 800, height: 24)
        let strip = ScreenCapture.menuBarDisplayStripFrame(displayFrame: displayFrame, height: 40)
        XCTAssertEqual(strip.height, 24)
    }

    private func makeTestImage(width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }
}
