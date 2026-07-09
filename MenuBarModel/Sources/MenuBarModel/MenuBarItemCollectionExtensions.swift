//
//  MenuBarItemCollectionExtensions.swift
//  Project: MenuBarModel
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

// MARK: - Collection where Element == MenuBarItem

extension Collection<MenuBarItem> {
    /// Returns the first index where the menu bar item matching the specified
    /// tag appears in the collection.
    public func firstIndex(matching tag: MenuBarItemTag) -> Index? {
        if tag.matchesVisibleControlItem {
            return firstIndex { $0.tag.matchesVisibleControlItem }
        }
        return firstIndex { $0.tag == tag }
    }
}

// MARK: - RangeReplaceableCollection where Element == MenuBarItem

extension RangeReplaceableCollection where Element == MenuBarItem {
    /// Removes and returns the first menu bar item that matches
    /// the specified tag.
    public mutating func removeFirst(matching tag: MenuBarItemTag) -> MenuBarItem? {
        guard let index = firstIndex(matching: tag) else {
            return nil
        }
        return remove(at: index)
    }
}

// MARK: - Sequence where Element == MenuBarItem

extension Sequence<MenuBarItem> {
    /// Returns the first menu bar item that matches the specified tag.
    public func first(matching tag: MenuBarItemTag) -> MenuBarItem? {
        if tag.matchesVisibleControlItem {
            return first { $0.tag.matchesVisibleControlItem }
        }
        return first { $0.tag == tag }
    }
}

// MARK: - Comparable

extension Comparable {
    /// Returns a copy of this value, clamped to the given minimum
    /// and maximum limiting values.
    public func clamped(min: Self, max: Self) -> Self {
        precondition(min <= max, "Clamp requires min <= max")
        return Swift.min(Swift.max(self, min), max)
    }

    /// Returns a copy of this value, clamped to the given limiting
    /// range.
    public func clamped(to range: ClosedRange<Self>) -> Self {
        clamped(min: range.lowerBound, max: range.upperBound)
    }
}
