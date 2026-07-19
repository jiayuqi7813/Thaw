//
//  OverflowFallbackIcon.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

// MARK: - OverflowFallbackIcon

/// Interim fallback that renders menu bar items using their owning app's icon
/// instead of the live screenshot crop when captured glyphs are unavailable or
/// the user opts out of live previews.
///
/// On macOS 27 native hiding / overflow often produces incomplete hosting-window
/// crops. When the image cache clears those failed captures, this fallback keeps
/// IceBar and the layout editor from showing blank slots until a complete
/// capture succeeds.
enum OverflowFallbackIcon {
    /// The shared Control Center icon, reused for system-owned items whose
    /// `sourceApplication` resolves to a system agent rather than a real app.
    private static let controlCenterIcon: NSImage? = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.controlcenter")
        .first?
        .icon

    /// Whether macOS 27 may render app icons when live captures are missing.
    @MainActor
    static func supportsMissingCaptureFallback(for section: MenuBarSection.Name?) -> Bool {
        guard #available(macOS 27, *) else { return false }
        return section != nil
    }

    /// Whether items in `section` should use the app icon instead of a captured
    /// glyph.
    @MainActor
    static func shouldPreferAppIcon(
        for section: MenuBarSection.Name?,
        appState: AppState,
        cachedImage: NSImage?
    ) -> Bool {
        guard supportsMissingCaptureFallback(for: section) else { return false }
        // User escape hatch: always render the owning app's icon instead of the
        // live capture, regardless of whether a (possibly polluted) capture
        // exists. Lets users sidestep macOS 27 native-overflow capture bleed.
        if appState.settings.advanced.alwaysUseAppIconForMenuBarItems {
            return true
        }
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
