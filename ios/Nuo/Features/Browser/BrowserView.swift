import SwiftUI

/// « Navigateur »: live view of the shared browser on the gateway, where the user logs in to sites for his agents.
struct BrowserScreen: View {
    @Environment(SessionStore.self) private var session
    let onClose: () -> Void
    @State private var model: BrowserModel?

    var body: some View {
        Group {
            if let model {
                BrowserContent(model: model, onClose: onClose)
            } else {
                Color.canvas
            }
        }
        .task {
            // Reopening the window reuses the model `onDisappear` stopped: start it again.
            let current = model ?? BrowserModel(transport: session.makeBrowserTransport())
            model = current
            current.start()
        }
        .onDisappear { model?.stop() }
    }
}

private struct BrowserContent: View {
    @Bindable var model: BrowserModel
    let onClose: () -> Void

    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var typing = ""
    @State private var sentText = ""
    @State private var secure = false
    @FocusState private var typingFocused: Bool
    @State private var mobileLayout = Self.prefersMobileLayout
    @State private var canvasSize: CGSize = .zero
    @State private var showsCredentials = false
    @State private var forcesInput = false
    /// A slider or a map needs the button held down while the finger travels, which a scroll can never say.
    @State private var dragsPage = false
    @Environment(\.displayScale) private var displayScale

