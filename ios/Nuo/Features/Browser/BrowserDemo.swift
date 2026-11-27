import CoreGraphics
import Foundation
import SwiftUI

/// `-demo`: a fake login page rendered locally, which reacts to taps and typing like the real stream.
@MainActor
final class DemoBrowserTransport: BrowserTransport {
    private var continuation: AsyncStream<BrowserEvent>.Continuation?
    private var viewport: BrowserViewport?
    private var focused: DemoLoginPage.Field?
    private var email = ""
    private var password = ""
    private var lastTap: CGPoint?
    private var activeTab = "d1"
    private var loggedIn = false
    private var loginsPending = true

    private static let desktop = CGSize(width: 1280, height: 712)

    func connect() -> AsyncStream<BrowserEvent> {
        let (stream, continuation) = AsyncStream<BrowserEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task { @MainActor [weak self] in
            continuation.yield(.status("starting"))
            try? await Task.sleep(for: .milliseconds(400))
            continuation.yield(.status("ready"))
            self?.publish()
        }
        return stream
    }

    func send(_ command: BrowserCommand) {
        switch command {
        case let .click(x, y, _, _):
            let size = pageSize
            let point = CGPoint(x: x * size.width, y: y * size.height)
            lastTap = point
            focused = DemoLoginPage.field(at: point, in: size)
            if focused == .submit {
                loggedIn = !email.isEmpty && !password.isEmpty
                focused = nil
            }
        case let .text(text):
            if focused == .email { email += text } else if focused == .password { password += text }
        case let .key(key, _):
            if key == "Backspace" {
                if focused == .email, !email.isEmpty { email.removeLast() }
                if focused == .password, !password.isEmpty { password.removeLast() }
            } else if key == "Tab" {
                focused = focused == .email ? .password : .email
            } else if key == "Enter" {
                loggedIn = !email.isEmpty && !password.isEmpty
            }
        case let .viewport(width, height):
            viewport = width > 0 && height > 0 ? BrowserViewport(width: min(width, 1280), height: min(height, 712)) : nil
        case let .selectTab(id):
            activeTab = id
        case .done:
            loginsPending = false
            continuation?.yield(.done)
        case .ack, .ping, .surface, .zoom:
            return
        default:
            break
        }
        publish()
    }

    func disconnect() {
        continuation?.finish()
        continuation = nil
    }

    private var pageSize: CGSize {
        viewport.map { CGSize(width: $0.width, height: $0.height) } ?? Self.desktop
    }

    private func publish() {
        guard let continuation else { return }
        let tabs = [
            BrowserTab(id: "d1", title: loggedIn ? String(localized: "News feed | example.org") : String(localized: "Sign-in | example.org"), url: loggedIn ? "https://www.example.org/feed/" : "https://www.example.org/login"),
            BrowserTab(id: "d2", title: "Example Domain", url: "https://example.com/"),
        ]
        let active = tabs.first { $0.id == activeTab } ?? tabs[0]
        continuation.yield(.state(BrowserPageState(
            tabs: tabs, activeTabId: active.id, url: active.url, title: active.title, canGoBack: true, canGoForward: false, loading: false,
            viewport: viewport,
            focus: focused == .password ? "password" : focused == .email ? "text" : nil,
            logins: loginsPending ? [BrowserLogin(id: "l1", site: "LinkedIn", url: "https://www.linkedin.com/login")] : [])))
        let size = pageSize
        let page = DemoLoginPage(size: size, email: email, passwordLength: password.count, focused: focused, tap: lastTap, loggedIn: loggedIn, example: activeTab == "d2")
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        continuation.yield(.frame(image, cssSize: size))
    }
}

/// A generic login form (no real site's branding), laid out at fixed positions so taps can be hit-tested.
struct DemoLoginPage: View {
    enum Field { case email, password, submit }

    let size: CGSize
    let email: String
    let passwordLength: Int
    let focused: Field?
    let tap: CGPoint?
    let loggedIn: Bool
    let example: Bool

    static func frames(in size: CGSize) -> [Field: CGRect] {
        let width = min(360, size.width - 40)
        let x = (size.width - width) / 2
        let top = max(150, size.height * 0.3)
        return [
            .email: CGRect(x: x, y: top, width: width, height: 44),
            .password: CGRect(x: x, y: top + 64, width: width, height: 44),
            .submit: CGRect(x: x, y: top + 132, width: width, height: 44),
        ]
    }

    static func field(at point: CGPoint, in size: CGSize) -> Field? {
        frames(in: size).first { $0.value.contains(point) }?.key
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.97)
            if example {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Example Domain").font(.system(size: 30, weight: .bold))
                    Text("This domain is for use in documentation examples without needing permission.").font(.system(size: 15))
                }
                .foregroundStyle(.black)
                .frame(width: min(560, size.width - 40), alignment: .leading)
                .position(x: size.width / 2, y: 140)
            } else if loggedIn {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text("Signed in").font(.system(size: 24, weight: .semibold)).foregroundStyle(.black)
                    Text("Your session stays open for your agents.").font(.system(size: 14)).foregroundStyle(.gray)
                }
                .position(x: size.width / 2, y: size.height * 0.4)
            } else {
                form
            }
            if let tap {
                Circle().fill(Color.orange.opacity(0.35)).frame(width: 22, height: 22).position(tap)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private var form: some View {
        let frames = Self.frames(in: size)
        let email = frames[.email]!
        Text("Sign-in")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.black)
            .position(x: size.width / 2, y: email.minY - 60)
        input(self.email.isEmpty ? String(localized: "Email or phone") : self.email, placeholder: self.email.isEmpty, field: .email, rect: email)
        input(passwordLength == 0 ? String(localized: "Password") : String(repeating: "•", count: passwordLength), placeholder: passwordLength == 0, field: .password, rect: frames[.password]!)
        let submit = frames[.submit]!
        Text("Log in")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: submit.width, height: submit.height)
            .background(Capsule().fill(Color(red: 0.04, green: 0.4, blue: 0.76)))
            .position(x: submit.midX, y: submit.midY)
    }

    private func input(_ text: String, placeholder: Bool, field: Field, rect: CGRect) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(placeholder ? Color.gray : Color.black)
            .padding(.horizontal, 12)
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused == field ? Color(red: 0.04, green: 0.4, blue: 0.76) : Color.gray.opacity(0.5), lineWidth: focused == field ? 2 : 1))
            .position(x: rect.midX, y: rect.midY)
    }
}
