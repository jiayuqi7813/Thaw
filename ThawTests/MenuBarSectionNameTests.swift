//
//  MenuBarSectionNameTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

// MARK: - MenuBarSection.Name Tests

final class MenuBarSectionNameTests: XCTestCase {
    // MARK: - CaseIterable

    func testAllCasesCount() {
        XCTAssertEqual(MenuBarSection.Name.allCases.count, 3)
    }

    func testAllCasesContainsVisible() {
        XCTAssertTrue(MenuBarSection.Name.allCases.contains(.visible))
    }

    func testAllCasesContainsHidden() {
        XCTAssertTrue(MenuBarSection.Name.allCases.contains(.hidden))
    }

    func testAllCasesContainsAlwaysHidden() {
        XCTAssertTrue(MenuBarSection.Name.allCases.contains(.alwaysHidden))
    }

    // MARK: - displayString

    func testDisplayStringVisible() {
        XCTAssertEqual(MenuBarSection.Name.visible.displayString, "Visible")
    }

    func testDisplayStringHidden() {
        XCTAssertEqual(MenuBarSection.Name.hidden.displayString, "Hidden")
    }

    func testDisplayStringAlwaysHidden() {
        XCTAssertEqual(MenuBarSection.Name.alwaysHidden.displayString, "Always-Hidden")
    }

    func testAllDisplayStringsNonEmpty() {
        for name in MenuBarSection.Name.allCases {
            XCTAssertFalse(name.displayString.isEmpty, "\(name) should have non-empty displayString")
        }
    }

    // MARK: - logString

    func testLogStringVisible() {
        XCTAssertEqual(MenuBarSection.Name.visible.logString, "visible section")
    }

    func testLogStringHidden() {
        XCTAssertEqual(MenuBarSection.Name.hidden.logString, "hidden section")
    }

    func testLogStringAlwaysHidden() {
        XCTAssertEqual(MenuBarSection.Name.alwaysHidden.logString, "always-hidden section")
    }

    func testAllLogStringsContainSection() {
        for name in MenuBarSection.Name.allCases {
            XCTAssertTrue(name.logString.contains("section"), "\(name).logString should contain 'section'")
        }
    }

    // MARK: - localized

    func testLocalizedVisible() {
        // LocalizedStringKey doesn't expose its value directly, but we can verify it exists
        let localized = MenuBarSection.Name.visible.localized
        XCTAssertNotNil(localized)
    }

    func testLocalizedHidden() {
        let localized = MenuBarSection.Name.hidden.localized
        XCTAssertNotNil(localized)
    }

    func testLocalizedAlwaysHidden() {
        let localized = MenuBarSection.Name.alwaysHidden.localized
        XCTAssertNotNil(localized)
    }

    // MARK: - notchGap Static Constant

    func testNotchGapValue() {
        XCTAssertEqual(MenuBarSection.notchGap, 24)
    }

    func testNotchGapIsPositive() {
        XCTAssertGreaterThan(MenuBarSection.notchGap, 0)
    }

    // MARK: - Presentation Mode

    private func capacity(
        width: CGFloat = 1200,
        appMenuRightEdge: CGFloat? = 250,
        notchFrame: CGRect? = nil
    ) -> MenuBarCapacitySnapshot {
        MenuBarCapacitySnapshot(
            displayID: 1,
            displayBounds: CGRect(x: 0, y: 0, width: width, height: 800),
            notchFrame: notchFrame,
            applicationMenuFrame: appMenuRightEdge.map {
                CGRect(x: 0, y: 0, width: $0, height: 30)
            },
            trailingBoundary: width,
            overflowControlBounds: []
        )
    }

    func testPresentationModeUsesInlineWhenItemsAlreadyFit() {
        let mode = MenuBarSection.presentationMode(
            totalItemsWidth: 300,
            capacity: capacity(),
            allowHidingApplicationMenus: false
        )

        XCTAssertEqual(mode, .inline)
    }

    func testPresentationModeFallsBackToIceBarWhenItemsDoNotFitAndHidingMenusIsDisabled() {
        let mode = MenuBarSection.presentationMode(
            totalItemsWidth: 1000,
            capacity: capacity(appMenuRightEdge: 350),
            allowHidingApplicationMenus: false
        )

        XCTAssertEqual(mode, .iceBar)
    }

    func testPresentationModeHidesApplicationMenusBeforeUsingIceBar() {
        let mode = MenuBarSection.presentationMode(
            totalItemsWidth: 1000,
            capacity: capacity(appMenuRightEdge: 350),
            allowHidingApplicationMenus: true
        )

        XCTAssertEqual(mode, .inlineHidingApplicationMenus)
    }

    func testPresentationModeStillUsesIceBarWhenItemsCannotFitEvenAfterHidingMenus() {
        let mode = MenuBarSection.presentationMode(
            totalItemsWidth: 1400,
            capacity: capacity(appMenuRightEdge: 350),
            allowHidingApplicationMenus: true
        )

        XCTAssertEqual(mode, .iceBar)
    }

    func testUsableInlineWidthAccountsForNotchGapOnBothSides() {
        let width = capacity(
            width: 1600,
            appMenuRightEdge: 200,
            notchFrame: CGRect(x: 700, y: 0, width: 200, height: 30)
        ).availableWidth(
            in: .inline,
            applicationMenus: .visible
        )

        XCTAssertEqual(width, 1152)
    }
}
