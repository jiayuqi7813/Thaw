//
//  IceSection.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct IceSectionOptions: OptionSet {
    let rawValue: Int

    static let isBordered = IceSectionOptions(rawValue: 1 << 0)
    static let hasDividers = IceSectionOptions(rawValue: 1 << 1)

    static let plain: IceSectionOptions = []
    static let defaultValue: IceSectionOptions = [.isBordered, .hasDividers]
}

struct IceSection<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer
    private let spacing: CGFloat
    private let options: IceSectionOptions

    private var isBordered: Bool {
        options.contains(.isBordered)
    }

    private var hasDividers: Bool {
        options.contains(.hasDividers)
    }

    init(
        spacing: CGFloat = .iceSectionDefaultSpacing,
        options: IceSectionOptions = .defaultValue,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.spacing = spacing
        self.options = options
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    init(
        spacing: CGFloat = .iceSectionDefaultSpacing,
        options: IceSectionOptions = .defaultValue,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) where Header == EmptyView {
        self.init(spacing: spacing, options: options) {
            EmptyView()
        } content: {
            content()
        } footer: {
            footer()
        }
    }

    init(
        spacing: CGFloat = .iceSectionDefaultSpacing,
        options: IceSectionOptions = .defaultValue,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.init(spacing: spacing, options: options) {
            header()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        spacing: CGFloat = .iceSectionDefaultSpacing,
        options: IceSectionOptions = .defaultValue,
        @ViewBuilder content: () -> Content
    ) where Header == EmptyView, Footer == EmptyView {
        self.init(spacing: spacing, options: options) {
            EmptyView()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        _ title: LocalizedStringKey,
        spacing: CGFloat = .iceSectionDefaultSpacing,
        options: IceSectionOptions = .defaultValue,
        @ViewBuilder content: () -> Content
    ) where Header == Text, Footer == EmptyView {
        self.init(spacing: spacing, options: options) {
            // No explicit font — the native grouped Section header styles it.
            Text(title)
        } content: {
            content()
        }
    }

    var body: some View {
        // Native grouped Section. The OS provides the glass card, row insets,
        // and separators between rows (so `hasDividers` needs no custom layout).
        // `.plain` (`!isBordered`) opts out of the card via a cleared row
        // background.
        if isBordered {
            nativeSection
        } else {
            nativeSection
                .listRowBackground(Color.clear)
        }
    }

    private var nativeSection: some View {
        Section {
            content
        } header: {
            headerView
        } footer: {
            footerView
        }
    }

    @ViewBuilder
    private var headerView: some View {
        if Header.self != EmptyView.self {
            header
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var footerView: some View {
        if Footer.self != EmptyView.self {
            footer
        }
    }
}

extension CGFloat {
    /// The default spacing for an ``IceSection``.
    static let iceSectionDefaultSpacing: CGFloat = 8
}
