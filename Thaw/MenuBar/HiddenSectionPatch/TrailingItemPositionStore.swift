//
//  TrailingItemPositionStore.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Reads and writes `TrailingItemPreferredPositions` in
/// `com.apple.MenuBarAgent`'s preferences domain.
///
/// On macOS 27 there are no per-item CG windows and AX attributes like
/// `AXHidden` or `AXAlternateUIVisible` are unsupported on menu-bar items
/// (confirmed via AX probe). The only per-item control surface that remains
/// is the position-preference dictionary `TrailingItemPreferredPositions`,
/// used to lock item positions.
///
/// Each item is keyed as `status:{bundleID}::{title}` and maps to an integer
/// position. Items are ordered by position from right to left.
///
/// Rather than hiding items with elevated positions (50000 just shifts them
/// left without collapsing), this store locks **visible** items at their
/// current positions before the assessment-mode assertion fires. Without a
/// lock the assertion re-composites the whole bar on every activation,
/// ghosting dynamic neighbors like iStat Menus. Writing a position tells
/// MenuBarAgent to keep the item anchored at that slot regardless of
/// concealment/reflow elsewhere.
@MainActor
final class TrailingItemPositionStore {
    private static let agentDomain = "com.apple.MenuBarAgent" as CFString
    private static let positionKey = "TrailingItemPreferredPositions"

    /// The unmodified position dictionary at lock-time, before we pin visible
    /// items at their current positions. Restored when locking stops.
    private var originalPositions: [String: Int]?

    private let diagLog = DiagLog(category: "TrailingItemPos")

    /// Writes the current on-screen position of each visible item so
    /// MenuBarAgent anchors them in place during the assertion reflow. Call
    /// before every assertion apply/pulse while the experimental flag is on.
    ///
    /// Any item previously locked that is no longer visible gets restored to
    /// its original position (or its key removed).
    ///
    /// - Parameters:
    ///   - visibleItemKeys: `TrailingItemPreferredPositions` keys for items
    ///     that should stay anchored.
    ///   - allItems: The full live item list, used to read current positions.
    @discardableResult
    func lockVisiblePositions(visibleItemKeys: Set<String>, allItems: [MenuBarItem]) -> Set<String> {
        var current = readPositions()
        let isFirstApply = originalPositions == nil
        if isFirstApply {
            originalPositions = current
        }

        // Build a lookup of current on-screen positions.
        var currentPositions: [String: Int] = [:]
        for item in allItems {
            let key = Self.key(for: item)
            let pos = Int(item.bounds.midX.rounded())
            currentPositions[key] = pos
        }

        var changed = false
        var handled = Set<String>()

        // Restore previously pinned items that should now be free.
        if let saved = originalPositions {
            let pinnedKeys = current.keys.filter { saved.keys.contains($0) }
            for key in pinnedKeys where !visibleItemKeys.contains(key) {
                if let original = saved[key] {
                    current[key] = original
                    changed = true
                    diagLog.debug("restored original position \(original) for \(key)")
                } else {
                    current.removeValue(forKey: key)
                    changed = true
                    diagLog.debug("removed position override for \(key)")
                }
            }
        }

        // Write current on-screen positions for visible items.
        for key in visibleItemKeys {
            guard let pos = currentPositions[key] else { continue }
            if current[key] == pos {
                handled.insert(key)
                continue
            }
            if originalPositions?[key] == nil {
                originalPositions?[key] = current[key] ?? pos
                diagLog.debug("saved original position \(originalPositions?[key] ?? 0) for \(key)")
            }
            current[key] = pos
            handled.insert(key)
            changed = true
            diagLog.debug("locked position \(pos) for \(key)")
        }

        guard changed else { return handled }

        writePositions(current)

        if !handled.isEmpty {
            diagLog.info("lock: pinned \(handled.count) visible item position(s)")
        }
        return handled
    }

    /// Restores all positions to their original values.
    func restoreAll() {
        guard let saved = originalPositions else { return }
        writePositions(saved)
        diagLog.info("restoreAll: restored \(saved.count) position(s)")
        originalPositions = nil
    }

    /// Builds the `TrailingItemPreferredPositions` key for a menu-bar item.
    /// Format: `status:{bundleID}::{title}`
    static func key(for item: MenuBarItem) -> String {
        "status:\(item.tag.namespace)::\(item.tag.title)"
    }

    // MARK: Private

    private func readPositions() -> [String: Int] {
        // Try CFPreferences with AnyHost first (matches `defaults read`).
        if let dict = CFPreferencesCopyValue(
            Self.positionKey as CFString,
            Self.agentDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Int] {
            return dict
        }
        // Fallback: read the plist file directly.
        let plistPath = ("~/Library/Preferences/\(Self.agentDomain as String).plist" as NSString).expandingTildeInPath
        if let plist = NSDictionary(contentsOfFile: plistPath),
           let dict = plist[Self.positionKey] as? [String: Int] {
            diagLog.debug("readPositions: read \(dict.count) entries from plist file")
            return dict
        }
        // Also try CurrentHost as last resort.
        if let dict = CFPreferencesCopyValue(
            Self.positionKey as CFString,
            Self.agentDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Int] {
            return dict
        }
        diagLog.debug("readPositions: no existing dict, starting empty")
        return [:]
    }

    private func writePositions(_ dict: [String: Int]) {
        // CFPreferences path.
        CFPreferencesSetValue(
            Self.positionKey as CFString,
            dict as CFPropertyList,
            Self.agentDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            Self.agentDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        // Direct plist write fallback so MenuBarAgent sees the change even
        // if CFPreferences sync doesn't propagate cross-process.
        let plistPath = ("~/Library/Preferences/\(Self.agentDomain as String).plist" as NSString).expandingTildeInPath
        let plist = (NSMutableDictionary(contentsOfFile: plistPath) as NSMutableDictionary?) ?? NSMutableDictionary()
        plist[Self.positionKey] = dict
        plist.write(toFile: plistPath, atomically: true)
    }
}
