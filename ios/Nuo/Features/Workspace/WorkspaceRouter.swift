import Foundation
import Observation
import SwiftUI

enum AppTab: Hashable {
    case bots, calendar, files, reminders
}

/// Screens of the Fichiers tab: collections, rows, dashboards and docs.
enum FilesRoute: Hashable {
    case collection(String)
    case row(collection: String, id: String)
    case dashboards
    case dashboard(String)
    case folder(String)
    case doc(String)
}

/// Selected tab and the navigation of the Fichiers and Rappels tabs (the Bots tab keeps `AppRouter`).
@MainActor
@Observable
final class WorkspaceRouter {
    static let shared = WorkspaceRouter()

    var tab: AppTab = .bots
    var filesPath: [FilesRoute] = []
    /// Reminder whose detail sheet should open (notification tap, `nuo://reminders/<id>`).
    var focusedReminder: String?
    /// Agenda item whose detail should open (`nuo://calendar/<id>`, widgets).
    var focusedAgendaItem: String?
    /// « Rendez-vous » should open (booking notification, `nuo://booking`).
    var showsBookings = false
    /// The shared browser should open (`nuo://browser`, « Connexion requise » notification).
    var showsBrowser = false
    /// The Muscu screen should open (`nuo://muscu`, the Coach's chat, the end of a rest).
    var showsMuscu = false
    /// The Mac's Réunions screen should open (meeting prompt without a calendar event).
    var showsMeetings = false

    /// Handles `nuo://data/<collection>[/<rowId>]`, `nuo://dashboard/<slug>`, `nuo://docs/<path>`,
    /// `nuo://reminders[/<id>]`, `nuo://calendar[/<itemId>]`, `nuo://booking`, `nuo://browser` and `nuo://muscu`; other links
    /// are left to `AppRouter`.
    @discardableResult
    func open(url: URL) -> Bool {
        guard url.scheme == "nuo", let host = url.host() else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "data":
            var path: [FilesRoute] = []
            if let collection = parts.first {
                path.append(.collection(collection))
                if parts.count > 1 { path.append(.row(collection: collection, id: parts[1])) }
            }
            showFiles(path)
        case "dashboard":
            showFiles(parts.first.map { [.dashboard($0)] } ?? [])
        case "docs":
            let path = parts.joined(separator: "/")
            // A path with an extension is a file (`.md`, `.html`…); anything else a folder.
            let isFile = !(path as NSString).pathExtension.isEmpty
            showFiles(path.isEmpty ? [] : [isFile ? .doc(path) : .folder(path)])
        case "reminders":
            tab = .reminders
            // `project/<id>` and `area/<id>` ride along; RemindersView tells them from a reminder id.
            focusedReminder = parts.isEmpty ? nil : parts.joined(separator: "/")
        case "calendar":
            tab = .calendar
            focusedAgendaItem = parts.first
        case "booking":
            openBookings()
        case "browser":
            showsBrowser = true
        case "muscu":
            showsMuscu = true
        default:
            return false
        }
        return true
    }

    func showFiles(_ path: [FilesRoute]) {
        tab = .files
        filesPath = path
    }

    func openReminder(id: String) {
        tab = .reminders
        focusedReminder = id
    }

    func openAgendaItem(id: String) {
        tab = .calendar
        focusedAgendaItem = id
    }

    func openBookings() {
        tab = .calendar
        showsBookings = true
    }

    /// `-demoTab calendar|files|reminders` and `-demoRoute data/factures` open a screen at launch for screenshots.
    func applyDemo() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo") else { return }
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        switch value("-demoTab") {
        case "calendar": tab = .calendar
        case "files": tab = .files
        case "reminders": tab = .reminders
        default: break
        }
        if let route = value("-demoRoute"), let url = URL(string: "nuo://\(route)") {
            open(url: url)
        }
    }
}
