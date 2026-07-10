//
//  MenuBarAgentPreferencesWatcherTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

@MainActor
final class MenuBarAgentPreferencesWatcherTests: XCTestCase {
    func testFileEventWithUnchangedPositionsDoesNotReportExternalChange() async throws {
        let fileURL = try makePreferencesFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let externalChange = expectation(description: "external change")
        externalChange.isInverted = true
        let positions = ["status:com.test::Item": 100]
        let watcher = MenuBarAgentPreferencesWatcher(
            path: fileURL.path,
            readPositions: { positions },
            onExternalChange: { _ in externalChange.fulfill() }
        )
        watcher.start()
        defer { watcher.stop() }

        try Data("same positions, different plist bytes".utf8).write(to: fileURL)

        await fulfillment(of: [externalChange], timeout: 0.8)
    }

    func testSelfWriteWindowSuppressesChangedPositions() async throws {
        let fileURL = try makePreferencesFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let externalChange = expectation(description: "external change")
        externalChange.isInverted = true
        var positions = ["status:com.test::Item": 100]
        let watcher = MenuBarAgentPreferencesWatcher(
            path: fileURL.path,
            readPositions: { positions },
            onExternalChange: { _ in externalChange.fulfill() }
        )
        watcher.start()
        defer { watcher.stop() }

        positions["status:com.test::Item"] = 200
        try Data("self write".utf8).write(to: fileURL)
        watcher.noteSelfWrite()

        await fulfillment(of: [externalChange], timeout: 0.8)
    }

    func testExternalChangeDuringSelfWriteWindowIsReportedAfterWindow() async throws {
        let fileURL = try makePreferencesFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let externalChange = expectation(description: "external change")
        var positions = ["status:com.test::Item": 100]
        let watcher = MenuBarAgentPreferencesWatcher(
            path: fileURL.path,
            readPositions: { positions },
            onExternalChange: { changedPositions in
                XCTAssertEqual(changedPositions["status:com.test::Item"], 300)
                externalChange.fulfill()
            }
        )
        watcher.start()
        defer { watcher.stop() }

        positions["status:com.test::Item"] = 200
        try Data("self write".utf8).write(to: fileURL)
        watcher.noteSelfWrite()

        positions["status:com.test::Item"] = 300
        try Data("external write".utf8).write(to: fileURL)

        await fulfillment(of: [externalChange], timeout: 2.5)
    }

    func testAtomicReplacementRearmsWatcherForLaterChanges() async throws {
        let fileURL = try makePreferencesFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let firstChange = expectation(description: "first external change")
        let secondChange = expectation(description: "second external change")
        var positions = ["status:com.test::Item": 100]
        var callbackCount = 0
        let watcher = MenuBarAgentPreferencesWatcher(
            path: fileURL.path,
            readPositions: { positions },
            onExternalChange: { _ in
                callbackCount += 1
                if callbackCount == 1 {
                    firstChange.fulfill()
                } else if callbackCount == 2 {
                    secondChange.fulfill()
                }
            }
        )
        watcher.start()
        defer { watcher.stop() }

        positions["status:com.test::Item"] = 200
        try Data("first replacement".utf8).write(to: fileURL, options: .atomic)
        await fulfillment(of: [firstChange], timeout: 2)

        positions["status:com.test::Item"] = 300
        try Data("second replacement".utf8).write(to: fileURL, options: .atomic)
        await fulfillment(of: [secondChange], timeout: 2)
    }

    private func makePreferencesFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThawPrefsWatcherTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("com.apple.MenuBarAgent.plist")
        try Data("initial".utf8).write(to: fileURL)
        return fileURL
    }
}
