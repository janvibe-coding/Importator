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
            HSplitView {
                SourcePanel()
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 520)
                GridPanel()
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .layoutPriority(1)
                DestinationPanel()
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 520)
            }
            Divider()
            BottomBar()
        }
        .frame(minWidth: 1100, minHeight: 640)
        .sheet(isPresented: $model.showReport) { FailuresView() }
        .alert(model.ejectError ?? "", isPresented: Binding(get: { model.ejectError != nil },
                                                           set: { if !$0 { model.clearEjectError() } })) {
            Button("OK") { model.clearEjectError() }
        }
    }
}
