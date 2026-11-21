import AppKit
import SwiftUI

@main
struct ImportatorApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Importator", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenFixDatesButton()
            }
        }

        Window("Fix Missing Dates", id: "fixdates") {
            FixDatesView()
        }
        .defaultSize(width: 640, height: 520)
    }
}

struct OpenFixDatesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Fix Missing Dates…") { openWindow(id: "fixdates") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SourcePanel()
                    .frame(width: 240)
                Divider()
                GridPanel()
                    .frame(minWidth: 420, maxWidth: .infinity)
                Divider()
                DestinationPanel()
                    .frame(width: 290)
            }
            Divider()
            BottomBar()
        }
        .frame(minWidth: 1100, minHeight: 640)
        .sheet(isPresented: $model.showFailures) { FailuresView() }
    }
}
