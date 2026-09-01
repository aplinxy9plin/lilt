import AppKit
import SwiftUI

@main
struct BitChordMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    private let updateChecker = UpdateChecker()

    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Lilt") {
            BitChordRootView(model: model, player: model.player)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.player.savePlaybackState()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.player.savePlaybackState()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateChecker.checkForUpdates()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Music…") { model.importAudio() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Add Music Folder…") { model.addLocalFolder() }
                Divider()
                Button("Open YouTube Music Link…") { model.showOpenLink = true }
                    .keyboardShortcut("l", modifiers: [.command])
            }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .pasteboard) { }
            CommandGroup(replacing: .textEditing) { }
            CommandGroup(replacing: .textFormatting) { }
            CommandGroup(replacing: .help) {
                Button("Lilt on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/aplinxy9plin/lilt")!)
                }
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.removeUnusedMenuItems()
        }
    }

    private static func removeUnusedMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let formatItem = mainMenu.items.first(where: { $0.title == "Format" }) {
            mainMenu.removeItem(formatItem)
        }
    }
}
