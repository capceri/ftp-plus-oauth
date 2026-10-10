import AppKit
import SwiftUI

@main
struct FITStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: FileStore

    init() {
        let store = FileStore()
        _store = StateObject(wrappedValue: store)
        AppDelegate.store = store
    }

    var body: some Scene {
        Window("FIT Studio", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { store.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Adjusted Copy…") { store.saveAdjustedCopyOfSelection() }
                    .keyboardShortcut("s")
                    .disabled(store.selectedFile == nil)
                Button("Export CSV…") { store.exportCSVOfSelection() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.selectedFile == nil)
                Divider()
                Button("Close File") { store.closeSelection() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(store.selectedFile == nil)
            }
            CommandGroup(after: .sidebar) {
                ForEach(FileTab.allCases) { tab in
                    Button(tab.title) { store.show(tab) }
                        .keyboardShortcut(tab.shortcut, modifiers: [.command])
                        .disabled(store.selectedFile == nil)
                }
                Divider()
                Button("Compare Files") { store.selection = .compare }
                    .keyboardShortcut("k")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: FileStore?

    /// Files opened from Finder ("Open With", double-click, or dropped on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.store?.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Adjustments only exist in memory until saved as a copy, so check before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = AppDelegate.store?.files.filter(\.hasUnsavedAdjustments) ?? []
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? "“\(unsaved[0].name)” has adjustments that haven’t been saved"
            : "\(unsaved.count) files have adjustments that haven’t been saved"
        alert.informativeText = "Your original files are never changed. Save an adjusted copy first if you want to keep the adjustments."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
