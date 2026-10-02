import AppKit
import AVFoundation
import CoreAudio
import CryptoKit

struct VerificationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let products = ["08b2", "08d7"]
let productNames = ["08b2": "QuickCam Pro 4000 Microphone", "08d7": "QuickCam Communicate STX Microphone"]
let aggregatePrefix = "org.quickcam-native.microphone.v1."

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw VerificationError("\(operation) failed (OSStatus \(status)).") }
}

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var property = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &value) { pointer in
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer), "Read audio property")
    }
    return value
}

func objectProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> AnyObject {
    var property = address(selector)
    var value: Unmanaged<CFTypeRef>?
    var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
    try withUnsafeMutablePointer(to: &value) { pointer in
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, pointer), "Read audio object property")
    }
    guard let value else { throw VerificationError("Audio object property is missing.") }
    return value.takeRetainedValue()
}

func identifiers(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var property = address(selector, scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read audio list size")
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    if !values.isEmpty {
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &values), "Read audio list")
    }
    return values
}

func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) throws -> Int {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read stream configuration size")
    guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory), "Read stream configuration")
    return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}

struct Device {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let model: String
    let transport: UInt32
    let inputs: Int
    let outputs: Int

    func hasSameIdentity(as other: Device) -> Bool {
        id == other.id && uid == other.uid && model == other.model && transport == other.transport
            && inputs == other.inputs && outputs == other.outputs
    }

    var physicalProduct: String? {
        guard transport == kAudioDeviceTransportTypeUSB, inputs > 0, outputs == 0 else { return nil }
        return products.first { model.uppercased().hasSuffix(":046D:" + $0.uppercased()) }
    }
}

func inventory() throws -> [Device] {
    try identifiers(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
        guard let uid = try objectProperty(id, kAudioDevicePropertyDeviceUID) as? String,
              let name = try objectProperty(id, kAudioObjectPropertyName) as? String else { return nil }
        let model = (try? objectProperty(id, kAudioDevicePropertyModelUID) as? String) ?? ""
        return Device(id: id, uid: uid, name: name, model: model,
                      transport: try scalar(id, kAudioDevicePropertyTransportType, UInt32(0)),
                      inputs: try channelCount(id, kAudioObjectPropertyScopeInput),
                      outputs: try channelCount(id, kAudioObjectPropertyScopeOutput))
    }
}

func aggregateUID(product: String, physicalUID: String) -> String {
    aggregatePrefix + product + "." + SHA256.hash(data: Data(physicalUID.utf8)).map { String(format: "%02x", $0) }.joined()
}

