//
//  OverflowFallbackIcon.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

// MARK: - OverflowFallbackIcon

/// Interim fallback that renders concealed menu bar items using their owning
/// app's icon instead of the live screenshot crop when captured glyphs are
/// unavailable.
///
/// On macOS 27 the per-item reveal/capture used for concealed sections can
/// miss glyphs during MenuBarAgent reflows. Until a capture succeeds, the
/// app-icon fallback keeps the IceBar and layout editor from showing blank
/// slots.
enum OverflowFallbackIcon {
    /// The shared Control Center icon, reused for system-owned items whose
    /// `sourceApplication` resolves to a system agent rather than a real app.
    private static let controlCenterIcon: NSImage? = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.controlcenter")
        .first?
        .icon

    /// Whether concealed sections on macOS 27 may render app icons when live
    /// captures are missing or unreliable.
    @MainActor
    static func supportsMissingCaptureFallback(for section: MenuBarSection.Name?) -> Bool {
        guard #available(macOS 27, *) else { return false }
        guard let section, section != .visible else { return false }
        return true
    }

    /// Whether concealed items in `section` should fall back to the app icon
    /// when no captured glyph exists.
    @MainActor
    static func shouldPreferAppIcon(
        for section: MenuBarSection.Name?,
        appState _: AppState,
        cachedImage: NSImage?
    ) -> Bool {
        guard supportsMissingCaptureFallback(for: section) else { return false }
        return cachedImage == nil
    }

    /// The image Thaw Bar / layout UI should display for a concealed item.
    @MainActor
    static func resolvedImage(
        for item: MenuBarItem,
        section: MenuBarSection.Name?,
        appState: AppState,
        cachedImage: NSImage?
    ) -> NSImage? {
        if shouldPreferAppIcon(for: section, appState: appState, cachedImage: cachedImage) {
            return image(for: item)
        }
        return cachedImage
    }

    /// The owning app's icon for `item`, falling back to a generic menu-bar
    /// glyph when no application can be resolved (e.g. some system items).
    static func image(for item: MenuBarItem) -> NSImage? {
        switch item.tag.namespace {
        case .controlCenter, .systemUIServer, .textInputMenuAgent:
            if let controlCenterIcon {
                return controlCenterIcon
            }
        default:
            if let icon = item.sourceApplication?.icon {
                return icon
            }
        }
        return NSImage(
            systemSymbolName: "menubar.rectangle",
            accessibilityDescription: item.displayName
        )
    }
}
