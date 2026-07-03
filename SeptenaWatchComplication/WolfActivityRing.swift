//  WolfActivityRing.swift
//
//  Vendored from WolfActivityRing — https://github.com/wolfmcnally/WolfActivityRing
//  Copyright © Wolf McNally. Licensed under the MIT License (full text below).
//
//  Septena adaptations:
//   • `ActivityRingOptions` default `backgroundColor`/`outlineColor` no longer use
//     `Color(.systemGray6/.systemGray4)` (UIColor APIs unavailable on watchOS) —
//     replaced with cross-platform `Color` values. Callers override these anyway.
//   • The DEBUG preview harness + demo color extensions were dropped.
//  Over-100% reads via the `color → tipColor` angular gradient + bright tip cap
//  (pure color contrast), which survives the restricted watchOS complication
//  (WidgetKit) rendering mode where `.shadow()` is unreliable.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import SwiftUI

public struct ActivityRingProgressKey: EnvironmentKey {
    public static let defaultValue: Double = 0
}

extension EnvironmentValues {
    public var activityRingProgress: Double {
        get { self[ActivityRingProgressKey.self] }
        set { self[ActivityRingProgressKey.self] = newValue }
    }
}

public struct ActivityRingOptions {
    public var radius: Double = 30
    public var thickness: Double = 10
    public var color: Color = .accentColor
    public var tipColor: Color? = nil
    // Cross-platform defaults (watchOS has no UIColor.systemGray6/4). Septena
    // overrides these per ring anyway.
    public var backgroundColor: Color = Color(white: 0.13)
    public var tipShadowColor: Color = .black.opacity(0.3)
    public var outlineColor: Color = Color.gray.opacity(0.35)
    public var outlineThickness: Double = 1

    public init() {
    }
}

public struct ActivityRing<Content>: View where Content: View {
    let progress: Double
    let options: ActivityRingOptions
    let content: Content

    public init(
        progress: Double,
        options: ActivityRingOptions,
        @ViewBuilder content: () -> Content)
    {
        self.progress = progress
        self.options = options
        self.content = content()
    }

    private var effectiveTipColor: Color {
        options.tipColor ?? options.color
    }

    public var body: some View {
        let activityAngularGradient = AngularGradient(
            gradient: Gradient(colors: [options.color, effectiveTipColor]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360.0 * progress))

        ZStack {
            if options.backgroundColor != .clear {
                Circle()
                    .stroke(options.backgroundColor, lineWidth: options.thickness)
                    .frame(width: options.radius * 2.0)
            }
            if options.outlineColor != .clear {
                Circle()
                    .stroke(options.outlineColor, lineWidth: options.outlineThickness)
                    .frame(width:(options.radius * 2.0) + options.thickness - options.outlineThickness)
                Circle()
                    .stroke(options.outlineColor, lineWidth: options.outlineThickness)
                    .frame(width:(options.radius * 2.0) - options.thickness + options.outlineThickness)
            }
            Circle()
                .trim(from: 0, to: self.progress)
                .stroke(
                    activityAngularGradient,
                    style: StrokeStyle(lineWidth: options.thickness, lineCap: .round))
                .rotationEffect(Angle(degrees: -90))
                .frame(width: options.radius * 2.0)
                .animation(.easeOut, value: progress)
            RingCap(progress: progress,
                            ringRadius: options.radius)
                .fill(effectiveTipColor, strokeBorder: effectiveTipColor, lineWidth: 1) // hide seam
                .frame(width:options.thickness, height:options.thickness)
                .shadow(color: options.tipShadowColor,
                        radius: 2.5,
                        x: ringTipShadowOffset.x,
                        y: ringTipShadowOffset.y
                )
                .clipShape(
                    RingClipShape(radius: options.radius, thickness: options.thickness)
                )
                .opacity(tipOpacity)
                .animation(.easeOut, value: progress)
            content
                .environment(\.activityRingProgress, progress)
        }
        .aspectRatio(1, contentMode: .fill)
        .frame(width: size, height: size)
    }

    private var size: Double {
        return options.radius * 2 + options.thickness
    }

    private var tipOpacity: Double {
        if progress < 0.95 {
            return 0
        } else {
            return 1
        }
    }

    private var ringTipShadowOffset: CGPoint {
        let ringTipPosition = tipPosition(progress: progress, radius: options.radius)
        let shadowPosition = tipPosition(progress: progress + 0.0075, radius: options.radius)
        return CGPoint(x: shadowPosition.x - ringTipPosition.x,
                       y: shadowPosition.y - ringTipPosition.y)
    }

    private func tipPosition(progress: Double, radius: Double) -> CGPoint {
        let progressAngle = Angle(degrees: (360.0 * progress) - 90.0)
        return CGPoint(
            x: radius * cos(progressAngle.radians),
            y: radius * sin(progressAngle.radians))
    }
}

extension Shape {
    func fill<Fill: ShapeStyle, Stroke: ShapeStyle>(_ fillStyle: Fill, strokeBorder strokeStyle: Stroke, lineWidth: CGFloat = 1) -> some View {
        self
            .stroke(strokeStyle, lineWidth: lineWidth)
            .background(self.fill(fillStyle))
    }
}

extension ActivityRing where Content == EmptyView {
    public init(
        progress: Double,
        options: ActivityRingOptions
    ) {
        self.init(
            progress: progress,
            options: options
        ) {
            EmptyView()
        }
    }
}

struct RingClipShape: Shape {
    let radius: Double
    let thickness: Double

    func path(in rect: CGRect) -> Path {
        let outerRadius = radius + thickness / 2
        let innerRadius = radius - thickness / 2
        let center = CGPoint(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
        path.addArc(center: center, radius: innerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        return path
    }
}

struct RingCap: Shape {
    var progress: Double
    let ringRadius: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else {
            return Path()
        }

        var path = Path()
        let progressAngle = Angle(degrees: (360.0 * progress) - 90.0)
        let tipRadius = rect.width / 2
        let center = CGPoint(
            x: ringRadius * cos(progressAngle.radians) + tipRadius,
            y: ringRadius * sin(progressAngle.radians) + tipRadius
        )
        let startAngle = progressAngle + .degrees(180)
        let endAngle = startAngle - .degrees(180)
        path.addArc(center: center, radius: tipRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

public struct ActivityRingPercent: View {
    @Environment(\.activityRingProgress) var progress: Double

    public var body: some View {
        Text("\(Int(progress * 100))%")
    }
}
