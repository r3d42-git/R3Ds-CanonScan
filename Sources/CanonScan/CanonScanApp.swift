import SwiftUI

@main struct CanonScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    var body: some Scene {
        WindowGroup("R3Ds CanonScan") {
            DocumentView(settings: settings)
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            DocumentCommands()
            PreviewZoomCommands()
        }
        Settings {
            ScanSettingsView(store: settings)
                .frame(width: 420)
                .padding(24)
        }
    }
}

struct DocumentCommands: Commands {
    @FocusedObject var document: DocumentModel?
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neuer Scan") { document?.requestNew() }.keyboardShortcut("n")
                .disabled(document == nil || document?.busy == true)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Entfernen widerrufen") { document?.undoRemoval() }.keyboardShortcut("z")
                .disabled(document?.canUndo != true)
        }
        CommandMenu("Seite") {
            Button("Nach rechts drehen") { document?.rotate() }.keyboardShortcut("r")
                .disabled(document?.selectedPage == nil || document?.busy == true)
            Button("Nach vorne verschieben") { document?.moveSelected(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(document?.selectedIndex == nil || document?.selectedIndex == 0 || document?.busy == true)
            Button("Nach hinten verschieben") { document?.moveSelected(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(document?.selectedIndex == nil || document?.selectedIndex == (document?.pages.count ?? 0) - 1 || document?.busy == true)
            Divider()
            Button("Seite entfernen") { document?.removeSelected() }.keyboardShortcut(.delete, modifiers: [])
                .disabled(document?.selectedPage == nil || document?.busy == true)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
