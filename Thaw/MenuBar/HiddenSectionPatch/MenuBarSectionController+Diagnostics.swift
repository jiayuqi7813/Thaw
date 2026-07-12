//
//  MenuBarSectionController+Diagnostics.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@preconcurrency import AXSwift
import Cocoa
import MenuBarModel
import PlatformRuntimeKit
import ThawCapture

/// Assessment-mode scene probes and log dumps for ``MenuBarSectionController``.
///
/// Gated behind debug defaults (``Defaults.Key/diagnosticAssessmentModeSceneProbes``
/// and related keys). These methods have no production behavior when the defaults
/// are off; they exist only to capture restriction-scene snapshots for debugging.
extension MenuBarSectionController {
    var shouldRunAssessmentModeSceneProbes: Bool {
        guard #available(macOS 27, *) else {
            return false
        }
        return Defaults.bool(forKey: .diagnosticAssessmentModeSceneProbes)
    }

    func logRestrictionProbeSnapshot(reason: String, items: [MenuBarItem]) {
        guard shouldRunAssessmentModeSceneProbes else {
            return
        }
        logMenuBarAgentSequence(reason: reason, items: items)
        logThawAXSequence(reason: reason, items: items)
        logControlItemStates(reason: reason)
    }

    func runPostRestrictionSceneProbes() {
        guard shouldRunAssessmentModeSceneProbes else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard #available(macOS 27, *) else { return }
            await runSceneProbe(reason: "after-apply+0ms")
            try? await Task.sleep(for: .milliseconds(250))
            await runSceneProbe(reason: "after-apply+250ms")
            try? await Task.sleep(for: .milliseconds(750))
            await runSceneProbe(reason: "after-apply+1000ms")
        }
    }

    @available(macOS 27, *)
    private func runSceneProbe(reason: String) async {
        let items = MenuBarItemAXProvider.menuBarItems(option: [])
        logRestrictionProbeSnapshot(reason: reason, items: items)
        await logControlItemCrops(reason: reason, items: items)
        if reason == "after-apply+250ms" {
            probeHiddenTriggerPressIfEnabled(reason: reason)
        }
    }

    private func logControlItemStates(reason: String) {
        guard let menuBarManager = appState?.menuBarManager else {
            return
        }

        for section: MenuBarSection.Name in [.visible, .hidden, .alwaysHidden] {
            guard let controlItem = menuBarManager.controlItem(withName: section) else {
                diagLog.info("controlState[\(reason)] \(section.rawValue): nil")
                continue
            }
            diagLog.info("controlState[\(reason)] \(controlItem.diagnosticStateDescription())")
        }
    }

    private func logMenuBarAgentSequence(reason: String, items: [MenuBarItem]) {
        let sequence = MenuBarItem.sortByLeadingEdge(
            items.filter { $0.tag.namespace == .menuBarAgent }
        )
        .map { item in
            "\(item.uniqueIdentifier) title=\(item.title ?? "nil") frame=\(NSStringFromRect(item.bounds))"
        }
        diagLog.info("menuBarAgentSequence[\(reason)] count=\(sequence.count) \(sequence.joined(separator: " | "))")
    }

    private func logThawAXSequence(reason: String, items: [MenuBarItem]) {
        let sequence = MenuBarItem.sortByLeadingEdge(
            items.filter { item in
                item.tag.namespace == .thaw || item.uniqueIdentifier.contains("Thaw.ControlItem.")
            }
        )
        .map { item in
            "\(item.uniqueIdentifier) title=\(item.title ?? "nil") frame=\(NSStringFromRect(item.bounds))"
        }
        diagLog.info("thawAXSequence[\(reason)] count=\(sequence.count) \(sequence.joined(separator: " | "))")
    }

    @available(macOS 27, *)
    private func logControlItemCrops(reason: String, items: [MenuBarItem]) async {
        let displayID = Bridging.getActiveMenuBarDisplayID() ?? CGMainDisplayID()
        await ScreenCapture.logMenuBarHostingWindowCandidates(displayID: displayID, reason: reason)

        guard let capture = await ScreenCapture.captureMenuBarHostingWindowAsync(displayID: displayID) else {
            diagLog.warning("controlCrop[\(reason)]: hosting capture unavailable")
            return
        }

        let imageBounds = CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
        for identifier in [ControlItem.Identifier.visible, .hidden] {
            guard let item = controlItem(in: items, matching: identifier) else {
                diagLog.info("controlCrop[\(reason)] id=\(identifier.rawValue): missing from fresh AX items")
                continue
            }

            let cropRect = CGRect(
                x: (item.bounds.minX - capture.windowFrame.minX) * capture.scale,
                y: (item.bounds.minY - capture.windowFrame.minY) * capture.scale,
                width: item.bounds.width * capture.scale,
                height: item.bounds.height * capture.scale
            ).integral
            let clippedCropRect = cropRect.intersection(imageBounds)

            guard !clippedCropRect.isNull, !clippedCropRect.isEmpty else {
                diagLog.warning(
                    "controlCrop[\(reason)] id=\(identifier.rawValue) crop outside host " +
                        "axFrame=\(NSStringFromRect(item.bounds)) crop=\(NSStringFromRect(cropRect))"
                )
                continue
            }

            guard let cropped = capture.image.cropping(to: clippedCropRect) else {
                diagLog.warning(
                    "controlCrop[\(reason)] id=\(identifier.rawValue) crop failed " +
                        "axFrame=\(NSStringFromRect(item.bounds)) crop=\(NSStringFromRect(clippedCropRect))"
                )
                continue
            }

            diagLog.info(
                "controlCrop[\(reason)] id=\(identifier.rawValue) " +
                    "axFrame=\(NSStringFromRect(item.bounds)) crop=\(NSStringFromRect(clippedCropRect)) " +
                    "size=\(cropped.width)x\(cropped.height) transparent=\(cropped.isTransparent())"
            )
        }
    }

    private func controlItem(
        in items: [MenuBarItem],
        matching identifier: ControlItem.Identifier
    ) -> MenuBarItem? {
        items.first { item in
            item.title == identifier.rawValue ||
                item.uniqueIdentifier.hasSuffix(":\(identifier.rawValue)") ||
                item.uniqueIdentifier == identifier.rawValue
        }
    }

    @available(macOS 27, *)
    private func probeHiddenTriggerPressIfEnabled(reason: String) {
        guard Defaults.bool(forKey: .diagnosticAssessmentModeProbeHiddenTriggerPress) else {
            return
        }

        guard let element = controlAXElement(matching: .hidden) else {
            diagLog.warning("hiddenTriggerAXPress[\(reason)]: element not found")
            return
        }

        let frame = AXHelpers.frame(for: element).map(NSStringFromRect) ?? "nil"
        let enabled = AXHelpers.enabledAttribute(element).map(String.init) ?? "nil"
        let role = AXHelpers.role(for: element).map { "\($0)" } ?? "nil"
        let didPress = AXHelpers.press(element)
        diagLog.info(
            "hiddenTriggerAXPress[\(reason)]: didPress=\(didPress) " +
                "role=\(role) enabled=\(enabled) frame=\(frame)"
        )
    }

    @available(macOS 27, *)
    private func controlAXElement(matching identifier: ControlItem.Identifier) -> UIElement? {
        guard
            let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                Constants.isThawOwnedBundleIdentifier($0.bundleIdentifier)
            }),
            let app = AXHelpers.application(for: runningApp),
            let extrasMenuBar = AXHelpers.extrasMenuBar(for: app)
        else {
            return nil
        }

        return AXHelpers.children(for: extrasMenuBar).first { child in
            resolvedAXIdentifier(for: child) == identifier.rawValue
        }
    }

    @available(macOS 27, *)
    private func resolvedAXIdentifier(for element: UIElement) -> String? {
        // NOT `.lazy`: lazy `compactMap` evaluates the transform twice for the
        // first match (filter then force-unwrap), and this transform is a live
        // AX query that can return a different value between the two calls,
        // trapping on the `$0!`. Eager runs each query once; child lists are tiny.
        AXHelpers.identifier(for: element)?.nonEmpty
            ?? AXHelpers.children(for: element)
            .compactMap { AXHelpers.identifier(for: $0)?.nonEmpty }
            .first
            ?? AXHelpers.title(for: element)?.nonEmpty
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
