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

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
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
