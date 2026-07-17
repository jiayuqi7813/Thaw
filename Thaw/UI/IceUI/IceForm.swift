//
//  IceForm.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct IceForm<Content: View>: View {
    @Environment(\.settingsPaneTitle) private var settingsPaneTitle

    private let alignment: HorizontalAlignment
    private let padding: EdgeInsets
    private let spacing: CGFloat
    private let content: Content

    init(
        alignment: HorizontalAlignment = .center,
        padding: EdgeInsets = .iceFormDefaultPadding,
        spacing: CGFloat = .iceFormDefaultSpacing,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.padding = padding
        self.spacing = spacing
        self.content = content()
    }

    init(
        alignment: HorizontalAlignment = .center,
        padding: CGFloat,
        spacing: CGFloat = .iceFormDefaultSpacing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            alignment: alignment,
            padding: EdgeInsets(all: padding),
            spacing: spacing
        ) {
            content()
        }
    }

    var body: some View {
        // Page title sits above the Form (not in a grouped row/card). Form
        // scrolls in the remaining space so content cannot pass under the title.
        VStack(alignment: .leading, spacing: 0) {
            if let settingsPaneTitle {
                Text(settingsPaneTitle)
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, SettingsDetailLayout.titleTopInset)
                    .padding(.horizontal, SettingsDetailLayout.titleHorizontalInset)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
            }

            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusSection()
        .accessibilityElement(children: .contain)
    }
}

extension EdgeInsets {
    /// The default padding for an ``IceForm``. Top inset stays tight so the
    /// in-pane page title can sit close to the first section cards.
    static let iceFormDefaultPadding: EdgeInsets = .init(top: 8, leading: 20, bottom: 20, trailing: 20)
}

extension CGFloat {
    /// The default spacing for an ``IceForm``.
    static let iceFormDefaultSpacing: CGFloat = 24
}
