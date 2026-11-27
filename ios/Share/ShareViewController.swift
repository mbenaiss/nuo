import ObjectiveC
import SwiftUI
import UIKit

/// Entry point of the share extension: hosts the SwiftUI sheet and completes the extension request.
final class ShareViewController: UIViewController {
    private var model: ShareModel?
    private let workDirectory = FileManager.default.temporaryDirectory
        .appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)

    override func viewDidLoad() {
        super.viewDidLoad()
        let inputs = ShareInput.collect(from: extensionContext?.inputItems ?? [])
        let model = ShareModel(inputs: inputs, gateway: ShareGateway.current(), workDirectory: workDirectory)
        model.onFinish = { [weak self] in self?.finish() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onOpenURL = { [weak self] url in self?.openInHostApp(url) }
        self.model = model

        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.start()
    }

    private func finish() {
        cleanUp()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        cleanUp()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// `UIApplication.open` is unavailable to extensions at compile time, but the instance is in the responder
    /// chain; `NSExtensionContext.open` only works for widgets.
    private func openInHostApp(_ url: URL) {
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, let method = class_getInstanceMethod(type(of: current), selector) {
                let open = unsafeBitCast(method_getImplementation(method), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
        extensionContext?.open(url, completionHandler: nil)
    }
}
