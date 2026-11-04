import AVFoundation
import CoreAudio

struct CoreAudioError: LocalizedError {
    let step: String
    let status: OSStatus

    var errorDescription: String? {
        "System audio capture failed at \(step) (OSStatus \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
    }
}

/// Captures everything the Mac plays (minus excluded apps) via a Core Audio process tap
/// read through a private aggregate device. Delivers copied buffers on a private queue.
final class SystemAudioTap {
    static let defaultExcludedBundleIDs = ["com.spotify.client", "com.apple.Music"]

    private let excludedBundleIDs: [String]
    private let queue = DispatchQueue(label: "app.meetingscribe.systemtap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var format: AVAudioFormat?

    private var meter = LevelMeter(name: "System audio")

    init(excludedBundleIDs: [String] = SystemAudioTap.defaultExcludedBundleIDs) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    deinit { stop() }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        do {
            try createTap()
            try createAggregateDevice()
            try startIO(onBuffer: onBuffer)
        } catch {
            stop()
            throw error
        }
    }

    /// Strict teardown order: stop → destroy IOProc → destroy aggregate → destroy tap.
    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            check(AudioDeviceStop(aggregateID, ioProcID), "AudioDeviceStop")
            check(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "AudioDeviceDestroyIOProcID")
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            check(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            check(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = AudioObjectID(kAudioObjectUnknown)
            Log.audio.info("System audio tap stopped after \(self.meter.bufferCount) buffers")
        }
    }

    // MARK: - Setup steps

    private func createTap() throws {
        let excluded = excludedProcessObjects()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "MeetingScribe System Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try require(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        var asbd = AudioStreamBasicDescription()
        try require(CA.read(tapID, kAudioTapPropertyFormat, into: &asbd), "read kAudioTapPropertyFormat")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(step: "AVAudioFormat(streamDescription:)", status: kAudioHardwareUnsupportedOperationError)
        }
        self.format = format
        Log.audio.info("Tap created (excluding \(excluded.count) processes), format: \(format.description, privacy: .public)")
    }

    private func createAggregateDevice() throws {
        let outputUID = try defaultOutputDeviceUID()
        let tapUID = tapUUID.uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingScribe Aggregate",
            kAudioAggregateDeviceUIDKey: "app.meetingscribe.aggregate.\(tapUID)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        try require(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                    "AudioHardwareCreateAggregateDevice")

        // ~12 callbacks/s instead of ~90. Failure is harmless.
        var frames: UInt32 = 4096
        let status = CA.write(aggregateID, kAudioDevicePropertyBufferFrameSize, &frames)
        if status != noErr {
            Log.audio.notice("Could not set buffer frame size to 4096 (OSStatus \(status)); using device default")
        }
    }

    private func startIO(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let format else { return }
        meter = LevelMeter(name: "System audio")
        let meter = meter
        try require(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer.copying(input, format: format) else { return }
            meter.record(buffer)
            onBuffer(buffer)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try require(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        Log.audio.info("System audio tap started")
    }

    // MARK: - Lookups

    private func excludedProcessObjects() -> [AudioObjectID] {
        var result: [AudioObjectID] = []
        var pid = getpid()
        var own = AudioObjectID(kAudioObjectUnknown)
        let status = CA.read(CA.system, kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: &pid, into: &own)
        if status == noErr, own != kAudioObjectUnknown {
            result.append(own)
        } else {
            Log.audio.notice("Own process has no audio object yet (OSStatus \(status))")
        }

        for process in CA.readArray(CA.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
            guard let bundleID = CA.readString(process, kAudioProcessPropertyBundleID) else { continue }
            if excludedBundleIDs.contains(where: { bundleID.hasPrefix($0) }) {
                result.append(process)
                Log.audio.debug("Excluding \(bundleID, privacy: .public)")
            }
        }
        return result
    }

    private func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        try require(CA.read(CA.system, kAudioHardwarePropertyDefaultOutputDevice, into: &device),
                    "read kAudioHardwarePropertyDefaultOutputDevice")
        guard let uid = CA.readString(device, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(step: "read kAudioDevicePropertyDeviceUID", status: kAudioHardwareUnspecifiedError)
        }
        return uid
    }

    // MARK: - Status handling

    private func require(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            Log.audio.error("\(step, privacy: .public) failed: OSStatus \(status)")
            throw CoreAudioError(step: step, status: status)
        }
    }

    private func check(_ status: OSStatus, _ step: String) {
        if status != noErr { Log.audio.error("\(step, privacy: .public) failed: OSStatus \(status)") }
    }
}

/// Thin wrappers over AudioObject property access.
private enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> OSStatus {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    }

    static func read<Q: BitwiseCopyable, T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           qualifier: inout Q, into value: inout T) -> OSStatus {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, UInt32(MemoryLayout<Q>.size), &qualifier, &size, &value)
    }

    static func write<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var addr = address(selector)
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    static func readArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of _: T.Type) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}
