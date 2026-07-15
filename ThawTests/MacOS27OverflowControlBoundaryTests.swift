//
//  MacOS27OverflowControlBoundaryTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import MenuBarModel
import Testing
@testable import Thaw

@Suite("macOS 27 overflow control boundaries")
struct MacOS27OverflowControlBoundaryTests {
    @Test("Managed-cache items retain the Hidden boundary")
    func managedCacheItemsRetainHiddenBoundary() {
        let visibleControl = MenuBarItem.fixture(
            tag: .visibleControlItem,
            windowID: 81,
            bounds: CGRect(x: 100, y: 0, width: 24, height: 22)
        )

        let controlUIDs = MenuBarItemManager.macOS27OverflowControlUIDs(in: [visibleControl])

        #expect(controlUIDs.visible == visibleControl.uniqueIdentifier)
        #expect(controlUIDs.hidden == MenuBarItemTag.hiddenControlItem.tagIdentifier)
    }
}
