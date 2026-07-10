//
//  AssessmentStateMonitor.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Observes the system Do-Not-Disturb / Assessment-Mode state so Thaw can
/// recover when its menu-bar concealment assertion is torn down or changed out
/// from under it.
///
/// On macOS 27 Thaw hides items by holding an `MBAssessmentModeAssertion` (see
/// ``RuntimeSessionController``). That assertion lives in the same subsystem as
/// Focus / Do-Not-Disturb; the system can invalidate or supersede it when the
/// user toggles a Focus, when another menu-bar manager takes an assertion, or
/// after certain reflows — leaving Thaw *believing* items are hidden while they
/// are actually back on screen.
///
/// ## Why not read `Assertions.json`?
///
/// The authoritative record lives at
/// `~/Library/DoNotDisturb/DB/Assertions.json`, but that directory is
/// TCC-protected: reading it returns `EPERM` unless the user grants **Full Disk
/// Access**, which Thaw does not require for anything else. Rather than demand
/// that entitlement, this monitor watches the **distributed notification**
/// `com.apple.donotdisturb.stateChanged`, which any process may observe without
/// special permission, and reconciles Thaw's in-process assertion against the
/// desired state when the subsystem reports a change.
@MainActor
final class AssessmentStateMonitor {
    /// Posted by the Do-Not-Disturb subsystem whenever assertion / Focus state
    /// changes. Observed via `DistributedNotificationCenter` (cross-process).
    static let stateChangedNotification = Notification.Name("com.apple.donotdisturb.stateChanged")

    private let onStateChanged: @MainActor () -> Void
    private let center: DistributedNotificationCenter
    private let diagLog = DiagLog(category: "AssessmentStateMonitor")
    private var observer: NSObjectProtocol?
    private var ignoreNextNotificationBefore: Date?

    /// Bounds attribution of one notification to Thaw's own assertion pulse.
    /// Only one notification is consumed; any second notification in the same
    /// burst is treated as external and reconciled immediately.
    private static let selfChangeAttributionWindow: TimeInterval = 1.5

    /// - Parameters:
    ///   - center: The distributed center to observe. Injectable for tests;
    ///     defaults to `.default()`.
    ///   - onStateChanged: Invoked on the main actor (debounced by the poster's
    ///     own coalescing) when the DND/assessment state changes, so the caller
    ///     can re-verify and, if needed, re-apply its concealment assertion.
    init(
        center: DistributedNotificationCenter = .default(),
        onStateChanged: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.onStateChanged = onStateChanged
    }

    isolated deinit {
        if let observer {
            // `DistributedNotificationCenter` observer removal is thread-safe.
            center.removeObserver(observer)
        }
    }

    /// Begins observing. Idempotent — a second call replaces the observer.
    func start() {
        stop()
        observer = center.addObserver(
            forName: Self.stateChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `DistributedNotificationCenter` delivers on the main queue here, so
            // main-actor isolation holds even though the closure is not isolated.
            MainActor.assumeIsolated {
                guard let self else { return }
                if let deadline = self.ignoreNextNotificationBefore,
                   Date() < deadline
                {
                    self.ignoreNextNotificationBefore = nil
                    self.diagLog.debug("ignoring one self-attributed DND/assessment state change")
                    return
                }
                self.ignoreNextNotificationBefore = nil
                self.diagLog.info("DND/assessment state changed; requesting reconcile")
                self.onStateChanged()
            }
        }
    }

    /// Attributes at most the next prompt distributed notification to Thaw's
    /// own assertion pulse, preventing that pulse from recursively triggering
    /// itself without suppressing the rest of the notification burst.
    func noteSelfChange() {
        ignoreNextNotificationBefore = Date().addingTimeInterval(Self.selfChangeAttributionWindow)
    }

    /// Stops observing.
    func stop() {
        if let observer {
            center.removeObserver(observer)
            self.observer = nil
        }
    }
}
