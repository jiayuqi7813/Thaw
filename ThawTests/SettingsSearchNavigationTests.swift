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
        state.settingsNavigationIdentifier = .advanced
        var query = "icon preview"

        SettingsSearchNavigation.selectSearchResult(
            entry(pane: .advanced, disclosure: .iconPreviews),
            navigationState: state,
            query: &query
        )

        #expect(state.settingsNavigationIdentifier == .advanced)
        #expect(state.requestedSettingsDisclosure == .iconPreviews)
        #expect(query.isEmpty)
        #expect(SettingsSearchNavigation.consumeDisclosure(.iconPreviews, navigationState: state))
        #expect(state.requestedSettingsDisclosure == nil)
    }

    @Test("Cross-pane result changes panes and replaces a stale disclosure")
    @MainActor
    func crossPaneResultChangesPaneAndReplacesStaleDisclosure() {
        let state = AppNavigationState()
        state.settingsNavigationIdentifier = .advanced
        state.requestedSettingsDisclosure = .iconPreviews
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
        state.requestedSettingsDisclosure = .iconPreviews

        SettingsSearchNavigation.selectSidebarPane(.tools, navigationState: state)

        #expect(state.settingsNavigationIdentifier == .tools)
        #expect(state.requestedSettingsDisclosure == nil)
    }

    @Test("Reappearing sidebar selection does not consume a pending disclosure")
    @MainActor
    func unchangedSidebarSelectionPreservesPendingDisclosure() {
        let state = AppNavigationState()
        state.settingsNavigationIdentifier = .advanced
        state.requestedSettingsDisclosure = .iconPreviews

        SettingsSearchNavigation.selectSidebarPane(.advanced, navigationState: state)

        #expect(state.requestedSettingsDisclosure == .iconPreviews)
    }

    private func entry(
        pane: SettingsNavigationIdentifier,
        disclosure: AppNavigationState.SettingsDisclosure
    ) -> SearchEntry {
        let id = switch disclosure {
        case .advancedLayoutControls: "advanced.menuBarOrderFulfillmentTimeout"
        case .iconPreviews: "advanced.useContinuousMenuBarCapture"
        }

        return SearchEntry(
            id: id,
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
