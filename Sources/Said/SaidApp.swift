import SwiftUI

@main
struct SaidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(recorder)
                .environmentObject(recorder.transcriber)
        } label: {
            if recorder.isRecording {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill")
                    Text(recorder.elapsed.clock)
                        .monospacedDigit()
                }
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

extension TimeInterval {
    /// 00:42 / 1:02:03
    var clock: String {
        let s = Int(self.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Notifier.shared.setUp() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(Recorder.shared.handle) }
    }
}
