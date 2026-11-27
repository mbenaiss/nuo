#if DEBUG
import AppKit
import QuartzCore

/// `-demo -demoRows 10000 -demoBench scroll|switch` drives the collection table without clicks to profile it:
/// `scroll` scrolls the bank transactions down for 15 s (`-demoBenchSpeed`, 3000 pt/s by default, waiting at the end for
/// the next page), `switch` opens the three big collections in turn ten times and scrolls each down for a while.
/// Frame intervals, row views and the memory footprint go to stdout.
@MainActor
enum DemoBench {
    private static var started = false
    private static let collections = ["transactions", "factures", "virements"]

    static func scheduleIfRequested(navigator: MacNavigator) {
        guard !started, let mode = DemoDirector.argument("-demoBench") else { return }
        started = true
        Task { await run(mode, navigator: navigator) }
    }

    private static func run(_ mode: String, navigator: MacNavigator) async {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }), let screen = NSScreen.screens.first {
            window.setContentSize(NSSize(width: 1440, height: 860))
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        }
        if mode == "paste" {
            await DemoPasteBench.run(navigator: navigator)
            return
        }
        if mode == "chat" {
            await DemoChatTest.run(navigator: navigator)
            return
        }
        if mode == "screens" {
            await DemoPasteBench.screens(navigator: navigator)
            return
        }
        navigator.sidebar = .collections
        navigator.collection = collections[0]
        try? await Task.sleep(for: .seconds(5))
        log("ready \(tableReport())")
        let monitor = FrameMonitor()
        switch mode {
        case "switch":
            log("start switch")
            monitor.start()
            for index in 1...10 {
                let id = collections[index % collections.count]
                let started = CACurrentMediaTime()
                let before = table.map(ObjectIdentifier.init)
                navigator.collection = id
                while table.map(ObjectIdentifier.init) == before || (table?.numberOfRows ?? 0) == 0 {
                    try? await Task.sleep(for: .milliseconds(5))
                    if CACurrentMediaTime() - started > 10 { break }
                }
                let shown = CACurrentMediaTime() - started
                await monitor.scroll(seconds: 2.5, speed: 6_000)
                log(String(format: "switch %d %@ shown=%.0fms %@ footprint=%@", index, id, shown * 1_000, tableReport(), footprint()))
            }
            monitor.stop()
            log("switch frames \(monitor.summary())")
        default:
            log("start scroll")
            monitor.start()
            await monitor.scroll(seconds: 15, speed: Double(DemoDirector.argument("-demoBenchSpeed") ?? "") ?? 3_000)
            monitor.stop()
            log("scroll frames \(monitor.summary()) \(tableReport())")
        }
        try? await Task.sleep(for: .seconds(2))
        log("done footprint=\(footprint())")
    }

    /// The collection grid: the only table of the window with more than one column.
    static var table: NSTableView? {
        guard let root = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 })?.contentView else { return nil }
        var found: [NSTableView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let table = view as? NSTableView, table.numberOfColumns > 1, table.window != nil { found.append(table) }
            stack.append(contentsOf: view.subviews)
        }
        return found.max { $0.bounds.width < $1.bounds.width }
    }

    private static func tableReport() -> String {
        guard let table else { return "rows=- views=-" }
        let rowViews = table.subviews.filter { $0 is NSTableRowView }
        let visible = table.rows(in: table.visibleRect)
        var views = 0
        var stack: [NSView] = [table]
        while let view = stack.popLast() {
            views += 1
            stack.append(contentsOf: view.subviews)
        }
        return String(format: "rows=%d rowViews=%d visible=%d columns=%d views=%d rowHeight=%.1f", table.numberOfRows, rowViews.count,
                      visible.length, table.numberOfColumns, views, table.numberOfRows > 0 ? table.rect(ofRow: 0).height : 0)
    }

    static func footprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return String(format: "%.0fMB", Double(info.phys_footprint) / 1_048_576)
    }

    static func log(_ message: String) {
        print(String(format: "bench %.3f %@", CACurrentMediaTime(), message))
        fflush(stdout)
    }
}

/// Display-link frame intervals; a frame counts as a hitch past 1.5 refresh periods.
@MainActor
private final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var intervals: [Double] = []
    private var period = 1.0 / 60
    private var scrollSpeed = 0.0
    private var exact = 0.0

    func start() {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 })?.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func scroll(seconds: Double, speed: Double) async {
        exact = Double(DemoBench.table?.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
        scrollSpeed = speed
        try? await Task.sleep(for: .seconds(seconds))
        scrollSpeed = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        period = link.duration > 0 ? link.duration : period
        defer { last = link.timestamp }
        guard let last else { return }
        let interval = link.timestamp - last
        intervals.append(interval)
        guard scrollSpeed > 0, let scrollView = DemoBench.table?.enclosingScrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        exact = min(maxY, exact + scrollSpeed * min(interval, 0.1))
        // A real scroll lands on device pixels.
        let scale = scrollView.window?.backingScaleFactor ?? 2
        origin.y = (exact * scale).rounded() / scale
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func summary() -> String {
        guard !intervals.isEmpty else { return "none" }
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1_000 }
        let total = intervals.reduce(0, +)
        let hitches = intervals.filter { $0 > period * 1.5 }
        let dropped = intervals.reduce(0) { $0 + max(0, ($1 / period).rounded() - 1) }
        return String(format: "frames=%d fps=%.1f p50=%.1fms p95=%.1fms p99=%.1fms max=%.0fms hitches=%d hitchTime=%.0fms dropped=%.0f%% period=%.1fms",
                      intervals.count, Double(intervals.count) / total, percentile(0.5), percentile(0.95), percentile(0.99),
                      (sorted.last ?? 0) * 1_000, hitches.count, hitches.reduce(0) { $0 + $1 - period } * 1_000,
                      dropped / (dropped + Double(intervals.count)) * 100, period * 1_000)
    }
}
#endif
