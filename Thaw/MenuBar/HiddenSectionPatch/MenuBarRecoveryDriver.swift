//
//  MenuBarRecoveryDriver.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import PlatformRuntimeKit

/// App-facing driver for the runtime recovery policy.
///
/// PlatformRuntimeKit owns the settle probe, consistency validation, and
/// escalation ladder. During the first integration phase, only
/// `AssessmentStateMonitor` and `MenuBarAgentPreferencesWatcher` feed this
/// adapter. Wake, display, and Space observers remain on their existing paths
/// until they can be migrated individually without duplicate subscribers.
@MainActor
final class MenuBarRecoveryDriver {
    private let coordinator: RuntimeRecoveryCoordinator

    init(
        environment: RuntimeRecoveryCoordinator.Environment,
        tunables: RuntimeRecoveryCoordinator.Tunables = .init()
    ) {
        coordinator = RuntimeRecoveryCoordinator(
            environment: environment,
            tunables: tunables
        )
    }

    func recover(trigger: RuntimeRecoveryCoordinator.Trigger) {
        coordinator.recover(trigger: trigger)
    }

    func stop() {
        coordinator.stop()
    }
}
