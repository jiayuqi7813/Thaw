//
//  MenuBarLayoutSettingsPane.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import MenuBarModel
import SwiftUI
import ThawCapture

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager
    @State private var isHidingAvailable = true

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    /// Whether to show the "hiding unsupported" warning: only relevant on
    /// macOS 27+ (where `sectionController` exists) and only when its backend
    /// reports the private Assessment Mode API is unavailable.
    private var isHidingUnavailable: Bool {
        guard #available(macOS 27, *) else { return false }
        return !isHidingAvailable
    }

    private func syncHidingAvailability() {
        isHidingAvailable = menuBarManager.sectionController?.isHidingAvailable ?? true
    }

    var body: some View {
        IceForm(spacing: 20) {
            LayoutSectionOptions(
                settings: appState.settings.advanced,
                isHidingUnavailable: isHidingUnavailable
            )

            if !ScreenCapture.cachedCheckPermissions() {
                MissingLayoutPermissionView()
            } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
                CannotArrangeLayoutView()
            } else {
                LayoutHeaderSection()
                LayoutBarsSection(itemManager: itemManager)
                if #available(macOS 27, *) {
                    LayoutSystemItemControl(isEnabled: systemItemHidingBinding)
                    LayoutAdvancedControls(
                        navigationState: appState.navigationState,
                        reorderTimeout: reorderTimeoutBinding,
                        preventsOverflow: overflowPreventionBinding
                    )
                }
                LayoutResetControls(
                    itemManager: itemManager,
                    controlItemsDisabled: itemManager.areControlItemsMissing,
                    alwaysHiddenEnabled: appState.settings.advanced.enableAlwaysHiddenSection
                )
            }
        }
        .onAppear {
            appState.imageCache.markSettingsPaneOpened()
            syncHidingAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            menuBarManager.sectionController?.refreshHidingAvailability()
            syncHidingAvailability()
        }
    }

    private var systemItemHidingBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.advanced.enableExperimentalSystemItemHiding },
            set: { newValue in
                appState.settings.advanced.enableExperimentalSystemItemHiding = newValue
                appState.menuBarManager.sectionController?.refresh()
            }
        )
    }

    private var reorderTimeoutBinding: Binding<TimeInterval> {
        Binding(
            get: { appState.settings.advanced.menuBarOrderFulfillmentTimeout },
            set: { appState.settings.advanced.menuBarOrderFulfillmentTimeout = $0 }
        )
    }

    private var overflowPreventionBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.advanced.enableExperimentalOverflowPrevention },
            set: { newValue in
                appState.settings.advanced.enableExperimentalOverflowPrevention = newValue
                appState.menuBarManager.sectionController?.refresh()
            }
        )
    }
}

private struct LayoutSectionOptions: View {
    @ObservedObject var settings: AdvancedSettings
    let isHidingUnavailable: Bool

    var body: some View {
        IceSection("Sections") {
            if isHidingUnavailable {
                SettingsWarningPill(
                    message: "Hiding is unavailable on this macOS build (the required system capability was not found). Reordering still works; hiding does not."
                )
            }
            Toggle(
                "Enable the always-hidden section",
                isOn: $settings.enableAlwaysHiddenSection
            )
            IcePicker("Section divider style", selection: $settings.sectionDividerStyle) {
                ForEach(SectionDividerStyle.allCases) { style in
                    Text(style.localized).tag(style)
                }
            }
        }
    }
}

private struct LayoutHeaderSection: View {
    var body: some View {
        IceSection {
            VStack(spacing: 3) {
                Text("Arrange menu bar items")
                    .font(.title3.bold())
                Text("Drag items between sections. Move New Items to choose where future items appear.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Tip: Hold ⌘ Command while dragging an item directly in the menu bar.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct LayoutBarsSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager
    @State private var loadDeadlineReached = false

    private let diagLog = DiagLog(category: "MenuBarLayoutPane")

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                if let menuBarSection = appState.menuBarManager.section(withName: section), menuBarSection.isEnabled {
                    VStack(alignment: .leading) {
                        Text(section.localized)
                            .font(.headline)
                            .padding(.leading, 8)
                        LayoutBar(imageCache: appState.imageCache, section: section)
                    }
                }
            }
        }
        .opacity(hasItems ? 1 : 0.75)
        .blur(radius: hasItems ? 0 : 5)
        .allowsHitTesting(hasItems)
        .overlay {
            if !hasItems {
                loadingOverlay
            }
        }
        .task(id: hasItems) {
            await loadItemsIfNeeded()
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 8) {
            if loadDeadlineReached {
                VStack(spacing: 4) {
                    if itemManager.areControlItemsMissing {
                        Text("One or more section dividers are hidden by macOS")
                        Text("Check System Settings > Menu Bar and enable \(Constants.displayName)")
                            .font(.calloutBox)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unable to load menu bar items")
                    }
                }
            } else {
                Text("Loading menu bar items…")
                ProgressView()
            }
        }
    }

    private func loadItemsIfNeeded() async {
        loadDeadlineReached = false
        guard !hasItems, ScreenCapture.cachedCheckPermissions() else { return }

        diagLog.debug("Preloading menu bar layout caches (hasItems=\(self.hasItems), screenRecording=\(ScreenCapture.cachedCheckPermissions()))")
        async let preloadCaches: Void = preloadLayoutCaches()
        try? await Task.sleep(for: .seconds(3))

        if !Task.isCancelled, !hasItems {
            loadDeadlineReached = true
            diagLog.error("Menu bar layout failed to load items after 3s timeout. cacheItems: \(itemManager.itemCache.managedItems.count), images: \(appState.imageCache.images.count), displayID: \(self.itemManager.itemCache.displayID.map { "\($0)" } ?? "nil")")
        }
        await preloadCaches
    }

    private func preloadLayoutCaches() async {
        await itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
        guard !Task.isCancelled else { return }

        if #available(macOS 27, *) {
            await appState.imageCache.prewarmConcealedImagesMacOS27(
                sections: [.hidden, .alwaysHidden],
                onlyMissingImages: true
            )
            guard !Task.isCancelled else { return }
        }

        await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
    }
}

