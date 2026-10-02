import Foundation
import CoreAudio
import CryptoKit

enum QuickCamMicrophoneModel: String, CaseIterable {
    case pro4000 = "08b2"
    case stx = "08d7"

    init?(modelUID: String) {
        guard let model = Self.allCases.first(where: {
            modelUID.uppercased().hasSuffix(":046D:\($0.rawValue.uppercased())")
        }) else { return nil }
        self = model
    }

    var name: String {
        switch self {
        case .pro4000: return "QuickCam Pro 4000 Microphone"
        case .stx: return "QuickCam Communicate STX Microphone"
        }
    }
}

struct QuickCamMicrophoneComposition {
    var subdeviceUIDs: [String]
    var fullSubdeviceUIDs: [String]
    var mainUID: String
    var isPrivate: Bool
    var hasTaps: Bool
}

struct QuickCamAudioSnapshot {
    var id: AudioObjectID
    var uid: String
    var modelUID: String
    var transport: UInt32
    var inputChannels: UInt32
    var outputChannels: UInt32
    var nominalRate: Double
    var isRunning: Bool
    var composition: QuickCamMicrophoneComposition? = nil

    var microphoneModel: QuickCamMicrophoneModel? {
        guard transport == kAudioDeviceTransportTypeUSB,
              inputChannels > 0, outputChannels == 0, !uid.isEmpty else { return nil }
        return QuickCamMicrophoneModel(modelUID: modelUID)
    }
}

struct QuickCamMicrophoneAddition {
    let source: QuickCamAudioSnapshot
    let uid: String
    let name: String
}

struct QuickCamMicrophonePlan {
    let additions: [QuickCamMicrophoneAddition]
    let connectedCount: Int
    let existingCount: Int
}

struct QuickCamMicrophoneError: LocalizedError {
    let message: String
    let status: OSStatus?
    var errorDescription: String? { message }
    func isMissingDevice(hasUID: Bool) -> Bool {
        status == kAudioHardwareBadObjectError || status == kAudioHardwareBadDeviceError ||
            (status == kAudioHardwareUnknownPropertyError && !hasUID)
    }

    init(_ message: String) {
        self.message = message
        status = nil
    }

    init(_ operation: String, status: OSStatus) {
        self.status = status
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> ((3 - $0) * 8)) }
        let code = bytes.allSatisfy { (32...126).contains($0) }
            ? " '\(String(bytes: bytes, encoding: .ascii)!)'" : ""
        message = "\(operation) failed (Core Audio \(status)\(code)). Reconnect the camera and try again."
    }
}

enum QuickCamMicrophones {
    static let uidPrefix = "org.quickcam-native.microphone.v1."