    private static var prefersMobileLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if model.page.tabs.count > 1 { tabStrip }
            if !model.page.logins.isEmpty { loginBanner }
            BrowserCanvas(model: model, onPageTap: resetTyping, dragsPage: dragsPage)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    canvasSize = size
                    applyLayout()
                }
            if showsInput { inputBar }
        }
        .background(Color.canvas)
        .onChange(of: model.page.url) { _, url in
            if !addressFocused { address = url }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .ready { applyLayout() }
        }
        .onChange(of: mobileLayout) { _, _ in applyLayout() }
        .onChange(of: displayScale) { _, _ in applyLayout() }
        // The page says which field has the keyboard: the input follows it, masked when it is a password.
        .onChange(of: model.page.focus) { _, focus in
            secure = focus == "password"
            resetTyping()
            if focus == nil { forcesInput = false } else { typingFocused = true }
        }
        .sheet(isPresented: $showsCredentials) {
            BrowserCredentialsSheet(site: host(model.page.url), isEditing: model.page.isEditing) { identifier, password, submit in
                fill(identifier: identifier, password: password, submit: submit)
            }
        }
        .alert("Browser", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Done") { model.finish(onClose) }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accent)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    Text(model.activeTab?.title.isEmpty == false ? model.activeTab!.title : String(localized: "Browser"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    statusLine
                }
                Spacer(minLength: 0)
                menu
            }
            HStack(spacing: 10) {
                iconButton("chevron.left", label: "Back", enabled: model.page.canGoBack) { model.send(.back) }
                iconButton("chevron.right", label: "Forward", enabled: model.page.canGoForward) { model.send(.forward) }
                TextField("Address or search", text: $address)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        model.send(.navigate(address))
                        addressFocused = false
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.chip, in: Capsule())
                #if os(iOS)
                iconButton("hand.draw", label: dragsPage ? "Back to scrolling" : "Drag instead of scrolling", enabled: model.phase == .ready, active: dragsPage) {
                    dragsPage.toggle()
                    Haptics.selection()
                }
                #endif
                iconButton("person.badge.key", label: "Fill in a login", enabled: model.phase == .ready) { showsCredentials = true }
                iconButton(model.page.loading ? "xmark" : "arrow.clockwise", label: "Reload", enabled: model.phase == .ready) { model.send(.reload) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.card)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .connecting:
            Text("Connecting…").font(.caption2).foregroundStyle(Color.text2)
        case .starting:
            Text("Starting the browser…").font(.caption2).foregroundStyle(Color.text2)
        case .ready:
            Text(host(model.page.url)).font(.caption2).foregroundStyle(Color.text2).lineLimit(1)
        case let .offline(message):
            Text(message).font(.caption2).foregroundStyle(Color.bad).lineLimit(1)
        }
    }

    private var menu: some View {
        Menu {
            Button { model.send(.newTab) } label: { Label("New tab", systemImage: "plus.square.on.square") }
            if let tab = model.activeTab {
                Button(role: .destructive) { model.send(.closeTab(tab.id)) } label: { Label("Close tab", systemImage: "xmark.square") }
            }
            Divider()
            Toggle(isOn: $mobileLayout) { Label("Narrow layout", systemImage: "iphone") }
            #if os(iOS)
            // A page that hides its fields from us (a cross-origin frame) still needs a way to be typed into.
            Toggle(isOn: $forcesInput) { Label("Keyboard for the page", systemImage: "keyboard") }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Color.ink)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More options")
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.page.tabs) { tab in
                    let active = tab.id == model.page.activeTabId
                    Button { model.send(.selectTab(tab.id)) } label: {
                        Text(tab.title.isEmpty ? host(tab.url) : tab.title)
                            .font(.caption.weight(active ? .semibold : .regular))
                            .lineLimit(1)
                            .frame(maxWidth: 160)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(active ? Color.onInk : Color.ink)
                            .background(active ? Color.inkFill : Color.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { model.send(.newTab) } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold)).padding(7).background(Color.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New tab")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(Color.card)
    }

    private var loginBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.badge.key.fill").foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign-in required on \(model.page.logins.map(\.site).formatted(.list(type: .and)))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text("An agent is waiting. Sign in, then tap “Done”.")
                    .font(.caption)
                    .foregroundStyle(Color.text2)
            }
            Spacer(minLength: 0)
            Button("Sign in") { showsCredentials = true }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentSoft)
    }

    // MARK: Text input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if secure {
                        SecureField("Type into the page (hidden)", text: $typing)
                            .textContentType(.password)
                    } else {
                        TextField("Type into the page", text: $typing)
                            .textContentType(.username)
                    }
                }
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.return)
                .focused($typingFocused)
                .onChange(of: typing) { _, text in forward(text) }
                .onSubmit {
                    model.send(.key("Enter"))
                    resetTyping()
                    typingFocused = true
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.chip, in: Capsule())
                iconButton(secure ? "eye.slash" : "eye", label: secure ? "Show typing" : "Hide typing", enabled: true) {
                    secure.toggle()
                    resetTyping()
                }
                iconButton("arrow.right.to.line", label: "Tab", enabled: model.phase == .ready) {
                    model.send(.key("Tab"))
                    resetTyping()
                }
                iconButton("delete.left", label: "Delete", enabled: model.phase == .ready) { model.send(.key("Backspace")) }
            }
            Text("Agents never type your passwords.")
                .font(.caption2)
                .foregroundStyle(Color.text3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.card)
        .overlay(alignment: .top) { Divider() }
    }

    /// The field is a buffer: what changed since the last keystroke is typed into the page, so pasting or
    /// a password manager's fill arrives as one insertion.
    private func forward(_ text: String) {
        let old = sentText
        guard text != old else { return }
        let common = zip(old, text).prefix { $0 == $1 }.count
        for _ in 0 ..< (old.count - common) { model.send(.key("Backspace")) }
        let added = String(text.dropFirst(common))
        if !added.isEmpty { model.send(.text(added)) }
        sentText = text
    }

    private func resetTyping() {
        sentText = ""
        typing = ""
    }

    /// The Mac types into the page directly through the frame; the phone needs the field only while one is active.
    private var showsInput: Bool {
        #if os(macOS)
        false
        #else
        model.page.isEditing || forcesInput
        #endif
    }

    private func applyLayout() {
        if canvasSize.width > 0, canvasSize.height > 0 {
            model.setSurface(width: Int(canvasSize.width * displayScale), height: Int(canvasSize.height * displayScale))
        }
        guard mobileLayout, canvasSize.width > 0 else { return model.setViewport(nil) }
        model.setViewport(BrowserViewport(width: Int(canvasSize.width), height: Int(canvasSize.height)))
    }

    /// Types a pair the password manager filled into the page: identifier, Tab, password, and Enter when asked.
    private func fill(identifier: String, password: String, submit: Bool) {
        resetTyping()
        if !identifier.isEmpty {
            model.send(.text(identifier))
            if !password.isEmpty { model.send(.key("Tab")) }
        }
        if !password.isEmpty { model.send(.text(password)) }
        if submit { model.send(.key("Enter")) }
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, enabled: Bool, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(active ? Color.white : enabled ? Color.ink : Color.text3)
                .background(active ? Color.accent : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host() ?? url
    }
}

