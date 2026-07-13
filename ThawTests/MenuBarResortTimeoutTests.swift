//
//  MenuBarResortTimeoutTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

final class MenuBarResortTimeoutTests: XCTestCase {
    func testResortAttemptCountPreservesThreeSecondDefault() {
        XCTAssertEqual(
            MenuBarItemManager.menuBarAgentResortAttemptCount(
                timeout: 3,
                interval: .milliseconds(250)
            ),
            12
        )
    }

    func testResortAttemptCountUsesConfiguredFulfillmentWindow() {
        XCTAssertEqual(
            MenuBarItemManager.menuBarAgentResortAttemptCount(
                timeout: 5.5,
                interval: .milliseconds(250)
            ),
            22
        )
    }

    func testResortAttemptCountClampsMalformedPersistedValue() {
        XCTAssertEqual(
            MenuBarItemManager.menuBarAgentResortAttemptCount(
                timeout: 99,
                interval: .milliseconds(250)
            ),
            60
        )
    }
}
