//
//  HidingStateProviding.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

/// The subset of the app's `MenuBarSectionController` that the hard-path kit's backend
/// abstraction needs, without depending on the app target (`MenuBarSectionController`
/// is the public gateway that imports the private kit, so the private kit
/// cannot reference it by concrete type). The app conforms `MenuBarSectionController`
/// to this protocol retroactively, the same pattern it already uses for
/// `ControlCenterModuleManaging` and `TrailingItemPositioning`.
@MainActor
public protocol HidingStateProviding: AnyObject {
    /// The current section assignment, keyed by item identifier.
    var sectionAssignment: [String: MenuBarSectionName] { get }

    /// The section an item is currently assigned to.
    func section(for item: MenuBarItem) -> MenuBarSectionName

    /// The last-known retained snapshot for an item identifier, if any.
    func snapshot(for identifier: String) -> MenuBarItem?

    /// Orders a list of items within the given section.
    func ordered(_ items: [MenuBarItem], in section: MenuBarSectionName) -> [MenuBarItem]
}
