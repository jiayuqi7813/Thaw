//
//  ControlItemIdentifier.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

/// Raw identifiers for the control items that mark section boundaries.
///
/// Extracted from `ControlItem.Identifier` so `MenuBarItemTag` doesn't need
/// to depend on the (app-only) `ControlItem` class. `Thaw.ControlItem.Identifier`
/// becomes a `typealias` to this type; the `length(for:)` computed property
/// that references app-only types stays behind as an extension in the app
/// target.
public enum ControlItemIdentifier: String, CaseIterable, Sendable {
    /// The identifier for the control item for the visible section.
    case visible = "Thaw.ControlItem.Visible"
    /// The identifier for the control item for the hidden section.
    case hidden = "Thaw.ControlItem.Hidden"
    /// The identifier for the control item for the always-hidden section.
    case alwaysHidden = "Thaw.ControlItem.AlwaysHidden"

    /// A tag for the control item with this identifier.
    public var tag: MenuBarItemTag {
        switch self {
        case .visible: .visibleControlItem
        case .hidden: .hiddenControlItem
        case .alwaysHidden: .alwaysHiddenControlItem
        }
    }
}
