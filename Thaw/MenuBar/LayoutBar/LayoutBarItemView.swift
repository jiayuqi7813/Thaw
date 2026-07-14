//
//  LayoutBarItemView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine
import MenuBarModel

// MARK: - LayoutBarItemView

/// A view that displays an image in a menu bar layout view.
final class LayoutBarItemView: LayoutBarArrangedView {
    private enum Metrics {
        static let minWidth: CGFloat = 14
        static let maxWidth: CGFloat = 240
        static let minHeight: CGFloat = 18
        static let placeholderCornerRadius: CGFloat = 6
        static let placeholderHorizontalInset: CGFloat = 2
        static let placeholderVerticalInset: CGFloat = 2
        static let iconInset: CGFloat = 2
        static let fallbackSymbolPointSize: CGFloat = 11
        static let unresponsiveBadgeWidth: CGFloat = 15
    }

    private weak var appState: AppState?

    private var cancellables = Set<AnyCancellable>()

    /// The item that the view represents.
    let item: MenuBarItem

    private lazy var tooltipController = CustomTooltipController(text: item.displayName, view: self)
    private var tooltipTrackingArea: NSTrackingArea?
    private let placeholderImage: NSImage?
    /// Refreshed when the visible-section control item's icon or state changes.
    private var livePlaceholderImage: NSImage?

    /// The image displayed inside the view.
    private var cachedImage: MenuBarItemImageCache.CapturedImage? {
        didSet {
            cachedDrawImage = cachedImage.map {
                NSImage(cgImage: $0.cgImage, size: $0.scaledSize)
            }
            let previousSize = preferredSizeForCurrentDisplayMode(oldValue)
            let newSize = preferredSizeForCurrentDisplayMode(cachedImage)
            setFrameSize(newSize)
            if previousSize != newSize {
                (superview as? LayoutBarContainer)?.itemPreferredSizeDidChange(self)
            }
            needsDisplay = true
        }
    }

    /// Stable `NSImage` wrapper for the current capture, rebuilt only when the
    /// cache entry changes. Avoids allocating a new AppKit image on every
    /// `draw(_:)` pass.
    private var cachedDrawImage: NSImage?

    override var kind: Kind {
        .item(item)
    }