/// The frame, fitted to the space: taps, scrolling that keeps its momentum, and pinch to zoom the page itself.
private struct BrowserCanvas: View {
    let model: BrowserModel
    let onPageTap: () -> Void
    /// Drag mode: the toolbar's own switch, for a page the hold-to-grab shortcut is too fiddly for.
    var dragsPage = false
    @State private var pinch: CGFloat = 1
    @State private var lastDrag: CGSize = .zero
    @State private var lastTap: (time: Date, point: CGPoint)?
    @State private var coasting: Task<Void, Never>?
    @State private var touch = BrowserTouch()
    @State private var hold: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let fitted = fit(model.cssSize, in: proxy.size)
            ZStack {
                Color(white: 0.12)
                if let image = model.image {
                    page(image, size: fitted)
                        .scaleEffect(pinch)
                } else {
                    placeholder
                }
                if model.page.pageScale > 1.01 { resetZoom }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            #if os(iOS)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        pinch = 1
                        // The browser zooms the page for real, so the text comes back sharp instead of upscaled.
                        model.setZoom(model.page.pageScale * value.magnification)
                    })
            #endif
        }
    }

    @ViewBuilder
    private func page(_ image: CGImage, size: CGSize) -> some View {
        let picture = Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.medium)
            .frame(width: size.width, height: size.height)
        #if os(macOS)
        picture.overlay { MacBrowserInput(model: model, onPageTap: onPageTap) }
        #else
        picture
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                coasting?.cancel()
                // A finger that took hold of the page has already said what it meant; clicking on top would undo it.
                guard !touch.grabbed else { return }
                onPageTap()
                model.send(.click(x: value.location.x / size.width, y: value.location.y / size.height, clickCount: tapCount(at: value.location)))
            })
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in moved(value, in: size) }
                    .onEnded { value in ended(value, in: size) })
        #endif
    }

    #if os(iOS)
    private func moved(_ value: DragGesture.Value, in size: CGSize) {
        coasting?.cancel()
        if hold == nil {
            touch.began()
            Haptics.prepare()
            hold = Task { @MainActor in
                try? await Task.sleep(for: BrowserTouch.hold)
                guard !Task.isCancelled else { return }
                touch.held()
                // Without this the page looks the same whether the finger is about to scroll it or drag something on it.
                if touch.mode == .armed { Haptics.send() }
            }
        }
        let at = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
        switch touch.moved(translation: value.translation, grabbing: dragsPage) {
        case .nothing:
            break
        case .scroll:
            hold?.cancel()
            let step = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
            lastDrag = value.translation
            model.send(.wheel(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height, dx: -step.width / size.width, dy: -step.height / size.height))
        case .press:
            model.send(.mouse(action: "down", x: value.startLocation.x / size.width, y: value.startLocation.y / size.height))
            model.send(.mouse(action: "move", x: at.x, y: at.y))
        case .drag:
            model.send(.mouse(action: "move", x: at.x, y: at.y))
        case .release, .coast:
            break
        }
    }

    private func ended(_ value: DragGesture.Value, in size: CGSize) {
        hold?.cancel()
        hold = nil
        lastDrag = .zero
        switch touch.ended() {
        case .release:
            model.send(.mouse(action: "up", x: value.location.x / size.width, y: value.location.y / size.height))
        case .coast:
            coast(from: value, in: size)
        case .nothing, .scroll, .press, .drag:
            break
        }
    }
    #endif

    /// A second tap in the same spot is a double click, as the browser itself would report it: select a word, open an item.
    private func tapCount(at point: CGPoint) -> Int {
        let now = Date()
        if let last = lastTap, now.timeIntervalSince(last.time) < 0.35,
           abs(last.point.x - point.x) < 24, abs(last.point.y - point.y) < 24 {
            lastTap = nil
            return 2
        }
        lastTap = (time: now, point: point)
        return 1
    }

    /// A flick keeps running for a moment: without this the page stops dead the instant the finger leaves it.
    private func coast(from value: DragGesture.Value, in size: CGSize) {
        coasting?.cancel()
        guard size.width > 0, size.height > 0 else { return }
        var vx = value.velocity.width
        var vy = value.velocity.height
        guard max(abs(vx), abs(vy)) > 150 else { return }
        let x = value.location.x / size.width
        let y = value.location.y / size.height
        coasting = Task { @MainActor in
            let step = 1.0 / 30.0
            while !Task.isCancelled, max(abs(vx), abs(vy)) > 60 {
                try? await Task.sleep(for: .seconds(step))
                guard !Task.isCancelled else { return }
                model.send(.wheel(x: x, y: y, dx: -vx * step / size.width, dy: -vy * step / size.height))
                vx *= 0.86
                vy *= 0.86
            }
        }
    }

    private var resetZoom: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button("1×") { model.setZoom(1) }
                    .font(.caption.weight(.bold))
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
                    .padding(10)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case let .offline(message):
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                Text(message).font(.footnote).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            default:
                ProgressView().tint(.white)
                Text(model.phase == .starting ? "Starting the browser…" : "Connecting…").font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding()
    }

    private func fit(_ content: CGSize, in box: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / content.width, box.height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
}
