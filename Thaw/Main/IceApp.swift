//
//  IceApp.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI
import ThawCapture

@main
struct IceApp: App {
    init() {
        ScreenCapture.setProbeLoggingEnabled {
            Defaults.bool(forKey: .diagnosticAssessmentModeSceneProbes)
        }
    }

    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        WindowActionBridge(registerWindowActions: appDelegate.appState.registerWindowActions)
        SettingsWindow(appState: appDelegate.appState)
        PermissionsWindow(appState: appDelegate.appState)
    }
}
