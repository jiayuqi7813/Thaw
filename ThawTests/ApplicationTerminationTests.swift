//
//  ApplicationTerminationTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Testing
@testable import Thaw

@Suite("Application termination")
struct ApplicationTerminationTests {
    @Test("Termination is deferred through the supplied scheduler")
    @MainActor
    func terminationIsDeferred() {
        var scheduledAction: (@MainActor () -> Void)?
        var didTerminate = false

        ApplicationTermination.request(
            schedule: { scheduledAction = $0 },
            terminate: { didTerminate = true }
        )

        #expect(!didTerminate)
        #expect(scheduledAction != nil)

        scheduledAction?()

        #expect(didTerminate)
    }
}
