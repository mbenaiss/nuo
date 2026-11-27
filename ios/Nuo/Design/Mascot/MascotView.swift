import SwiftUI
import WidgetKit

/// What Orb, the Nuo mascot, is doing.
enum MascotState: String, CaseIterable, Sendable {
    case idle, talk, think, work, done, sleep
}

/// Orb: a cream pebble image, with its inner glow and its face drawn natively on top. The glow is its personality, so
/// it gets its own animated layer; the face is a few strokes, crisp at any size and free to blink or talk.
struct MascotView: View {
    let state: MascotState
    var size: CGFloat = 64
    /// Widgets and complications render a single frame.
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stateStart = Date()

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    MascotFrameView(frame: MascotFrame(state: state, time: context.date.timeIntervalSince(stateStart)), size: size)
                }
            } else {
                MascotFrameView(frame: MascotFrame(still: state), size: size)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: state) { stateStart = Date() }
        .accessibilityElement()
        .accessibilityLabel("Nuo")
        .accessibilityAddTraits(.isImage)
    }
}

/// Where things sit on the pebble, as fractions of the square canvas (measured on the source art).
private enum MascotGeometry {
    static let leftEye = CGPoint(x: 0.362, y: 0.487)
    static let rightEye = CGPoint(x: 0.637, y: 0.487)
    static let eyeWidth: CGFloat = 0.11
    static let eyeHeight: CGFloat = 0.036
    static let mouth = CGPoint(x: 0.5, y: 0.565)
    static let glowCenter = UnitPoint(x: 0.5, y: 0.82)
    static let glowRadius: CGFloat = 0.33
    static let spark = CGPoint(x: 0.83, y: 0.2)
    static let ink = Color(red: 0.196, green: 0.122, blue: 0.082)
    static let glow = Color(red: 1, green: 0.416, blue: 0.169)
}

private enum MascotEyes: Equatable {
    case open
    /// Thoughtful glance up and to the right.
    case glance
    /// Shorter, thicker, angled inward.
    case focused
    /// Gentle ◡ arcs; `depth` scales the curve.
    case closed(depth: CGFloat)
    /// Happy ◠ arcs.
    case smiling
}

private enum MascotMouth: Equatable {
    case none, line, open, smile
}

/// One animation frame. `glow` is the glow layer's strength (0...1.2), `glowScale` its radius factor.
private struct MascotFrame {
    var eyes = MascotEyes.open
    var mouth = MascotMouth.none
    var glow: Double = 0.7
    var glowScale: CGFloat = 1
    var lift: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var spark: Double = 0
    var sleepZ: Double = 0

    init(still state: MascotState) {
        switch state {
        case .idle: break
        case .talk: mouth = .line
        case .think: eyes = .glance; glow = 0.85; glowScale = 0.85
        case .work: eyes = .focused; glow = 0.95; spark = 1
        case .done: eyes = .smiling; mouth = .smile; glow = 1; glowScale = 1.12
        case .sleep: eyes = .closed(depth: 0.6); glow = 0.25; glowScale = 0.8; sleepZ = 0.5
        }
    }

