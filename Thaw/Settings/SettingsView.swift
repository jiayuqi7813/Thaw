//
//  SettingsView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let appState: AppState
    @ObservedObject var navigationState: AppNavigationState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            settingsPane
                .id(navigationState.settingsNavigationIdentifier)
                .transition(paneTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .buttonStyle(.settingsGlass)
                .glassEffect(paneGlass, in: Rectangle())
                .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .navigationTitle(navigationState.settingsNavigationIdentifier.localized)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var paneTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.animation(.easeOut(duration: 0.14))
    }

    private var paneGlass: Glass {
        colorScheme == .dark ? .identity : .regular
    }

    private var sidebar: some View {
        Group {
            if #available(macOS 27, *) {
                SettingsSearchSidebar(navigationState: navigationState)
            } else {
                SettingsSidebarPaneList(navigationState: navigationState)
                    .navigationSplitViewColumnWidth(ideal: 200, max: 240)
            }
        }
        .background {
            SidebarTranslucencyBackground()
        }
    }

    @ViewBuilder
    private var settingsPane: some View {
        switch navigationState.settingsNavigationIdentifier {
        case .general:
            GeneralSettingsPane(
                settings: appState.settings.general,
                advancedSettings: appState.settings.advanced
            )
        case .menuBarLayout:
            MenuBarLayoutSettingsPane(itemManager: appState.itemManager)
        case .displays:
            DisplaySettingsPane(displaySettings: appState.settings.displaySettings)
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
        case .tools:
            ToolsSettingsPane(settings: appState.settings.advanced)
        case .about:
            AboutSettingsPane(updatesManager: appState.updatesManager)
        }
    }
}

// MARK: - SidebarTranslucencyBackground

/// Uses behind-window blending so the sidebar samples the desktop rather than
/// the system-owned `NavigationSplitView` backdrop beneath the SwiftUI layer.
private struct SidebarTranslucencyBackground: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}

struct SettingsGlassButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            configuration.trigger()
        } label: {
            configuration.label
                .padding(.horizontal, 16)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }
}

extension PrimitiveButtonStyle where Self == SettingsGlassButtonStyle {
    static var settingsGlass: SettingsGlassButtonStyle {
        .init()
    }
}

// MARK: - SettingsSearchSidebar

@available(macOS 27, *)
private struct SettingsSearchSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var navigationState: AppNavigationState

    @StateObject private var searchModel = SearchModel()

    private var isSearching: Bool {
        !searchModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var contentMode: ContentMode {
        if !isSearching {
            return .navigation
        }
        return searchModel.displayedGroups.isEmpty ? .empty : .results
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchModel.searchText)

            Group {
                switch contentMode {
                case .navigation:
                    SettingsSidebarPaneList(
                        navigationState: navigationState
                    )
                case .results:
                    SearchResultsList(groups: searchModel.displayedGroups) { entry in
                        SettingsSearchNavigation.selectSearchResult(
                            entry,
                            navigationState: navigationState,
                            query: &searchModel.searchText
                        )
                    }
                case .empty:
                    SearchEmptyView()
                }
            }
            .id(contentMode)
            .transition(contentTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewColumnWidth(ideal: 200, max: 240)
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.animation(.easeOut(duration: 0.1))
    }

    private enum ContentMode: Hashable {
        case navigation
        case results
        case empty
    }
}

// MARK: - SettingsSidebarPaneList

/// The default settings sidebar navigation list.
private struct SettingsSidebarPaneList: View {
    @ObservedObject var navigationState: AppNavigationState

    var body: some View {
        let selection = Binding<SettingsNavigationIdentifier>(
            get: { navigationState.settingsNavigationIdentifier },
            set: { newValue in
                SettingsSearchNavigation.selectSidebarPane(
                    newValue,
                    navigationState: navigationState
                )
            }
        )

        List(selection: selection) {
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
        .scrollContentBackground(.hidden)
    }
}
