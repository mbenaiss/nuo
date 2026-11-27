import Foundation
#if os(macOS)
import AppKit
#endif

/// Saves a file attached to a message, under its own name. The iPhone saves through the share sheet instead.
enum ArtifactSave {
    /// The name the file is downloaded and saved under: the gateway's name as is, accents and spaces included.
    static func fileName(_ name: String) -> String {
        let last = (name.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? String(localized: "file") : last
    }

    /// Resolved: in the sandbox, Downloads is a link from the app's container to the user's own folder.
    static var defaultFolder: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath()
    }

    /// Atomic: an existing file the save panel agreed to replace is never left half written.
    static func copy(_ file: URL, to destination: URL) throws {
        try Data(contentsOf: file).write(to: destination, options: .atomic)
    }

    #if os(macOS)
    /// Asks where to save the file, starting in Downloads; returns a message when the copy failed.
    @MainActor
    static func save(_ file: URL) async -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.directoryURL = defaultFolder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let destination = panel.url else { return nil }
        do {
            try copy(file, to: destination)
            return nil
        } catch {
            return String(localized: "Couldn't save: \(error.localizedDescription)")
        }
    }
    #endif
}
