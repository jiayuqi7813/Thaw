//
//  SpotlightMenuItemManager.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

/// Governs the menu-bar visibility of the Spotlight item, which the macOS 27
/// Assessment Mode allowlist *cannot* hide.
///
/// On macOS 27 the Spotlight menu-bar item is vended by `Campo.app`
/// (`com.apple.campo`, `/System/Applications/Campo.app`). It is neither a
/// Control Center module (so ``ControlCenterModuleManager`` does not own it) nor
/// an item with an `MBSystemItemIdentifier` index (so the Assessment Mode
/// system-item path cannot reach it). Putting `com.apple.campo` in the
/// assessment allowlist's *concealed* set is a silent no-op — Spotlight stays
/// visible. The only mechanism that actually hides it is Campo's own per-host
/// preference:
///
///     defaults -currentHost write com.apple.Spotlight MenuItemHidden -bool YES
///
/// where `YES`/`1` hides the item and `NO`/`0` (or absence) shows it
/// (reversibly confirmed via a live flip-test). Campo reads the preference at
/// launch, so this manager restarts it whenever it mutates the value; Campo is a
/// managed agent and relaunches itself within ~1-2s.
///
/// This mirrors ``ControlCenterModuleManager`` as a *separate subsystem* from
/// ``AssessmentModeBackend``: when the Spotlight item is assigned hidden it is
/// stripped from the assessment allowlist input and handled here instead.
@MainActor
final class SpotlightMenuItemManager {
    /// Injectable side effects used to read and mutate Spotlight state. Keeping
    /// these actor-isolated makes the production manager Swift 6-safe while
    /// allowing tests to use an in-memory preference value.
    @MainActor
    struct Environment {
        let readHidden: @MainActor () -> Bool?
        let writeHidden: @MainActor (Bool?) -> Bool
        let synchronize: @MainActor () -> Void
        let restartCampo: @MainActor () -> Void

        static var live: Environment {
            Environment(
                readHidden: { SpotlightMenuItemManager.readHidden() },
                writeHidden: { SpotlightMenuItemManager.writeHidden($0) },
                synchronize: { SpotlightMenuItemManager.synchronize() },
                restartCampo: { SpotlightMenuItemManager.restartCampo() }
            )
        }
    }

    /// The owning app's bundle identifier (the Spotlight menu-bar agent).
    static nonisolated let campoBundleID = "com.apple.campo"

    /// The item title the Spotlight menu-bar item exposes via AX.
    static nonisolated let spotlightItemTitle = "Spotlight"

    private static let domain = "com.apple.Spotlight" as CFString
    private static let hiddenKey = "MenuItemHidden" as CFString

    private let diagLog = DiagLog(category: "SpotlightMenuItemManager")
    private let environment: Environment

    /// Whether this manager currently has Spotlight hidden.
    private var isHidden = false

    /// The exact pre-hide preference to restore (absence is distinct from an
    /// explicit value so teardown removes a key that did not exist before Thaw).
    private var originalValue: OriginalPreference?

    /// Retains the block-based termination observer for the app's lifetime (this
    /// manager is owned by ``SimpleItemHider``, which lives the whole session).
    private var terminationObserver: NSObjectProtocol?

    init(
        environment: Environment = .live,
        notificationCenter: NotificationCenter = .default
    ) {
        self.environment = environment

        // Restore Spotlight if Thaw quits while it is hidden, so a pref hide
        // never outlives the app that applied it.
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        }
    }

    /// An exact snapshot of the preference before Thaw changed it.
    private enum OriginalPreference {
        case absent
        case value(Bool)

        init(_ value: Bool?) {
            self = value.map(Self.value) ?? .absent
        }

        var value: Bool? {
            switch self {
            case .absent:
                nil
            case let .value(value):
                value
            }
        }
    }

    // MARK: Identifier helpers

    /// Whether the given item `uniqueIdentifier` is the Spotlight item this
    /// manager governs (and therefore should be kept out of the assessment-mode
    /// allowlist input). The identifier is `com.apple.campo:Spotlight`.
    static nonisolated func isGovernable(itemIdentifier identifier: String) -> Bool {
        identifier == "\(campoBundleID):\(spotlightItemTitle)"
            || identifier.hasSuffix(":\(spotlightItemTitle)") && identifier.hasPrefix("\(campoBundleID):")
    }

    // MARK: Apply

    /// Hides or shows the Spotlight item via its per-host preference, restarting
    /// Campo only when the value actually changes (so the steady-state 1s refresh
    /// is a no-op once the desired state is applied).
    ///
    /// - Returns: `true` if the preference changed (and Campo was restarted),
    ///   `false` otherwise.
    @discardableResult
    func apply(hidden desiredHidden: Bool) -> Bool {
        guard desiredHidden != isHidden else {
            return false
        }

        var changed = false
        if desiredHidden {
            // Capture the pre-hide value once, on the transition into hiding.
            if originalValue == nil {
                originalValue = OriginalPreference(environment.readHidden())
            }
            changed = environment.writeHidden(true)
        } else {
            let restore = originalValue?.value
            originalValue = nil
            // Restoring to `nil` removes the key Thaw added; restoring to an
            // explicit prior value re-establishes what the user had.
            changed = environment.writeHidden(restore)
        }

        isHidden = desiredHidden

        if changed {
            environment.synchronize()
            environment.restartCampo()
            diagLog.info("applied Spotlight visibility; hidden=\(desiredHidden)")
        }
        return changed
    }

    /// Restores Spotlight to its pre-hide visibility. Used on teardown / app
    /// termination so a pref hide never persists past Thaw.
    func restore() {
        apply(hidden: false)
    }

    // MARK: Preference I/O

    private static func readHidden() -> Bool? {
        let value = CFPreferencesCopyValue(
            hiddenKey,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return (value as? NSNumber)?.boolValue
    }

    @discardableResult
    private static func writeHidden(_ hidden: Bool?) -> Bool {
        if readHidden() == hidden {
            return false
        }
        if let hidden {
            CFPreferencesSetValue(
                hiddenKey,
                hidden as CFBoolean,
                domain,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        } else {
            CFPreferencesSetValue(
                hiddenKey,
                nil,
                domain,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }
        return true
    }

    private static func synchronize() {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    /// Sends SIGTERM to the running Campo (Spotlight menu-bar agent) so it
    /// relaunches and re-reads the preference. Campo is a managed agent and
    /// restarts itself automatically within ~1-2s.
    private static func restartCampo() {
        for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier == campoBundleID
        {
            kill(app.processIdentifier, SIGTERM)
        }
    }
}
