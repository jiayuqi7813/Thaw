//
//  AssessmentStateMonitor.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation
import MenuBarModel

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
    private var suppressSelfChangesUntil = Date.distantPast

    /// How long after a self-initiated assertion change to ignore DND/assessment
    /// notifications.
    ///
    /// This must suppress the *whole* burst, not just one notification: a single
    /// recovery rung mutates the assertion more than once (the double-toggle does
    /// `apply` then `pulse`, and `pulse` itself invalidates-then-reapplies), and
    /// because Thaw's concealment assertion lives in the Do-Not-Disturb subsystem,
    /// each mutation posts its own `stateChanged`. Consuming only the first would
    /// let the second re-enter recovery — re-applying the assertion, posting again
    /// — a feedback loop that continuously re-composites the menu bar and
    /// eventually crashes the status-item scene machinery. A time window swallows
    /// the entire self-attributed burst; a genuine external teardown that lands
    /// inside the window is picked up by the next reconcile trigger.
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
                // Suppress the entire self-attributed burst, not just the first
                // notification — otherwise a recovery re-apply's second
                // `stateChanged` re-enters recovery and loops.
                if Date() < self.suppressSelfChangesUntil {
                    self.diagLog.debug("ignoring self-attributed DND/assessment state change")
                    return
                }
                self.diagLog.info("DND/assessment state changed; requesting reconcile")
                self.onStateChanged()
            }
        }
    }

    /// Opens a window during which DND/assessment notifications are attributed to
    /// Thaw's own assertion change and ignored. Call immediately before each
    /// self-initiated assertion mutation; re-arming extends the window so a
    /// multi-step recovery (which mutates the assertion several times) stays
    /// covered for its whole duration.
    func noteSelfChange() {
        suppressSelfChangesUntil = Date().addingTimeInterval(Self.selfChangeAttributionWindow)
    }

    /// Stops observing.
    func stop() {
        if let observer {
            center.removeObserver(observer)
            self.observer = nil
        }
    }
}
