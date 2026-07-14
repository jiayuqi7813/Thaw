//
//  MenuBarItemCache.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import Foundation

/// Cache for menu bar items.
///
/// Extracted from `MenuBarItemManager.ItemCache` so the hard-path kit's
/// backend abstraction can operate on it without depending on the app's
/// orchestrator class. `MenuBarItemManager.ItemCache` becomes a `typealias`
/// to this type.
public struct MenuBarItemCache: Hashable, MenuBarSectionBucketed, Sendable {
    /// Storage for cached menu bar items, keyed by section.
    private var storage = [MenuBarSectionName: [MenuBarItem]]()

    /// The identifier of the display with the active menu bar at
    /// the time this cache was created.
    public let displayID: CGDirectDisplayID?

    /// The cached menu bar items as an array.
    public var managedItems: [MenuBarItem] {
        MenuBarSectionName.allCases.reduce(into: []) { result, section in
            guard let items = storage[section] else {
                return
            }
            result.append(contentsOf: items)
        }
    }

    /// Creates a cache with the given display identifier.
    public init(displayID: CGDirectDisplayID?) {
        self.displayID = displayID
    }

    /// Returns the managed menu bar items for the given section.
    public func managedItems(for section: MenuBarSectionName) -> [MenuBarItem] {
        self[section]
    }

    /// Returns the address for the menu bar item with the given tag,
    /// if it exists in the cache.
    public func address(for tag: MenuBarItemTag) -> (section: MenuBarSectionName, index: Int)? {
        for (section, items) in storage {
            guard let index = items.firstIndex(matching: tag) else {
                continue
            }
            return (section, index)
        }
        return nil
    }

    /// Inserts the given menu bar item into the cache at the specified
    /// destination.
    public mutating func insert(_ item: MenuBarItem, at destination: MoveDestination) {
        let targetTag = destination.targetItem.tag

        if targetTag == .hiddenControlItem {
            switch destination {
            case .leftOfItem:
                self[.hidden].append(item)
            case .rightOfItem:
                self[.visible].insert(item, at: 0)
            }
            return
        }

        if targetTag == .alwaysHiddenControlItem {
            switch destination {
            case .leftOfItem:
                self[.alwaysHidden].append(item)
            case .rightOfItem:
                self[.hidden].insert(item, at: 0)
            }
            return
        }

        guard case (let section, var index)? = address(for: targetTag) else {
            return
        }

        if case .rightOfItem = destination {
            let range = self[section].startIndex ... self[section].endIndex
            index = (index + 1).clamped(to: range)
        }

        self[section].insert(item, at: index)
    }

    /// Accesses the items in the given section.
    public subscript(section: MenuBarSectionName) -> [MenuBarItem] {
        get { storage[section, default: []] }
        set { storage[section] = newValue }
    }
}

/// A pair of control items, taken from a list of menu bar items
/// during a menu bar item cache operation.
///
/// Extracted from `MenuBarItemManager.ControlItemPair` so the hard-path kit's
/// backend abstraction can operate on it without depending on the app's
/// orchestrator class. `MenuBarItemManager.ControlItemPair` becomes a
/// `typealias` to this type.
public struct ControlItemPair: Sendable {
    public let hidden: MenuBarItem
    public let alwaysHidden: MenuBarItem?

    /// Creates a control item pair from already-known control items.
    ///
    /// Used by test fixtures and by callers that have already resolved the
    /// hidden and always-hidden items themselves. Production discovery from
    /// a live menu bar uses the failable initializer below.
    public init(hidden: MenuBarItem, alwaysHidden: MenuBarItem?) {
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }

    /// Creates a control item pair from a list of menu bar items.
    ///
    /// The initializer first attempts a tag-based lookup (namespace + title).
    /// If that fails it falls back to matching by the current process PID and
    /// known control-item titles, and finally to matching by known window IDs.
    ///
    /// On macOS 26 (Tahoe), all menu bar item windows are owned by Control
    /// Center and the item title reported by `kCGWindowName` may differ from
    /// the `NSStatusItem` autosaveName used to build the expected tag, so the
    /// primary lookup can fail.
    public init?(
        items: inout [MenuBarItem],
        hiddenControlItemWindowID: CGWindowID? = nil,
        alwaysHiddenControlItemWindowID: CGWindowID? = nil
    ) {
        // Primary lookup: match by tag (namespace + title).
        if let hidden = items.removeFirst(matching: .hiddenControlItem) {
            self.hidden = hidden
            self.alwaysHidden = items.removeFirst(matching: .alwaysHiddenControlItem)
            return
        }

        // Fallback 1: match by sourcePID (our own process) + known title.
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let hiddenTitle = ControlItemIdentifier.hidden.rawValue
        let alwaysHiddenTitle = ControlItemIdentifier.alwaysHidden.rawValue

        if let idx = items.firstIndex(where: { $0.sourcePID == ourPID && $0.title == hiddenTitle }) {
            self.hidden = items.remove(at: idx)
            if let ahIdx = items.firstIndex(where: { $0.sourcePID == ourPID && $0.title == alwaysHiddenTitle }) {
                self.alwaysHidden = items.remove(at: ahIdx)
            } else {
                self.alwaysHidden = nil
            }
            return
        }

        // Fallback 2: match by known window IDs obtained from the ControlItem
        // objects themselves. This handles the case where both the tag and the
        // window title are unreliable on macOS 26.
        if let hiddenWID = hiddenControlItemWindowID,
           let idx = items.firstIndex(where: { $0.windowID == hiddenWID })
        {
            self.hidden = items.remove(at: idx)
            if let ahWID = alwaysHiddenControlItemWindowID,
               let ahIdx = items.firstIndex(where: { $0.windowID == ahWID })
            {
                self.alwaysHidden = items.remove(at: ahIdx)
            } else {
                self.alwaysHidden = nil
            }
            return
        }

        return nil
    }
}
