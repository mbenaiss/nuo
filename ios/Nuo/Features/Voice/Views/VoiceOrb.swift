import SwiftUI

/// Glowing orb of the voice mode. Breathes when idle, swells with the user's voice while
/// listening, ripples with the bot's voice while speaking, shimmers while thinking.
struct VoiceOrb: View {
    enum Mood: Equatable { case idle, listening, thinking, speaking, muted, failed }

    var mood: Mood
    var meter: LevelMeter
    var tint: OrbPalette = .ember

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let level = currentLevel
            Canvas { canvas, size in
                draw(in: &canvas, size: size, time: time, level: level)
            }
        }
        .accessibilityHidden(true)
    }

    private var currentLevel: CGFloat {
        switch mood {
        case .listening: CGFloat(meter.input)
        case .speaking, .thinking: CGFloat(meter.output)
        default: 0
        }
    }

    private var palette: OrbPalette {
        switch mood {
        case .muted: .ash
        case .failed: .dimmed
        default: tint
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval, level: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = min(size.width, size.height)
        let base = side * 0.31
        let breathing = CGFloat(sin(time * 1.4)) * 0.012
        let thinkingPulse = mood == .thinking ? CGFloat(sin(time * 3.2)) * 0.02 : 0
        let swell = mood == .muted ? -0.06 : level * (mood == .listening ? 0.10 : 0.07)
        let radius = base * (1 + breathing + thinkingPulse + swell)
        let colors = palette

        // Halo
        let haloRadius = min(radius * (1.5 + level * 0.3), side / 2)
        let haloOpacity = mood == .muted ? 0.12 : 0.34 + Double(level) * 0.35
        canvas.fill(
            Circle().path(in: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [colors.glow.opacity(haloOpacity), colors.glow.opacity(haloOpacity * 0.35), .clear]),
                center: center, startRadius: radius * 0.6, endRadius: haloRadius
            )
        )

        let wobble = mood == .speaking || mood == .listening ? level : (mood == .thinking ? 0.25 : 0)
        let shape = blobPath(center: center, radius: radius, time: time, intensity: wobble)

        canvas.drawLayer { layer in
            layer.clip(to: shape)
            let light = CGPoint(x: center.x - radius * 0.38, y: center.y - radius * 0.42)
            layer.fill(shape, with: .radialGradient(
                Gradient(stops: [
                    .init(color: colors.highlight, location: 0),
                    .init(color: colors.mid, location: 0.42),
                    .init(color: colors.deep, location: 0.82),
                    .init(color: colors.edge, location: 1),
                ]),
                center: light, startRadius: 0, endRadius: radius * 1.85
            ))

            // Slowly drifting inner currents give the surface life.
            layer.blendMode = .screen
            let speed = mood == .thinking ? 1.6 : 0.6
            for index in 0..<3 {
                let phase = time * speed * (0.5 + Double(index) * 0.23) + Double(index) * 2.1
                let orbit = radius * (0.32 + 0.08 * CGFloat(index))
                let blobCenter = CGPoint(
                    x: center.x + CGFloat(cos(phase)) * orbit,
                    y: center.y + CGFloat(sin(phase * 1.3)) * orbit * 0.8
                )
                let blobRadius = radius * (0.55 + level * 0.25)
                layer.fill(
                    Circle().path(in: CGRect(x: blobCenter.x - blobRadius, y: blobCenter.y - blobRadius, width: blobRadius * 2, height: blobRadius * 2)),
                    with: .radialGradient(
                        Gradient(colors: [colors.current.opacity(0.32 + Double(level) * 0.25), .clear]),
                        center: blobCenter, startRadius: 0, endRadius: blobRadius
                    )
                )
            }

            layer.blendMode = .multiply
            let shadowCenter = CGPoint(x: center.x + radius * 0.45, y: center.y + radius * 0.55)
            layer.fill(shape, with: .radialGradient(
                Gradient(colors: [.clear, colors.edge.opacity(0.55)]),
                center: shadowCenter, startRadius: radius * 1.6, endRadius: radius * 0.2
            ))

            layer.blendMode = .screen
            let sheen = CGRect(x: center.x - radius * 0.62, y: center.y - radius * 0.72, width: radius * 0.75, height: radius * 0.5)
            layer.fill(Ellipse().path(in: sheen), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.28), .clear]),
                center: CGPoint(x: sheen.midX, y: sheen.midY), startRadius: 0, endRadius: radius * 0.4
            ))
        }
    }

    /// Circle whose outline ripples with a few drifting harmonics, scaled by the voice level.
    private func blobPath(center: CGPoint, radius: CGFloat, time: TimeInterval, intensity: CGFloat) -> Path {
        var path = Path()
        let steps = 96
        let amplitude = radius * 0.028 * min(intensity, 1)
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let ripple = sin(3 * angle + time * 2.1) * 0.6 + sin(5 * angle - time * 2.9) * 0.4 + sin(2 * angle + time * 1.3) * 0.5
            let r = radius + amplitude * CGFloat(ripple)
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

struct OrbPalette: Equatable {
    var highlight: Color
    var mid: Color
    var deep: Color
    var edge: Color
    var current: Color
    var glow: Color

    static let ember = OrbPalette(
        highlight: Color(red: 1.0, green: 0.80, blue: 0.62),
        mid: Color(red: 0.99, green: 0.52, blue: 0.30),
        deep: Color(red: 0.88, green: 0.30, blue: 0.16),
        edge: Color(red: 0.45, green: 0.10, blue: 0.06),
        current: Color(red: 1.0, green: 0.70, blue: 0.45),
        glow: Color(red: 1.0, green: 0.42, blue: 0.18)
    )

    static let ash = OrbPalette(
        highlight: Color(white: 0.62),
        mid: Color(white: 0.40),
        deep: Color(white: 0.24),
        edge: Color(white: 0.10),
        current: Color(white: 0.5),
        glow: Color(white: 0.45)
    )

    static let dimmed = OrbPalette(
        highlight: Color(red: 0.75, green: 0.45, blue: 0.40),
        mid: Color(red: 0.55, green: 0.22, blue: 0.20),
        deep: Color(red: 0.35, green: 0.12, blue: 0.11),
        edge: Color(red: 0.15, green: 0.05, blue: 0.05),
        current: Color(red: 0.6, green: 0.3, blue: 0.3),
        glow: Color(red: 0.6, green: 0.15, blue: 0.12)
    )
}
