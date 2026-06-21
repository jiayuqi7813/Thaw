//
//  LayoutPlanner.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Pure planning module for MenuBarAgent's anchor-constrained physical order.
/// It contains no AX enumeration or synthetic input; callers provide one live
/// snapshot and execute the returned move through the move engine.
enum LayoutPlanner {
    typealias MoveDestination = MenuBarItemManager.MoveDestination
    typealias ControlItemPair = MenuBarItemManager.ControlItemPair

    static func liveOrderSatisfiesDestination(
        items: [MenuBarItem],
        item: MenuBarItem,
        destination: MoveDestination
    ) -> Bool {
        let orderedItems = items
            .filter { !$0.isSystemClone && !$0.tag.isLayoutAnchoredSystemItem }
            .sorted(by: visualOrder)
        let target = destination.targetItem
        guard !item.tag.matchesIgnoringWindowID(target.tag),
              let itemIndex = orderedItems.firstIndex(where: { $0.tag.matchesIgnoringWindowID(item.tag) }),
              let targetIndex = orderedItems.firstIndex(where: { $0.tag.matchesIgnoringWindowID(target.tag) })
        else {
            return false
        }

        return switch destination {
        case .leftOfItem: itemIndex + 1 == targetIndex
        case .rightOfItem: itemIndex == targetIndex + 1
        }
    }

