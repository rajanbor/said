import AVFoundation
import CoreAudio
import os

/// Records audio that apps play (other people's voices in a call) using a
/// Core Audio process tap (macOS 14.2+). It needs only the "System Audio Recording"
/// permission, not screen recording, and never sends anything anywhere.
///
/// Scope: either specific processes (e.g. just Zoom) or everything the Mac plays.
@available(macOS 14.2, *)
final class SystemAudioTap {
    enum Scope {
        case processes([AudioObjectID])
        case everything
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "said.system-audio", qos: .userInitiated)
    private let levelLock = OSAllocatedUnfairLock(initialState: Float(0))

    /// Latest RMS level of the tapped audio, 0...1.
    var level: Float { levelLock.withLock { $0 } }

    /// Starts writing tapped audio to `url` (CAF, float PCM).
    func start(scope: Scope, writingTo url: URL) throws {
        let description: CATapDescription
        switch scope {
        case .processes(let ids): description = CATapDescription(stereoMixdownOfProcesses: ids)
        case .everything: description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.uuid = UUID()
        description.name = "Said"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "utworzyć tapu audio")

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Said system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "utworzyć urządzenia audio")

        var asbd = try Self.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw Self.error("Nieobsługiwany format dźwięku systemowego.")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.file = file

        let levelLock = self.levelLock
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            // The aggregate's input = the output device's own input streams (if it has any,
            // e.g. BlackHole) followed by the tap. The tap is the last buffer.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let tapBuffer = buffers.last else { return }
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: tapBuffer)
            withUnsafePointer(to: &single) { list in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil)
                else { return }
                try? file.write(from: buffer)
                let rms = Self.rms(buffer)
                levelLock.withLock { $0 = rms }
            }
        }, "uruchomić odczytu dźwięku")
        try check(AudioDeviceStart(aggregateID, procID), "uruchomić nagrywania dźwięku systemowego")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync { file = nil }   // flush & close after the last callback
    }

    deinit { stop() }

    // MARK: - Helpers

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { let v = data[0][i]; sum += v * v }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { throw error("Brak domyślnego wyjścia audio.") }

        addr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
        guard status == noErr, let uid else { throw error("Nie można odczytać wyjścia audio.") }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr
        else { throw error("Nie można odczytać formatu dźwięku systemowego.") }
        return asbd
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw Self.error("Nie udało się \(what) (kod \(status)).") }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Said.SystemAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
