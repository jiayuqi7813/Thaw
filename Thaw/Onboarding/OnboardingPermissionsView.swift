//
//  OnboardingPermissionsView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// Permission step used by both first-launch onboarding and later
/// missing-permission startup recovery.
struct ThawPermissionsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var permissions: AppPermissions

    var onContinue: () -> Void

    @State private var appeared = false

    private var requiredGranted: Bool {
        permissions.permissionsState != .missing
    }

    private var allGranted: Bool {
        permissions.permissionsState == .hasAll
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 7) {
                Text("Enable Permissions")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Thaw uses the permissions below to manage your menu bar. Permission checks happen on your Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            .scaleEffect(appeared ? 1 : 0.96)
            .opacity(appeared ? 1 : 0)

            HStack(alignment: .top, spacing: 14) {
                ForEach(permissions.allPermissions) { permission in
                    OnboardingPermissionCard(permission: permission)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 30)

            privacyPanel

            VStack(spacing: 12) {
                Button {
                    Task {
                        await permissions.refreshPermissionsState()
                        onContinue()
                    }
                } label: {
                    Text(requiredGranted && !allGranted ? "Continue in Limited Mode" : "Continue")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.glassProminent)
                .disabled(!requiredGranted)

                Text("Accessibility is required to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(requiredGranted ? 0 : 1)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 24)
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffectBackground())
        .onAppear {
            Task {
                await permissions.refreshPermissionsState()
            }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.3)) {
                appeared = true
            }
        }
    }

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            privacyFact("No analytics or usage tracking")
            privacyFact("Permission checks stay on your Mac")
            privacyFact("Open source under GPL; inspect how it works")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 30)
    }

    private func privacyFact(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 1.5)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingPermissionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var permission: Permission

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: permission.iconName)
                    .foregroundStyle(permission.iconColor)

                Text(permission.title)
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                if !permission.isRequired {
                    Text("Optional")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(permission.onboardingDetails, id: \.self) { detail in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 3))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 5)

                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if permission.hasPermission {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            } else {
                Button {
                    permission.performRequest()
                } label: {
                    Text("Grant Access")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: permission.hasPermission)
    }
}
