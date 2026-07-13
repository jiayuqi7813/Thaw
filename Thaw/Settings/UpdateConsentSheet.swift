//
//  UpdateConsentSheet.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct UpdateConsentSheet: View {
    var onEnable: (_ autoDownload: Bool) -> Void
    var onDisable: () -> Void

    @State private var isProcessing = false
    @State private var autoDownload = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep \(Constants.displayName) up to date?")
                .font(.title2.bold())

            Text("\(Constants.displayName) can check for updates automatically. You can also check manually from the menu bar or Settings \(Constants.menuArrow) About.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            Toggle(isOn: $autoDownload) {
                Text("Download and install updates automatically")
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Check Manually") {
                    guard !isProcessing else { return }
                    isProcessing = true
                    onDisable()
                }
                .disabled(isProcessing)
                .buttonStyle(.glass)
                Button("Check Automatically") {
                    guard !isProcessing else { return }
                    isProcessing = true
                    onEnable(autoDownload)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