    /// Creates a view that displays the given menu bar item.
    init(appState: AppState, item: MenuBarItem) {
        self.item = item
        self.appState = appState
        self.placeholderImage = Self.makePlaceholderImage(for: item, appState: appState)
        if item.tag.matchesVisibleControlItem {
            self.livePlaceholderImage = placeholderImage
        }

        let initialImage = appState.imageCache.image(for: item.tag)
        self.cachedImage = initialImage

        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize(for: item, image: initialImage)))
        unregisterDraggedTypes()

        let experimentalSystemItemHiding = appState.settings.advanced.enableExperimentalSystemItemHiding
        isEnabled = LayoutBarPaddingView.acceptsLayoutDrag(of: item) &&
            item.isMovable(experimentalSystemItemHiding: experimentalSystemItemHiding)

        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var tooltipDelay: TimeInterval {
        appState?.settings.advanced.tooltipDelay ?? 0.5
    }

    override func draggingImage() -> NSImage? {
        if shouldPreferPlaceholderImage {
            return placeholderBitmapImage()
        }
        return cachedImage?.nsImage ?? placeholderBitmapImage()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tooltipTrackingArea {
            removeTrackingArea(tooltipTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tooltipTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        tooltipController.scheduleShow(delay: tooltipDelay)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tooltipController.cancel()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            let tag = item.tag
            let imageForTag = appState.imageCache.$images
                .map { [weak appState] _ -> MenuBarItemImageCache.CapturedImage? in
                    appState?.imageCache.image(for: tag)
                }

            imageForTag
                .removeDuplicates(by: MenuBarItemImageCache.CapturedImage.isVisuallyEqual)
                .sink { [weak self] image in
                    guard let self else {
                        return
                    }
                    self.cachedImage = image
                }
                .store(in: &c)

            if item.tag.matchesVisibleControlItem,
               let controlItem = appState.menuBarManager.section(withName: .visible)?.controlItem
            {
                controlItem.$state
                    .combineLatest(
                        appState.settings.general.$iceIcon,
                        appState.settings.general.$customIceIconIsTemplate
                    )
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.refreshLivePlaceholderImage()
                        self?.needsDisplay = true
                    }
                    .store(in: &c)
            }
        }

        cancellables = c
    }

    /// Provides an alert to display when the item view is disabled.
    func provideAlertForDisabledItem() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Menu bar item is not movable.")
        alert.informativeText = String(localized: "macOS prohibits \"\(item.displayName)\" from being moved.")
        return alert
    }

    /// Provides an alert to display when a menu bar item is unresponsive.
    func provideAlertForUnresponsiveItem() -> NSAlert {
        let alert = provideAlertForDisabledItem()
        alert.informativeText = String(localized: "\(item.displayName) is unresponsive. Until it is restarted, it cannot be moved. Movement of other menu bar items may also be affected until this is resolved.")
        return alert
    }

    override func draw(_: NSRect) {
        if !isDraggingPlaceholder {
            if shouldPreferPlaceholderImage {
                drawOverflowFallback()
            } else if let capturedImage = cachedDrawImage {
                capturedImage.draw(
                    in: bounds,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: isEnabled ? 1.0 : 0.67
                )
            } else {
                drawPlaceholder()
            }
            if Bridging.isProcessUnresponsive(item.ownerPID) {
                let warningImage = NSImage.warning
                let width = Metrics.unresponsiveBadgeWidth
                let scale = width / warningImage.size.width
                let size = CGSize(
                    width: width,
                    height: warningImage.size.height * scale
                )
                warningImage.draw(
                    in: CGRect(
                        x: bounds.maxX - size.width,
                        y: bounds.minY,
                        width: size.width,
                        height: size.height
                    )
                )
            }
        }
    }

    private var shouldPreferPlaceholderImage: Bool {
        guard let appState, let section = (superview as? LayoutBarContainer)?.section else {
            return false
        }
        // Oversized captures are almost always poisoned (near-full-bar / menu-chrome
        // crops). Prefer the app icon instead of stretching Finder menus across
        // the layout row while the image cache invalidates them.
        if let cachedDrawImage, cachedDrawImage.size.width > Metrics.maxWidth {
            return OverflowFallbackIcon.supportsMissingCaptureFallback(for: section)
        }
        return OverflowFallbackIcon.shouldPreferAppIcon(
            for: section,
            appState: appState,
            cachedImage: cachedDrawImage
        )
    }

    /// Draws the owning app's icon when no usable capture exists (macOS 27
    /// incomplete hosting-window crops / native hide). Falls back to the
    /// generic box placeholder when no icon resolves (e.g. Thaw's own control
    /// items). See ``OverflowFallbackIcon``.
    private func drawOverflowFallback() {
        guard
            !item.isControlItem,
            let icon = OverflowFallbackIcon.image(for: item)
        else {
            drawPlaceholder()
            return
        }
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let iconRect = CGRect(
            x: bounds.midX - (side / 2),
            y: bounds.midY - (side / 2),
            width: side,
            height: side
        )
        icon.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: isEnabled ? 1.0 : 0.5
        )
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        tooltipController.cancel()

        guard isEnabled else {
            let alert = provideAlertForDisabledItem()
            alert.runModal()
            return
        }

        guard !Bridging.isProcessUnresponsive(item.ownerPID) else {
            let alert = provideAlertForUnresponsiveItem()
            alert.runModal()
            return
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(Data(), forType: .layoutBarItem)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: draggingImage())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func preferredSize(for image: MenuBarItemImageCache.CapturedImage?) -> CGSize {
        Self.preferredSize(for: item, image: image)
    }

    private func preferredSizeForCurrentDisplayMode(_ image: MenuBarItemImageCache.CapturedImage?) -> CGSize {
        preferredSize(for: shouldPreferPlaceholderImage ? nil : image)
    }

    private static func preferredSize(
        for item: MenuBarItem,
        image: MenuBarItemImageCache.CapturedImage?
    ) -> CGSize {
        if let image {
            // Clamp so a poisoned near-full-bar crop cannot dominate the
            // Visible layout strip (Finder menu chrome spanning the row).
            let width = image.scaledSize.width.clamped(to: Metrics.minWidth ... Metrics.maxWidth)
            let height = max(image.scaledSize.height, Metrics.minHeight)
            return CGSize(width: width, height: height)
        }

        let width = item.bounds.width.clamped(to: Metrics.minWidth ... Metrics.maxWidth)
        let height = max(item.bounds.height, Metrics.minHeight)
        return CGSize(width: width, height: height)
    }

    private static func makePlaceholderImage(for item: MenuBarItem, appState: AppState) -> NSImage? {
        if item.tag.matchesVisibleControlItem {
            let icon = appState.settings.general.iceIcon
            let state = appState.menuBarManager.section(withName: .visible)?.controlItem.state ?? .hideSection
            return switch state {
            case .showSection: icon.visible.nsImage(for: appState)
            case .hideSection: icon.hidden.nsImage(for: appState)
            }
        }
        return NSImage(
            systemSymbolName: "menubar.rectangle",
            accessibilityDescription: item.displayName
        )
    }

    private func drawPlaceholder() {
        let placeholderRect = bounds.insetBy(
            dx: Metrics.placeholderHorizontalInset,
            dy: Metrics.placeholderVerticalInset
        )
        let backgroundPath = NSBezierPath(
            roundedRect: placeholderRect,
            xRadius: Metrics.placeholderCornerRadius,
            yRadius: Metrics.placeholderCornerRadius
        )
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        backgroundPath.fill()

        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()

        guard let image = resolvedPlaceholderImage() else {
            return
        }

        let iconBounds = placeholderRect.insetBy(
            dx: Metrics.iconInset,
            dy: Metrics.iconInset
        )
        let iconSide = min(iconBounds.width, iconBounds.height)
        guard iconSide > 0 else {
            return
        }

        let iconRect = CGRect(
            x: placeholderRect.midX - (iconSide / 2),
            y: placeholderRect.midY - (iconSide / 2),
            width: iconSide,
            height: iconSide
        )

        if image.isTemplate {
            NSGraphicsContext.saveGraphicsState()
            NSColor.secondaryLabelColor.set()
            image.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: isEnabled ? 0.8 : 0.5
            )
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: isEnabled ? 0.9 : 0.5
            )
        }
    }

    private func refreshLivePlaceholderImage() {
        guard item.tag.matchesVisibleControlItem, let appState else { return }
        livePlaceholderImage = Self.makePlaceholderImage(for: item, appState: appState)
    }

    private func resolvedPlaceholderImage() -> NSImage? {
        if item.tag.matchesVisibleControlItem {
            return livePlaceholderImage ?? placeholderImage
        }
        return placeholderImage
    }

    private func placeholderBitmapImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: Layout Bar Item Pasteboard Type

extension NSPasteboard.PasteboardType {
    static let layoutBarItem = Self("\(Constants.bundleIdentifier).layout-bar-item")
}
