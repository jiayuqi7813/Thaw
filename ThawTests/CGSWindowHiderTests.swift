//
//  RuntimeWindowControllerTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import PlatformRuntimeKit
import XCTest

// MARK: - RuntimeWindowController Tests

/// Covers the off-screen hide/restore bookkeeping through an in-memory window
/// server. No real CGS calls are made.
@MainActor
final class RuntimeWindowControllerTests: XCTestCase {
    func testApplyMovesProcessWindowsOffScreenAndRestoresOnRemoval() {
        // pid 100 owns two menu-bar windows at known origins.
        let store = FakeWindowServer(
            windowsByPID: [100: [10, 11]],
            origins: [10: CGPoint(x: 200, y: 0), 11: CGPoint(x: 240, y: 0)]
        )
        let hider = makeHider(store)

        XCTAssertEqual(hider.apply(hiddenPIDs: [100]), [100])
        XCTAssertEqual(store.origins[10]?.x, RuntimeWindowController.offScreenX)
        XCTAssertEqual(store.origins[11]?.x, RuntimeWindowController.offScreenX)

        // Removing the pid from the set restores the original origins exactly.
        XCTAssertEqual(hider.apply(hiddenPIDs: []), [])
        XCTAssertEqual(store.origins[10], CGPoint(x: 200, y: 0))
        XCTAssertEqual(store.origins[11], CGPoint(x: 240, y: 0))
    }

    func testReapplyIsIdempotentWhenNothingChanges() {
        let store = FakeWindowServer(
            windowsByPID: [100: [10]],
            origins: [10: CGPoint(x: 200, y: 0)]
        )
        let hider = makeHider(store)

        XCTAssertEqual(hider.apply(hiddenPIDs: [100]), [100])
        let movesAfterFirst = store.moveCount
        // A second identical apply re-asserts the off-screen position (reflow
        // guard) but must never re-capture the off-screen point as "original".
        hider.apply(hiddenPIDs: [100])
        XCTAssertGreaterThanOrEqual(store.moveCount, movesAfterFirst)

        hider.apply(hiddenPIDs: [])
        XCTAssertEqual(store.origins[10], CGPoint(x: 200, y: 0), "original must survive re-applies")
    }

    func testRestoreAllReturnsEveryHiddenWindow() {
        let store = FakeWindowServer(
            windowsByPID: [100: [10], 200: [20]],
            origins: [10: CGPoint(x: 200, y: 0), 20: CGPoint(x: 300, y: 0)]
        )
        let hider = makeHider(store)

        hider.apply(hiddenPIDs: [100, 200])
        XCTAssertEqual(store.origins[10]?.x, RuntimeWindowController.offScreenX)
        XCTAssertEqual(store.origins[20]?.x, RuntimeWindowController.offScreenX)

        hider.restoreAll()
        XCTAssertEqual(store.origins[10], CGPoint(x: 200, y: 0))
        XCTAssertEqual(store.origins[20], CGPoint(x: 300, y: 0))
    }

    func testTerminationRestoresHiddenWindows() {
        let notificationCenter = NotificationCenter()
        let store = FakeWindowServer(
            windowsByPID: [100: [10]],
            origins: [10: CGPoint(x: 200, y: 0)]
        )
        let hider = makeHider(store, notificationCenter: notificationCenter)

        hider.apply(hiddenPIDs: [100])
        XCTAssertEqual(store.origins[10]?.x, RuntimeWindowController.offScreenX)

        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(store.origins[10], CGPoint(x: 200, y: 0))
    }

    private func makeHider(
        _ store: FakeWindowServer,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> RuntimeWindowController {
        let environment = RuntimeWindowController.Environment(
            menuBarWindowIDs: { store.windowsByPID[$0] ?? [] },
            windowOrigin: { store.origins[$0] },
            moveWindow: { store.move($0, to: $1) }
        )
        return RuntimeWindowController(environment: environment, notificationCenter: notificationCenter)
    }

    private final class FakeWindowServer {
        let windowsByPID: [pid_t: [CGWindowID]]
        var origins: [CGWindowID: CGPoint]
        var moveCount = 0

        init(windowsByPID: [pid_t: [CGWindowID]], origins: [CGWindowID: CGPoint]) {
            self.windowsByPID = windowsByPID
            self.origins = origins
        }

        func move(_ windowID: CGWindowID, to origin: CGPoint) -> Bool {
            origins[windowID] = origin
            moveCount += 1
            return true
        }
    }
}
