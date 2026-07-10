//
//  ScreenCapture.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation
import MenuBarModel
import os.lock

typealias ProbeLoggingProvider = @Sendable () -> Bool

/// A namespace for screen capture operations.
public enum ScreenCapture {
    static let diagLog = DiagLog(category: "ScreenCapture")
    static let cachedPermissionResult = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    static let probeLoggingProvider = OSAllocatedUnfairLock<ProbeLoggingProvider>(initialState: { false })

    /// Registers a live predicate for diagnostic probe logging.
    public static func setProbeLoggingEnabled(_ f: @escaping @Sendable () -> Bool) {
        probeLoggingProvider.withLock { $0 = f }
    }

    static func isProbeLoggingEnabled() -> Bool {
        probeLoggingProvider.withLock { $0() }
    }
}