@available(macOS 27, *)
private struct LayoutSystemItemControl: View {
    @Binding var isEnabled: Bool

    var body: some View {
        IceSection {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $isEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allow hiding macOS system items")
                            .font(.headline)
                        Text("Allows items such as Clock, Control Center, and Siri to be moved into hidden sections.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Note: When Thaw Bar is off, hidden Clock, Control Center, and Siri stay anchored at the right side of the layout. You can still change whether they are visible or hidden.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@available(macOS 27, *)
struct LayoutAdvancedControls: View {
    @ObservedObject var navigationState: AppNavigationState
    @Binding var reorderTimeout: TimeInterval
    @Binding var preventsOverflow: Bool
    @State private var isExpanded = false
    @State private var hasConnectedNotchedDisplay = NSScreen.managedScreens.contains(where: \.hasNotch)

    static let defaultsExpanded = false

    var body: some View {
        IceSection {
            DisclosureGroup("Advanced layout controls", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Reorder timeout") {
                        IceSlider(value: $reorderTimeout, in: 1 ... 15, step: 0.5) {
                            SecondsLabel(value: reorderTimeout)
                        }
                    }
                    .annotation("How long Thaw waits for macOS to apply a menu bar reorder before continuing with any remaining layout work.")

                    if hasConnectedNotchedDisplay {
                        Toggle(isOn: $preventsOverflow) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("Keep visible items out of macOS overflow")
                                        .font(.headline)
                                    Text("Experimental")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                                Text("When a notched menu bar is full, prefer hiding already-hidden items behind macOS's overflow chevron so visible items remain on screen.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasConnectedNotchedDisplay = NSScreen.managedScreens.contains(where: \.hasNotch)
        }
        .onChange(of: navigationState.requestedSettingsDisclosure, initial: true) { _, disclosure in
            guard disclosure == .advancedLayoutControls else { return }
            isExpanded = true
            navigationState.requestedSettingsDisclosure = nil
        }
    }
}

private struct LayoutResetControls: View {
    @ObservedObject var itemManager: MenuBarItemManager
    let controlItemsDisabled: Bool
    let alwaysHiddenEnabled: Bool

    @State private var isResetting = false
    @State private var isConfirming = false
    @State private var status: ResetStatus?

    var body: some View {
        IceSection(options: [.isBordered]) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reset menu bar layout")
                            .font(.headline)
                        Text("Moves every movable item except the \(Constants.displayName) icon to the selected section — just like a fresh install.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Button {
                        isConfirming = true
                    } label: {
                        if isResetting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Reset Layout…")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(isResetting || controlItemsDisabled)
                }

                if isConfirming {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose where to move the menu bar items:")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Visible") { reset(to: .visible) }
                            Button("Hidden") { reset(to: .hidden) }
                            if alwaysHiddenEnabled {
                                Button("Always Hidden") { reset(to: .alwaysHidden) }
                            }
                            Button("Cancel", role: .cancel) { isConfirming = false }
                        }
                        .buttonStyle(.glass)
                    }
                }

                if let status {
                    Text(status.message)
                        .font(.footnote)
                        .foregroundStyle(status.isError ? .red : .secondary)
                }
            }
        }
    }

    private func reset(to target: ResetTarget) {
        isConfirming = false
        isResetting = true
        status = nil

        Task { @MainActor in
            do {
                let failures = switch target {
                case .visible: try await itemManager.resetLayoutToVisible()
                case .hidden: try await itemManager.resetLayoutToFreshState()
                case .alwaysHidden: try await itemManager.resetLayoutToAlwaysHidden()
                }
                status = failures == 0 ? .success(target) : .partialFailure(failures)
            } catch {
                status = .failure(error.localizedDescription)
            }
            isResetting = false
        }
    }

    private enum ResetTarget {
        case visible
        case hidden
        case alwaysHidden
    }

    private enum ResetStatus {
        case success(ResetTarget)
        case partialFailure(Int)
        case failure(String)

        var message: String {
            switch self {
            case .success(.hidden): String(localized: "Layout reset. Items were moved to the Hidden section.")
            case .success(.alwaysHidden): String(localized: "Layout reset. Items were moved to the Always Hidden section.")
            case .success(.visible): String(localized: "Items were moved to the Visible section.")
            case let .partialFailure(count): String(localized: "Reset completed with \(count) item(s) that could not be moved. Check the menu bar and try again if needed.")
            case let .failure(message): String(localized: "Reset failed: \(message)")
            }
        }

        var isError: Bool {
            switch self {
            case .success: false
            case .partialFailure, .failure: true
            }
        }
    }
}

private struct CannotArrangeLayoutView: View {
    var body: some View {
        Text("\(Constants.displayName) cannot arrange menu bar items in automatically hidden menu bars.")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct MissingLayoutPermissionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack {
            Text("Menu bar layout requires screen recording permissions.")
                .font(.title2)
            Button("Go to Advanced Settings") {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            }
            .buttonStyle(.link)
        }
    }
}
