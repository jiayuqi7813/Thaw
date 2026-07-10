//
//  MenuBarAgentPreferencesWatcher.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Watches `com.apple.MenuBarAgent`'s preferences file for **external** changes
/// to `TrailingItemPreferredPositions` and reports them so the section layout
/// can be reconciled.
///
/// On macOS 27 the menu bar is hosted by `MenuBarAgent`, and item order is
/// driven by the `TrailingItemPreferredPositions` dictionary in its preferences
/// (see ``RuntimePreferenceStore``). That dictionary is not owned exclusively by
/// Thaw: `MenuBarAgent` rewrites it during its own reflows, other menu-bar
/// managers write it, and `defaults`/MDM can mutate it. When it changes out from
/// under us the live order can drift away from the layout the user configured.
///
/// This watcher gives Thaw a signal to restore concealment immediately after
/// such an external change — without polling. Persisted-order recovery remains
/// owned by the item manager's guarded saved-layout pipeline.
///
/// ## Loop safety
///
/// Thaw itself writes this file constantly during reorders, so a naive watcher
/// would feed its own writes straight back into a reconcile and oscillate. Two
/// guards prevent that:
///
/// 1. **Self-write suppression** — callers mark confirmed writes with
///    ``noteSelfWrite()``, which opens a short window during which file events
///    are ignored.
/// 2. **Snapshot diffing** — the reported positions are compared against the
///    last snapshot; identical contents never fire the callback, so a reconcile
///    that re-writes the same values cannot sustain a loop.
///
/// The callback is additionally debounced, because a single `cfprefsd` flush can
/// emit several file-system events (the file is replaced atomically).
@MainActor
final class MenuBarAgentPreferencesWatcher {
    /// Default path to `MenuBarAgent`'s per-user preferences plist. `cfprefsd`
    /// persists `kCFPreferencesAnyHost` values here (matching how
    /// ``RuntimePreferenceStore`` reads them).
    static var defaultPath: String {
        ("~/Library/Preferences/com.apple.MenuBarAgent.plist" as NSString).expandingTildeInPath
    }

    /// How long a single `noteSelfWrite()` suppresses subsequent file events.
    /// Comfortably longer than the `cfprefsd` flush latency for one write burst,
    /// short enough that a genuine external change right afterwards is not
    /// swallowed for long.
    private static let selfWriteSuppression: TimeInterval = 1.5

    /// Coalesces the burst of events from one atomic replace into a single
    /// callback.
    private static let debounceInterval: TimeInterval = 0.3

    private let path: String
    private let readPositions: @MainActor () -> [String: Int]
    private let onExternalChange: @MainActor ([String: Int]) -> Void
    private let diagLog = DiagLog(category: "MenuBarAgentPrefsWatcher")

    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    /// The last positions we reported (or seeded at `start()`). Used to suppress
    /// no-op events.
    private var lastSnapshot: [String: Int] = [:]

    /// File events at or before this instant are treated as Thaw's own writes
    /// and ignored.
    private var suppressUntil: Date = .distantPast

    /// - Parameters:
    ///   - path: The plist to watch. Defaults to ``defaultPath``; injectable for
    ///     tests.
    ///   - readPositions: Reads the current `TrailingItemPreferredPositions`.
    ///     Injected rather than re-deriving the `CFPreferences` access so the
    ///     watcher stays a pure file-event source.
    ///   - onExternalChange: Invoked on the main actor with the new positions
    ///     when the file changes for a reason other than Thaw's own writes.
    init(
        path: String = MenuBarAgentPreferencesWatcher.defaultPath,
        readPositions: @escaping @MainActor () -> [String: Int],
        onExternalChange: @escaping @MainActor ([String: Int]) -> Void
    ) {
        self.path = path
        self.readPositions = readPositions
        self.onExternalChange = onExternalChange
    }

    isolated deinit {
        debounceTask?.cancel()
        source?.cancel()
    }

    /// Begins watching. Seeds the snapshot with the current positions so the
    /// first genuine change is diffed against reality rather than firing
    /// spuriously. Safe to call once; re-arms itself when the file is replaced.
    func start() {
        lastSnapshot = readPositions()
        arm()
    }

    /// Stops watching and releases the file descriptor.
    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
    }

    /// Opens a window during which file events are attributed to Thaw's own
    /// writes and ignored. Call immediately after a synchronous confirmed write
    /// to `TrailingItemPreferredPositions`. The watcher and callers are both
    /// main-actor isolated, so a queued file event cannot interleave with the
    /// write and this marker.
    func noteSelfWrite() {
        lastSnapshot = readPositions()
        suppressUntil = Date().addingTimeInterval(Self.selfWriteSuppression)
    }

    // MARK: - Private

    /// Opens the file `O_EVTONLY` and installs a `DispatchSource`. `cfprefsd`
    /// rewrites the plist atomically (write-temp + rename), which unlinks the
    /// descriptor's inode, so `.delete`/`.rename` re-arm against the new file.
    private func arm() {
        source?.cancel()
        source = nil

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file may not exist yet (no positions written). Retry shortly;
            // MenuBarAgent creates it as soon as any item is positioned.
            diagLog.debug("open(\(self.path)) failed errno=\(errno); retrying")
            scheduleRearm()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The source is queued on `.main`, so main-actor isolation holds at
            // runtime even though the handler type is `@Sendable`.
            MainActor.assumeIsolated {
                guard let self else { return }
                let data = source.data
                if data.contains(.delete) || data.contains(.rename) || data.contains(.revoke) {
                    // Inode replaced/removed: re-open against the current path.
                    self.scheduleRearm()
                    return
                }
                self.scheduleCallback()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    /// Re-arms after an atomic replace, coalescing rapid delete/rename bursts and
    /// re-checking for a real change once the new file settles.
    private func scheduleRearm() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceInterval))
            guard let self, !Task.isCancelled else { return }
            self.arm()
            self.emitIfChanged()
        }
    }

    /// Debounces a write burst, then emits if the contents genuinely changed.
    private func scheduleCallback(after delay: TimeInterval = MenuBarAgentPreferencesWatcher.debounceInterval) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.emitIfChanged()
        }
    }

    /// Reports the new positions unless (a) we are inside a self-write window or
    /// (b) the contents are identical to the last snapshot.
    private func emitIfChanged() {
        let current = readPositions()
        guard current != lastSnapshot else { return }
        guard Date() >= suppressUntil else {
            let delay = max(suppressUntil.timeIntervalSinceNow, Self.debounceInterval)
            diagLog.debug("deferring MenuBarAgent positions change during self-write window")
            scheduleCallback(after: delay)
            return
        }
        lastSnapshot = current
        diagLog.info("external TrailingItemPreferredPositions change detected (\(current.count) key(s))")
        onExternalChange(current)
    }
}
