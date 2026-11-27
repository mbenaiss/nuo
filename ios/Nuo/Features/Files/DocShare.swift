import Foundation
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// A document handed to the share sheet as a file under its own name, so the receiving app sees `rapport.pdf`.
/// Downloaded only when the user shares: opening a document never pays for it.
enum DocShare {
    static func file(_ path: String, load: @Sendable (String) async throws -> Data) async throws -> URL {
        let data = try await load(path)
        // One folder per share: two documents with the same name in different folders never overwrite each other.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: file, options: .atomic)
        return file
    }
}

struct SharedDocFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// How long a public drop link lives: the choices drop's own page offers.
enum DropLifetime: Int, CaseIterable, Identifiable {
    case hour = 60
    case day = 1440
    case week = 10080
    case forever = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .hour: String(localized: "1 hour")
        case .day: String(localized: "24 hours")
        case .week: String(localized: "7 days")
        case .forever: String(localized: "No expiration")
        }
    }
}

#if os(iOS)
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