    init(state: MascotState, time: TimeInterval) {
        self.init(still: state)
        let t = max(0, time)
        func wave(_ period: Double, phase: Double = 0) -> Double { sin(2 * .pi * (t / period + phase)) }
        let float = CGFloat(wave(4.2))
        switch state {
        case .idle:
            glow = 0.62 + 0.14 * wave(4.2)
            glowScale = 1 + 0.04 * CGFloat(wave(4.2))
            lift = -0.012 * float
            // Blinks every few seconds, with an occasional double blink so it never feels mechanical.
            let cycle = t.truncatingRemainder(dividingBy: 4.6)
            if (2.8..<2.95).contains(cycle) || (Int(t / 4.6) % 3 == 2 && (3.1..<3.24).contains(cycle)) { eyes = .closed(depth: 0.5) }
        case .talk:
            let mouths: [MascotMouth] = [.line, .open, .none, .open, .line, .none]
            mouth = mouths[Int(t / 0.14) % mouths.count]
            glow = 0.7 + (mouth == .open ? 0.12 : 0)
            lift = -0.008 * float
        case .think:
            // A quick, uneven shimmer: two waves out of step.
            glow = 0.8 + 0.12 * wave(1.1) + 0.06 * wave(0.47, phase: 0.3)
            glowScale = 0.85 + 0.05 * CGFloat(wave(1.1))
            lift = -0.02 * CGFloat((wave(2.4) + 1) / 2)
        case .work:
            glow = 0.95 + 0.04 * wave(0.35)
            let hop = abs(sin(2 * .pi * t / 0.9))
            lift = -0.025 * CGFloat(hop)
            scaleY = 1 - 0.015 * CGFloat(1 - hop)
            scaleX = 1 + 0.01 * CGFloat(1 - hop)
            spark = 0.55 + 0.45 * (wave(0.8) + 1) / 2
        case .done:
            // Flashes once when the state starts, then settles into a warm, slow breath.
            if t < 0.25 {
                glow = 0.7 + 0.5 * t / 0.25
                glowScale = 1 + 0.3 * CGFloat(t / 0.25)
            } else if t < 1 {
                let k = (t - 0.25) / 0.75
                glow = 1.2 - 0.25 * k
                glowScale = 1.3 - 0.18 * CGFloat(k)
            } else {
                glow = 0.95 + 0.06 * wave(3.6)
                glowScale = 1.12
            }
            let pop: CGFloat = t < 0.18 ? 0.9 + 0.16 * CGFloat(t / 0.18) : t < 0.36 ? 1.06 - 0.06 * CGFloat((t - 0.18) / 0.18) : 1
            scaleX = pop
            scaleY = pop
        case .sleep:
            let breath = wave(5.2)
            glow = 0.22 + 0.08 * breath
            scaleY = 1 + 0.02 * CGFloat(breath)
            scaleX = 1 + 0.008 * CGFloat(breath)
            sleepZ = t.truncatingRemainder(dividingBy: 3.4) / 3.4
        }
    }
}

private struct MascotFrameView: View {
    let frame: MascotFrame
    let size: CGFloat

    var body: some View {
        ZStack {
            // Desaturated rather than flattened to a silhouette on a tinted Home Screen widget; no effect elsewhere.
            Image("MascotBody").resizable().interpolation(.high).widgetAccentedRenderingMode(.desaturated)
            RadialGradient(
                colors: [MascotGeometry.glow.opacity(0.95), MascotGeometry.glow.opacity(0.45), MascotGeometry.glow.opacity(0)],
                center: MascotGeometry.glowCenter, startRadius: 0, endRadius: size * MascotGeometry.glowRadius * frame.glowScale)
                // Wider than tall, like light spreading through the base of the pebble.
                .scaleEffect(x: 1.2, y: 0.85, anchor: MascotGeometry.glowCenter)
                .opacity(min(frame.glow, 1))
                .brightness(max(0, frame.glow - 1) * 0.5)
                .mask { Image("MascotBody").resizable() }
            MascotFace(eyes: frame.eyes, mouth: frame.mouth, size: size)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: frame.scaleX, y: frame.scaleY, anchor: .bottom)
        .offset(y: frame.lift * size)
        .overlay {
            if frame.spark > 0 { MascotSpark(size: size, intensity: frame.spark) }
            if frame.sleepZ > 0 { MascotSleepZ(size: size, progress: frame.sleepZ) }
        }
    }
}

