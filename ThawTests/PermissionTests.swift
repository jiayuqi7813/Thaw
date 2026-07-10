//
//  PermissionTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

@MainActor
final class PermissionTests: XCTestCase {
    func testPerformRequestRefreshesPermissionState() {
        var isGranted = false
        let permission = Permission(
            title: "Test Permission",
            iconName: "checkmark",
            iconColor: .green,
            details: [],
            isRequired: true,
            settingsURL: nil,
            check: { isGranted },
            request: { isGranted = true }
        )

        XCTAssertFalse(permission.hasPermission)

        permission.performRequest()

        XCTAssertTrue(permission.hasPermission)
    }
}
