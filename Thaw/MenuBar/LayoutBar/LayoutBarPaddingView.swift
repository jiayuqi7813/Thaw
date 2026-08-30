//
//  LayoutBarPaddingView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine
import Observation

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private static let diagLog = DiagLog(category: "LayoutBarPaddingView")
    private static let stabilizationRecoveryTimeout: Duration = .seconds(45)

    private let container: LayoutBarContainer
    private var isStabilizing = false
    private var stabilizationGeneration = 0
    private var stabilizationTask: Task<Void, Never>?
    private weak var acceptedDraggingSource: LayoutBarArrangedView?

    private var notchView: NotchIndicatorView?
    private var notchWidthConstraint: NSLayoutConstraint?
    private var notchTrailingConstraint: NSLayoutConstraint?
    private var minWidthConstraint: NSLayoutConstraint?
    private var containerLeadingAfterNotchConstraint: NSLayoutConstraint?
    private var containerLeadingInsetConstraint: NSLayoutConstraint?
    private var notchObservers = Set<AnyCancellable>()

    /// Task observing `menuBarManager.averageColorInfo` (wave 3), replacing
    /// the old `$averageColorInfo` sink.
    private var averageColorInfoObservationTask: Task<Void, Never>?

    deinit {
        averageColorInfoObservationTask?.cancel()
        stabilizationTask?.cancel()
    }

    /// The layout view's arranged views.
    var arrangedViews: [LayoutBarArrangedView] {
        get { container.arrangedViews }
        set { container.arrangedViews = newValue }
    }

    /// Creates a layout bar view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    init(appState: AppState, section: MenuBarSection.Name) {
        self.container = LayoutBarContainer(appState: appState, section: section)

        super.init(frame: .zero)

        addSubview(container)
        self.translatesAutoresizingMaskIntoConstraints = false

        let leadingInsetConstraint = leadingAnchor.constraint(lessThanOrEqualTo: container.leadingAnchor, constant: -7.5)
        self.containerLeadingInsetConstraint = leadingInsetConstraint

        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7.5),
            leadingInsetConstraint,
        ])

        registerForDraggedTypes([.layoutBarItem])

        configureNotchObservers(appState: appState)
        updateNotchPresentation()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing,
              let sourceView = sender.draggingSource as? LayoutBarArrangedView,
              Self.canAcceptDrag(
                  containerAllowsUpdates: container.canSetArrangedViews,
                  beganInContainer: sourceView.beganDragging(in: container),
                  alreadyAccepted: acceptedDraggingSource === sourceView
              )
        else { return [] }
        acceptedDraggingSource = sourceView
        // Freeze the destination's arrangedViews so that the cache refresh
        // triggered while the system move is in flight cannot overwrite the
        // mid-drag visual state. updateNewItemsPlacement at the end of move()
        // depends on that state to capture the badge's new neighbors; without
        // this guard the dropped item bounces to the wrong side of the badge.
        container.canSetArrangedViews = false
        return container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !isStabilizing else { return }
        guard let acceptedDraggingSource else { return }
        if let sender {
            guard sender.draggingSource as? LayoutBarArrangedView === acceptedDraggingSource else {
                return
            }
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }

        // A pointer can cross one or more rows before it reaches the final
        // destination. Each entered row is frozen above, so thaw a row as
        // soon as it is no longer participating in the drag. Keep only the
        // original source frozen; refreshing it now would reinsert a duplicate
        // item behind the dragging image.
        if !acceptedDraggingSource.beganDragging(in: container) {
            container.resumeArrangedViewUpdatesWithoutAnimation()
        }
        self.acceptedDraggingSource = nil
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing,
              sender.draggingSource as? LayoutBarArrangedView === acceptedDraggingSource
        else { return [] }
        return container.updateArrangedViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard !isStabilizing,
              sender.draggingSource as? LayoutBarArrangedView === acceptedDraggingSource
        else { return }
        container.updateArrangedViewsForDrag(with: sender, phase: .ended)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let draggingSource = sender.draggingSource as? LayoutBarArrangedView,
              acceptedDraggingSource === draggingSource
        else {
            return false
        }
        defer { acceptedDraggingSource = nil }

        if case let .item(draggingItem) = draggingSource.kind,
           draggingItem.tag == .visibleControlItem,
           container.section != .visible
        {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Cannot move \(Constants.displayName) icon.")
            alert.informativeText = String(localized: "The \(Constants.displayName) icon must always remain in the visible section.")

            if let window {
                alert.beginSheetModal(for: window)
            }

            // Revert the visual state: remove the item from the container it was dropped into
            // and set hasContainer to false so it snaps back to its original container.
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
            draggingSource.hasContainer = false

            container.resumeArrangedViewUpdatesWithoutAnimation()
            return false
        }

        if draggingSource.isNewItemsBadge {
            let sourceContainer = draggingSource.oldContainerInfo?.container
            container.appState?.itemManager.updateNewItemsPlacement(
                section: container.section,
                arrangedViews: arrangedViews
            )
            draggingSource.oldContainerInfo = nil
            container.resumeArrangedViewUpdatesWithoutAnimation()
            sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
            if let appState = container.appState {
                sourceContainer?.setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: sourceContainer?.section ?? container.section))
                if sourceContainer !== container {
                    container.setArrangedViews(items: appState.itemManager.itemCache.managedItems(for: container.section))
                }
            }
            return true
        }

        var willMove = false
        let sourceContainer = draggingSource.oldContainerInfo?.container

        if let index = arrangedViews.firstIndex(of: draggingSource) {
            if arrangedViews.count == 1 {
                willMove = true
                Task {
                    guard case let .item(item) = draggingSource.kind else {
                        self.container.resumeArrangedViewUpdatesWithoutAnimation()
                        sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
                        return
                    }
                    if let destination = await self.liveFallbackDestinationForDraggedItem() {
                        self.move(item: item, to: destination, sourceContainer: sourceContainer)
                    } else {
                        Self.diagLog.error("No target item for layout bar drag")
                        self.container.resumeArrangedViewUpdatesWithoutAnimation()
                        sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
                    }
                }
            } else if case let .item(item) = draggingSource.kind {
                if let targetItem = nearestItem(toRightOf: index) {
                    willMove = true
                    move(item: item, to: .leftOfItem(targetItem), sourceContainer: sourceContainer)
                } else if let targetItem = nearestItem(toLeftOf: index) {
                    willMove = true
                    move(item: item, to: .rightOfItem(targetItem), sourceContainer: sourceContainer)
                } else if !arrangedViews.isEmpty {
                    willMove = true
                    Task {
                        if let destination = await self.liveFallbackDestinationForDraggedItem() {
                            self.move(item: item, to: destination, sourceContainer: sourceContainer)
                        } else {
                            Self.diagLog.error("No target item for layout bar drag")
                            self.container.resumeArrangedViewUpdatesWithoutAnimation()
                            sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
                        }
                    }
                }
            }
        }

        // Only re-enable view updates here if no move was initiated.
        // When a move IS initiated, the move() Task re-enables after stabilization.
        if !willMove {
            container.resumeArrangedViewUpdatesWithoutAnimation()
            if sourceContainer !== container {
                sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
            }
            draggingSource.oldContainerInfo = nil
        }

        return true
    }

    /// A frozen row accepts only the drag that already owns that freeze. This
    /// prevents a second cross-row move from being reconciled by the first
    /// move's eventual thaw.
    static nonisolated func canAcceptDrag(
        containerAllowsUpdates: Bool,
        beganInContainer: Bool,
        alreadyAccepted: Bool
    ) -> Bool {
        containerAllowsUpdates || beganInContainer || alreadyAccepted
    }

    private func move(
        item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        sourceContainer: LayoutBarContainer? = nil
    ) {
        guard let appState = container.appState else {
            container.resumeArrangedViewUpdatesWithoutAnimation()
            sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
            return
        }
        guard !isStabilizing else {
            container.resumeArrangedViewUpdatesWithoutAnimation()
            sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
            return
        }
        isStabilizing = true
        stabilizationGeneration &+= 1
        let generation = stabilizationGeneration

        // Explicit strong captures: the move must complete even if the view
        // is torn down mid-drag; only the longer-lived watchdog below holds
        // weak references.
        stabilizationTask = Task { [self, appState] in
            var didValidateUserMove = false
            @MainActor
            func acceptValidatedUserMove() {
                // Clear an unfinished automatic-batch latch only after the
                // editor move has reached its requested settled placement.
                appState.itemManager.recordExternalMoveOperation()
                didValidateUserMove = true
            }

            // Increased delay to allow macOS to settle after operations like Reset Layout.
            // Prevents transient errors when dragging items immediately after reset.
            // A cancelled sleep must not leave the layouts frozen or isStabilizing
            // stuck true (the watchdog that would reset them hasn't started yet).
            guard await (try? Task.sleep(for: .milliseconds(150))) != nil else {
                _ = await resetStabilizingStateIfNeeded(
                    generation: generation,
                    sourceContainer: sourceContainer
                )
                return
            }

            let watchdogTask = Task { [weak self, weak appState, weak sourceContainer] in
                try? await Task.sleep(for: Self.stabilizationRecoveryTimeout)
                guard let self, !Task.isCancelled else { return }
                guard await self.resetStabilizingStateIfNeeded(
                    generation: generation,
                    sourceContainer: sourceContainer,
                    cancelOwningTask: true
                ) else { return }
                guard let appState else { return }
                // The owner task's cancellation runs its defer and cancels
                // this watchdog. Launch recovery independently so that mutual
                // cancellation cannot abort it, and retry until the old cache
                // owner actually releases CacheGate instead of issuing a
                // one-shot refresh that will probably be dropped.
                Task { [weak appState] in
                    guard let appState else { return }
                    guard await appState.itemManager.refreshCacheAfterLayoutEditorMove() else {
                        return
                    }
                    await appState.imageCache.updateCacheWithoutChecks(
                        sections: MenuBarSection.Name.allCases
                    )
                }
            }
            defer { watchdogTask.cancel() }
            do {
                try await appState.itemManager.move(
                    item: item,
                    to: destination,
                    skipInputPause: true,
                    watchdogTimeout: MenuBarItemManager.layoutWatchdogTimeout
                )
                guard isCurrentStabilization(generation) else { return }
                appState.itemManager.removeTemporarilyShownItemFromCache(with: item.tag)
                if await stabilizePlacement(
                    of: item,
                    to: destination,
                    expectedSection: container.section,
                    appState: appState,
                    generation: generation
                ), isCurrentStabilization(generation) {
                    acceptValidatedUserMove()
                }
            } catch MenuBarItemManager.EventError.menuTrackingActive {
                // A menu bar item's menu (Wi-Fi picker, input method panel,
                // etc.) was open and the move was deferred to avoid tearing
                // down the user's interaction. This isn't a failure worth
                // alerting on — log only.
                Self.diagLog.info("Move deferred, a menu bar item menu was open")
            } catch MenuBarItemManager.EventError.moveEngineBusy {
                // Another move held the bar for the whole wait. Nothing was
                // tried, so nothing failed; the editor snaps the item back
                // and the user can drag again once the bar is free.
                Self.diagLog.info("Move deferred, another move held the bar")
            } catch {
                guard isCurrentStabilization(generation) else { return }
                Self.diagLog.error("Error moving menu bar item: \(error)")
                // The system event-driven move sometimes throws cannotComplete
                // after macOS has already settled the item into the requested
                // slot: the click sequence bounces the item past the target
                // and back during verification, but a subsequent reconciliation
                // lands it where the user asked. Resample the cache after a
                // short settle window and only show the alert when the item
                // is NOT in the position the user actually dragged it to;
                // showing it for a move that visibly worked is a false alarm.
                try? await Task.sleep(for: .milliseconds(250))
                guard isCurrentStabilization(generation) else { return }
                _ = await appState.itemManager.refreshCacheAfterLayoutEditorMove()
                guard isCurrentStabilization(generation) else { return }
                let reachedPosition = didItemReachIntendedPosition(
                    item: item,
                    destination: destination,
                    expectedSection: container.section,
                    cache: appState.itemManager.itemCache
                )
                let isBlocked = if reachedPosition {
                    false
                } else {
                    await appState.itemManager.isItemCurrentlyBlocked(item)
                }
                guard isCurrentStabilization(generation) else { return }
                let action = MenuBarItemManager.classifyHiddenDragFailure(
                    reachedPosition: reachedPosition,
                    isBlocked: isBlocked,
                    controlItemsMissing: appState.itemManager.areControlItemsMissing
                )
                switch action {
                case .suppress:
                    Self.diagLog.info("Move verification failed but \(item.logString) reached intended position in \(container.section.logString); suppressing alert")
                    acceptValidatedUserMove()
                case .rescueAndRetry:
                    // The item is stuck at the x=-1 sentinel. Rescue it to
                    // the visible section, let macOS settle, then retry the
                    // original move exactly once (no loop). Only if that
                    // retry also fails do we alert, and with a calm message
                    // rather than the raw error, matching the safe-harbor
                    // behavior of restoreBlockedItemsToVisible.
                    Self.diagLog.warning("\(item.logString) is blocked (x=-1); attempting one rescue-and-retry before alerting")
                    _ = await appState.itemManager.rescueBlockedItemToVisible(item)
                    guard isCurrentStabilization(generation) else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard isCurrentStabilization(generation) else { return }
                    _ = await appState.itemManager.refreshCacheAfterLayoutEditorMove()
                    guard isCurrentStabilization(generation) else { return }
                    do {
                        try await appState.itemManager.move(
                            item: item,
                            to: destination,
                            skipInputPause: true,
                            watchdogTimeout: MenuBarItemManager.layoutWatchdogTimeout
                        )
                        guard isCurrentStabilization(generation) else { return }
                        appState.itemManager.removeTemporarilyShownItemFromCache(with: item.tag)
                        if await stabilizePlacement(
                            of: item,
                            to: destination,
                            expectedSection: container.section,
                            appState: appState,
                            generation: generation
                        ), isCurrentStabilization(generation) {
                            acceptValidatedUserMove()
                        }
                    } catch MenuBarItemManager.EventError.menuTrackingActive {
                        // Same deferral the outer catch handles: the user
                        // opened a menu bar item's menu while the retry was
                        // in flight. Nothing failed, so don't alert.
                        Self.diagLog.info("Rescue-and-retry deferred, a menu bar item menu was open")
                    } catch {
                        guard isCurrentStabilization(generation) else { return }
                        Self.diagLog.error("Rescue-and-retry failed for \(item.logString): \(error)")
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = container.section == .alwaysHidden
                            ? String(localized: "Couldn't move \(item.displayName) to the always-hidden section.")
                            : String(localized: "Couldn't move \(item.displayName) to the hidden section.")
                        alert.informativeText = String(localized: "The item was left in the visible section so it isn't stuck offscreen. Try dragging it again in a moment.")
                        let report = await MoveFailureDiagnosticReport.generate(
                            for: .init(
                                item: item,
                                destination: destination,
                                expectedSection: container.section,
                                error: error,
                                note: "The item was stuck at x=-1; a rescue to the visible section and one retry of the move also failed."
                            ),
                            appState: appState
                        )
                        guard isCurrentStabilization(generation) else { return }
                        report.run(alert, in: window)
                    }
                case .alertControlItemsMissing:
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "Couldn't move the item right now.")
                    alert.informativeText = String(localized: "\(Constants.displayName) can't locate its hidden-section divider right now. It is attempting recovery in the background — try again in a few seconds.")
                    let report = await MoveFailureDiagnosticReport.generate(
                        for: .init(
                            item: item,
                            destination: destination,
                            expectedSection: container.section,
                            error: error,
                            note: "The hidden-section divider could not be located; recovery was started in the background."
                        ),
                        appState: appState
                    )
                    guard isCurrentStabilization(generation) else { return }
                    report.run(alert, in: window)
                case .alertGeneric:
                    // Generated before the alert shows so the "Save Diagnostic
                    // Report…" button has the bar as it was at the failure,
                    // not as it settles while the alert is up.
                    let report = await MoveFailureDiagnosticReport.generate(
                        for: .init(
                            item: item,
                            destination: destination,
                            expectedSection: container.section,
                            error: error
                        ),
                        appState: appState
                    )
                    guard isCurrentStabilization(generation) else { return }
                    report.run(NSAlert(error: error), in: window)
                }
            }
            guard isCurrentStabilization(generation) else { return }
            let didRefresh = await appState.itemManager.refreshCacheAfterLayoutEditorMove(
                forcePersistSavedOrder: didValidateUserMove
            )
            guard isCurrentStabilization(generation) else { return }
            if !didRefresh {
                Self.diagLog.error(
                    "Thawing Layout editor after post-move cache refresh timed out"
                )
            }
            let didThawCurrentMove = await MainActor.run {
                guard self.isStabilizing,
                      self.stabilizationGeneration == generation
                else {
                    return false
                }
                self.isStabilizing = false
                self.stabilizationTask = nil
                // Update the badge anchor BEFORE re-enabling view updates, using
                // the current visual arrangement from the drag. This ensures the
                // didSet refresh uses the correct anchor position.
                // Only update if this section actually contains the badge.
                if let appState = self.container.appState,
                   self.containsNewItemsBadge()
                {
                    appState.itemManager.updateNewItemsPlacement(
                        section: self.container.section,
                        arrangedViews: self.container.arrangedViews
                    )
                }
                // Re-enable view updates on both the destination (frozen by
                // draggingEntered) and the source (frozen by willBeginAt on
                // the dragging session). Without resetting the source, its
                // arrangedViews would stay frozen at the mid-drag snapshot
                // until the next drag originated from that container.
                self.container.resumeArrangedViewUpdatesWithoutAnimation()
                if sourceContainer !== self.container {
                    sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
                }
                return true
            }

            // Thumbnail capture is allowed to lag behind geometry. The moved
            // view retains its last stable image, so holding both rows frozen
            // while capture retries only makes the editor feel stuck.
            if didThawCurrentMove {
                await MainActor.run {
                    appState.imageCache.performCacheCleanup()
                }
                await appState.imageCache.updateCacheWithoutChecks(
                    sections: MenuBarSection.Name.allCases
                )
            }
        }
    }

    /// Returns true when the dragged item is sitting in the slot the user
    /// asked for: in the destination section, immediately adjacent to the
    /// target on the requested side. For control-item targets (section
    /// dividers) there is no array entry to anchor against, so containment
    /// in the destination section is the strongest claim we can make.
    private func didItemReachIntendedPosition(
        item: MenuBarItem,
        destination: MenuBarItemManager.MoveDestination,
        expectedSection: MenuBarSection.Name,
        cache: MenuBarItemManager.ItemCache
    ) -> Bool {
        Self.itemReachedIntendedPosition(
            item: item,
            destination: destination,
            sectionItems: cache[expectedSection]
        )
    }

    /// Whether `item` sits in `sectionItems` where `destination` asked for
    /// it. Pure, so the identity rule below can be tested.
    static nonisolated func itemReachedIntendedPosition(
        item: MenuBarItem,
        destination: MenuBarItemManager.MoveDestination,
        sectionItems: [MenuBarItem]
    ) -> Bool {
        guard let itemIndex = sectionItems.firstIndex(where: { Self.isSameItem($0, item) }) else {
            return false
        }
        let target = destination.targetItem
        if target.isControlItem {
            return true
        }
        guard let targetIndex = sectionItems.firstIndex(where: { Self.isSameItem($0, target) }) else {
            return false
        }
        return switch destination {
        case .leftOfItem: itemIndex + 1 == targetIndex
        case .rightOfItem: itemIndex == targetIndex + 1
        }
    }

    /// Whether a cached item is the item that was dragged.
    ///
    /// The dragged item's tag is a snapshot. The cache refreshed after the
    /// move can name the same window differently — a provisional
    /// `com.apple.controlcenter:Item-0` resolves to its app's identifier
    /// once the source process is known — and an exact tag comparison then
    /// misses the item that just landed, which re-drags it (the move engine
    /// finds it already in place and cancels) and, on the failure path,
    /// alerts for a move that worked. The window is what moved: match it
    /// first, and fall back to the tag without its window for a window that
    /// was recreated in between.
    static nonisolated func isSameItem(_ cached: MenuBarItem, _ dragged: MenuBarItem) -> Bool {
        cached.windowID == dragged.windowID || cached.tag.matchesIgnoringWindowID(dragged.tag)
    }

    /// Whether the async continuation still belongs to the move that owns the
    /// frozen editor rows. The recovery watchdog invalidates the generation
    /// and cancels that task before reopening the editor, so a slow old move
    /// cannot resume later and reorder the bar over a newer drag.
    private func isCurrentStabilization(_ generation: Int) -> Bool {
        isStabilizing && stabilizationGeneration == generation && !Task.isCancelled
    }

    @MainActor
    private func resetStabilizingStateIfNeeded(
        generation: Int,
        sourceContainer: LayoutBarContainer? = nil,
        cancelOwningTask: Bool = false
    ) async -> Bool {
        guard isStabilizing, stabilizationGeneration == generation else {
            return false
        }
        if cancelOwningTask {
            stabilizationTask?.cancel()
            stabilizationGeneration &+= 1
        }
        stabilizationTask = nil
        isStabilizing = false
        container.resumeArrangedViewUpdatesWithoutAnimation()
        if sourceContainer !== container {
            sourceContainer?.resumeArrangedViewUpdatesWithoutAnimation()
        }
        return true
    }

    private func containsNewItemsBadge() -> Bool {
        for arrangedView in container.arrangedViews where arrangedView.isNewItemsBadge {
            return true
        }
        return false
    }

    private func nearestItem(toRightOf index: Int) -> MenuBarItem? {
        guard arrangedViews.indices.contains(index + 1) else {
            return nil
        }
        for candidateIndex in (index + 1) ..< arrangedViews.count {
            if case let .item(item) = arrangedViews[candidateIndex].kind {
                return item
            }
        }
        return nil
    }

    private func nearestItem(toLeftOf index: Int) -> MenuBarItem? {
        guard arrangedViews.indices.contains(index - 1) else {
            return nil
        }
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            if case let .item(item) = arrangedViews[candidateIndex].kind {
                return item
            }
        }
        return nil
    }

    private func liveFallbackDestinationForDraggedItem() async -> MenuBarItemManager.MoveDestination? {
        // This fallback only needs the section's control item. Resolving every
        // item's source process can block on Accessibility for many seconds,
        // leaving both drag rows frozen before move() can start its watchdog.
        let items = await MenuBarItem.getMenuBarItems(
            option: .activeSpace,
            resolveSourcePID: false
        )
        return switch container.section {
        case .visible:
            nil
        case .hidden:
            items.first(matching: .hiddenControlItem).map { .leftOfItem($0) }
        case .alwaysHidden:
            items.first(matching: .alwaysHiddenControlItem).map { .leftOfItem($0) }
        }
    }

    /// Ensures the dragged item remains in the intended section and its icon appears.
    private func stabilizePlacement(
        of item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        expectedSection: MenuBarSection.Name,
        appState: AppState,
        generation: Int
    ) async -> Bool {
        guard isCurrentStabilization(generation) else { return false }
        // A dropped refresh is not evidence. Keep the drag projection frozen
        // until this move owns and completes a fast geometry cache pass.
        guard await appState.itemManager.refreshCacheAfterLayoutEditorMove() else {
            return false
        }
        guard isCurrentStabilization(generation) else { return false }

        func isInExpectedSection() -> Bool {
            appState.itemManager.itemCache[expectedSection].contains { Self.isSameItem($0, item) }
        }

        if !isInExpectedSection() {
            // Allow macOS a brief moment to settle, then retry once.
            try? await Task.sleep(for: .milliseconds(120))
            guard isCurrentStabilization(generation) else { return false }
            do {
                try await appState.itemManager.move(
                    item: item,
                    to: destination,
                    skipInputPause: true,
                    watchdogTimeout: MenuBarItemManager.layoutWatchdogTimeout
                )
                guard isCurrentStabilization(generation) else { return false }
                guard await appState.itemManager.refreshCacheAfterLayoutEditorMove() else {
                    return false
                }
                guard isCurrentStabilization(generation) else { return false }
            } catch {
                guard isCurrentStabilization(generation) else { return false }
                Self.diagLog.error("Stabilize move failed: \(error)")
            }
        }

        return isInExpectedSection()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateNotchPresentation()
        }
    }

    private func configureNotchObservers(appState: AppState) {
        guard container.section == .visible else {
            return
        }

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNotchPresentation()
            }
            .store(in: &notchObservers)

        NotificationCenter.default
            .publisher(for: NSWindow.didChangeScreenNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let notifyingWindow = notification.object as? NSWindow,
                      notifyingWindow === self.window
                else { return }
                self.updateNotchPresentation()
            }
            .store(in: &notchObservers)

        // `menuBarManager` is now `@Observable` (wave 3), so it no longer has
        // an `$averageColorInfo` publisher.
        averageColorInfoObservationTask = Task { [weak self, weak appState] in
            var previous: MenuBarAverageColorInfo?
            let changes = Observations { appState?.menuBarManager.averageColorInfo }
            for await colorInfo in changes {
                guard let self else { return }
                guard colorInfo != previous else { continue }
                previous = colorInfo
                self.notchView?.averageColorInfo = colorInfo
            }
        }
    }

    private func updateNotchPresentation() {
        guard
            container.section == .visible,
            let screen = NSScreen.screenWithActiveMenuBar ?? NSScreen.main,
            screen.hasNotch,
            let notch = screen.frameOfNotch
        else {
            tearDownNotchPresentation()
            return
        }

        let notchIndicatorWidth = notch.width + MenuBarSection.notchGap
        // Distance from the bar's trailing edge to the notch indicator's
        // trailing edge — equals the real-world items area (everything
        // right of `notch.maxX + notchGap` in the menu bar) plus the 7.5pt
        // cosmetic inset that sits between items and the rounded edge.
        let notchTrailingOffset = max(0, screen.frame.maxX - notch.maxX - MenuBarSection.notchGap) + 7.5
        // Bar must always be wide enough to represent the real-world span
        // from `notch.minX` to `screen.maxX`, with no inset on the left
        // (the notch itself sits flush) and 7.5pt cosmetic inset on the
        // right. When the Settings pane is wider, the bar grows past this
        // and the empty area is shown to the LEFT of the notch.
        let barMinWidth = max(0, screen.frame.maxX - notch.minX) + 7.5
        let colorInfo = container.appState?.menuBarManager.averageColorInfo

        if let notchView {
            notchView.isHidden = false
            notchView.averageColorInfo = colorInfo
            notchWidthConstraint?.constant = notchIndicatorWidth
            notchTrailingConstraint?.constant = -notchTrailingOffset
            minWidthConstraint?.constant = barMinWidth
            containerLeadingInsetConstraint?.constant = 0
            return
        }

        let view = NotchIndicatorView(averageColorInfo: colorInfo)
        addSubview(view, positioned: .below, relativeTo: container)
        self.notchView = view

        let widthConstraint = view.widthAnchor.constraint(equalToConstant: notchIndicatorWidth)
        let trailingConstraint = view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -notchTrailingOffset)
        // Lower priority so the bar can grow leftward when the user has
        // more items than fit between the notch and the bar's trailing
        // edge. With this at .required, container.leading is hard-pinned
        // at notchView.trailing, the container's slot is fixed in width,
        // and overflowing items get clipped without ever pushing the
        // documentView wider than the scroll view's visible area, so no
        // horizontal scrollbar appears. Dropping to .defaultHigh keeps
        // the notch as the preferred boundary while letting AutoLayout
        // break it when items need more room — paddingView then extends
        // further left (via the existing leading inset constraint),
        // NSScrollView observes documentView wider than visible and
        // surfaces the horizontal scroller. The container is z-above
        // notchView, so items rendered over the notch indicator stay
        // draggable.
        let containerLeading = container.leadingAnchor.constraint(greaterThanOrEqualTo: view.trailingAnchor)
        containerLeading.priority = .defaultHigh
        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: barMinWidth)

        NSLayoutConstraint.activate([
            trailingConstraint,
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            containerLeading,
            minWidth,
        ])

        notchWidthConstraint = widthConstraint
        notchTrailingConstraint = trailingConstraint
        containerLeadingAfterNotchConstraint = containerLeading
        minWidthConstraint = minWidth
        containerLeadingInsetConstraint?.constant = 0
    }

    private func tearDownNotchPresentation() {
        notchWidthConstraint?.isActive = false
        notchTrailingConstraint?.isActive = false
        containerLeadingAfterNotchConstraint?.isActive = false
        minWidthConstraint?.isActive = false
        notchWidthConstraint = nil
        notchTrailingConstraint = nil
        containerLeadingAfterNotchConstraint = nil
        minWidthConstraint = nil
        containerLeadingInsetConstraint?.constant = -7.5
        notchView?.removeFromSuperview()
        notchView = nil
    }
}
