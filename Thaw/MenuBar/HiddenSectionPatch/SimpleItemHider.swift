//
//  SimpleItemHider.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3
//

@preconcurrency import AXSwift
import Cocoa

/// macOS 27 section-based hiding, the authority behind the restored
/// drag-between-sections layout UI.
///
/// macOS 27 removed every legacy mechanism for moving a status item off-screen, so
/// the classic Visible / Hidden / Always-Hidden model is reconstructed here on
/// top of a single source of truth that this object owns:
///
/// - **Section assignment** (``sectionAssignment``): which section each item
///   belongs to, keyed by ``MenuBarItem/uniqueIdentifier`` and persisted. This
///   is what the layout bars render and what drags mutate.
/// - **Temporary reveal** (``revealedSection``): the Hidden / Always-Hidden
///   section currently shown from the Thaw icon or hotkeys. This only changes
///   the live assertion allowlist; persisted assignments stay untouched.
///
/// The actual hiding is delegated to ``AssessmentModeBackend``: the private
/// visibility-restriction assertion that genuinely removes the icons and reflows
/// the bar. Its allowlist is recomputed from the assignment map. When the private
/// API is unavailable the backend is inert (nothing is hidden) and there is no
/// cosmetic overlay fallback.
///
/// Created only on macOS 27+ (see `MenuBarManager`), so everything it owns is
/// implicitly gated to that OS — macOS 26 keeps its native section machinery.
@MainActor
final class SimpleItemHider: ObservableObject {
    /// UserDefaults key for the persisted per-item section assignment
    /// (`[uniqueIdentifier: sectionRawValue]`, `.visible` entries omitted).
    private static let assignmentKey = "Thaw.simpleSectionAssignment"

    /// Legacy UserDefaults key from the binary switch-list era. Read once at
    /// first launch to migrate hidden items into the new assignment map.
    private static let legacyHiddenKey = "Thaw.simpleHiddenItemIdentifiers"

    /// UserDefaults key for the persisted per-section item order
    /// (`[sectionRawValue: [uniqueIdentifier]]`).
    private static let orderKey = "Thaw.simpleSectionOrder"

    private weak var appState: AppState?
    private let diagLog = DiagLog(category: "SimpleItemHider")

    /// Section each item is assigned to, keyed by ``MenuBarItem/uniqueIdentifier``.
    /// Entries equal to `.visible` are omitted (the default), so the map only
    /// holds the hidden / always-hidden items. Published so the settings UI and
    /// layout bars reflect changes.
    @Published private(set) var sectionAssignment: [String: MenuBarSection.Name]

    /// User-chosen left-to-right order of items within each section, set by
    /// layout-bar drags and persisted. The Visible section renders from fresh
    /// AX geometry on macOS 27 so stale saved order cannot drift from the real
    /// menu bar.
    @Published private(set) var sectionItemOrder: [MenuBarSection.Name: [String]]

    /// The currently revealed hidden section, if any. `.hidden` reveals only
    /// Hidden items; `.alwaysHidden` reveals both Hidden and Always-Hidden items.
    @Published private(set) var revealedSection: MenuBarSection.Name?

    /// Item identifiers temporarily forced visible for a single-item reveal.
    /// Unlike ``revealedSection``, this exposes just the touched item (used by
    /// the Thaw Bar click path on macOS 27) instead of its whole section, so a
    /// click never flashes every hidden icon into the menu bar.
    private var temporarilyRevealedIDs: Set<String> = []

    /// The backend that performs the hiding (the private visibility-restriction
    /// assertion).
    private let backend: AssessmentModeBackend

    /// Governs Apple Control Center modules (AirDrop / Focus / User / Now Playing
    /// / WiFi / Bluetooth) that the assessment-mode allowlist cannot hide. Items
    /// it owns are hidden via their Control Center preference and kept out of the
    /// backend input.
    private let ccModuleManager: ControlCenterModuleManager

    /// Off-screen CGS window hider. When the experimental window
    /// hiding flag is on, third-party items are hidden by moving their windows
    /// off-screen via CGS instead of the assessment-mode assertion, so hiding one
    /// item no longer reflows the bar and ghosts dynamic neighbors like iStat.
    private let cgsWindowHider: CGSWindowHider

    /// AX-based item hider. On macOS 27 per-item CG windows don't exist, so the
    /// CGS hider cannot operate. This hider sets `AXHidden` on each item's AX
    /// element instead — hiding items
    /// surgically without whole-bar reflow.
    ///
    /// Note: AXHidden is not settable on macOS 27 menu-bar items; this hider is
    /// kept for diagnostics but is effectively a no-op there.
    private let axItemHider: AXItemHider

    /// Position lock for visible items. On macOS 27 the assessment-mode
    /// assertion re-composites the whole bar, ghosting dynamic neighbors (iStat).
    /// Writing visible items' current positions to `TrailingItemPreferredPositions`
    /// before the assertion fires tells MenuBarAgent to anchor them in place
    /// during reflow, preventing the ghosting.
    private let positionStore: TrailingItemPositionStore

