/*********************************************************************************
WiiBalanceScale for macOS

MIT License

Copyright (c) 2017-2023 Bernhard Schelling
Copyright (c) 2023 Carl Ansell
**********************************************************************************/

import AppKit
import SwiftUI
import WiiBalanceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct WiiBalanceScaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var journal = JournalModel()
    @StateObject private var scale = ScaleModel()

    var body: some Scene {
        WindowGroup("Wii Balance Scale") {
            ContentView()
                .environmentObject(journal)
                .environmentObject(scale)
                .frame(minWidth: 820, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(journal)
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case scale
    case progress
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .scale: return "Scale"
        case .progress: return "Progress"
        case .history: return "History"
        }
    }

    var systemImage: String {
        switch self {
        case .scale: return "scalemass"
        case .progress: return "chart.xyaxis.line"
        case .history: return "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var journal: JournalModel
    @EnvironmentObject private var scale: ScaleModel
    @AppStorage(Preferences.autoSave) private var autoSave = true
    @State private var selection: AppSection? = .scale

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch selection ?? .scale {
            case .scale:
                ScaleView()
            case .progress:
                ProgressDashboardView()
            case .history:
                HistoryView()
            }
        }
        .onAppear { scale.start() }
        // Handled here rather than in ScaleView so weigh-ins are saved whichever section is shown.
        .onChange(of: scale.stableReading) { reading in
            guard autoSave, let reading, !scale.recordedThisStepOn else { return }
            journal.addWeighIn(kilograms: reading.kilograms, source: .balanceBoard)
            scale.markSaved()
        }
        .alert("Weight Journal", isPresented: Binding(
            get: { journal.errorMessage != nil },
            set: { if !$0 { journal.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(journal.errorMessage ?? "")
        }
    }
}
