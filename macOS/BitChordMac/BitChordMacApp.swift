import AppKit
import SwiftUI

@main
struct BitChordMacApp: App {
    @StateObject private var model: AppModel

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
            CommandGroup(after: .newItem) {
                Button("Add Music…") { model.importAudio() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Add Music Folder…") { model.addLocalFolder() }
                Divider()
                Button("Open YouTube Music Link…") { model.showOpenLink = true }
                    .keyboardShortcut("l", modifiers: [.command])
            }
            CommandGroup(after: .textEditing) {
                Button("Search Lilt") { model.section = .search }
                    .keyboardShortcut("f", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Button("Lilt Help") {
                    NSWorkspace.shared.open(URL(string: "https://music.youtube.com")!)
                }
            }
        }
    }
}