    static func aggregateUID(model: QuickCamMicrophoneModel, sourceUID: String) -> String {
        let hash = SHA256.hash(data: Data(sourceUID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(uidPrefix)\(model.rawValue).\(hash)"
    }

    static func ownedModel(of device: QuickCamAudioSnapshot,
                           among devices: [QuickCamAudioSnapshot]) -> QuickCamMicrophoneModel? {
        guard device.transport == kAudioDeviceTransportTypeAggregate,
              device.outputChannels == 0,
              let composition = device.composition,
              !composition.isPrivate, !composition.hasTaps,
              composition.subdeviceUIDs.count == 1,
              composition.fullSubdeviceUIDs == composition.subdeviceUIDs,
              let sourceUID = composition.subdeviceUIDs.first, !sourceUID.isEmpty,
              composition.mainUID == sourceUID,
              let model = QuickCamMicrophoneModel.allCases.first(where: {
                  device.uid == aggregateUID(model: $0, sourceUID: sourceUID)
              }) else { return nil }
        let sources = devices.filter { $0.uid == sourceUID }
        guard sources.count <= 1,
              sources.first.map({ $0.microphoneModel == model }) ?? true else { return nil }
        return model
    }

    static func plan(_ devices: [QuickCamAudioSnapshot]) throws -> QuickCamMicrophonePlan {
        let sources = devices.filter { $0.microphoneModel != nil }.sorted { $0.uid < $1.uid }
        guard Set(sources.map(\.uid)).count == sources.count else {
            throw QuickCamMicrophoneError("Core Audio reported duplicate microphone identifiers. Reconnect the cameras and try again.")
        }
        var additions: [QuickCamMicrophoneAddition] = []
        var existingCount = 0
        for source in sources {
            let model = source.microphoneModel!
            let uid = aggregateUID(model: model, sourceUID: source.uid)
            let matches = devices.filter { $0.uid == uid }
            if !matches.isEmpty {
                guard matches.count == 1, ownedModel(of: matches[0], among: devices) == model else {
                    throw QuickCamMicrophoneError("A microphone entry has a conflicting configuration. Check QuickCam entries in Audio MIDI Setup before trying again.")
                }
                existingCount += 1
                continue
            }
            var modelUIDs = Set(sources.filter { $0.microphoneModel == model }.map(\.uid))
            for device in devices where ownedModel(of: device, among: devices) == model {
                modelUIDs.formUnion(device.composition!.subdeviceUIDs)
            }
            let duplicate = modelUIDs.count > 1
            let suffix = duplicate ? " (\(uid.suffix(6)))" : ""
            additions.append(QuickCamMicrophoneAddition(source: source, uid: uid, name: model.name + suffix))
        }
        return QuickCamMicrophonePlan(additions: additions, connectedCount: sources.count,
                                     existingCount: existingCount)
    }

    static func status() throws -> String {
        let devices = try QuickCamCoreAudio.snapshot()
        let connected = devices.filter { $0.microphoneModel != nil }.count
        let named = devices.filter { ownedModel(of: $0, among: devices) != nil }.count
        return "\(connected) supported microphone(s) connected. \(named) named microphone input(s) installed."
    }

    static func setUp() throws -> String {
        let setup = try plan(QuickCamCoreAudio.snapshot())
        guard setup.connectedCount > 0 else {
            return "Connect a QuickCam Pro 4000 or Communicate STX to set up its microphone name."
        }
        var added = 0
        do {
            for addition in setup.additions {
                let current = try QuickCamCoreAudio.snapshot()
                guard let source = current.first(where: { $0.uid == addition.source.uid }),
                      source.microphoneModel == addition.source.microphoneModel else {
                    throw QuickCamMicrophoneError("A camera disconnected. Reconnect it and try again.")
                }
                guard !source.isRunning else {
                    throw QuickCamMicrophoneError("Stop using \(source.microphoneModel!.name) before setting up its microphone name.")
                }
                if let existing = current.first(where: { $0.uid == addition.uid }) {
                    guard ownedModel(of: existing, among: current) == source.microphoneModel else {
                        throw QuickCamMicrophoneError("A microphone entry has a conflicting configuration. Check QuickCam entries in Audio MIDI Setup.")
                    }
                    continue
                }
                try QuickCamCoreAudio.create(addition, source: source)
                added += 1
            }
        } catch {
            throw QuickCamMicrophoneError("\(added) microphone name(s) added. \(error.localizedDescription)")
        }
        return "\(added) microphone name(s) added. Select a QuickCam microphone in your app's audio settings."
    }

    static func remove() throws -> String {
        let devices = try QuickCamCoreAudio.snapshot()
        let owned = devices.filter { ownedModel(of: $0, among: devices) != nil }
        let defaultInput = try QuickCamCoreAudio.defaultInput()
        guard !owned.contains(where: { $0.isRunning || $0.id == defaultInput }) else {
            throw QuickCamMicrophoneError("Select a different microphone in System Settings and close apps using the QuickCam microphones before removing their names.")
        }
        var removed = 0
        var removedIDs: Set<AudioObjectID> = []
        do {
            for device in owned {
                let current = try QuickCamCoreAudio.snapshot(excluding: removedIDs)
                guard let same = current.first(where: { $0.id == device.id && $0.uid == device.uid }) else { continue }
                guard ownedModel(of: same, among: current) != nil,
                      !same.isRunning, same.id != (try QuickCamCoreAudio.defaultInput()) else {
                    throw QuickCamMicrophoneError("A microphone's configuration or usage changed. Close audio apps and try again.")
                }
                try QuickCamCoreAudio.destroy(same.id)
                removedIDs.insert(same.id)
                removed += 1
            }
        } catch {
            throw QuickCamMicrophoneError("\(removed) microphone name(s) removed. \(error.localizedDescription)")
        }
        return "\(removed) microphone name(s) removed. The original USB audio inputs remain available."
    }
}

private enum QuickCamCoreAudio {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ result: OSStatus, _ operation: String) throws {
        if result != noErr { throw QuickCamMicrophoneError(operation, status: result) }
    }

    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var property = address(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
        }
        try check(status, "Read microphone settings")
        return result
    }

