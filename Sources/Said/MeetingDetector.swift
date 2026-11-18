import CoreAudio
import Foundation

/// Notices when a meeting app starts using the microphone (Zoom, Teams, Meet in a browser…).
///
/// Uses Core Audio's per-process info (macOS 14+): which processes are currently
/// capturing audio input, and their bundle IDs. No extra permission, no network,
/// no window titles — just "is a known meeting app recording from a mic right now".
@MainActor
final class MeetingDetector: ObservableObject {
    struct Meeting: Equatable {
        let bundleID: String
        let name: String
    }

    /// The meeting app currently using the mic (after a short debounce).
    @Published private(set) var active: Meeting?

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    var onStart: ((Meeting) -> Void)?
    var onEnd: ((Meeting) -> Void)?

    private static let enabledKey = "detectMeetings"
    private var timer: Timer?
    private var seenStreak = 0
    private var goneStreak = 0
    private var candidate: Meeting?

    /// Bundle ID prefix → name shown to the user. Helper processes share the prefix
    /// (e.g. com.google.Chrome.helper), which is where browsers capture the mic.
    private static let known: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webex", "Webex"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.google.Chrome", "Google Meet / Chrome"),
        ("company.thebrowser.Browser", "Google Meet / Arc"),
        ("com.microsoft.edgemac", "Google Meet / Edge"),
        ("com.brave.Browser", "Google Meet / Brave"),
        ("org.mozilla.firefox", "Google Meet / Firefox"),
        ("com.apple.WebKit.GPU", "Google Meet / Safari"),
    ]

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if isEnabled { start() }
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let active { self.active = nil; onEnd?(active) }
        seenStreak = 0; goneStreak = 0; candidate = nil
    }

    private func poll() {
        let now = Self.meetingUsingMic()
        if let now {
            goneStreak = 0
            seenStreak = (now == candidate) ? seenStreak + 1 : 1
            candidate = now
            // ~4 s of continuous use: ignore quick mic tests and blips.
            if active == nil, seenStreak >= 2 {
                active = now
                onStart?(now)
            }
        } else {
            seenStreak = 0
            candidate = nil
            if let active {
                goneStreak += 1
                // ~6 s without the mic: the call is over.
                if goneStreak >= 3 {
                    self.active = nil
                    goneStreak = 0
                    onEnd?(active)
                }
            }
        }
    }

    // MARK: - Core Audio

    private static func meetingUsingMic() -> Meeting? {
        for process in processObjects() where isRunningInput(process) {
            guard let id = bundleID(process) else { continue }
            if let match = known.first(where: { id.hasPrefix($0.prefix) }) {
                return Meeting(bundleID: match.prefix, name: match.name)
            }
        }
        return nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func bundleID(_ process: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