private struct MascotFace: View {
    let eyes: MascotEyes
    let mouth: MascotMouth
    let size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width
            let ink = GraphicsContext.Shading.color(MascotGeometry.ink)
            let w = MascotGeometry.eyeWidth * s
            let h = MascotGeometry.eyeHeight * s
            let stroke = StrokeStyle(lineWidth: h * 0.85, lineCap: .round)
            for (index, center) in [MascotGeometry.leftEye, MascotGeometry.rightEye].enumerated() {
                let c = CGPoint(x: center.x * s, y: center.y * s)
                let inward: CGFloat = index == 0 ? 1 : -1
                switch eyes {
                case .open:
                    context.fill(Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), cornerRadius: h / 2), with: ink)
                case .glance:
                    var eye = context
                    eye.translateBy(x: c.x + 0.015 * s, y: c.y - 0.02 * s)
                    eye.rotate(by: .degrees(-16))
                    eye.fill(Path(roundedRect: CGRect(x: -w * 0.45, y: -h / 2, width: w * 0.9, height: h), cornerRadius: h / 2), with: ink)
                case .focused:
                    var eye = context
                    eye.translateBy(x: c.x, y: c.y)
                    eye.rotate(by: .degrees(Double(8 * inward)))
                    let fw = w * 0.78, fh = h * 1.2
                    eye.fill(Path(roundedRect: CGRect(x: -fw / 2, y: -fh / 2, width: fw, height: fh), cornerRadius: fh / 2), with: ink)
                case let .closed(depth):
                    var arc = Path()
                    arc.move(to: CGPoint(x: c.x - w / 2, y: c.y - h * 0.3))
                    arc.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: c.y - h * 0.3), control: CGPoint(x: c.x, y: c.y + h * 1.6 * depth))
                    context.stroke(arc, with: ink, style: stroke)
                case .smiling:
                    var arc = Path()
                    arc.move(to: CGPoint(x: c.x - w * 0.45, y: c.y + h * 0.4))
                    arc.addQuadCurve(to: CGPoint(x: c.x + w * 0.45, y: c.y + h * 0.4), control: CGPoint(x: c.x, y: c.y - h * 1.1))
                    context.stroke(arc, with: ink, style: stroke)
                }
            }
            let m = CGPoint(x: MascotGeometry.mouth.x * s, y: MascotGeometry.mouth.y * s)
            switch mouth {
            case .none: break
            case .line:
                context.fill(Path(roundedRect: CGRect(x: m.x - w * 0.2, y: m.y - h * 0.35, width: w * 0.4, height: h * 0.7), cornerRadius: h * 0.35), with: ink)
            case .open:
                context.fill(Path(ellipseIn: CGRect(x: m.x - w * 0.13, y: m.y - h * 0.55, width: w * 0.26, height: h * 1.1)), with: ink)
            case .smile:
                var arc = Path()
                arc.move(to: CGPoint(x: m.x - w * 0.22, y: m.y - h * 0.25))
                arc.addQuadCurve(to: CGPoint(x: m.x + w * 0.22, y: m.y - h * 0.25), control: CGPoint(x: m.x, y: m.y + h * 0.75))
                context.stroke(arc, with: ink, style: StrokeStyle(lineWidth: h * 0.6, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Four-point spark above the pebble while it works.
private struct MascotSpark: View {
    let size: CGFloat
    let intensity: Double

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width
            let c = CGPoint(x: MascotGeometry.spark.x * s, y: MascotGeometry.spark.y * s)
            let r = s * 0.055 * (0.8 + 0.2 * intensity)
            var star = Path()
            star.move(to: CGPoint(x: c.x, y: c.y - r))
            star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
            star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
            star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
            star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
            context.fill(star, with: .color(MascotGeometry.glow.opacity(intensity)))
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// A small « z » drifting up from the top right while asleep.
private struct MascotSleepZ: View {
    let size: CGFloat
    let progress: Double

    var body: some View {
        Text(verbatim: "z")
            .font(.system(size: max(7, size * 0.13), weight: .semibold, design: .rounded))
            .foregroundStyle(Color(white: 0.55).opacity(sin(.pi * progress)))
            .position(x: size * (0.8 + 0.04 * progress), y: size * (0.22 - 0.08 * progress))
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

#Preview {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
        ForEach(MascotState.allCases, id: \.self) { state in
            VStack {
                MascotView(state: state, size: 96)
                Text(state.rawValue).font(.caption)
            }
        }
    }
    .padding()
    .background(Color(white: 0.95))
}
