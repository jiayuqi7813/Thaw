//
//  SettingsView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    let appState: AppState
    @ObservedObject var navigationState: AppNavigationState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            settingsPane
                .id(navigationState.settingsNavigationIdentifier)
        }
        .navigationTitle(navigationState.settingsNavigationIdentifier.localized)
    }

    private var sidebar: some View {
        // Use a Binding that wraps the navigation state to ensure updates happen
        // on the main thread and avoid view update warnings.
        let selection = Binding<SettingsNavigationIdentifier>(
            get: { navigationState.settingsNavigationIdentifier },
            set: { newValue in
                if navigationState.settingsNavigationIdentifier != newValue {
                    Task { @MainActor in
                        navigationState.settingsNavigationIdentifier = newValue
                    }
                }
            }
        )

        return List(selection: selection) {
            Section {
                ForEach(SettingsNavigationIdentifier.allCases) { identifier in
                    Label {
                        Text(identifier.localized)
                    } icon: {
                        identifier.iconResource.view
                    }
                    .tag(identifier)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(ideal: 180, max: 220)
    }

    @ViewBuilder
    private var settingsPane: some View {
        switch navigationState.settingsNavigationIdentifier {
        case .general:
            GeneralSettingsPane(settings: appState.settings.general)
        case .displays:
            DisplaySettingsPane(displaySettings: appState.settings.displaySettings)
        case .menuBarLayout:
            MenuBarLayoutSettingsPane(itemManager: appState.itemManager)
        case .menuBarAppearance:
            MenuBarAppearanceSettingsPane(appearanceManager: appState.appearanceManager)
        case .hotkeys:
            HotkeysSettingsPane(settings: appState.settings.hotkeys)
        case .profiles:
            ProfileSettingsPane(profileManager: appState.profileManager)
        case .advanced:
            AdvancedSettingsPane(settings: appState.settings.advanced)
        case .automation:
            AutomationSettingsPane()
        case .about:
            AboutSettingsPane(updatesManager: appState.updatesManager)
        }
    }
}
