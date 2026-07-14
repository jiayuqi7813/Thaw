//
//  IceForm.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct IceForm<Content: View>: View {
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
        // Native SwiftUI grouped form. The detail host supplies the page-level
        // Liquid Glass surface; hiding only the scroll background lets that
        // surface show around the native section cards.
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .focusSection()
        .accessibilityElement(children: .contain)
    }
}

extension EdgeInsets {
    /// The default padding for an ``IceForm``. The top inset separates the
    /// scrolling content from the window header/toolbar so the section cards'
    /// rounded corners and shadows clear the header band instead of being cut.
    static let iceFormDefaultPadding: EdgeInsets = .init(top: 24, leading: 20, bottom: 20, trailing: 20)
}

extension CGFloat {
    /// The default spacing for an ``IceForm``.
    static let iceFormDefaultSpacing: CGFloat = 24
}
