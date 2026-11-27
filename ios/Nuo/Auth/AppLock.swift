#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import SwiftUI

/// Face ID / Touch ID lock of the app: at launch, and when it comes back after a configurable time in the
/// background. Extensions are not affected (they hold scoped tokens, not the device key).
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    enum Delay: Int, CaseIterable, Identifiable, Sendable {
        case immediate = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .immediate: String(localized: "Immediately")
            case .oneMinute: String(localized: "After 1 minute")
            case .fiveMinutes: String(localized: "After 5 minutes")
            case .fifteenMinutes: String(localized: "After 15 minutes")
            }
        }
    }

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    var delay: Delay {
        didSet { UserDefaults.standard.set(delay.rawValue, forKey: Keys.delay) }
    }

    private(set) var isLocked: Bool
    private(set) var isUnlocking = false
    @ObservationIgnored private var backgroundedAt: Date?
    /// A biometric prompt of the lock itself may take the app out of the front; that is not leaving it.
    @ObservationIgnored private var prompting = false

    private enum Keys {
        static let enabled = "nuo.lock.enabled"
        static let delay = "nuo.lock.delay"
    }

    private init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        isEnabled = enabled
        delay = Delay(rawValue: defaults.object(forKey: Keys.delay) as? Int ?? Delay.fiveMinutes.rawValue) ?? .fiveMinutes
        // Demo and UI-test launches skip the lock so screenshots stay scriptable; `-demoLocked` shows it without prompting.
        isLocked = enabled && (!ProcessInfo.processInfo.arguments.contains("-demo") || Self.demoLocked)
        #if os(macOS)
        // A Mac window's scene stays active behind other apps: the app's own activation tells when it was left.
        let center = NotificationCenter.default
        _ = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activityChanged(active: false) }
        }
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activityChanged(active: true) }
        }
        #endif
    }

    private static var demoLocked: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-demo") && arguments.contains("-demoLocked")
    }

    func sceneDidChange(to phase: ScenePhase) {
        switch phase {
        case .background: activityChanged(active: false)
        case .active: activityChanged(active: true)
        default: break
        }
    }

    /// The app left the front (`active == false`) or came back to it: past the delay, it locks and asks to unlock.
    func activityChanged(active: Bool) {
        guard isEnabled else { return }
        guard active else {
            if backgroundedAt == nil, !prompting { backgroundedAt = Date() }
            return
        }
        if let since = backgroundedAt, Date().timeIntervalSince(since) >= TimeInterval(delay.rawValue) { isLocked = true }
        backgroundedAt = nil
        if isLocked, !Self.demoLocked { Task { await unlock() } }
    }

    func unlock() async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        if await confirm(reason: String(localized: "Unlock Nuo.")) { isLocked = false }
    }

    private func confirm(reason: String) async -> Bool {
        prompting = true
        let confirmed = await BiometricGate.confirm(reason: reason)
        prompting = false
        #if os(macOS)
        // Leaving for another app during the prompt was ignored: count the absence from now on.
        if !NSApp.isActive, backgroundedAt == nil { backgroundedAt = Date() }
        #endif
        return confirmed
    }

    /// Turning the lock off is itself confirmed, otherwise anyone holding the unlocked app could disable it.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if !enabled, !(await confirm(reason: String(localized: "Confirm to turn off the Nuo lock."))) { return }
        isEnabled = enabled
        if !enabled { isLocked = false }
    }
}

extension View {
    /// Lock screen while locked, and a blurred privacy screen whenever the app is not active (app switcher).
    func appLock(_ lock: AppLock = .shared) -> some View {
        modifier(AppLockModifier(lock: lock))
    }
}

private struct AppLockModifier: ViewModifier {
    let lock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                if lock.isLocked {
                    LockScreen(lock: lock).transition(.opacity)
                } else if scenePhase != .active {
                    PrivacyScreen().transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.2), value: lock.isLocked)
            #if !os(macOS)
            .onChange(of: scenePhase, initial: true) { _, phase in lock.sceneDidChange(to: phase) }
            #endif
    }
}

private struct PrivacyScreen: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay { MascotView(state: .sleep, size: MascotMetrics.hero, animated: false) }
            .ignoresSafeArea()
    }
}

private struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                MascotView(state: .sleep, size: MascotMetrics.hero)
                Text("Nuo is locked").font(.title2.bold()).foregroundStyle(Color.ink)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock", systemImage: BiometricGate.biometryName == "Touch ID" ? "touchid" : "faceid")
                }
                .buttonStyle(InkButtonStyle())
                .frame(maxWidth: 260)
                .disabled(lock.isUnlocking)
            }
            .padding(24)
        }
    }
}
