import AppKit
import SwiftUI

@main
struct DualRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sensors: SensorManager
    @StateObject private var recorder: RecordingController

    init() {
        let sensors = SensorManager()
        let recorder = RecordingController(sensors: sensors)
        _sensors = StateObject(wrappedValue: sensors)
        _recorder = StateObject(wrappedValue: recorder)
        AppDelegate.recorder = recorder
    }

    var body: some Scene {
        Window("Dual Recorder", id: "main") {
            MainView()
                .environmentObject(sensors)
                .environmentObject(recorder)
        }
        .defaultSize(width: 600, height: 760)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(sensors)
                .environmentObject(recorder)
        } label: {
            MenuBarLabel(recorder: recorder, sensors: sensors)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var recorder: RecordingController?

    /// Closing the window keeps the app (and any recording) running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Never lose a ride by quitting: offer to stop and save first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = Self.recorder, recorder.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A ride is being recorded"
        alert.informativeText = "Stop the recording and save the FIT files before quitting?"
        alert.addButton(withTitle: "Stop, Save & Quit")
        alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        recorder.stop()
        return .terminateNow
    }
}