func aggregateSource(_ device: Device, product: String, physical: [Device]) throws -> Device? {
    guard device.transport == kAudioDeviceTransportTypeAggregate,
          device.uid.hasPrefix(aggregatePrefix + product + "."),
          device.inputs > 0, device.outputs == 0,
          let composition = try objectProperty(device.id, kAudioAggregateDevicePropertyComposition) as? [String: Any],
          (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue != true,
          (composition[kAudioAggregateDeviceTapListKey] as? [Any] ?? []).isEmpty,
          let subdevices = composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
          subdevices.count == 1,
          let physicalUID = subdevices[0][kAudioSubDeviceUIDKey] as? String,
          composition[kAudioAggregateDeviceMainSubDeviceKey] as? String == physicalUID,
          let fullList = try objectProperty(device.id, kAudioAggregateDevicePropertyFullSubDeviceList) as? [String],
          fullList == [physicalUID],
          let source = physical.first(where: { $0.uid == physicalUID && $0.physicalProduct == product }),
          device.uid == aggregateUID(product: product, physicalUID: physicalUID) else { return nil }
    return source
}

struct Selection {
    let product: String
    let device: Device
    let source: Device

    func hasSameIdentity(as other: Selection) -> Bool {
        product == other.product && device.hasSameIdentity(as: other.device) && source.hasSameIdentity(as: other.source)
    }
}

func selectedDevices(_ requested: [String], physicalOnly: Bool) throws -> [Selection] {
    let devices = try inventory()
    return try requested.map { product in
        let physical = devices.filter { $0.physicalProduct == product }
        guard !physical.isEmpty else { throw VerificationError("\(productNames[product]!) is not connected as a USB audio input.") }
        if !physicalOnly {
            let named = try devices.compactMap { device -> Selection? in
                guard let source = try aggregateSource(device, product: product, physical: physical) else { return nil }
                return Selection(product: product, device: device, source: source)
            }
            guard named.count == 1 else {
                throw VerificationError("Expected one named \(productNames[product]!), found \(named.count). Enable QuickCam microphone names first, or use --physical.")
            }
            return named[0]
        }
        guard physical.count == 1 else { throw VerificationError("Multiple physical \(productNames[product]!) devices found; selection is ambiguous.") }
        return Selection(product: product, device: physical[0], source: physical[0])
    }
}

func revalidate(_ expected: Selection) throws {
    let refreshed = try selectedDevices([expected.product], physicalOnly: expected.device.transport == kAudioDeviceTransportTypeUSB)
    guard refreshed.count == 1, expected.hasSameIdentity(as: refreshed[0]) else {
        throw VerificationError("Selected microphone identity changed. Retry verification with the current devices.")
    }
}

struct Levels {
    var callbacks = 0
    var frames = 0
    var samples = 0
    var nonzero = 0
    var sumSquares = 0.0
    var peak = 0.0
    var error: String?

    mutating func consume(_ buffer: AudioBuffer, format: AudioStreamBasicDescription) {
        guard error == nil else { return }
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = Int(format.mBitsPerChannel / 8)
        let channels = planar ? 1 : Int(buffer.mNumberChannels)
        guard format.mFormatID == kAudioFormatLinearPCM,
              (float && (bytes == 4 || bytes == 8)) || (signed && [1, 2, 3, 4].contains(bytes)),
              format.mBitsPerChannel == bytes * 8,
              format.mBytesPerFrame == bytes * channels,
              channels > 0, let data = buffer.mData else {
            error = "Unsupported or missing PCM stream data."
            return
        }
        let sampleCount = Int(buffer.mDataByteSize) / bytes
        for index in 0..<sampleCount {
            let sampleData = data.advanced(by: index * bytes).assumingMemoryBound(to: UInt8.self)
            var bits: UInt64 = 0
            for byte in 0..<bytes {
                bits |= UInt64(sampleData[byte]) << ((bigEndian ? bytes - 1 - byte : byte) * 8)
            }
            let value: Double
            if float {
                value = bytes == 4 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits)
            } else {
                let shift = 64 - bytes * 8
                value = Double(Int64(bitPattern: bits << shift) >> shift) / pow(2, Double(bytes * 8 - 1))
            }
            guard value.isFinite else { error = "Non-finite audio sample received."; return }
            samples += 1
            if value != 0 { nonzero += 1 }
            peak = max(peak, abs(value))
            sumSquares += value * value
        }
        frames += sampleCount / channels
    }
}

func microphoneAccess() throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return
    case .denied, .restricted:
        throw VerificationError("Allow QuickCam Audio Verification in System Settings > Privacy & Security > Microphone, then retry.")
    case .notDetermined:
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        var result: Bool?
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { result = granted }
        }
        let deadline = Date(timeIntervalSinceNow: 180)
        while result == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard result == true else { throw VerificationError("Microphone permission was not granted. No input was opened.") }
    @unknown default:
        throw VerificationError("Unknown microphone permission state. No input was opened.")
    }
}

