//
//  CacheRebucketter.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

/// Reconstructs Visible/Hidden/Always-Hidden cache buckets from assertion-backed
/// assignments. AX enumeration only returns live items and cannot classify the
/// zero-width section dividers on macOS 27.
enum CacheRebucketter {
    @MainActor
    static func rebucket(
        _ input: MenuBarItemManager.ItemCache,
        hider: SimpleItemHider,
        allowsAlwaysHidden: Bool
    ) -> MenuBarItemManager.ItemCache {
        var cache = input
        var visible = [MenuBarItem]()
        var hidden = [MenuBarItem]()
        var alwaysHidden = [MenuBarItem]()

        for item in cache[.visible] {
            guard !item.isControlItem else {
                visible.append(item)
                continue
            }
            switch hider.section(for: item) {
            case .visible:
                visible.append(item)
            case .hidden:
                hidden.append(item)
            case .alwaysHidden:
                if allowsAlwaysHidden {
                    alwaysHidden.append(item)
                } else {
                    hidden.append(item)
                }
            }
        }
        cache[.visible] = visible
        cache[.hidden] = hidden + cache[.hidden]
        cache[.alwaysHidden] = alwaysHidden + cache[.alwaysHidden]

        let liveIdentifiers = Set(
            MenuBarSection.Name.allCases.flatMap { cache[$0].map(\.uniqueIdentifier) }
        )
        for (identifier, section) in hider.sectionAssignment where !liveIdentifiers.contains(identifier) {
            guard let snapshot = hider.snapshot(for: identifier) else { continue }
            let target: MenuBarSection.Name = section == .alwaysHidden && allowsAlwaysHidden
                ? .alwaysHidden
                : .hidden
            cache[target].append(snapshot)
        }

        for section in MenuBarSection.Name.allCases {
            cache[section] = hider.ordered(cache[section], in: section)
        }
        return cache
    }
}
