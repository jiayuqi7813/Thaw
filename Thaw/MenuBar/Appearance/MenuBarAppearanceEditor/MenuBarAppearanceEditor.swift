//
//  MenuBarAppearanceEditor.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct MenuBarAppearanceEditor: View {
    enum Location {
        case settings
        case panel
    }

    @EnvironmentObject var appState: AppState
    @ObservedObject var appearanceManager: MenuBarAppearanceManager
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isResetPromptPresented = false
    @State private var editingAppearance = SystemAppearance.current
    @State private var currentAppearance = SystemAppearance.current

    let location: Location
    let onDone: (() -> Void)?

    var body: some View {
        if case .panel = location {
            bodyContent
                .safeAreaBar(edge: .top, spacing: 0) {
                    panelHeading
                }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    panelBottomBar
                }
        } else {
            bodyContent
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotEdit
        } else {
            mainForm
                .scrollEdgeEffectStyle(.automatic, for: .vertical)
        }
    }

    private var panelHeading: some View {
        Text("Appearance")
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
    }

    private var cannotEdit: some View {
        Text("\(Constants.displayName) cannot edit the appearance of automatically hidden menu bars.")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var mainForm: some View {
        IceForm {
            IceSection {
                isDynamicToggle
            }

            if appearanceManager.configuration.isDynamic {
                appearanceModePicker
            }

            IceSection {
                Text("Background")
            } content: {
                UnlabeledAppearanceFillEditor(
                    configuration: editedPartialConfiguration,
                    fillKind: .background
                )
            } footer: {
                Text("Fills the menu bar behind or around a custom shape.")
            }

            IceSection("Shape") {
                shapePicker
                isInset
            }

            if appearanceManager.configuration.shapeKind != .noShape {
                IceSection {
                    Text("Shape fill")
                } content: {
                    UnlabeledAppearanceFillEditor(
                        configuration: editedPartialConfiguration,
                        fillKind: .shapeFill
                    )
                } footer: {
                    Text("Colors the area inside the shape.")
                }
            }

            if
                appearanceManager.configuration.current.tintKind != .noTint
                || appearanceManager.configuration.shapeKind != .noShape
                || appearanceManager.configuration.current.backgroundKind != .none
            {
                Text(
                    "If effects are not visible, disable “Show menu bar background” in System Settings \(Constants.menuArrow) Menu Bar."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .settings = location {
                settingsFooter
            }
        }
        .onReceive(NSApp.publisher(for: \.effectiveAppearance)) { _ in
            currentAppearance = .current
        }
        .onChange(of: appearanceManager.configuration.isDynamic) { _, isDynamic in
            if isDynamic {
                editingAppearance = currentAppearance
            }
        }
        .resetAppearanceAlert(isPresented: $isResetPromptPresented) {
            appearanceManager.configuration = .defaultConfiguration
        }
    }

    private var isDynamicToggle: some View {
        Toggle("Use different settings for Light and Dark Mode", isOn: $appearanceManager.configuration.isDynamic)
            .annotation("Edit Light and Dark separately. Switch modes below to customize each.")
    }

    private var appearanceModePicker: some View {
        IceSection {
            LabeledContent("Editing") {
                HStack(spacing: 8) {
                    Picker("Appearance mode", selection: $editingAppearance) {
                        Text("Light").tag(SystemAppearance.light)
                        Text("Dark").tag(SystemAppearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    if currentAppearance != editingAppearance {
                        PreviewButton(appearance: editingAppearance)
                    }

                    Button(editingAppearance == .light ? "Copy from Dark" : "Copy from Light") {
                        copyFromOppositeAppearance()
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
        }
    }

    private var editedPartialConfiguration: Binding<MenuBarAppearancePartialConfiguration> {
        Binding(
            get: {
                if appearanceManager.configuration.isDynamic {
                    switch editingAppearance {
                    case .light: appearanceManager.configuration.lightModeConfiguration
                    case .dark: appearanceManager.configuration.darkModeConfiguration
                    }
                } else {
                    appearanceManager.configuration.staticConfiguration
                }
            },
            set: { newValue in
                if appearanceManager.configuration.isDynamic {
                    switch editingAppearance {
                    case .light: appearanceManager.configuration.lightModeConfiguration = newValue
                    case .dark: appearanceManager.configuration.darkModeConfiguration = newValue
                    }
                } else {
                    appearanceManager.configuration.staticConfiguration = newValue
                }
            }
        )
    }

    private func copyFromOppositeAppearance() {
        switch editingAppearance {
        case .light:
            appearanceManager.configuration.lightModeConfiguration =
                appearanceManager.configuration.darkModeConfiguration
        case .dark:
            appearanceManager.configuration.darkModeConfiguration =
                appearanceManager.configuration.lightModeConfiguration
        }
    }

    @ViewBuilder
    private var settingsFooter: some View {
        if
            appState.settings.advanced.enableSecondaryContextMenu
            || appearanceManager.configuration != .defaultConfiguration
        {
            IceSection {
                if appState.settings.advanced.enableSecondaryContextMenu {
                    Text("Tip: Right-click an empty area of the menu bar to edit appearance without opening Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if appearanceManager.configuration != .defaultConfiguration {
                    HStack {
                        Spacer()
                        Button("Reset Appearance", role: .destructive) {
                            isResetPromptPresented = true
                        }
                    }
                }
            }
        }
    }

    private var panelBottomBar: some View {
        HStack {
            Button("Done") {
                if let onDone {
                    onDone()
                } else {
                    dismissWindow()
                }
            }

            Spacer()

            if
                !appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults,
                appearanceManager.configuration != .defaultConfiguration
            {
                Button("Reset") {
                    isResetPromptPresented = true
                }
            }
        }
        .buttonBorderShape(.capsule)
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))
    }

    private var shapePicker: some View {
        MenuBarShapePicker(configuration: $appearanceManager.configuration)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var isInset: some View {
        if appearanceManager.configuration.shapeKind != .noShape {
            Toggle(
                "Inset on notched displays",
                isOn: $appearanceManager.configuration.isInset
            )
            .annotation("Shrinks the shape slightly so it sits below the notch.")
        }
    }
}

// MARK: - Reset Alert

private extension View {
    func resetAppearanceAlert(
        isPresented: Binding<Bool>,
        onReset: @escaping () -> Void
    ) -> some View {
        alert("Reset Appearance", isPresented: isPresented) {
            Button("Cancel", role: .cancel) {
                isPresented.wrappedValue = false
            }
            Button("Reset", role: .destructive) {
                onReset()
                isPresented.wrappedValue = false
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

// MARK: - Appearance Fill Editor

private enum AppearanceFillKind {
    case background
    case shapeFill
}

/// Shared Style / Effect / Opacity / Shadow / Border controls for background
/// and shape fill. The two surfaces use parallel fields on the partial
/// configuration but present the same editing affordances.
private struct UnlabeledAppearanceFillEditor: View {
    @Binding var configuration: MenuBarAppearancePartialConfiguration
    let fillKind: AppearanceFillKind

    var body: some View {
        styleSection
        borderToggle
        if hasBorder {
            borderColor
            borderWidth
        }
    }

    @ViewBuilder
    private var styleSection: some View {
        stylePicker
        if showsOpacity {
            opacitySlider
        }
        if showsGlassStyle {
            glassStylePicker
        }
        shadowToggle
    }

    @ViewBuilder
    private var stylePicker: some View {
        switch fillKind {
        case .background:
            LabeledContent("Style") {
                HStack {
                    IcePicker("Background", selection: $configuration.backgroundKind) {
                        ForEach(MenuBarBackgroundKind.allCases, id: \.self) { kind in
                            Text(kind.localized).tag(kind)
                        }
                    }
                    .labelsHidden()

                    backgroundColorControls
                }
                .frame(height: 24)
            }
        case .shapeFill:
            LabeledContent("Style") {
                HStack {
                    IcePicker("Shape fill", selection: $configuration.tintKind) {
                        ForEach(MenuBarTintKind.allCases) { tintKind in
                            Text(tintKind.localized).tag(tintKind)
                        }
                    }
                    .labelsHidden()

                    shapeFillColorControls
                }
                .frame(height: 24)
            }
        }
    }

    @ViewBuilder
    private var backgroundColorControls: some View {
        switch configuration.backgroundKind {
        case .none, .glass, .adaptive:
            EmptyView()
        case .solid:
            ColorPicker(
                "Background",
                selection: $configuration.backgroundColor,
                supportsOpacity: false
            )
            .labelsHidden()
        case .gradient:
            IceGradientPicker(
                "Background",
                gradient: $configuration.backgroundGradient,
                supportsOpacity: false
            )
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var shapeFillColorControls: some View {
        switch configuration.tintKind {
        case .noTint, .glass, .adaptive:
            EmptyView()
        case .solid:
            ColorPicker(
                "Shape fill",
                selection: $configuration.tintColor,
                supportsOpacity: false
            )
            .labelsHidden()
        case .gradient:
            IceGradientPicker(
                "Shape fill",
                gradient: $configuration.tintGradient,
                supportsOpacity: false
            )
            .labelsHidden()
        }
    }

    private var glassStylePicker: some View {
        LabeledContent("Effect") {
            IcePicker("Glass Style", selection: glassStyleBinding) {
                ForEach(MenuBarGlassStyle.allCases, id: \.self) { style in
                    Text(style.localized).tag(style)
                }
            }
            .labelsHidden()
        }
    }

    private var opacitySlider: some View {
        LabeledContent("Opacity") {
            IceSlider(
                value: opacityBinding,
                in: 0 ... 1,
                step: 0.05,
                showsValue: false
            ) {
                Text(opacityBinding.wrappedValue, format: .percent.precision(.fractionLength(0)))
            }
        }
    }

    private var shadowToggle: some View {
        Toggle("Shadow", isOn: shadowBinding)
    }

    private var borderToggle: some View {
        Toggle("Border", isOn: borderBinding)
    }

    private var borderColor: some View {
        ColorPicker(
            "Border Color",
            selection: borderColorBinding,
            supportsOpacity: true
        )
    }

    private var borderWidth: some View {
        IcePicker(
            "Border Width",
            selection: borderWidthBinding
        ) {
            Text(verbatim: "1").tag(1.0)
            Text(verbatim: "2").tag(2.0)
            Text(verbatim: "3").tag(3.0)
        }
    }

    // MARK: Kind-specific bindings

    private var showsOpacity: Bool {
        switch fillKind {
        case .background:
            configuration.backgroundKind != .none && configuration.backgroundKind != .glass
        case .shapeFill:
            configuration.tintKind != .noTint && configuration.tintKind != .glass
        }
    }

    private var showsGlassStyle: Bool {
        switch fillKind {
        case .background: configuration.backgroundKind == .glass
        case .shapeFill: configuration.tintKind == .glass
        }
    }

    private var hasBorder: Bool {
        switch fillKind {
        case .background: configuration.backgroundHasBorder
        case .shapeFill: configuration.hasBorder
        }
    }

    private var opacityBinding: Binding<Double> {
        switch fillKind {
        case .background: $configuration.backgroundOpacity
        case .shapeFill: $configuration.tintOpacity
        }
    }

    private var glassStyleBinding: Binding<MenuBarGlassStyle> {
        switch fillKind {
        case .background: $configuration.backgroundGlassStyle
        case .shapeFill: $configuration.tintGlassStyle
        }
    }

    private var shadowBinding: Binding<Bool> {
        switch fillKind {
        case .background: $configuration.backgroundHasShadow
        case .shapeFill: $configuration.hasShadow
        }
    }

    private var borderBinding: Binding<Bool> {
        switch fillKind {
        case .background: $configuration.backgroundHasBorder
        case .shapeFill: $configuration.hasBorder
        }
    }

    private var borderColorBinding: Binding<CGColor> {
        switch fillKind {
        case .background: $configuration.backgroundBorderColor
        case .shapeFill: $configuration.borderColor
        }
    }

    private var borderWidthBinding: Binding<Double> {
        switch fillKind {
        case .background: $configuration.backgroundBorderWidth
        case .shapeFill: $configuration.borderWidth
        }
    }
}

// MARK: - Preview Button

private struct PreviewButton: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPressed = false

    let appearance: SystemAppearance

    private var manager: MenuBarAppearanceManager {
        appState.appearanceManager
    }

    private var previewConfiguration: MenuBarAppearancePartialConfiguration {
        switch appearance {
        case .light:
            manager.configuration.lightModeConfiguration
        case .dark:
            manager.configuration.darkModeConfiguration
        }
    }

    var body: some View {
        Button("Hold to Preview") {
            // Button action is handled by onChange modifier tracking isPressed state
        }
        .buttonStyle(PreviewButtonStyle(isPressed: $isPressed))
        .onChange(of: isPressed) {
            manager.previewConfiguration = isPressed ? previewConfiguration : nil
        }
    }
}

private struct PreviewButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}