    static func object<T: AnyObject>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        let result: Unmanaged<T>? = try value(id, selector, initial: Optional<Unmanaged<T>>.none)
        guard let result else { throw QuickCamMicrophoneError("Core Audio returned an empty microphone property.") }
        return result.takeRetainedValue()
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let result: CFString = try object(id, selector)
        return result as String
    }

    static func ids() throws -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size), "Find microphones")
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &result), "Find microphones")
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard AudioObjectHasProperty(id, &property) else { return 0 }
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read microphone channels")
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, data), "Read microphone channels")
        return UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + $1.mNumberChannels }
    }

    static func composition(_ id: AudioObjectID) throws -> QuickCamMicrophoneComposition? {
        let dictionary: CFDictionary = try object(id, kAudioAggregateDevicePropertyComposition)
        let fields = dictionary as NSDictionary
        let full: CFArray = try object(id, kAudioAggregateDevicePropertyFullSubDeviceList)
        guard let subdevices = fields[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
              let fullUIDs = full as? [String],
              let main = fields[kAudioAggregateDeviceMainSubDeviceKey] as? String else { return nil }
        let uids = subdevices.compactMap { $0[kAudioSubDeviceUIDKey] as? String }
        guard uids.count == subdevices.count else { return nil }
        let taps = fields[kAudioAggregateDeviceTapListKey]
        let privacy = fields[kAudioAggregateDeviceIsPrivateKey]
        guard privacy == nil || privacy is NSNumber else { return nil }
        return QuickCamMicrophoneComposition(subdeviceUIDs: uids, fullSubdeviceUIDs: fullUIDs, mainUID: main,
            isPrivate: (privacy as? NSNumber)?.boolValue ?? false,
            hasTaps: taps != nil && (taps as? [Any])?.isEmpty != true)
    }

    static func snapshot(excluding excludedIDs: Set<AudioObjectID> = []) throws -> [QuickCamAudioSnapshot] {
        try ids().filter { !excludedIDs.contains($0) }.compactMap { id in
            do {
                let transport = try value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
                guard transport == kAudioDeviceTransportTypeUSB || transport == kAudioDeviceTransportTypeAggregate else { return nil }
                return QuickCamAudioSnapshot(id: id,
                    uid: try string(id, kAudioDevicePropertyDeviceUID),
                    modelUID: (try? string(id, kAudioDevicePropertyModelUID)) ?? "",
                    transport: transport,
                    inputChannels: try channels(id, scope: kAudioObjectPropertyScopeInput),
                    outputChannels: try channels(id, scope: kAudioObjectPropertyScopeOutput),
                    nominalRate: (try? value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))) ?? 0,
                    isRunning: try value(id, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) != 0,
                    composition: transport == kAudioDeviceTransportTypeAggregate ? try composition(id) : nil)
            } catch let error as QuickCamMicrophoneError {
                var identity = address(kAudioDevicePropertyDeviceUID)
                if error.isMissingDevice(hasUID: AudioObjectHasProperty(id, &identity)) { return nil }
                throw error
            }
        }
    }

    static func defaultInput() throws -> AudioObjectID {
        try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                  initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func create(_ addition: QuickCamMicrophoneAddition, source: QuickCamAudioSnapshot) throws {
        guard source.nominalRate.isFinite, source.nominalRate > 0 else {
            throw QuickCamMicrophoneError("The microphone has no valid sample rate. Reconnect it and try again.")
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: addition.uid,
            kAudioAggregateDeviceNameKey: addition.name,
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: source.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: source.uid,
                kAudioSubDeviceInputChannelsKey: source.inputChannels,
                kAudioSubDeviceOutputChannelsKey: 0,
                kAudioSubDeviceDriftCompensationKey: 0
            ]]
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Add microphone name")
        do {
            let rate = try value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            if rate != source.nominalRate {
                var property = address(kAudioDevicePropertyNominalSampleRate)
                var desired = source.nominalRate
                try check(AudioObjectSetPropertyData(id, &property, 0, nil, UInt32(MemoryLayout<Double>.size), &desired), "Preserve microphone sample rate")
            }
        } catch {
            let cleanup = AudioHardwareDestroyAggregateDevice(id)
            if cleanup != noErr {
                throw QuickCamMicrophoneError("\(error.localizedDescription) Remove the incomplete QuickCam microphone entry in Audio MIDI Setup (cleanup error \(cleanup)).")
            }
            throw error
        }
    }

    static func destroy(_ id: AudioObjectID) throws {
        try check(AudioHardwareDestroyAggregateDevice(id), "Remove microphone name")
    }
}
