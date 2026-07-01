//
//  SimpleItemHiderTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

/// Characterizes `SimpleItemHider`'s instance lifecycle against fakes for its
/// five collaborators. `refresh()` (and everything that calls it — `show`,
/// `hideRevealedSections`, `setSection`, `revealItemTemporarily`) guards on
/// `appState` being non-nil as its very first line, so constructing the
/// hider with `appState: nil` exercises the guard itself (a real no-op
/// production path when the item manager hasn't attached yet) while still
/// letting the reveal/assignment state transitions run and be observed
/// through the hider's own internal (non-private) accessors.
@MainActor
final class SimpleItemHiderTests: XCTestCase {
    final class FakeAssessmentModeBackend: AssessmentModeBackending {
        private(set) var applyCallCount = 0
        private(set) var pulseCallCount = 0
        private(set) var markExternallyTornDownCallCount = 0
        var applyResult = false

        func apply(sectionAssignment _: [String: MenuBarSection.Name], allItems _: [MenuBarItem]) -> Bool {
            applyCallCount += 1
            return applyResult
        }

        func pulse(sectionAssignment _: [String: MenuBarSection.Name], allItems _: [MenuBarItem]) -> Bool {
            pulseCallCount += 1
            return false
        }

        func markExternallyTornDown() {
            markExternallyTornDownCallCount += 1
        }
    }

    final class FakeControlCenterModuleManager: ControlCenterModuleManaging {
        private(set) var applyCallCount = 0

        func apply(hiddenMenuExtraTitles _: Set<String>) -> Bool {
            applyCallCount += 1
            return false
        }
    }

    final class FakeCGSWindowHider: CGSWindowHiding {
        private(set) var applyCallCount = 0

        func apply(hiddenPIDs _: Set<pid_t>) -> Set<pid_t> {
            applyCallCount += 1
            return []
        }
    }

    final class FakeAXItemHider: AXItemHiding {
        private(set) var applyCallCount = 0

        func apply(hiddenPIDs _: Set<pid_t>, allItems _: [MenuBarItem]) -> Set<pid_t> {
            applyCallCount += 1
            return []
        }
    }

    final class FakeTrailingItemPositionStore: TrailingItemPositioning {
        private(set) var hasHiddenItems = false
        private(set) var restoreAllCallCount = 0
        var storedPositions: [String: Int] = [:]

        func readPositions() -> [String: Int] { storedPositions }
        func writePositions(_ dict: [String: Int]) { storedPositions = dict }
        func restoreAll() { restoreAllCallCount += 1 }

        func hideItems(_: [MenuBarItem]) -> Set<String> {
            hasHiddenItems = true
            return []
        }

        func showItems(_: [MenuBarItem], allItems _: [MenuBarItem]) -> Set<String> {
            hasHiddenItems = false
            return []
        }

        func lockVisiblePositions(visibleItemKeys _: Set<String>, allItems _: [MenuBarItem]) -> Set<String> {
            []
        }
    }

    private var backend: FakeAssessmentModeBackend!
    private var ccModuleManager: FakeControlCenterModuleManager!
    private var cgsWindowHider: FakeCGSWindowHider!
    private var axItemHider: FakeAXItemHider!
    private var positionStore: FakeTrailingItemPositionStore!

    override func setUp() {
        super.setUp()
        backend = FakeAssessmentModeBackend()
        ccModuleManager = FakeControlCenterModuleManager()
        cgsWindowHider = FakeCGSWindowHider()
        axItemHider = FakeAXItemHider()
        positionStore = FakeTrailingItemPositionStore()
    }

    private func makeHider() -> SimpleItemHider {
        SimpleItemHider(
            appState: nil,
            backend: backend,
            ccModuleManager: ccModuleManager,
            cgsWindowHider: cgsWindowHider,
            axItemHider: axItemHider,
            positionStore: positionStore
        )
    }

    func testRefresh_NoOpsWithoutAttachedAppState() {
        let hider = makeHider()

        hider.refresh()

        // refresh() guards on `appState` being non-nil as its very first
        // line; with no item manager attached yet (the real state before
        // AppState finishes wiring up), the backend must never be touched.
        XCTAssertEqual(backend.applyCallCount, 0)
    }

    func testShow_RevealsOnlyRequestedSection() {
        let hider = makeHider()

        hider.show(.hidden)

        XCTAssertEqual(hider.revealedSection, .hidden)
    }

    func testShow_IsIdempotentForSameSection() {
        let hider = makeHider()

        hider.show(.hidden)
        hider.show(.hidden)

        // Second call with the same already-revealed target returns early
        // (guarded by `revealedSection != target`); refresh() is a no-op
        // either way here, so this only characterizes the reveal state
        // itself, not call counts into refresh().
        XCTAssertEqual(hider.revealedSection, .hidden)
    }

    func testHideRevealedSections_ClearsReveal() {
        let hider = makeHider()
        hider.show(.hidden)
        XCTAssertEqual(hider.revealedSection, .hidden)

        hider.hideRevealedSections()

        XCTAssertNil(hider.revealedSection)
    }

    func testHideRevealedSections_NoOpsWhenNothingRevealed() {
        let hider = makeHider()

        // Must not crash or misbehave when called with nothing revealed.
        hider.hideRevealedSections()

        XCTAssertNil(hider.revealedSection)
    }

    func testSetSection_PersistsAssignment() {
        let hider = makeHider()
        let identifier = "com.example.app:Item-0"

        hider.setSection(.hidden, identifier: identifier)

        XCTAssertEqual(hider.section(for: identifier), .hidden)
    }

    func testSetSection_RejectsControlItemIdentifier() {
        let hider = makeHider()
        let controlItemIdentifier = ControlItem.Identifier.hidden.rawValue

        hider.setSection(.hidden, identifier: controlItemIdentifier)

        // Control-item identifiers can never be assigned a section — they're
        // the dividers themselves, not hideable app items.
        XCTAssertEqual(hider.section(for: controlItemIdentifier), .visible)
    }
}
