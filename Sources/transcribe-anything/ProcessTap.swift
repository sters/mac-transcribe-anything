import AVFAudio
import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError(what: what, status: status) }
}

/// Captures the audio other processes play, through a Core Audio process tap wrapped in a private
/// aggregate device. An empty `bundleIDs` taps every process.
final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "ProcessTap.io", qos: .userInteractive)
    private var tapFormat = AudioStreamBasicDescription()
    /// Only touched on `queue`.
    private var format: AVAudioFormat?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    init(bundleIDs: [String]) throws {
        let description: CATapDescription
        if bundleIDs.isEmpty {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        } else {
            description = CATapDescription(monoMixdownOfProcesses: [])
            description.bundleIDs = Self.withHelpers(bundleIDs)
            description.isProcessRestoreEnabled = true
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        do {
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapFormat), "read kAudioTapPropertyFormat")

            // The output device is the aggregate's clock source; without a sub-device the IOProc never runs.
            let outputUID = try Self.defaultSystemOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "transcribe-anything-tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")
        } catch {
            // Creating the aggregate device is the last step, so only the tap can exist here.
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    /// Chromium and Electron apps play audio from a helper process (e.g. `com.google.Chrome.helper`),
    /// not the main one, and a tap matches bundle IDs exactly. `<id>.helper` is added even when it is
    /// not running yet so process restore picks it up later; other running `<id>.*` processes are
    /// added as well.
    private static func withHelpers(_ bundleIDs: [String]) -> [String] {
        let running = runningProcessBundleIDs()
        var result: [String] = []
        for id in bundleIDs {
            let candidates = [id, "\(id).helper"] + running.filter { $0.hasPrefix("\(id).") }.sorted()
            for candidate in candidates where !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    private static func runningProcessBundleIDs() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        address.mSelector = kAudioProcessPropertyBundleID
        var result = Set<String>()
        for process in processes {
            var bundleID: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundleID) == noErr, let bundleID else { continue }
            result.insert(bundleID.takeRetainedValue() as String)
        }
        return result
    }

    private static func defaultSystemOutputUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID), "read default system output device")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "read output device UID")
        guard let uid else { throw CoreAudioError(what: "read output device UID", status: kAudioHardwareBadDeviceError) }
        return uid.takeRetainedValue() as String
    }

    /// `handler` runs on the I/O queue with a buffer that is only valid for the duration of the call.
    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        var address = Self.nominalSampleRateAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.updateFormat() }
        try check(AudioObjectAddPropertyListenerBlock(aggregateID, &address, queue, listener), "listen for sample rate changes")
        sampleRateListener = listener
        queue.sync { updateFormat() }

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, input, _, _, _ in
                guard let format = self?.format,
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                else { return }
                handler(buffer)
            }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    private static var nominalSampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The tap reports the output device's preferred rate, but the aggregate device runs at its
    /// clock device's current rate, which differs e.g. when a Bluetooth headset switches to the
    /// 16 kHz hands-free profile because a call app opened its microphone. Labelling buffers with
    /// the tap's rate would make them sound sped up or slowed down, so the aggregate's rate is used
    /// and followed as it changes.
    private func updateFormat() {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = Self.nominalSampleRateAddress
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return }
        var description = tapFormat
        description.mSampleRate = rate
        format = AVAudioFormat(streamDescription: &description)
    }

    /// Tears down in the order the objects depend on each other: IOProc, aggregate device, tap.
    func stop() {
        if let sampleRateListener {
            var address = Self.nominalSampleRateAddress
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address, queue, sampleRateListener)
            self.sampleRateListener = nil
        }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