    private var timer: Timer?
    private var boundaryReconciliationTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        self.sectionAssignment = Self.loadAssignment()
        self.sectionItemOrder = Self.loadOrder()
        self.backend = AssessmentModeBackend()
        self.ccModuleManager = ControlCenterModuleManager()
        self.cgsWindowHider = CGSWindowHider()
        self.axItemHider = AXItemHider()
        self.positionStore = TrailingItemPositionStore()
        Bridging.logSystemMenuBarWindows()
        let assessmentModeAvailable = AssessmentModeBackend.isAvailable
        diagLog.info("hiding backend: AssessmentMode (\(assessmentModeAvailable ? "available" : "unavailable")); \(sectionAssignment.count) assigned item(s)")
    }

    /// Loads the persisted section assignment, migrating from the old binary
    /// hidden set on first launch.
    private static func loadAssignment() -> [String: MenuBarSection.Name] {
        let defaults = UserDefaults.standard
        if let stored = defaults.dictionary(forKey: assignmentKey) as? [String: String] {
            var map = [String: MenuBarSection.Name]()
            for (identifier, raw) in stored {
                if let section = MenuBarSection.Name(rawValue: raw), section != .visible {
                    map[identifier] = section
                }
            }
            return sanitizedSectionAssignment(map)
        }
        // One-time migration: every item the user had hidden in the switch-list
        // era becomes a member of the Hidden section.
        if let legacy = defaults.stringArray(forKey: legacyHiddenKey), !legacy.isEmpty {
            return sanitizedSectionAssignment(legacy.reduce(into: [:]) { $0[$1] = .hidden })
        }
        return [:]
    }

    /// Drops assignments that can never be valid hidden-section entries.
    static func sanitizedSectionAssignment(
        _ assignment: [String: MenuBarSection.Name]
    ) -> [String: MenuBarSection.Name] {
        assignment.filter { identifier, section in
            section != .visible &&
                !isControlItemAssignmentIdentifier(identifier) &&
                !isOwnAppAssignmentIdentifier(identifier) &&
                !isHidingUnsupportedAssignmentIdentifier(identifier)
        }
    }

    /// Whether the identifier belongs to an app whose hiding is not yet
    /// supported (e.g. iStat Menus with its per-second title rotation).
    /// These items can be reordered but must never be assigned to a hidden
    /// section — the assertion cannot reliably hide them and the dynamic
    /// titles create stale-assignment leaks. Such items are simply never
    /// placed in the hidden-assignment list.
    private static func isHidingUnsupportedAssignmentIdentifier(_ identifier: String) -> Bool {
        MenuBarItemTag.hidingUnsupportedBundleIDs.contains { bundleID in
            identifier.hasPrefix("\(bundleID):")
        }
    }

    static func canAssign(
        _ item: MenuBarItem,
        to section: MenuBarSection.Name,
        experimentalSystemItemHiding: Bool
    ) -> Bool {
        section == .visible
            || item.canBeHidden(experimentalSystemItemHiding: experimentalSystemItemHiding)
    }

    static func isProtectedAssignmentItem(
        _ item: MenuBarItem,
        experimentalSystemItemHiding: Bool
    ) -> Bool {
        item.isControlItem ||
            isOwnAppItem(item) ||
            (item.tag.isLayoutAnchoredSystemItem && !experimentalSystemItemHiding)
    }

    /// Whether an item should be hidden by the CGS off-screen hider rather than
    /// the assessment-mode assertion when experimental window hiding is on. Scoped
    /// to ordinary third-party app items: Apple/system items (`com.apple.*`) stay
    /// on the assertion / Control Center / Spotlight paths, and Thaw's own items
    /// and control items are never hidden.
    static func isCGSWindowHideable(_ item: MenuBarItem) -> Bool {
        guard !item.isControlItem, !isOwnAppItem(item) else { return false }
        if case let .string(bundleID) = item.tag.namespace {
            return !bundleID.hasPrefix("com.apple.")
        }
        return false
    }

    private static func isOwnAppAssignmentIdentifier(_ identifier: String) -> Bool {
        Constants.isThawOwnedAssignmentIdentifier(identifier)
    }

    private static func isControlItemAssignmentIdentifier(_ identifier: String) -> Bool {
        if identifier.contains(".Spacer.") {
            return true
        }

        let controlTitles = Set(ControlItem.Identifier.allCases.map(\.rawValue))
        if controlTitles.contains(identifier) {
            return true
        }

        let thawControlIdentifiers = Set(
            ControlItem.Identifier.allCases.map { "\(MenuBarItemTag.Namespace.thaw):\($0.rawValue)" }
        )
        return thawControlIdentifiers.contains(identifier)
    }

    private func persistAssignment() {
        let raw = sectionAssignment.mapValues(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.assignmentKey)
    }

    /// Loads the persisted per-section item order.
    private static func loadOrder() -> [MenuBarSection.Name: [String]] {
        guard let stored = UserDefaults.standard.dictionary(forKey: orderKey) as? [String: [String]] else {
            return [:]
        }
        var map = [MenuBarSection.Name: [String]]()
        for (raw, ids) in stored {
            if let section = MenuBarSection.Name(rawValue: raw) {
                map[section] = ids
            }
        }
        return map
    }

    private func persistOrder() {
        let raw = Dictionary(uniqueKeysWithValues: sectionItemOrder.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: Self.orderKey)
    }

    /// Returns the temporary reveal target for a section control.
    ///
    /// The Visible control item is the user-facing Thaw icon; like Ice on macOS
    /// 26, clicking it reveals the Hidden section.
    static func revealTarget(for section: MenuBarSection.Name) -> MenuBarSection.Name? {
        switch section {
        case .visible, .hidden:
            return .hidden
        case .alwaysHidden:
            return .alwaysHidden
        }
    }

    /// Whether the section should currently be considered hidden by the UI.
    static func isSectionHidden(
        _ section: MenuBarSection.Name,
        revealedSection: MenuBarSection.Name?
    ) -> Bool {
        switch section {
        case .visible, .hidden:
            return revealedSection != .hidden && revealedSection != .alwaysHidden
        case .alwaysHidden:
            return revealedSection != .alwaysHidden
        }
    }

    /// Assignment map to use for the live assertion while a section is revealed.
    static func effectiveSectionAssignment(
        _ assignment: [String: MenuBarSection.Name],
        revealing revealedSection: MenuBarSection.Name?
    ) -> [String: MenuBarSection.Name] {
        let sanitized = sanitizedSectionAssignment(assignment)
        guard let revealedSection else {
            return sanitized
        }

        return sanitized.filter { _, section in
            switch revealedSection {
            case .visible, .hidden:
                return section == .alwaysHidden
            case .alwaysHidden:
                return false
            }
        }
    }

    /// Temporarily reveals a hidden section in the real menu bar.
    func show(
        _ section: MenuBarSection.Name,
        reconcileBoundary: Bool = true
    ) {
        if !reconcileBoundary {
            boundaryReconciliationTask?.cancel()
            boundaryReconciliationTask = nil
        }
        guard let target = Self.revealTarget(for: section), revealedSection != target else {
            return
        }
        revealedSection = target
        diagLog.info("show(\(target.rawValue)); temporarily revealing assigned item(s)")
        refresh()

        guard reconcileBoundary else { return }

        // Existing assignments created by earlier macOS 27 builds may never
        // have crossed a physical divider. Once their AX elements reappear,
        // repair that persisted layout so the revealed bar is always:
        // Hidden < divider < Visible.
        boundaryReconciliationTask?.cancel()
        boundaryReconciliationTask = Task { @MainActor [weak self, weak appState] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self,
                  let appState,
                  !Task.isCancelled,
                  self.revealedSection == target
            else {
                return
            }
            await appState.itemManager.reconcileMacOS27SectionBoundaries(
                revealing: target
            )
        }
    }

    /// Re-applies the persisted assignment, concealing temporary reveals.
    func hideRevealedSections() {
        guard revealedSection != nil else {
            return
        }
        boundaryReconciliationTask?.cancel()
        boundaryReconciliationTask = nil
        let previous = revealedSection
        revealedSection = nil
        diagLog.info("hideRevealedSections(previous=\(previous?.rawValue ?? "none"))")
        refresh()
    }

    /// Temporarily forces a single item visible (its owning bundle is dropped
    /// from the concealment assertion) without revealing the rest of its
    /// section. Used by the Thaw Bar click path so only the touched icon
    /// appears in the menu bar.
    func revealItemTemporarily(_ identifier: String) {
        guard !temporarilyRevealedIDs.contains(identifier) else { return }
        temporarilyRevealedIDs.insert(identifier)
        diagLog.info("revealItemTemporarily(\(identifier)); single-item reveal")
        refresh()
    }

    /// Re-conceals an item previously revealed via ``revealItemTemporarily``.
    func concealTemporarilyRevealedItem(_ identifier: String) {
        guard temporarilyRevealedIDs.remove(identifier) != nil else { return }
        diagLog.info("concealTemporarilyRevealedItem(\(identifier))")
        refresh()
    }

    /// Toggles the temporary reveal state for a section.
    func toggle(_ section: MenuBarSection.Name) {
        if Self.isSectionHidden(section, revealedSection: revealedSection) {
            show(section)
        } else {
            hideRevealedSections()
        }
    }

    /// Whether the section is currently concealed by the live assertion.
    func isSectionHidden(_ section: MenuBarSection.Name) -> Bool {
        Self.isSectionHidden(section, revealedSection: revealedSection)
    }

    /// Records the user's left-to-right order for a section (from a layout-bar
    /// drag) and persists it. The caller is expected to trigger a recache so the
    /// layout bars re-render in the new order.
    func setSectionOrder(_ identifiers: [String], for section: MenuBarSection.Name) {
        sectionItemOrder[section] = identifiers
        persistOrder()
        appState?.itemManager.mirrorMacOS27SectionOrder(identifiers, for: section)
        diagLog.info("setSectionOrder(\(section.rawValue)); \(identifiers.count) item(s)")
    }

    /// Records a section order from live layout items, dropping structural
    /// control items and fixed system anchors before persistence. The movable
    /// visible Thaw control remains part of visible order.
    func setSectionOrder(from items: [MenuBarItem], for section: MenuBarSection.Name) {
        let experimentalSystemItemHiding = appState?.settings.advanced.enableExperimentalSystemItemHiding ?? false
        setSectionOrder(
            Self.persistableOrderIdentifiers(
                from: items,
                in: section,
                experimentalSystemItemHiding: experimentalSystemItemHiding
            ),
            for: section
        )
    }

    /// Returns the identifiers Thaw is allowed to persist for a section order.
    static func persistableOrderIdentifiers(
        from items: [MenuBarItem],
        in section: MenuBarSection.Name
    ) -> [String] {
        persistableOrderIdentifiers(
            from: items,
            in: section,
            experimentalSystemItemHiding: false
        )
    }

    static func persistableOrderIdentifiers(
        from items: [MenuBarItem],
        in section: MenuBarSection.Name,
        experimentalSystemItemHiding: Bool
    ) -> [String] {
        items.compactMap { item in
            if section == .visible,
               item.tag.title == ControlItem.Identifier.visible.rawValue,
               item.tag.namespace == .thaw
            {
                return item.uniqueIdentifier
            }
            guard !item.isControlItem,
                  item.isMovable(experimentalSystemItemHiding: experimentalSystemItemHiding),
                  !isOwnAppItem(item)
            else {
                return nil
            }
            return item.uniqueIdentifier
        }
    }

    /// Reorders `items` for the requested section.
    ///
    /// On macOS 27, the visible layout must mirror fresh AX geometry instead of
    /// persisted order. Persisted visible order can be stale after a failed
    /// physical move, which makes the layout UI drift away from the real menu
    /// bar. Hidden-style sections still use the user's recorded order because
    /// those items may not have meaningful live positions.
    func ordered(_ items: [MenuBarItem], in section: MenuBarSection.Name) -> [MenuBarItem] {
        let order = sectionItemOrder[section] ?? []
        return Self.orderedItems(items, in: section, using: order)
    }

    static func orderedItems(
        _ items: [MenuBarItem],
        in section: MenuBarSection.Name,
        using order: [String]
    ) -> [MenuBarItem] {
        if section == .visible {
            return liveVisualOrder(items)
        }

        guard !order.isEmpty else {
            return items
        }

        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            let lr = rank[lhs.element.uniqueIdentifier] ?? (order.count + lhs.offset)
            let rr = rank[rhs.element.uniqueIdentifier] ?? (order.count + rhs.offset)
            return lr < rr
        }.map(\.element)
    }

    private static func liveVisualOrder(_ items: [MenuBarItem]) -> [MenuBarItem] {
        items.sorted { lhs, rhs in
            if lhs.bounds.midX == rhs.bounds.midX {
                if lhs.bounds.minX == rhs.bounds.minX {
                    return lhs.uniqueIdentifier < rhs.uniqueIdentifier
                }
                return lhs.bounds.minX < rhs.bounds.minX
            }
            return lhs.bounds.midX < rhs.bounds.midX
        }
    }

    static func isProtectedAssignmentItem(_ item: MenuBarItem) -> Bool {
        isProtectedAssignmentItem(item, experimentalSystemItemHiding: false)
    }

    private static func isOwnAppItem(_ item: MenuBarItem) -> Bool {
        item.tag.namespace == .thaw ||
            Constants.isThawOwnedBundleIdentifier(item.sourceApplication?.bundleIdentifier) ||
            Constants.isThawOwnedBundleIdentifier(item.owningApplication?.bundleIdentifier) ||
            isOwnAppAssignmentIdentifier(item.uniqueIdentifier)
    }

    /// Starts the periodic refresh that keeps the backend in sync with the live
    /// item set (e.g. re-applying the allowlist when apps appear or quit).
    func start() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// The section the item with the given identifier is assigned to.
    func section(for identifier: String) -> MenuBarSection.Name {
        sectionAssignment[identifier] ?? .visible
    }

    /// The section for a live item. System anchors and any item Thaw can't
    /// conceal are always visible even if stale defaults say otherwise.
    func section(for item: MenuBarItem) -> MenuBarSection.Name {
        let experimentalSystemItemHiding = appState?.settings.advanced.enableExperimentalSystemItemHiding ?? false
        if (item.sectionManagementPolicy.isForcedVisible && !experimentalSystemItemHiding) ||
            Self.isOwnAppItem(item)
        {
            return .visible
        }
        return section(for: item.uniqueIdentifier)
    }

    /// Assigns the item to a section. Dropping it back into `.visible` removes
    /// the entry (the default). Persists and re-applies the restriction.
    func setSection(_ section: MenuBarSection.Name, identifier: String) {
        guard !Self.isControlItemAssignmentIdentifier(identifier),
              !Self.isOwnAppAssignmentIdentifier(identifier)
        else {
            if sectionAssignment.removeValue(forKey: identifier) != nil {
                persistAssignment()
                refresh()
            }
            diagLog.warning("ignored protected section assignment for \(identifier)")
            return
        }

        if section == .visible {
            sectionAssignment.removeValue(forKey: identifier)
        } else {
            sectionAssignment[identifier] = section
        }
        persistAssignment()
        diagLog.info("setSection(\(section.rawValue)) \(identifier); \(sectionAssignment.count) assigned item(s)")
        refresh()
    }

    /// Assigns a live item to a section, rejecting items that can never be
    /// safely concealed on macOS 27. Use this overload when a caller has the
    /// `MenuBarItem`; it can identify Thaw-owned generic `Item-0` entries even
    /// when their persisted identifier is not the stable control-item title.
    func setSection(_ section: MenuBarSection.Name, item: MenuBarItem) {
        // Reject control/anchored/own items, and any item that can't be hidden
        // being dropped into a non-visible section (Apple system modules on
        // macOS 27): they stay visible. Dropping one back to .visible is always
        // allowed so an existing stale assignment can be cleared.
        let experimentalSystemItemHiding = appState?.settings.advanced.enableExperimentalSystemItemHiding ?? false
        let cannotHideHere = !Self.canAssign(
            item,
            to: section,
            experimentalSystemItemHiding: experimentalSystemItemHiding
        )
        guard !Self.isProtectedAssignmentItem(
            item,
            experimentalSystemItemHiding: experimentalSystemItemHiding
        ), !cannotHideHere else {
            if sectionAssignment.removeValue(forKey: item.uniqueIdentifier) != nil {
                persistAssignment()
                refresh()
            }
            diagLog.warning("ignored section assignment for protected/non-hideable item \(item.uniqueIdentifier)")
            return
        }
        // Retain the exact live item before setSection(identifier:) refreshes
        // the restriction. The refresh can conceal the owning app immediately,
        // removing this item from AX and itemCache before refresh() gets another
        // chance to snapshot it.
        snapshots = Self.updatedSnapshots(
            snapshots,
            afterAssigning: item,
            to: section
        )
        setSection(section, identifier: item.uniqueIdentifier)
    }

    /// Replaces the entire section assignment wholesale (used by Reset Layout).
    /// `.visible` entries are dropped (the default), then the restriction is
    /// persisted and re-applied.
    func resetAssignment(to assignment: [String: MenuBarSection.Name]) {
        sectionAssignment = Self.sanitizedSectionAssignment(assignment)
        persistAssignment()
        diagLog.info("resetAssignment; \(sectionAssignment.count) assigned item(s)")
        refresh()
    }

    /// Applies a profile or saved-layout spec on macOS 27. Section membership
    /// is written through the assignment model; intra-section order is persisted
    /// per section. Visible entries are omitted from the assignment map.
    ///
    /// Items from apps that cannot be reliably hidden (iStat Menus with its
    /// per-second title rotation — see ``MenuBarItemTag/hidingUnsupportedBundleIDs``)
    /// are filtered out of hidden assignments and forced to their existing
    /// section (visible), excluding them from the hidden-order list entirely.
    func applyProfileLayout(
        itemSectionMap: [String: String],
        itemOrder: [String: [String]]
    ) {
        var assignment = Self.assignment(
            from: itemSectionMap,
            itemOrder: itemOrder
        )
        // Filter out identifiers from apps whose hiding is not yet supported.
        // Their bundle IDs are in hidingUnsupportedBundleIDs; they can be
        // reordered but must never be assigned to a hidden section, even when
        // a profile import or layout export tries to do so.
        assignment = assignment.filter { identifier, _ in
            !MenuBarItemTag.hidingUnsupportedBundleIDs.contains { bundleID in
                identifier.hasPrefix("\(bundleID):")
            }
        }
        sectionAssignment = Self.sanitizedSectionAssignment(assignment)
        persistAssignment()

        var newOrder = [MenuBarSection.Name: [String]]()
        for (sectionKey, identifiers) in itemOrder {
            guard let section = MenuBarSection.Name(rawValue: sectionKey) else { continue }
            let filtered = identifiers.filter(Self.isPersistableProfileOrderIdentifier)
            if !filtered.isEmpty {
                newOrder[section] = filtered
            }
        }
        sectionItemOrder = newOrder
        persistOrder()
        diagLog.info(
            "applyProfileLayout; \(sectionAssignment.count) assigned item(s), order sections=\(sectionItemOrder.keys.map(\.rawValue))"
        )
        refresh()
    }

    /// Builds a non-visible section assignment from profile layout fields.
    static func assignment(
        from itemSectionMap: [String: String],
        itemOrder: [String: [String]]
    ) -> [String: MenuBarSection.Name] {
        var assignment = [String: MenuBarSection.Name]()
        for (identifier, sectionKey) in itemSectionMap {
            guard let section = MenuBarSection.Name(rawValue: sectionKey),
                  section != .visible,
                  isPersistableProfileOrderIdentifier(identifier)
            else {
                continue
            }
            assignment[identifier] = section
        }

        if assignment.isEmpty {
            for (sectionKey, identifiers) in itemOrder {
                guard let section = MenuBarSection.Name(rawValue: sectionKey),
                      section != .visible
                else {
                    continue
                }
                for identifier in identifiers where isPersistableProfileOrderIdentifier(identifier) {
                    assignment[identifier] = section
                }
            }
        }

        return assignment
    }

    private static func isPersistableProfileOrderIdentifier(_ identifier: String) -> Bool {
        !isControlItemAssignmentIdentifier(identifier) &&
            !isOwnAppAssignmentIdentifier(identifier)
    }

    /// Last-known snapshots of assigned items, captured while they were still
    /// enumerable. A concealed item has no window and drops out of the AX
    /// enumeration, so the layout bars resurrect it from its snapshot (see the
    /// macOS 27 re-bucketing in `MenuBarItemManager`). Keyed by
    /// ``MenuBarItem/uniqueIdentifier``.
    private var snapshots: [String: MenuBarItem] = [:]

    /// Applies the snapshot side of a live-item section assignment. This is a
    /// separate transition so the assign-before-conceal ordering stays covered
    /// without invoking the system visibility assertion in tests.
    static func updatedSnapshots(
        _ existing: [String: MenuBarItem],
        afterAssigning item: MenuBarItem,
        to section: MenuBarSection.Name
    ) -> [String: MenuBarItem] {
        var updated = existing
        if section == .visible {
            updated.removeValue(forKey: item.uniqueIdentifier)
        } else {
            updated[item.uniqueIdentifier] = item
        }
        return updated
    }

    /// The retained snapshot for an assigned item, if one was captured this
    /// session (while the item was still visible).
    func snapshot(for identifier: String) -> MenuBarItem? {
        snapshots[identifier]
    }

    /// Tags of every assigned item that has a retained snapshot. The image cache
    /// preserves these so a concealed item that briefly drops out of the live
    /// item cache (between conceal and the snapshot re-add) doesn't lose its
    /// last-good icon to the stale-entry cleanup, leaving a blank Hidden slot.
    var assignedSnapshotTags: Set<MenuBarItemTag> {
        Set(sectionAssignment.keys.compactMap { snapshots[$0]?.tag })
    }

    /// Re-applies the current assignment against the live item cache, and
    /// refreshes the retained snapshots.
    func refresh() {
        guard let appState else { return }
        let experimentalSystemItemHiding = appState.settings.advanced.enableExperimentalSystemItemHiding
        let allItems = appState.itemManager.itemCache.managedItems
        let assignedControlItemIDs = Set(sectionAssignment.keys.filter(Self.isControlItemAssignmentIdentifier))
        let protectedAssignedIDs = Set(
            allItems
                .filter {
                    (Self.isProtectedAssignmentItem(
                        $0,
                        experimentalSystemItemHiding: experimentalSystemItemHiding
                    ) ||
                        !Self.canAssign(
                            $0,
                            to: sectionAssignment[$0.uniqueIdentifier] ?? .visible,
                            experimentalSystemItemHiding: experimentalSystemItemHiding
                        )) &&
                        sectionAssignment[$0.uniqueIdentifier] != nil
                }
                .map(\.uniqueIdentifier)
        )
        let assignedOwnAppIDs = Set(sectionAssignment.keys.filter(Self.isOwnAppAssignmentIdentifier))
        let liveItemIDs = Set(allItems.map(\.uniqueIdentifier))
        let missingLiveIDs = Set(sectionAssignment.keys).subtracting(liveItemIDs)
        let invalidAssignmentIDs = assignedControlItemIDs
            .union(assignedOwnAppIDs)
            .union(protectedAssignedIDs)
            .union(missingLiveIDs)
        if !invalidAssignmentIDs.isEmpty {
            for identifier in invalidAssignmentIDs {
                sectionAssignment.removeValue(forKey: identifier)
            }
            persistAssignment()
            diagLog.info("removed \(invalidAssignmentIDs.count) stale/invalid assignment(s)")
        }
        // Snapshot every assigned item while it's still live, so it can keep
        // appearing in the layout bars after it's concealed. Drop snapshots for
        // items that are no longer assigned.
        for item in allItems where sectionAssignment[item.uniqueIdentifier] != nil {
            snapshots[item.uniqueIdentifier] = item
        }
        snapshots = snapshots.filter { sectionAssignment[$0.key] != nil }
        let effectiveAssignment = effectiveAssignmentExcludingTemporarilyRevealed()

        // Apple Control Center modules cannot be hidden by the assessment-mode
        // allowlist (proven 2026-06-18); route them to their Control Center
        // preference instead, and strip them from the backend input.
        //
        // CC modules follow the *persisted* assignment, NOT the reveal-adjusted
        // `effectiveAssignment`: changing a CC pref restarts Control Center
        // (~1-2s blank of the whole CC area). Driving that off temporary reveals
        // made every Thaw-icon click restart Control Center and rapid clicks
        // thrashed it to empty. So a temporary reveal leaves CC modules as-is —
        // they show/hide only on a real assignment change (drag to/from Hidden).
        var ccHiddenTitles = Set<String>()
        for (identifier, section) in sectionAssignment where section != .visible {
            if let title = ControlCenterModuleManager.governableMenuExtraTitle(forItemIdentifier: identifier) {
                ccHiddenTitles.insert(title)
            }
        }
        ccModuleManager.apply(hiddenMenuExtraTitles: ccHiddenTitles)

        // Strip CC modules from the backend input regardless of
        // reveal state (they are handled by their dedicated managers above).
        var backendAssignment = backendAssignmentInput()

        // Experimental: hide third-party items surgically (CGS window move, then
        // AX hide, then visible-position lock) instead of the assessment-mode
        // assertion, which re-composites the WHOLE bar and ghosts dynamic
        // neighbors like iStat. Items a surgical hider took over are stripped
        // from `backendAssignment` so the assertion leaves them alone. See
        // ``applyExperimentalWindowHiding`` for the strategy and the off-path
        // teardown. When the flag is off this is a no-op except for restoring
        // anything a previous on-state stranded off-screen / AX-hidden / locked.
        applyExperimentalWindowHiding(
            enabled: appState.settings.advanced.enableExperimentalWindowHiding,
            effectiveAssignment: effectiveAssignment,
            allItems: allItems,
            backendAssignment: &backendAssignment
        )

        logRestrictionProbeSnapshot(reason: "before-apply", items: allItems)
        let didChangeRestriction = backend.apply(
            sectionAssignment: backendAssignment,
            allItems: allItems
        )
        if didChangeRestriction {
            appState.itemManager.noteRestrictionChange()
            restoreVisibleControlItemAfterRestrictionChange()
            diagLog.info("restriction changed; restored visible control item state")
            runPostRestrictionSceneProbes()
        }

        // Post-assertion safety net: re-enumerate from AX after the assertion
        // reflow (stale `allItems` would show `isOnScreen = true` for items the
        // assertion just hid). If any hiding-unsupported item became invisible,
        // tear down the restriction immediately.
        verifyHidingUnsupportedItemsVisiblePostAssertion()
    }

    /// Re-enumerates from AX after the assertion fires and tears down the
    /// restriction if any hiding-unsupported item (iStat Menus) has become
    /// invisible. Uses a fresh AX snapshot — the pre-assertion `allItems`
    /// cache has stale `isOnScreen` values.
    private func verifyHidingUnsupportedItemsVisiblePostAssertion() {
        guard #available(macOS 27, *),
              AssessmentModeBackend.isAvailable,
              !MenuBarItemTag.hidingUnsupportedBundleIDs.isEmpty
        else { return }

        let freshItems = MenuBarItemAXProvider.menuBarItems(option: [])

        let unsupportedItems = freshItems.filter { item in
            item.tag.isHidingUnsupported
        }

        let invisible = unsupportedItems.filter { !$0.isOnScreen }
        guard !invisible.isEmpty else { return }

        // Also check against the known bundle IDs: are any hiding-unsupported
        // bundles absent from the fresh enumeration entirely? The assertion
        // can remove items from AX visibility, so a bundle with zero visible
        // items in the fresh snapshot is also a signal.
        let unsupportedBundleIDs = MenuBarItemTag.hidingUnsupportedBundleIDs
        let visibleBundleIDs = Set(freshItems.compactMap { item in
            MenuBarItemTag.hidingUnsupportedBundleIDs.contains(where: {
                item.tag.namespace.description == $0
            }) ? item.tag.namespace.description : nil
        })
        let fullyAbsent = unsupportedBundleIDs.subtracting(visibleBundleIDs)

        if !invisible.isEmpty || !fullyAbsent.isEmpty {
            diagLog.error(
                "Post-assertion guard: \(invisible.count) hiding-unsupported item(s) " +
                "invisible, \(fullyAbsent.count) bundle(s) absent — " +
                "tearing down restriction. Invisible: " +
                invisible.map { "\($0.uniqueIdentifier) onScreen=\($0.isOnScreen)" }.joined(separator: ", ") +
                ". Absent: \(fullyAbsent.sorted().joined(separator: ", "))"
            )
            resetBackendRestriction()
        }
    }

    private func resetBackendRestriction() {
        backend.apply(sectionAssignment: [:], allItems: [])
    }

    /// Re-applies the current assertion allowlist without changing assignment.
    /// Used after reflow collateral leaves allowed bundles invisible at on-band
    /// AX coordinates (synthetic drags cannot recover those).
    @discardableResult
    func pulseRestrictionAfterReflow(liveItems: [MenuBarItem]) -> Bool {
        guard AssessmentModeBackend.isAvailable else { return false }
        guard sectionAssignment.values.contains(where: { $0 == .hidden || $0 == .alwaysHidden }) else {
            return false
        }

        let backendAssignment = backendAssignmentInput()
        logRestrictionProbeSnapshot(reason: "before-pulse", items: liveItems)
        let didPulse = backend.pulse(
            sectionAssignment: backendAssignment,
            allItems: liveItems
        )
        if didPulse {
            restoreVisibleControlItemAfterRestrictionChange()
            diagLog.info("restriction pulsed after reflow; restored visible control item state")
        }
        return didPulse
    }

    private func backendAssignmentInput() -> [String: MenuBarSection.Name] {
        var backendAssignment = effectiveAssignmentExcludingTemporarilyRevealed()
        for identifier in backendAssignment.keys
            where ControlCenterModuleManager.isGovernable(itemIdentifier: identifier)
        {
            backendAssignment.removeValue(forKey: identifier)
        }
        return backendAssignment
    }

    /// `effectiveSectionAssignment` with `temporarilyRevealedIDs` removed — the
    /// effective desired section for every item except those single-item reveals
    /// the Thaw Bar click path forces visible. Both the assertion input
    /// (``backendAssignmentInput``) and the experimental CGS/AX passes key off
    /// this; CC modules and Spotlight are stripped separately by their managers.
    private func effectiveAssignmentExcludingTemporarilyRevealed() -> [String: MenuBarSection.Name] {
        var effectiveAssignment = Self.effectiveSectionAssignment(
            sectionAssignment,
            revealing: revealedSection
        )
        for identifier in temporarilyRevealedIDs {
            effectiveAssignment.removeValue(forKey: identifier)
        }
        return effectiveAssignment
    }

    /// Experimental surgical hide: when `enabled`, hide third-party items via
    /// per-key plist manipulation instead of the assessment-mode assertion,
    /// which re-composites the whole bar and can disrupt dynamic neighbors
    /// like iStat Menus. Note that on macOS 27 removing keys from
    /// `TrailingItemPreferredPositions` alone does not hide items — the
    /// assertion remains the primary visibility mechanism.
    ///
    /// The passes run in order:
    /// 1. Plist hide/show — remove keys for newly-hidden items, restore keys
    ///    for items returned to visible. iStat and other hiding-unsupported
    ///    items are silently skipped.
    /// 2. CGS window move (legacy, no-op on macOS 27).
    /// 3. AX element hide (legacy, no-op on macOS 27).
    /// 4. Position lock — preserve visible items' existing weights, clean up
    ///    ghost keys from dynamic-title apps.
    private func applyExperimentalWindowHiding(
        enabled: Bool,
        effectiveAssignment: [String: MenuBarSection.Name],
        allItems: [MenuBarItem],
        backendAssignment: inout [String: MenuBarSection.Name]
    ) {
        guard enabled else {
            positionStore.restoreAll()
            cgsWindowHider.apply(hiddenPIDs: [])
            axItemHider.apply(hiddenPIDs: [], allItems: allItems)
            return
        }

        // ── 1. Plist-based hide/show (experimental) ──
        var toHide = [MenuBarItem]()
        var toShow = [MenuBarItem]()
        for item in allItems where Self.isCGSWindowHideable(item) {
            let section = effectiveAssignment[item.uniqueIdentifier] ?? .visible
            if section != .visible {
                toHide.append(item)
            } else if positionStore.hasHiddenItems {
                toShow.append(item)
            }
        }

        var plistHandledKeys = Set<String>()
        if !toHide.isEmpty {
            plistHandledKeys = positionStore.hideItems(toHide)
        }
        if !toShow.isEmpty {
            plistHandledKeys.formUnion(positionStore.showItems(toShow, allItems: allItems))
        }

        // Strip plist-handled items from the assertion input.
        if !plistHandledKeys.isEmpty {
            for item in allItems where Self.isCGSWindowHideable(item) {
                guard (effectiveAssignment[item.uniqueIdentifier] ?? .visible) != .visible else { continue }
                if plistHandledKeys.contains(TrailingItemPositionStore.key(for: item)) {
                    backendAssignment.removeValue(forKey: item.uniqueIdentifier)
                }
            }
        }

        // ── 2. CGS pass (legacy, no-op on macOS 27) ──
        var cgsHiddenPIDs = Set<pid_t>()
        for item in allItems where Self.isCGSWindowHideable(item) {
            let section = effectiveAssignment[item.uniqueIdentifier] ?? .visible
            guard section != .visible else { continue }
            if plistHandledKeys.contains(TrailingItemPositionStore.key(for: item)) { continue }
            let pid = item.sourcePID ?? item.ownerPID
            if #available(macOS 27, *) {
                guard item.sourcePID != nil else { continue }
            }
            cgsHiddenPIDs.insert(pid)
        }

        let cgsHandledPIDs = cgsWindowHider.apply(hiddenPIDs: cgsHiddenPIDs)
        stripSurgicallyHandledPIDs(
            cgsHandledPIDs,
            effectiveAssignment: effectiveAssignment,
            allItems: allItems,
            backendAssignment: &backendAssignment
        )

        // ── 3. AX pass (legacy, no-op on macOS 27) ──
        let remainingPIDs = cgsHiddenPIDs.subtracting(cgsHandledPIDs)
        if !remainingPIDs.isEmpty {
            let axHandledPIDs = axItemHider.apply(hiddenPIDs: remainingPIDs, allItems: allItems)
            stripSurgicallyHandledPIDs(
                axHandledPIDs,
                effectiveAssignment: effectiveAssignment,
                allItems: allItems,
                backendAssignment: &backendAssignment
            )
        }

        // ── 4. Position lock — preserve visible items' weights ──
        let visibleItemKeys = Set(
            allItems
                .filter { (effectiveAssignment[$0.uniqueIdentifier] ?? .visible) == .visible }
                .map { TrailingItemPositionStore.key(for: $0) }
        )
        positionStore.lockVisiblePositions(visibleItemKeys: visibleItemKeys, allItems: allItems)
    }

    /// Removes from `backendAssignment` every CGS/AX-hideable item whose owning
    /// PID was handled by a surgical hider, so the assertion allowlist no longer
    /// tries to conceal it (which would re-composite the whole bar). A no-op
    /// when `handledPIDs` is empty.
    private func stripSurgicallyHandledPIDs(
        _ handledPIDs: Set<pid_t>,
        effectiveAssignment: [String: MenuBarSection.Name],
        allItems: [MenuBarItem],
        backendAssignment: inout [String: MenuBarSection.Name]
    ) {
        guard !handledPIDs.isEmpty else { return }
        for item in allItems where Self.isCGSWindowHideable(item) {
            let section = effectiveAssignment[item.uniqueIdentifier] ?? .visible
            guard section != .visible else { continue }
            if handledPIDs.contains(item.sourcePID ?? item.ownerPID) {
                backendAssignment.removeValue(forKey: item.uniqueIdentifier)
            }
        }
    }

    private func restoreVisibleControlItemAfterRestrictionChange() {
        appState?.menuBarManager
            .controlItem(withName: .visible)?
            .restoreVisibleIconAfterRestrictionChange()

        Task { @MainActor [weak appState] in
            try? await Task.sleep(for: .milliseconds(250))
            appState?.menuBarManager
                .controlItem(withName: .visible)?
                .restoreVisibleIconAfterRestrictionChange()
        }
    }

    private var shouldRunAssessmentModeSceneProbes: Bool {
        guard #available(macOS 27, *) else {
            return false
        }
        return Defaults.bool(forKey: .diagnosticAssessmentModeSceneProbes)
    }

    private func logRestrictionProbeSnapshot(reason: String, items: [MenuBarItem]) {
        guard shouldRunAssessmentModeSceneProbes else {
            return
        }
        logMenuBarAgentSequence(reason: reason, items: items)
        logThawAXSequence(reason: reason, items: items)
        logControlItemStates(reason: reason)
    }

    private func runPostRestrictionSceneProbes() {
        guard shouldRunAssessmentModeSceneProbes else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard #available(macOS 27, *) else { return }
            await runSceneProbe(reason: "after-apply+0ms")
            try? await Task.sleep(for: .milliseconds(250))
            await runSceneProbe(reason: "after-apply+250ms")
            try? await Task.sleep(for: .milliseconds(750))
            await runSceneProbe(reason: "after-apply+1000ms")
        }
    }

    @available(macOS 27, *)
    private func runSceneProbe(reason: String) async {
        let items = MenuBarItemAXProvider.menuBarItems(option: [])
        logRestrictionProbeSnapshot(reason: reason, items: items)
        await logControlItemCrops(reason: reason, items: items)
        if reason == "after-apply+250ms" {
            probeHiddenTriggerPressIfEnabled(reason: reason)
        }
    }

    private func logControlItemStates(reason: String) {
        guard let menuBarManager = appState?.menuBarManager else {
            return
        }

        for section: MenuBarSection.Name in [.visible, .hidden, .alwaysHidden] {
            guard let controlItem = menuBarManager.controlItem(withName: section) else {
                diagLog.info("controlState[\(reason)] \(section.rawValue): nil")
                continue
            }
            diagLog.info("controlState[\(reason)] \(controlItem.diagnosticStateDescription())")
        }
    }

    private func logMenuBarAgentSequence(reason: String, items: [MenuBarItem]) {
        let sequence = items
            .filter { $0.tag.namespace == .menuBarAgent }
            .sorted { $0.bounds.minX < $1.bounds.minX }
            .map { item in
                "\(item.uniqueIdentifier) title=\(item.title ?? "nil") frame=\(NSStringFromRect(item.bounds))"
            }
        diagLog.info("menuBarAgentSequence[\(reason)] count=\(sequence.count) \(sequence.joined(separator: " | "))")
    }

    private func logThawAXSequence(reason: String, items: [MenuBarItem]) {
        let sequence = items
            .filter { item in
                item.tag.namespace == .thaw || item.uniqueIdentifier.contains("Thaw.ControlItem.")
            }
            .sorted { $0.bounds.minX < $1.bounds.minX }
            .map { item in
                "\(item.uniqueIdentifier) title=\(item.title ?? "nil") frame=\(NSStringFromRect(item.bounds))"
            }
        diagLog.info("thawAXSequence[\(reason)] count=\(sequence.count) \(sequence.joined(separator: " | "))")
    }

    @available(macOS 27, *)
    private func logControlItemCrops(reason: String, items: [MenuBarItem]) async {
        let displayID = Bridging.getActiveMenuBarDisplayID() ?? CGMainDisplayID()
        await ScreenCapture.logMenuBarHostingWindowCandidates(displayID: displayID, reason: reason)

        guard let capture = await ScreenCapture.captureMenuBarHostingWindowAsync(displayID: displayID) else {
            diagLog.warning("controlCrop[\(reason)]: hosting capture unavailable")
            return
        }

        let imageBounds = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
        for identifier in [ControlItem.Identifier.visible, .hidden] {
            guard let item = controlItem(in: items, matching: identifier) else {
                diagLog.info("controlCrop[\(reason)] id=\(identifier.rawValue): missing from fresh AX items")
                continue
            }

            let cropRect = CGRect(
                x: (item.bounds.minX - capture.windowFrame.minX) * capture.scale,
                y: (item.bounds.minY - capture.windowFrame.minY) * capture.scale,
                width: item.bounds.width * capture.scale,
                height: item.bounds.height * capture.scale
            ).integral
            let clippedCropRect = cropRect.intersection(imageBounds)

            guard !clippedCropRect.isNull, !clippedCropRect.isEmpty else {
                diagLog.warning(
                    "controlCrop[\(reason)] id=\(identifier.rawValue) crop outside host " +
                    "axFrame=\(NSStringFromRect(item.bounds)) crop=\(NSStringFromRect(cropRect))"
                )
                continue
            }

            guard let cropped = capture.image.cropping(to: clippedCropRect) else {
                diagLog.warning(
                    "controlCrop[\(reason)] id=\(identifier.rawValue) crop failed " +
                    "axFrame=\(NSStringFromRect(item.bounds)) crop=\(NSStringFromRect(clippedCropRect))"
                )
                continue
            }

            diagLog.info(
                "controlCrop[\(reason)] id=\(identifier.rawValue) " +
                "axFrame=\(NSStringFromRect(item.bounds)) crop=\(NSStringFromRect(clippedCropRect)) " +
                "size=\(cropped.width)x\(cropped.height) transparent=\(cropped.isTransparent())"
            )
        }
    }

    private func controlItem(
        in items: [MenuBarItem],
        matching identifier: ControlItem.Identifier
    ) -> MenuBarItem? {
        items.first { item in
            item.title == identifier.rawValue ||
                item.uniqueIdentifier.hasSuffix(":\(identifier.rawValue)") ||
                item.uniqueIdentifier == identifier.rawValue
        }
    }

    @available(macOS 27, *)
    private func probeHiddenTriggerPressIfEnabled(reason: String) {
        guard Defaults.bool(forKey: .diagnosticAssessmentModeProbeHiddenTriggerPress) else {
            return
        }

        guard let element = controlAXElement(matching: .hidden) else {
            diagLog.warning("hiddenTriggerAXPress[\(reason)]: element not found")
            return
        }

        let frame = AXHelpers.frame(for: element).map(NSStringFromRect) ?? "nil"
        let enabled = AXHelpers.enabledAttribute(element).map(String.init) ?? "nil"
        let role = AXHelpers.role(for: element).map { "\($0)" } ?? "nil"
        let didPress = AXHelpers.press(element)
        diagLog.info(
            "hiddenTriggerAXPress[\(reason)]: didPress=\(didPress) " +
            "role=\(role) enabled=\(enabled) frame=\(frame)"
        )
    }

    @available(macOS 27, *)
    private func controlAXElement(matching identifier: ControlItem.Identifier) -> UIElement? {
        guard
            let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                Constants.isThawOwnedBundleIdentifier($0.bundleIdentifier)
            }),
            let app = AXHelpers.application(for: runningApp),
            let extrasMenuBar = AXHelpers.extrasMenuBar(for: app)
        else {
            return nil
        }

        return AXHelpers.children(for: extrasMenuBar).first { child in
            resolvedAXIdentifier(for: child) == identifier.rawValue
        }
    }

    @available(macOS 27, *)
    private func resolvedAXIdentifier(for element: UIElement) -> String? {
        AXHelpers.identifier(for: element)?.nonEmpty
            ?? AXHelpers.children(for: element)
                .lazy
                .compactMap { AXHelpers.identifier(for: $0)?.nonEmpty }
                .first
            ?? AXHelpers.title(for: element)?.nonEmpty
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
