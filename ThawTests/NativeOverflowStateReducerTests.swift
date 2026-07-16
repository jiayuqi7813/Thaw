//
//  NativeOverflowStateReducerTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

final class NativeOverflowStateReducerTests: XCTestCase {
    func testDebouncesPresenceAndAbsenceAsymmetrically() {
        var reducer = NativeOverflowStateReducer(presentThreshold: 2, absentThreshold: 3)

        XCTAssertNil(reducer.consume(.present([]), on: 1))
        XCTAssertEqual(reducer.consume(.present([]), on: 1), true)
        XCTAssertTrue(reducer.isActive(on: 1))

        XCTAssertNil(reducer.consume(.absent, on: 1))
        XCTAssertNil(reducer.consume(.absent, on: 1))
        XCTAssertEqual(reducer.consume(.absent, on: 1), false)
        XCTAssertFalse(reducer.isActive(on: 1))
    }

    func testUnavailableObservationPreservesStableStateAndCandidate() {
        var reducer = NativeOverflowStateReducer(presentThreshold: 2, absentThreshold: 2)

        XCTAssertNil(reducer.consume(.present([]), on: 1))
        XCTAssertNil(reducer.consume(.unavailable, on: 1))
        XCTAssertEqual(reducer.consume(.present([]), on: 1), true)
        XCTAssertNil(reducer.consume(.unavailable, on: 1))
        XCTAssertTrue(reducer.isActive(on: 1))
    }

    func testTransientPresenceDoesNotPublish() {
        var reducer = NativeOverflowStateReducer(presentThreshold: 2, absentThreshold: 3)

        XCTAssertNil(reducer.consume(.present([]), on: 1))
        XCTAssertNil(reducer.consume(.absent, on: 1))
        XCTAssertFalse(reducer.isActive(on: 1))
    }

    func testDisplayStatesAreIndependent() {
        var reducer = NativeOverflowStateReducer(presentThreshold: 1, absentThreshold: 1)

        XCTAssertEqual(reducer.consume(.present([]), on: 1), true)
        XCTAssertTrue(reducer.isActive(on: 1))
        XCTAssertFalse(reducer.isActive(on: 2))
        XCTAssertEqual(reducer.consume(.present([]), on: 2), true)
        XCTAssertEqual(reducer.consume(.absent, on: 1), false)
        XCTAssertFalse(reducer.isActive(on: 1))
        XCTAssertTrue(reducer.isActive(on: 2))
    }
}
