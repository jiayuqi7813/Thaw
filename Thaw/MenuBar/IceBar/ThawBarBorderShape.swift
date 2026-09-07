//
//  ThawBarBorderShape.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// A rounded rectangle whose stroke can omit the top edge.
///
/// Used by the Thaw Bar when square corners meet the display's rounded
/// screen corners (#325): drawing the top edge would be clipped and look
/// broken, so only the leading, trailing, and bottom edges are stroked.
nonisolated struct ThawBarBorderShape: Shape {
    /// Corner radius of the un-inset clip path.
    var cornerRadius: CGFloat
    /// Matches the Thaw Bar clip: circular for fully rounded ends,
    /// continuous for square corners.
    var cornerStyle: RoundedCornerStyle = .continuous
    /// When `true`, the path starts at the top-leading corner, runs down the
    /// leading side, across the bottom, and up the trailing side — leaving the
    /// top edge open.
    var omitTopEdge: Bool
    /// Inset applied before constructing the path (half the stroke width so
    /// the stroke sits on the clip edge, matching `InsettableShape.inset`).
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let drawRect = rect.insetBy(dx: inset, dy: inset)
        let radius = min(max(cornerRadius - inset, 0), min(drawRect.width, drawRect.height) / 2)

        if !omitTopEdge {
            return RoundedRectangle(cornerRadius: radius, style: cornerStyle)
                .path(in: drawRect)
        }

        guard radius > 0 else {
            var path = Path()
            path.move(to: CGPoint(x: drawRect.minX, y: drawRect.minY))
            path.addLine(to: CGPoint(x: drawRect.minX, y: drawRect.maxY))
            path.addLine(to: CGPoint(x: drawRect.maxX, y: drawRect.maxY))
            path.addLine(to: CGPoint(x: drawRect.maxX, y: drawRect.minY))
            return path
        }

        // Top corners stay square (open edge); bottom corners follow
        // `cornerStyle` so the stroke matches the clip path for both
        // `.circular` and `.continuous`.
        let closed = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: 0
            ),
            style: cornerStyle
        ).path(in: drawRect)

        return Self.openPathOmittingTopEdge(closed, in: drawRect)
    }

    /// Drops the top edge of a closed rounded-rect path and reverses the
    /// remaining outline so the stroke runs top-leading → bottom → top-trailing.
    private static func openPathOmittingTopEdge(_ closed: Path, in rect: CGRect) -> Path {
        var current = CGPoint.zero
        var skippedTopEdge = false
        var chain: [(from: CGPoint, to: CGPoint, element: ElementKind)] = []

        closed.forEach { element in
            switch element {
            case .move(to: let point):
                current = point
            case .line(to: let point):
                if !skippedTopEdge,
                   abs(current.y - rect.minY) < 0.5,
                   abs(point.y - rect.minY) < 0.5 {
                    skippedTopEdge = true
                    current = point
                    return
                }
                chain.append((current, point, .line))
                current = point
            case .quadCurve(to: let point, control: let control):
                chain.append((current, point, .quad(control: control)))
                current = point
            case .curve(to: let point, control1: let c1, control2: let c2):
                chain.append((current, point, .cubic(control1: c1, control2: c2)))
                current = point
            case .closeSubpath:
                break
            }
        }

        var path = Path()
        guard let last = chain.last else {
            return path
        }

        // Reverse so drawing starts at the original end (top-leading).
        path.move(to: last.to)
        for segment in chain.reversed() {
            switch segment.element {
            case .line:
                path.addLine(to: segment.from)
            case .quad(let control):
                path.addQuadCurve(to: segment.from, control: control)
            case .cubic(let control1, let control2):
                path.addCurve(to: segment.from, control1: control2, control2: control1)
            }
        }
        return path
    }

    private enum ElementKind {
        case line
        case quad(control: CGPoint)
        case cubic(control1: CGPoint, control2: CGPoint)
    }
}
