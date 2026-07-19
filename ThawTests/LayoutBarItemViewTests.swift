//
//  LayoutBarItemViewTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
import MenuBarModel
@testable import Thaw
import XCTest

@MainActor
final class LayoutBarItemViewTests: XCTestCase {
    func testSystemHostCaptureReceivesMissingHorizontalPadding() throws {
        let image = try MenuBarItemImageCache.CapturedImage(
            cgImage: opaqueImage(width: 20, height: 20),
            scale: 1
        )
        let item = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .menuBarAgent, title: "WiFi"),
            windowID: 1
        )

        XCTAssertEqual(
            LayoutBarItemView.systemItemHorizontalPadding(
                for: item,
                image: image,
                desiredPadding: 16
            ),
            16
        )
    }

    func testAppCaptureDoesNotReceiveSystemItemPadding() throws {
        let image = try MenuBarItemImageCache.CapturedImage(
            cgImage: opaqueImage(width: 20, height: 20),
            scale: 1
        )
        let item = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .string("com.example.StatusApp"), title: "Status"),
            windowID: 2
        )

        XCTAssertEqual(
            LayoutBarItemView.systemItemHorizontalPadding(
                for: item,
                image: image,
                desiredPadding: 16
            ),
            0
        )
    }

    func testSystemHostCaptureDoesNotDoubleExistingPadding() throws {
        let image = try MenuBarItemImageCache.CapturedImage(
            cgImage: image(
                width: 36,
                height: 20,
                opaqueRect: CGRect(x: 8, y: 0, width: 20, height: 20)
            ),
            scale: 1
        )
        let item = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .menuBarAgent, title: "Sound"),
            windowID: 3
        )

        XCTAssertEqual(
            LayoutBarItemView.systemItemHorizontalPadding(
                for: item,
                image: image,
                desiredPadding: 16
            ),
            0
        )
    }

    private func opaqueImage(width: Int, height: Int) throws -> CGImage {
        try image(
            width: width,
            height: height,
            opaqueRect: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    private func image(width: Int, height: Int, opaqueRect: CGRect) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(opaqueRect)
        return try XCTUnwrap(context.makeImage())
    }
}
