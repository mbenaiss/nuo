import Foundation

/// Demo launch arguments (`-demo -demoScreen dashboard`) so the Mac screenshots need no clicks.
enum DemoDirector {
    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var screen: String? { argument("-demoScreen") }
    static var productSection: String? { argument("-demoProductSection") }
    static var editorFocus: String? { argument("-demoEditor") }
}
