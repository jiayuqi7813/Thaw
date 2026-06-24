//
//  MenuBarAgentPositionStore.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

/// Reorders menu bar items on macOS 27 by writing MenuBarAgent's own layout
/// preference instead of synthesizing a Command-drag.
///
/// macOS 27 hosts every status item inside `com.apple.MenuBarAgent` and records
/// the bar's left-to-right arrangement in a single preference value:
///
///     com.apple.MenuBarAgent → TrailingItemPreferredPositions : { key → Int }
///
/// (current-user / **any-host**; read it with `defaults read com.apple.MenuBarAgent`,
/// *not* `-currentHost`). Each key is one of:
///
///   * `module:<Name>`        — Apple Control Center modules (`module:WiFi`,
///                              `module:Clock` = 0, `module:BentoBox-0` = 88, …).
///   * `status:<App>::<ItemID>` — third-party status items, where `<App>` is the
///                              owning app's display name and `<ItemID>` is the
///                              status item's identifier (`status:Codex::Item-0`,
///                              `status:Hidden Bar::hiddenbar_expandcollapse`, …).
///
/// The integer is a sort weight; MenuBarAgent lays the bar out by ordering the
/// keys by that weight. Rewriting a key's weight and nudging the agent to
/// re-read therefore moves the item **without touching the cursor** — the
/// cursor-warp-free reorder Bartender 7 "Golden Gate" ships.
///
/// This store performs a *minimal* relative move: it reassigns only the moved
/// item's weight to the midpoint between its destination's two live neighbors,
/// so system anchors (Clock, Control Center) and unrelated items keep their
/// existing weights. The midpoint sorts between the neighbors regardless of
/// whether the global weight axis increases left-to-right or right-to-left, so
/// the store never has to assume a sign for the axis.
///
/// **Empirically uncertain** (validated at runtime by the caller, which falls
/// back to the synthetic ⌘-drag when a move does not verify): the exact
/// `status:` key spelling for a given third-party item, and whether a bare
/// write+synchronize is enough to make the agent re-lay-out without a restart.
/// The live environment plays it safe and SIGTERMs MenuBarAgent (a managed
/// launch agent that relaunches itself within ~1-2 s), mirroring how
/// ``ControlCenterModuleManager`` relaunches Control Center.
@available(macOS 27, *)
@MainActor
enum MenuBarAgentPositionStore {
    private static let diagLog = DiagLog(category: "MenuBarAgentPositionStore")

    private static let domain = "com.apple.MenuBarAgent" as CFString
    private static let positionsKey = "TrailingItemPreferredPositions" as CFString
    private static let agentBundleID = "com.apple.MenuBarAgent"

    // MARK: Environment

    /// Injectable side effects, so tests can drive an in-memory dictionary
    /// instead of the real preference domain and process table.
    @MainActor
    struct Environment {
        let readPositions: @MainActor () -> [String: Int]
        let writePositions: @MainActor ([String: Int]) -> Void
        let nudgeAgent: @MainActor () -> Void

        static var live: Environment {
            Environment(
                readPositions: { MenuBarAgentPositionStore.readPositions() },
                writePositions: { MenuBarAgentPositionStore.writePositions($0) },
                nudgeAgent: { MenuBarAgentPositionStore.nudgeAgent() }
            )
        }
    }

    // MARK: Orchestration

