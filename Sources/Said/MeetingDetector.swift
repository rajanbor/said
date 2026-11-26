import CoreAudio
import Foundation

/// Notices when a meeting app starts using the microphone (Zoom, Teams, Meet in a browser…).
///
/// Uses Core Audio's per-process info (macOS 14+): which processes are currently
/// capturing audio input, and their bundle IDs. No extra permission, no network,
/// no window titles — just "is a known meeting app recording from a mic right now".
///
/// Nothing is polled: Core Audio tells Said when a process starts or stops using the
/// microphone, so a Said that isn't recording does no work at all. A slow safety net
/// (once a minute, with a wide tolerance so macOS folds it into other wake-ups) covers
/// the rare case of a change that arrives without a notification.
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
    /// A change has to last this long to count, so quick mic tests and blips are ignored.
    private static let debounce: TimeInterval = 3
    private static let safetyNet: TimeInterval = 60

    private let queue = DispatchQueue(label: "said.meeting-detector")
    private struct Watcher {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    /// Core Audio listeners in place, so they can be removed again.
    private var watchers: [Watcher] = []
    private var settling: Task<Void, Never>?
    private var net: Timer?

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

    // MARK: - Watching

    private func start() {
        guard watchers.isEmpty, net == nil else { return }
        watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        watchProcesses()
        // Catches anything the notifications miss. The tolerance lets macOS run it together
        // with other timers instead of waking the Mac on its own.
        let timer = Timer(timeInterval: Self.safetyNet, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleSoon() }
        }
        timer.tolerance = Self.safetyNet / 2
        RunLoop.main.add(timer, forMode: .common)
        net = timer
        settleSoon()
    }

    private func stop() {
        settling?.cancel()
        settling = nil
        net?.invalidate()
        net = nil
        remove { _ in true }
        if let active { self.active = nil; onEnd?(active) }
    }

    /// Listens for `selector` on `object`, and remembers it so it can be removed again.
    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.changed(selector) }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        watchers.append(Watcher(object: object, address: address, block: block))
    }

    private func remove(where matches: (Watcher) -> Bool) {
        for watcher in watchers where matches(watcher) {
            var address = watcher.address
            AudioObjectRemovePropertyListenerBlock(watcher.object, &address, queue, watcher.block)
        }
        watchers.removeAll(where: matches)
    }

    /// One listener per process that uses audio, for "is it recording from a mic now".
    /// Processes come and go, so listeners follow the current list.
    private func watchProcesses() {
        let processes = Set(Self.processObjects())
        remove { $0.address.mSelector == kAudioProcessPropertyIsRunningInput && !processes.contains($0.object) }
        let listed = Set(watchers.map(\.object))
        for process in processes where !listed.contains(process) {
            watch(process, kAudioProcessPropertyIsRunningInput)
        }
    }

    private func changed(_ selector: AudioObjectPropertySelector) {
        // A new process started using audio: watch its microphone too.
        if selector == kAudioHardwarePropertyProcessObjectList { watchProcesses() }
        settleSoon()
    }

    /// Looks again once things have been quiet for `debounce` seconds.
    private func settleSoon() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounce))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        settling = nil
        let now = Self.meetingUsingMic()
        switch (active, now) {
        case (nil, .some(let meeting)):
            active = meeting
            onStart?(meeting)
        case (.some(let was), nil):
            active = nil
            onEnd?(was)
        case (.some(let was), .some(let meeting)) where was != meeting:
            active = meeting
            onEnd?(was)
            onStart?(meeting)
        default:
            break
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

    /// Core Audio process objects of every process whose bundle ID starts with `bundlePrefix`.
    static func processObjects(bundlePrefix: String) -> [AudioObjectID] {
        processObjects().filter { bundleID($0)?.hasPrefix(bundlePrefix) == true }
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
