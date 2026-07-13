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
            request: { completion in
                isGranted = true
                completion(true)
            }
        )

        XCTAssertFalse(permission.hasPermission)

        permission.performRequest()

        XCTAssertTrue(permission.hasPermission)
    }

    func testAsynchronousRequestCompletionRefreshesPermissionStateImmediately() async {
        var isGranted = false
        let permission = Permission(
            title: "Test Permission",
            iconName: "checkmark",
            iconColor: .green,
            details: [],
            isRequired: true,
            settingsURL: nil,
            check: { isGranted },
            request: { completion in
                Task { @MainActor in
                    isGranted = true
                    completion(true)
                }
            }
        )

        permission.performRequest()
        await Task.yield()

        XCTAssertTrue(permission.hasPermission)
    }

    func testAsynchronousRefreshRecognizesGrantWithoutRelaunch() async {
        let permission = Permission(
            title: "Test Permission",
            iconName: "checkmark",
            iconColor: .green,
            details: [],
            isRequired: false,
            settingsURL: nil,
            check: { false },
            asyncCheck: { true },
            request: { _ in }
        )

        await permission.refreshStatus()

        XCTAssertTrue(permission.hasPermission)
    }
}
