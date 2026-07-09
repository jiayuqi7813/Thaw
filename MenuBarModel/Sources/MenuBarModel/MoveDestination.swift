//
//  MoveDestination.swift
//  Project: MenuBarModel
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// Extracted from `MenuBarItemManager.MoveDestination` so the hard-path kit's
/// backend abstraction can operate on it without depending on the app's
/// orchestrator class. `MenuBarItemManager.MoveDestination` becomes a
/// `typealias` to this type.
public enum MoveDestination: Equatable, Sendable {
    /// The destination to the left of the given target item.
    case leftOfItem(MenuBarItem)
    /// The destination to the right of the given target item.
    case rightOfItem(MenuBarItem)

    /// The destination's target item.
    public var targetItem: MenuBarItem {
        switch self {
        case let .leftOfItem(item), let .rightOfItem(item): item
        }
    }

    /// Whether the destination is to the right of the anchor, used for
    /// computing offset weights in cursor-free reorder.
    public var isRightward: Bool {
        if case .rightOfItem = self {
            return true
        }
        return false
    }

    /// A string to use for logging purposes.
    public var logString: String {
        switch self {
        case let .leftOfItem(item): "left of \(item.logString)"
        case let .rightOfItem(item): "right of \(item.logString)"
        }
    }
}

/// Extracted from `MenuBarItemManager.LayoutResetDirection` so the hard-path
/// kit's backend abstraction can operate on it without depending on the app's
/// orchestrator class. `MenuBarItemManager.LayoutResetDirection` becomes a
/// `typealias` to this type.
public enum LayoutResetDirection: Equatable, Sendable {
    case toHidden
    case toVisible

    public func moveDestination(controlItems: ControlItemPair) -> MoveDestination {
        switch self {
        case .toHidden:
            .leftOfItem(controlItems.hidden)
        case .toVisible:
            .rightOfItem(controlItems.hidden)
        }
    }

    public func isNotYetInTarget(
        item _: MenuBarItem,
        bounds: CGRect,
        hiddenBounds: CGRect,
        alwaysHiddenBounds: CGRect?
    ) -> Bool {
        switch self {
        case .toHidden:
            if bounds.minX >= hiddenBounds.maxX {
                return true
            }
            if let alwaysHiddenBounds, bounds.maxX <= alwaysHiddenBounds.minX {
                return true
            }
            return false
        case .toVisible:
            return bounds.minX < hiddenBounds.maxX
        }
    }

    public var movesAllCandidatesInFirstPass: Bool {
        switch self {
        case .toHidden:
            true
        case .toVisible:
            false
        }
    }

    public var failureLogLabel: String {
        switch self {
        case .toHidden:
            "layout reset"
        case .toVisible:
            "reset-to-visible"
        }
    }
}