    /// Attempts to move `item` to `destination` by rewriting its preferred
    /// position. Returns `true` when a new weight was written and the agent
    /// nudged; `false` when the move could not be expressed as a position
    /// write (unresolved key, no numeric gap, or an end placement), so the
    /// caller should fall back to the synthetic drag.
    ///
    /// The caller is responsible for re-enumerating and verifying the order
    /// after this returns `true`; this method does not block on the agent
    /// re-laying-out.
    @discardableResult
    static func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        liveItems: [MenuBarItem],
        environment: Environment = .live
    ) -> Bool {
        guard item.isMovable, !destination.targetItem.tag.isLayoutAnchoredSystemItem else {
            return false
        }

        let positions = environment.readPositions()
        let keys = Array(positions.keys)

        guard let movedKey = resolveKey(for: item, existingKeys: keys) else {
            diagLog.debug("No MenuBarAgent key for \(item.logString); deferring to synthetic drag")
            return false
        }

        // Pick the two live neighbors that bracket the drop slot, computed from
        // the observed left-to-right visual order with the moved item removed.
        guard let neighbors = neighborItems(
            forMoving: item,
            to: destination,
            liveItems: liveItems
        ) else {
            return false
        }

        guard
            let anchorKey = resolveKey(for: neighbors.anchor, existingKeys: keys),
            let anchorValue = positions[anchorKey]
        else {
            return false
        }

        // The far neighbor may be absent (the anchor sits at the end of the
        // movable run). Without a second bound we cannot pick a direction-safe
        // midpoint, so defer to the synthetic drag for end placements.
        guard
            let farNeighbor = neighbors.far,
            let farKey = resolveKey(for: farNeighbor, existingKeys: keys),
            let farValue = positions[farKey]
        else {
            diagLog.debug("End placement for \(item.logString); deferring to synthetic drag")
            return false
        }

        guard let newValue = midpointPosition(between: anchorValue, and: farValue) else {
            diagLog.debug(
                "No numeric gap between \(anchorKey)=\(anchorValue) and \(farKey)=\(farValue); deferring"
            )
            return false
        }

        var updated = positions
        updated[movedKey] = newValue
        environment.writePositions(updated)
        environment.nudgeAgent()
        diagLog.info("Wrote \(movedKey)=\(newValue) (between \(anchorValue) and \(farValue)) for \(destination.logString)")
        return true
    }

    // MARK: Pure planning

    /// The two live items that bracket the slot `item` is moving into: `anchor`
    /// is the destination's target, `far` is the item on the other side of the
    /// slot (nil when the anchor is at the end of the movable run). Computed
    /// with the moved item removed so its current position never skews the slot.
    static func neighborItems(
        forMoving item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        liveItems: [MenuBarItem]
    ) -> (anchor: MenuBarItem, far: MenuBarItem?)? {
        let ordered = liveItems
            .filter { !$0.isSystemClone && !$0.tag.isLayoutAnchoredSystemItem }
            .filter { !$0.tag.matchesIgnoringWindowID(item.tag) }
            .sorted { $0.bounds.minX < $1.bounds.minX }

        let anchor = destination.targetItem
        guard let anchorIndex = ordered.firstIndex(where: {
            $0.tag.matchesIgnoringWindowID(anchor.tag)
        }) else {
            return nil
        }

        switch destination {
        case .leftOfItem:
            // Slot is between the anchor and its left neighbor.
            let far = anchorIndex > ordered.startIndex ? ordered[anchorIndex - 1] : nil
            return (ordered[anchorIndex], far)
        case .rightOfItem:
            // Slot is between the anchor and its right neighbor.
            let far = anchorIndex + 1 < ordered.endIndex ? ordered[anchorIndex + 1] : nil
            return (ordered[anchorIndex], far)
        }
    }

    /// Returns a weight that sorts strictly between `anchorValue` and
    /// `neighborValue`, or nil when no integer lies between them. Order-agnostic:
    /// the midpoint sorts between the two regardless of which is larger, so the
    /// caller never has to know whether the weight axis grows left or right.
    static func midpointPosition(between anchorValue: Int, and neighborValue: Int) -> Int? {
        let lo = min(anchorValue, neighborValue)
        let hi = max(anchorValue, neighborValue)
        guard hi - lo >= 2 else { return nil }
        return lo + (hi - lo) / 2
    }

    /// Resolves a live item to its existing key in the positions dictionary.
    ///
    /// Three key shapes appear in `TrailingItemPreferredPositions`:
    ///   * `module:<title>` — Apple Control Center modules.
    ///   * `status:<bundleID>::<itemID>` — the common third-party form, where
    ///     `<bundleID>` is the owning app's bundle identifier (== the item's
    ///     namespace) and `<itemID>` == Thaw's `tag.title` (both read the AX
    ///     identifier), e.g. `status:notion.id::Item-0`.
    ///   * `status:<AppDisplayName>::<itemID>` — the minority form used by apps
    ///     that register a display name (e.g. `status:iStat Menus Menubar::…`).
    ///
    /// Resolution tries them in that order. The bundle-ID form is exact, so it
    /// is preferred over the suffix match, which for generic `Item-0` titles has
    /// dozens of candidates that only the owning app's display name disambiguates.
    static func resolveKey(for item: MenuBarItem, existingKeys: [String]) -> String? {
        let title = item.tag.title
        guard !title.isEmpty else { return nil }

        // Apple modules hosted by MenuBarAgent.
        if item.tag.namespace.isMenuBarHostingNamespace {
            let moduleKey = "module:\(title)"
            if existingKeys.contains(moduleKey) {
                return moduleKey
            }
        }

        // Exact bundle-ID form: status:<namespace>::<title>.
        let bundleKey = "status:\(item.tag.namespace.description)::\(title)"
        if existingKeys.contains(bundleKey) {
            return bundleKey
        }

        // Display-name form, disambiguated by the owning app's display name when
        // the item title alone (e.g. "Item-0") matches several apps.
        let suffix = "::\(title)"
        let candidates = existingKeys.filter { $0.hasPrefix("status:") && $0.hasSuffix(suffix) }
        if candidates.count == 1 {
            return candidates[0]
        }
        if candidates.count > 1 {
            let appNames = candidateAppNames(for: item)
            if let match = candidates.first(where: { key in
                let app = key.dropFirst("status:".count).dropLast(suffix.count)
                return appNames.contains(String(app))
            }) {
                return match
            }
        }
        return nil
    }

    /// Display-name candidates MenuBarAgent might use for the item's owning app.
    private static func candidateAppNames(for item: MenuBarItem) -> Set<String> {
        var names = Set<String>()
        if let localized = item.sourceApplication?.localizedName {
            names.insert(localized)
        }
        names.insert(item.displayName)
        return names
    }

    // MARK: Preference I/O

    private static func readPositions() -> [String: Int] {
        // MenuBarAgent owns and continuously rewrites this domain in another
        // process. CFPreferences caches another app's values per reading
        // process, so a long-running Thaw would keep serving the snapshot it
        // cached the first time it touched the domain (near-empty at launch,
        // before the agent populated it) and every key lookup would miss.
        // Synchronizing first flushes that cache so each read reflects the
        // agent's current layout.
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let value = CFPreferencesCopyValue(
            positionsKey,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    private static func writePositions(_ positions: [String: Int]) {
        let cfValue = positions.mapValues { NSNumber(value: $0) } as CFDictionary
        CFPreferencesSetValue(
            positionsKey,
            cfValue,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// The last time ``nudgeAgent()`` SIGTERM'd MenuBarAgent. Used to coalesce
    /// restarts so a full layout pass — which calls ``move(...)`` once per item —
    /// does not relaunch the agent once per item.
    private static var lastNudge: Date = .distantPast
    private static let nudgeCoalesceWindow: TimeInterval = 1.5

    /// Makes MenuBarAgent re-read the layout. The reliable trigger is a restart:
    /// MenuBarAgent is a managed launch agent and relaunches within ~1-2 s, the
    /// same mechanism ``ControlCenterModuleManager`` uses for Control Center.
    ///
    /// Restarts are coalesced: ``writePositions(_:)`` always persists the full
    /// dictionary, so an agent already relaunching from a recent SIGTERM reads
    /// the latest cumulative layout. Skipping a redundant kill within the
    /// coalesce window avoids a relaunch storm (and menu-bar flicker) during a
    /// multi-item pass without dropping any positional change.
    private static func nudgeAgent() {
        let now = Date()
        guard now.timeIntervalSince(lastNudge) >= nudgeCoalesceWindow else {
            return
        }
        lastNudge = now
        for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier == agentBundleID
        {
            kill(app.processIdentifier, SIGTERM)
        }
    }
}
