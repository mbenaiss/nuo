import SwiftUI

// Shared feature views (sheets, forms, detail screens) carry iOS-only navigation and keyboard modifiers.
// These Mac stand-ins keep them compiling unchanged: macOS has no navigation bar, keyboard type or edit mode.

enum CompatTitleDisplayMode { case automatic, inline, large }
enum CompatAutocapitalization { case never, words, sentences, characters }
enum CompatKeyboardType { case `default`, numberPad, decimalPad, URL, emailAddress, asciiCapable, numbersAndPunctuation, phonePad, webSearch }
enum CompatDrawerDisplayMode { case automatic, always }
enum CompatListSectionSpacing { case `default`, compact }
enum CompatEditMode { case inactive, active, transient }

extension View {
    func navigationBarTitleDisplayMode(_ mode: CompatTitleDisplayMode) -> some View { self }
    func textInputAutocapitalization(_ value: CompatAutocapitalization?) -> some View { self }
    func keyboardType(_ type: CompatKeyboardType) -> some View { self }
    func listSectionSpacing(_ spacing: CompatListSectionSpacing) -> some View { self }
    func listSectionSpacing(_ spacing: CGFloat) -> some View { self }
}

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: CompatDrawerDisplayMode) -> SearchFieldPlacement { .automatic }
}

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}

extension EnvironmentValues {
    @Entry var editMode: Binding<CompatEditMode>?
}

extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var bottomBar: ToolbarItemPlacement { .status }
}

extension View {
    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    func fullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }
}
