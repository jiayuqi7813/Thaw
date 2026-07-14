//
//  SettingsSearchNavigationTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI
import Testing
@testable import Thaw

@Suite("Settings search navigation")
struct SettingsSearchNavigationTests {
    @Test("Same-pane result publishes and consumes its disclosure while clearing the query")
    @MainActor
    func samePaneResultConsumesDisclosureAndClearsQuery() {
        let state = AppNavigationState()
        state.settingsNavigationIdentifier = .menuBarLayout
        var query = "reorder timeout"

        SettingsSearchNavigation.selectSearchResult(
            entry(pane: .menuBarLayout, disclosure: .advancedLayoutControls),
            navigationState: state,
            query: &query
        )

        #expect(state.settingsNavigationIdentifier == .menuBarLayout)
        #expect(state.requestedSettingsDisclosure == .advancedLayoutControls)
        #expect(query.isEmpty)
        #expect(SettingsSearchNavigation.consumeDisclosure(.advancedLayoutControls, navigationState: state))
        #expect(state.requestedSettingsDisclosure == nil)
    }

    @Test("Cross-pane result changes panes and replaces a stale disclosure")
    @MainActor
    func crossPaneResultChangesPaneAndReplacesStaleDisclosure() {
        let state = AppNavigationState()
        state.settingsNavigationIdentifier = .advanced
        state.requestedSettingsDisclosure = .advancedLayoutControls
        var query = "reorder timeout"

        SettingsSearchNavigation.selectSearchResult(
            entry(pane: .menuBarLayout, disclosure: .advancedLayoutControls),
            navigationState: state,
            query: &query
        )

        #expect(state.settingsNavigationIdentifier == .menuBarLayout)
        #expect(state.requestedSettingsDisclosure == .advancedLayoutControls)
        #expect(query.isEmpty)
    }

    @Test("Manual sidebar selection clears a stale disclosure request")
    @MainActor
    func sidebarSelectionClearsStaleDisclosure() {
        let state = AppNavigationState()
        state.settingsNavigationIdentifier = .advanced
        state.requestedSettingsDisclosure = .advancedLayoutControls

        SettingsSearchNavigation.selectSidebarPane(.tools, navigationState: state)

        #expect(state.settingsNavigationIdentifier == .tools)
        #expect(state.requestedSettingsDisclosure == nil)
    }

    @Test("Reappearing sidebar selection does not consume a pending disclosure")
    @MainActor
    func unchangedSidebarSelectionPreservesPendingDisclosure() {
        let state = AppNavigationState()
        state.settingsNavigationIdentifier = .advanced
        state.requestedSettingsDisclosure = .advancedLayoutControls

        SettingsSearchNavigation.selectSidebarPane(.advanced, navigationState: state)

        #expect(state.requestedSettingsDisclosure == .advancedLayoutControls)
    }

    private func entry(
        pane: SettingsNavigationIdentifier,
        disclosure _: AppNavigationState.SettingsDisclosure
    ) -> SearchEntry {
        SearchEntry(
            id: "advanced.menuBarOrderFulfillmentTimeout",
            titleKey: "Test",
            titleText: "Test",
            descriptionText: nil,
            pane: pane,
            sectionKey: nil,
            sectionText: nil,
            keywords: [],
            property: nil
        )
    }
}
