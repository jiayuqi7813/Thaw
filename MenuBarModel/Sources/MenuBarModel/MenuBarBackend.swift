//
//  MenuBarBackend.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// Operating-system-specific menu-bar section behavior.
///
/// Two adapters make this a real seam: legacy macOS uses physical divider
/// reflow, while macOS 27 uses assertion-backed visibility and assignment-based
/// cache reconstruction.
public protocol MenuBarBackend: Sendable {
    var usesAssertionHiding: Bool { get }
    var supportsLegacySectionHiding: Bool { get }

    @MainActor
    func rebucket(
        _ cache: MenuBarItemCache,
        hider: (any HidingStateProviding)?,
        allowsAlwaysHidden: Bool
    ) -> MenuBarItemCache

    func capturableSections(
        from requested: [MenuBarSectionName],
        revealedSection: MenuBarSectionName?
    ) -> [MenuBarSectionName]

    /// Selects the bounds source used to validate an automatic relocation, or
    /// nil when the candidate has no usable bounds and the move should be
    /// skipped. Legacy trusts the WindowServer geometry; the assertion backend
    /// uses the item's own AX bounds (synthetic window IDs make a WindowServer
    /// lookup invalid) and rejects the `x == -1` / zero-size transient reads.
    nonisolated func relocationBounds(itemBounds: CGRect, windowServerBounds: CGRect?) -> CGRect?

    /// Whether an AX snapshot that is missing Thaw's own visible control item
    /// should be treated as a transient miss so the last-good cache is retained
    /// rather than overwritten with a bad frame.
    nonisolated func shouldRetainLastGoodCache(snapshotItems: [MenuBarItem], previousCachedItems: [MenuBarItem]) -> Bool

    /// Whether Thaw may synthesize its zero-length divider control items from
    /// the snapshot (only when the visible control item is actually present).
    nonisolated func canSynthesizeControlItems(snapshotItems: [MenuBarItem]) -> Bool

    /// Whether a windowID-set difference between two cache cycles is a genuine
    /// change that should trigger a saved-layout re-apply, or merely an artifact
    /// (active-display switch on legacy; synthetic-ID churn on the assertion
    /// backend, where logical identity and assignment divergence own restore
    /// detection instead).
    nonisolated func windowIDsChanged(
        previous: Set<CGWindowID>,
        current: Set<CGWindowID>,
        previousDisplayID: CGDirectDisplayID?,
        currentDisplayID: CGDirectDisplayID?
    ) -> Bool

    /// Whether the current bar differs from the saved layout in section
    /// membership — the secondary `applySavedLayout` trigger for ambient drift
    /// that leaves window IDs intact. `savedSectionByBaseID` maps each saved
    /// item's `namespace:title` base identifier to its saved section.
    ///
    /// Legacy classifies each item's section spatially from its bounds relative
    /// to the divider control items; the assertion backend reads membership from
    /// ``MenuBarSectionController/section(for:)`` because macOS 27 membership is
    /// assignment-driven and AX X-coordinates still read hidden-side after an
    /// assertion reflow. Both exclude non-concealable Apple system items and
    /// items parked off the bar band, which would otherwise never converge and
    /// re-fire the bulk apply every cache cycle.
    @MainActor
    func layoutMembershipDiverged(
        savedSectionByBaseID: [String: MenuBarSectionName],
        items: [MenuBarItem],
        controlItems: ControlItemPair,
        hider: (any HidingStateProviding)?
    ) -> Bool

    /// Which layout-snapshot persistence to run when the shared persist gate is
    /// open (`shouldPersist`). Legacy saves the position-derived spatial order;
    /// the assertion backend mirrors the assignment-driven section order.
    nonisolated func persistLayoutSnapshot(shouldPersist: Bool) -> LayoutSnapshotAction

    /// Which section-divider enforcement model applies on this OS.
    nonisolated var controlItemEnforcementStrategy: ControlItemEnforcementStrategy { get }

    nonisolated var preferredMovePath: PreferredMovePath { get }

    nonisolated func allowsSectionBoundaryDividerTarget(allowExplicitOptIn: Bool) -> Bool

    nonisolated func resetExecution(for target: SectionResetTarget) -> LayoutResetExecution

    nonisolated func itemCacheSignature(_ items: [MenuBarItem]) -> [String]?

    nonisolated var profileLayoutStrategy: ProfileLayoutStrategy { get }

    nonisolated var savedLayoutRestoreStrategy: SavedLayoutRestoreStrategy { get }

    nonisolated var classifiesSectionByDividerGeometry: Bool { get }

    nonisolated var shouldCoalesceCacheRerun: Bool { get }

    nonisolated var usesProfileWindowIDRelaunchHeuristic: Bool { get }
}
