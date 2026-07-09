//
//  BundleExtensions.swift
//  Project: MenuBarModel
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// The subset of `Bundle` metadata accessors that `Constants` needs.
///
/// The full extension (colors, display name, etc.) stays in the app's
/// `Extensions.swift`; only the pieces `Constants` depends on are duplicated
/// here to keep this package's dependency surface small.
extension Bundle {
    /// The bundle's copyright string.
    public var copyrightString: String? {
        object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    /// The bundle's display name.
    public var displayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Thaw"
    }

    /// The bundle's version string.
    public var versionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The bundle's build string.
    public var buildString: String? {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