func verify(_ selection: Selection) throws {
    try revalidate(selection)
    let device = selection.device
    let product = selection.product
    guard try scalar(device.id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) != 0 else {
        throw VerificationError("\(productNames[product]!) disconnected before verification.")
    }
    let rateBefore = try scalar(device.id, kAudioDevicePropertyNominalSampleRate, Float64(0))
    let streamIDs = try identifiers(device.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    let formats = try streamIDs.map { try scalar($0, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) }
    guard !formats.isEmpty else { throw VerificationError("No input streams for \(productNames[product]!).") }
    let queue = DispatchQueue(label: "org.quickcam-native.audio-verification", qos: .userInitiated)
    var levels = Levels()
    var procedure: AudioDeviceIOProcID?
    try revalidate(selection)
    try check(AudioDeviceCreateIOProcIDWithBlock(&procedure, device.id, queue) { _, input, _, _, _ in
        levels.callbacks += 1
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count == formats.count else { levels.error = "Input buffer and stream counts differ."; return }
        for (index, buffer) in buffers.enumerated() {
            levels.consume(buffer, format: formats[index])
        }
    }, "Create selected microphone input callback")
    guard let procedure else { throw VerificationError("Audio callback was not created.") }
    defer { AudioDeviceDestroyIOProcID(device.id, procedure) }
    print("Testing \(productNames[product]!) via \(device.transport == kAudioDeviceTransportTypeAggregate ? "named microphone" : "physical USB input") for 2 seconds…")
    fflush(stdout)
    try revalidate(selection)
    try check(AudioDeviceStart(device.id, procedure), "Start selected microphone")
    Thread.sleep(forTimeInterval: 2)
    let stopStatus = AudioDeviceStop(device.id, procedure)
    queue.sync {}
    try check(stopStatus, "Stop selected microphone")
    let result = levels
    if let error = result.error { throw VerificationError(error) }
    guard result.callbacks > 0, result.frames > 0 else { throw VerificationError("No audio buffers arrived for \(productNames[product]!).") }
    let rateAfter = try scalar(device.id, kAudioDevicePropertyNominalSampleRate, Float64(0))
    guard rateAfter == rateBefore else { throw VerificationError("Microphone sample rate changed during verification (\(rateBefore) to \(rateAfter)).") }
    let rms = sqrt(result.sumSquares / Double(max(1, result.samples)))
    print(String(format: "%@: %d frames, %d callbacks, %d nonzero samples, peak %.6f, RMS %.6f, %.0f Hz%@", productNames[product]!, result.frames, result.callbacks, result.nonzero, result.peak, rms, rateAfter, result.nonzero == 0 ? " (silent buffers)" : ""))
}

func selfTests() throws {
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError("Self-test failed: " + message) }
    }
    let samples: [Float] = [0, -0.5, 1, 0.25]
    var levels = Levels()
    var format = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
        mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    samples.withUnsafeBytes { memory in
        levels.consume(AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(memory.count), mData: UnsafeMutableRawPointer(mutating: memory.baseAddress)), format: format)
    }
    try require(levels.error == nil && levels.frames == 4 && levels.nonzero == 3 && levels.peak == 1 && levels.sumSquares == 1.3125, "float PCM statistics")
    let signedSamples: [UInt8] = [0x00, 0x80, 0xff, 0x7f, 0, 0]
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    format.mBytesPerPacket = 2; format.mBytesPerFrame = 2; format.mBitsPerChannel = 16
    var signedLevels = Levels()
    signedSamples.withUnsafeBytes { memory in
        signedLevels.consume(AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(memory.count), mData: UnsafeMutableRawPointer(mutating: memory.baseAddress)), format: format)
    }
    try require(signedLevels.error == nil && signedLevels.frames == 3 && signedLevels.nonzero == 2 && signedLevels.peak == 1, "signed PCM statistics")
    let physical = Device(id: 1, uid: "test", name: "Unknown USB Audio Device", model: "Unknown USB Audio Device:046D:08B2", transport: kAudioDeviceTransportTypeUSB, inputs: 1, outputs: 0)
    let c270 = Device(id: 2, uid: "other", name: "Unknown USB Audio Device", model: "Unknown USB Audio Device:046D:0825", transport: kAudioDeviceTransportTypeUSB, inputs: 1, outputs: 0)
    try require(physical.physicalProduct == "08b2" && c270.physicalProduct == nil, "physical model allowlist")
    try require(aggregateUID(product: "08b2", physicalUID: "test") == aggregatePrefix + "08b2.9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", "aggregate identity")
    let selection = Selection(product: "08b2", device: physical, source: physical)
    let reusedID = Device(id: physical.id, uid: c270.uid, name: physical.name, model: c270.model,
                          transport: physical.transport, inputs: 1, outputs: 0)
    let reconnected = Device(id: 42, uid: physical.uid, name: physical.name, model: physical.model,
                             transport: physical.transport, inputs: 1, outputs: 0)
    let renamed = Device(id: physical.id, uid: physical.uid, name: "Microphone (second copy)", model: physical.model,
                         transport: physical.transport, inputs: 1, outputs: 0)
    try require(!selection.hasSameIdentity(as: Selection(product: "08b2", device: reusedID, source: reusedID)), "reused audio object ID rejected")
    try require(!selection.hasSameIdentity(as: Selection(product: "08b2", device: reconnected, source: reconnected)), "reconnected device ID rejected")
    try require(!selection.hasSameIdentity(as: Selection(product: "08b2", device: physical, source: c270)), "changed aggregate source rejected")
    try require(selection.hasSameIdentity(as: Selection(product: "08b2", device: renamed, source: renamed)), "display name does not determine identity")
    print("Audio identity and PCM statistics tests passed. No microphone was opened.")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] {
        try selfTests()
    } else {
        let productArguments = arguments.filter { products.contains($0) }
        guard productArguments.count <= 1, arguments.filter({ $0 == "--physical" }).count <= 1,
              arguments.allSatisfy({ $0 == "--physical" || products.contains($0) }) else {
            throw VerificationError("Usage: QuickCam Audio Verification [--physical] [08b2|08d7] | --self-test")
        }
        let targets = try selectedDevices(productArguments.isEmpty ? products : productArguments, physicalOnly: arguments.contains("--physical"))
        try microphoneAccess()
        for target in targets { try revalidate(target) }
        for target in targets { try verify(target) }
        print("Verification complete. No audio was saved and no default input was changed.")
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
