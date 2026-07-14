//
//  HostMenuBarBackend.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import MenuBarModel

/// Host-native menu-bar policy: physical divider reflow, spatial layout, and
/// WindowServer-backed moves.
public struct HostMenuBarBackend: MenuBarBackend {
    public init() {}

    public let usesAssertionHiding = false
    public let supportsLegacySectionHiding = true

    @MainActor
    public func rebucket(
        _ cache: MenuBarItemCache,
        hider _: (any HidingStateProviding)?,
        allowsAlwaysHidden _: Bool
    ) -> MenuBarItemCache {
        cache
    }

    public func capturableSections(
        from requested: [MenuBarSectionName],
        revealedSection _: MenuBarSectionName?
    ) -> [MenuBarSectionName] {
        requested
    }

    public nonisolated func relocationBounds(itemBounds _: CGRect, windowServerBounds: CGRect?) -> CGRect? {
        windowServerBounds
    }

    public nonisolated func shouldRetainLastGoodCache(
        snapshotItems _: [MenuBarItem],
        previousCachedItems _: [MenuBarItem]
    ) -> Bool {
        false
    }

    public nonisolated func canSynthesizeControlItems(snapshotItems _: [MenuBarItem]) -> Bool {
        false
    }

    public nonisolated func windowIDsChanged(
        previous: Set<CGWindowID>,
        current: Set<CGWindowID>,
        previousDisplayID: CGDirectDisplayID?,
        currentDisplayID: CGDirectDisplayID?
    ) -> Bool {
        // First cycle: no prior frame to diff against.
        guard !previous.isEmpty else { return false }
        // The active menu bar display moved to another screen. With separate
        // Spaces the prior display's windows are no longer on the active space,
        // so they read as missing even though the same logical items are still
        // present elsewhere. Not an item quit; do not advance the gate. Only
        // suppress when both displays are known and genuinely differ, so an
        // unknown display falls back to the plain disappearance signal.
        if let previousDisplayID, let currentDisplayID, previousDisplayID != currentDisplayID {
            return false
        }
        return !previous.isSubset(of: current)
    }

    @MainActor
    public func layoutMembershipDiverged(
        savedSectionByBaseID: [String: MenuBarSectionName],
        items: [MenuBarItem],
        controlItems: ControlItemPair,
        hider _: (any HidingStateProviding)?
    ) -> Bool {
        let hiddenMinX = controlItems.hidden.bounds.minX
        let hiddenMaxX = controlItems.hidden.bounds.maxX
        let ahBounds = controlItems.alwaysHidden?.bounds

        // Non-concealable Apple system items (Sound/Wi-Fi/Spotlight/Siri/…) report
        // `canBeHidden` but can neither be bundle-concealed nor reliably dragged to
        // the hidden side, so an assigned-hidden one is *perpetually* "in the wrong
        // section". Including it here made divergence never clear, re-firing
        // applyProfileLayout every cache cycle (the runaway loop that thrashed the
        // divider and hijacked the cursor). They're managed best-effort elsewhere;
        // exclude them from divergence so only achievable (third-party) drift
        // triggers a re-apply.
        for item in items where !item.isControlItem && item.canBeHidden && item.isMovable
            && !item.isNonConcealableSystemItem
        {
            // Assertion reflows park items off the bar band briefly; their X
            // still reads hidden-side and would false-trigger a bulk re-apply.
            guard !item.isParkedOffMenuBarBand(among: items) else { continue }

            let baseID = "\(item.tag.namespace):\(item.tag.title)"
            guard let expectedSection = savedSectionByBaseID[baseID] else {
                continue
            }

            let currentSection: MenuBarSectionName? = if item.bounds.minX >= hiddenMaxX {
                .visible
            } else if let ahBounds, item.bounds.maxX <= ahBounds.minX {
                .alwaysHidden
            } else if let ahBounds, item.bounds.minX >= ahBounds.maxX, item.bounds.maxX <= hiddenMinX {
                .hidden
            } else if ahBounds == nil, item.bounds.maxX <= hiddenMinX {
                .hidden
            } else {
                nil
            }

            guard let currentSection else { continue }
            if currentSection != expectedSection {
                return true
            }
        }
        return false
    }

    public nonisolated func persistLayoutSnapshot(shouldPersist: Bool) -> LayoutSnapshotAction {
        shouldPersist ? .saveSpatialOrder : .none
    }

    public nonisolated var controlItemEnforcementStrategy: ControlItemEnforcementStrategy {
        .legacyDividerSwap
    }

    public nonisolated var preferredMovePath: PreferredMovePath {
        .legacyWindowServer
    }

    public nonisolated func allowsSectionBoundaryDividerTarget(allowExplicitOptIn _: Bool) -> Bool {
        true
    }

    public nonisolated func resetExecution(for target: SectionResetTarget) -> LayoutResetExecution {
        switch target {
        case .freshInstallHidden:
            .legacyPhysicalMoves(.toHidden)
        case .allVisible, .allAlwaysHidden:
            .legacyPhysicalMoves(.toVisible)
        }
    }

    public nonisolated func itemCacheSignature(_: [MenuBarItem]) -> [String]? {
        nil
    }

    public nonisolated var profileLayoutStrategy: ProfileLayoutStrategy {
        .legacyBulkMove
    }

    public nonisolated var savedLayoutRestoreStrategy: SavedLayoutRestoreStrategy {
        .spatialBulkApply
    }

    public nonisolated var classifiesSectionByDividerGeometry: Bool {
        true
    }

    public nonisolated var shouldCoalesceCacheRerun: Bool {
        false
    }

    public nonisolated var usesProfileWindowIDRelaunchHeuristic: Bool {
        true
    }
}