    /// Projects a desired order onto independently movable, anchor-bounded
    /// segments. Items never move through a fixed system anchor.
    static func achievableOrderSegments(
        items: [MenuBarItem],
        desiredOrder: [String]
    ) -> [[MenuBarItem]] {
        let orderedItems = items.filter { !$0.isSystemClone }.sorted(by: visualOrder)
        let desiredRank = Dictionary(
            desiredOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var physicalSegments = [[MenuBarItem]]()
        var currentSegment = [MenuBarItem]()
        for item in orderedItems {
            if item.tag.isLayoutAnchoredSystemItem {
                if !currentSegment.isEmpty {
                    physicalSegments.append(currentSegment)
                    currentSegment.removeAll(keepingCapacity: true)
                }
                continue
            }
            if item.isMovable, !item.isControlItem {
                currentSegment.append(item)
            }
        }
        if !currentSegment.isEmpty {
            physicalSegments.append(currentSegment)
        }

        return physicalSegments.map { segment in
            segment.enumerated().sorted { lhs, rhs in
                let lhsRank = desiredRank[lhs.element.uniqueIdentifier] ?? (desiredOrder.count + lhs.offset)
                let rhsRank = desiredRank[rhs.element.uniqueIdentifier] ?? (desiredOrder.count + rhs.offset)
                return lhsRank < rhsRank
            }.map(\.element)
        }
    }

    static func nextAchievableOrderMove(
        items: [MenuBarItem],
        desiredOrder: [String]
    ) -> (item: MenuBarItem, destination: MoveDestination)? {
        let currentSegments = achievableOrderSegments(items: items, desiredOrder: [])
        let desiredSegments = achievableOrderSegments(items: items, desiredOrder: desiredOrder)

        for (current, desired) in zip(currentSegments, desiredSegments) {
            guard current.map(\.uniqueIdentifier) != desired.map(\.uniqueIdentifier), desired.count > 1 else {
                continue
            }
            for index in 1 ..< desired.count {
                let item = desired[index]
                let destination = MoveDestination.rightOfItem(desired[index - 1])
                if !liveOrderSatisfiesDestination(items: items, item: item, destination: destination) {
                    return (item, destination)
                }
            }
        }
        return nil
    }

    static func achievableDestination(
        items: [MenuBarItem],
        item: MenuBarItem,
        desiredOrder: [String]
    ) -> MoveDestination? {
        let currentSegments = achievableOrderSegments(items: items, desiredOrder: [])
        let desiredSegments = achievableOrderSegments(items: items, desiredOrder: desiredOrder)

        for (current, desired) in zip(currentSegments, desiredSegments) {
            guard current.contains(where: { $0.tag.matchesIgnoringWindowID(item.tag) }),
                  current.map(\.uniqueIdentifier) != desired.map(\.uniqueIdentifier),
                  let desiredIndex = desired.firstIndex(where: { $0.tag.matchesIgnoringWindowID(item.tag) })
            else {
                continue
            }
            if desired.indices.contains(desiredIndex + 1) {
                return .leftOfItem(desired[desiredIndex + 1])
            }
            if desiredIndex > 0 {
                return .rightOfItem(desired[desiredIndex - 1])
            }
        }
        return nil
    }

    static func liveOrderSatisfiesSectionBoundary(
        items: [MenuBarItem],
        item: MenuBarItem,
        section: MenuBarSection.Name,
        controlItems: ControlItemPair
    ) -> Bool {
        let orderedItems = items.filter { !$0.isSystemClone }.sorted(by: visualOrder)
        guard let itemIndex = orderedItems.firstIndex(where: { $0.tag.matchesIgnoringWindowID(item.tag) }),
              let hiddenDividerIndex = orderedItems.firstIndex(where: {
                  $0.tag.matchesIgnoringWindowID(controlItems.hidden.tag)
              })
        else {
            return false
        }

        switch section {
        case .visible:
            return itemIndex > hiddenDividerIndex
        case .hidden:
            guard itemIndex < hiddenDividerIndex else { return false }
            guard let alwaysHidden = controlItems.alwaysHidden else { return true }
            guard let dividerIndex = orderedItems.firstIndex(where: {
                $0.tag.matchesIgnoringWindowID(alwaysHidden.tag)
            }) else { return false }
            return itemIndex > dividerIndex
        case .alwaysHidden:
            guard let alwaysHidden = controlItems.alwaysHidden,
                  let dividerIndex = orderedItems.firstIndex(where: {
                      $0.tag.matchesIgnoringWindowID(alwaysHidden.tag)
                  })
            else { return false }
            return itemIndex < dividerIndex
        }
    }

    static func sectionBoundaryDestination(
        for section: MenuBarSection.Name,
        controlItems: ControlItemPair
    ) -> MoveDestination? {
        switch section {
        case .visible: .rightOfItem(controlItems.hidden)
        case .hidden: .leftOfItem(controlItems.hidden)
        case .alwaysHidden: controlItems.alwaysHidden.map(MoveDestination.leftOfItem)
        }
    }

    static func dividerMoveDestination(
        items: [MenuBarItem],
        sectionAssignment: [String: MenuBarSection.Name],
        controlItems: ControlItemPair
    ) -> MoveDestination? {
        let divider = controlItems.hidden
        guard divider.isOnScreen else { return nil }

        let orderedItems = items.filter { !$0.isSystemClone }.sorted(by: visualOrder)
        guard let dividerIndex = orderedItems.firstIndex(where: {
            $0.tag.matchesIgnoringWindowID(divider.tag)
        }) else { return nil }

        let leftBarrier = orderedItems[..<dividerIndex].lastIndex(where: {
            $0.tag.isLayoutAnchoredSystemItem
        })
        let afterDivider = orderedItems.index(after: dividerIndex)
        let rightBarrier = afterDivider < orderedItems.endIndex
            ? orderedItems[afterDivider...].firstIndex(where: { $0.tag.isLayoutAnchoredSystemItem })
            : nil
        let segmentStart = leftBarrier.map { orderedItems.index(after: $0) } ?? orderedItems.startIndex
        let segmentEnd = rightBarrier ?? orderedItems.endIndex

        let visibleAnchor = orderedItems[segmentStart ..< segmentEnd].first { item in
            guard item.isMovable, !item.isControlItem || item.tag == .visibleControlItem else {
                return false
            }
            return sectionAssignment[item.uniqueIdentifier] == nil
        }
        guard let visibleAnchor, divider.bounds.maxX > visibleAnchor.bounds.minX else { return nil }
        return .leftOfItem(visibleAnchor)
    }

    static func orderDescription(_ items: [MenuBarItem]) -> String {
        items
            .filter { !$0.isSystemClone }
            .sorted(by: visualOrder)
            .map { item in
                "\(item.uniqueIdentifier) title=\(item.title ?? "<nil>") frame=\(NSStringFromRect(item.bounds))"
            }
            .joined(separator: " | ")
    }

    private static func visualOrder(_ lhs: MenuBarItem, _ rhs: MenuBarItem) -> Bool {
        if lhs.bounds.midX == rhs.bounds.midX {
            return lhs.uniqueIdentifier < rhs.uniqueIdentifier
        }
        return lhs.bounds.midX < rhs.bounds.midX
    }
}
