//
//  MenuBarItemGeometryTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

final class MenuBarItemGeometryTests: XCTestCase {
    func testMaxOnBarMidYPinsHistoricalThreshold() {
        XCTAssertEqual(MenuBarItemGeometry.maxOnBarMidY, 80)
    }
}
