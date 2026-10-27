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

    let format: AVAudioFormat

    init(bundleIDs: [String]) throws {
        let description: CATapDescription
        if bundleIDs.isEmpty {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        } else {
            description = CATapDescription(monoMixdownOfProcesses: [])
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        do {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "read kAudioTapPropertyFormat")
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CoreAudioError(what: "AVAudioFormat from tap format", status: kAudioHardwareUnsupportedOperationError)
            }
            self.format = format

            // The output device is the aggregate's clock source; without a sub-device the IOProc never runs.
            let outputUID = try Self.defaultSystemOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "transcribe-tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ],
                ],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")
        } catch {
            // Creating the aggregate device is the last step, so only the tap can exist here.
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
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
        let format = self.format
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            handler(buffer)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    /// Tears down in the order the objects depend on each other: IOProc, aggregate device, tap.
    func stop() {
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
