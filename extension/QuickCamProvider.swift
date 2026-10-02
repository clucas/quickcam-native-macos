import CoreMediaIO
import Foundation
import IOKit.audio
import os

private let log = Logger(subsystem: "local.quickcam.CameraExtension", category: "capture")
private let width = 640
private let height = 480
private let framesPerSecond: Int32 = 5
private let frameDuration = CMTime(value: 1, timescale: framesPerSecond)
private let recoveryDelay: TimeInterval = 2

struct CameraIdentity: Hashable {
    let productID: UInt16
    let locationID: UInt32
    let registryID: UInt64

    init(_ info: qc_device_info) {
        productID = info.product_id
        locationID = info.location_id
        registryID = info.registry_id
    }
}

private func captureError(_ code: Int = 1, message: String? = nil) -> NSError {
    NSError(domain: "local.quickcam.Capture", code: code,
            userInfo: [NSLocalizedDescriptionKey: message ?? String(cString: qc_last_error())])
}

private func modelName(_ product: UInt16) -> String? {
    switch product {
    case 0x08b2: return "Logitech QuickCam Pro 4000"
    case 0x08d7: return "Logitech QuickCam Communicate STX"
    default: return nil
    }
}

private let receiveFrame: qc_frame_callback = { context, bytes, frameWidth, frameHeight, stride, hostTime in
    guard let context, let bytes else { return }
    Unmanaged<QuickCamDevice>.fromOpaque(context).takeUnretainedValue()
        .sendFrame(bytes, width: Int(frameWidth), height: Int(frameHeight), stride: stride, hostTime: hostTime)
}

final class QuickCamProvider: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private(set) var devices: [CameraIdentity: QuickCamDevice] = [:]
    private(set) var retiringDevices: [QuickCamDevice] = []
    private var detectionTimer: DispatchSourceTimer?

    init(startPolling: Bool = true) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: .main)
        guard startPolling else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.refreshDevices() }
        timer.resume()
        detectionTimer = timer
        refreshDevices()
    }

    func refreshDevices(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard qc_initialize() == 0 else {
            log.error("USB initialization failed: \(String(cString: qc_last_error()), privacy: .public)")
            pollCaptureSources(at: now)
            return
        }
        var info = [qc_device_info](repeating: qc_device_info(), count: 32)
        let count = info.withUnsafeMutableBufferPointer { qc_enumerate($0.baseAddress, $0.count) }
        if count == 0 && qc_last_error().pointee != 0 {
            log.error("USB discovery failed: \(String(cString: qc_last_error()), privacy: .public)")
            pollCaptureSources(at: now)
            return
        }
        let connected = info.prefix(min(count, info.count)).filter {
            $0.vendor_id == 0x046d && modelName($0.product_id) != nil
        }
        let identities = Set(connected.map(CameraIdentity.init))
        for (identity, source) in devices where !identities.contains(identity) || source.isRetired {
            source.retire()
            do {
                try provider.removeDevice(source.device)
                devices.removeValue(forKey: identity)
                retiringDevices.append(source)
            } catch {
                log.error("Cannot remove camera: \(error.localizedDescription, privacy: .public)")
            }
        }
        pollCaptureSources(at: now)
        let blockedLocations = Set(retiringDevices.map { $0.identity.locationID })
            .union(devices.values.filter(\.isRetired).map { $0.identity.locationID })
        for camera in connected where devices[CameraIdentity(camera)] == nil && !blockedLocations.contains(camera.location_id) {
            do {
                let source = try QuickCamDevice(info: camera)
                try provider.addDevice(source.device)
                devices[source.identity] = source
            } catch {
                log.error("Cannot publish camera: \(error.localizedDescription, privacy: .public)")
            }
        }
        for source in devices.values { source.prepareIdleDevice(at: now) }
    }

    private func pollCaptureSources(at now: TimeInterval) {
        for source in devices.values { source.pollCapture(at: now) }
        for source in retiringDevices { source.pollCapture(at: now) }
        retiringDevices.removeAll { $0.isQuiescent }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let values = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { values.manufacturer = "QuickCam Native" }
        return values
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
}

final class QuickCamDevice: NSObject, CMIOExtensionDeviceSource {
    private enum CaptureState {
        case idle
        case running(OpaquePointer)
        case stopping(OpaquePointer)
    }

    private(set) var device: CMIOExtensionDevice!
    let identity: CameraIdentity
    private(set) var demand = 0
    private(set) var isRetired = false
    private var streamSource: QuickCamStream!
    private let info: qc_device_info
    private let model: String
    private let formatDescription: CMVideoFormatDescription
    private let bufferPool: CVPixelBufferPool
    private let bufferLimits = [kCVPixelBufferPoolAllocationThresholdKey: 5] as CFDictionary
    private var captureState: CaptureState = .idle
    private var nextRecoveryTime: TimeInterval = 0
    private var idleDevicePrepared = false
    private var nextIdlePreparationTime: TimeInterval = 0

    init(info: qc_device_info) throws {
        self.info = info
        self.identity = CameraIdentity(info)
        self.model = modelName(info.product_id)!
        var description: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(width), height: Int32(height), extensions: nil,
            formatDescriptionOut: &description)
        guard formatStatus == noErr, let description else {
            throw captureError(Int(formatStatus), message: "Cannot create the camera format.")
        }
        self.formatDescription = description
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw captureError(Int(poolStatus), message: "Cannot create camera frame buffers.")
        }
        self.bufferPool = pool
        super.init()
        let suffix = String(format: "%04X%08X", info.product_id, info.location_id)
        let deviceID = UUID(uuidString: "0D39E1F7-8B41-4364-9F4D-\(suffix)")!
        device = CMIOExtensionDevice(localizedName: model, deviceID: deviceID,
                                     legacyDeviceID: nil, source: self)
        let format = CMIOExtensionStreamFormat(formatDescription: description,
            maxFrameDuration: frameDuration, minFrameDuration: frameDuration, validFrameDurations: nil)
        streamSource = QuickCamStream(device: self,
            streamID: UUID(uuidString: "0D39E1F7-8B41-4365-9F4D-\(suffix)")!, format: format)
        try device.addStream(streamSource.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let values = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { values.transportType = kIOAudioDeviceTransportTypeUSB }
        if properties.contains(.deviceModel) { values.model = model }
        return values
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStream(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard !isRetired else { throw captureError(4, message: "This camera is disconnected.") }
        checkRunningCapture(at: now)
        reapStoppedCapture()
        demand += 1
        if case .idle = captureState, now >= nextRecoveryTime {
            do {
                try startCapture()
            } catch {
                demand -= 1
                nextRecoveryTime = now + recoveryDelay
                throw error
            }
        }
    }

    private func startCapture() throws {
        guard let handle = qc_start(info.location_id, UInt32(width), UInt32(height),
            UInt32(framesPerSecond), receiveFrame, Unmanaged.passUnretained(self).toOpaque()) else {
            throw captureError()
        }
        captureState = .running(handle)
        idleDevicePrepared = true
        nextRecoveryTime = 0
    }

    func prepareIdleDevice(at now: TimeInterval) {
        guard identity.productID == 0x08b2, !isRetired, demand == 0,
              !idleDevicePrepared, now >= nextIdlePreparationTime,
              case .idle = captureState else { return }
        var camera = info
        if qc_prepare_idle_device(&camera) == 0 {
            idleDevicePrepared = true
        } else {
            nextIdlePreparationTime = now + recoveryDelay
            log.debug("Idle camera setup deferred: \(String(cString: qc_last_error()), privacy: .public)")
        }
    }

    func stopStream() {
        guard demand > 0 else { return }
        demand -= 1
        if demand == 0 { requestStop() }
    }

    func retire() {
        isRetired = true
        demand = 0
        requestStop()
    }

    var isQuiescent: Bool {
        if case .idle = captureState { return true }
        return false
    }

    private func requestStop() {
        guard case .running(let handle) = captureState else { return }
        captureState = .stopping(handle)
        qc_request_stop(handle)
    }

    private func reapStoppedCapture() {
        guard case .stopping(let handle) = captureState else { return }
        if qc_finish_stop(handle) == 1 { captureState = .idle }
    }

    private func checkRunningCapture(at now: TimeInterval) {
        guard case .running(let handle) = captureState else { return }
        let status = qc_status(handle)
        guard status != 1 else { return }
        log.error("Camera stream ended with status \(status).")
        nextRecoveryTime = now + recoveryDelay
        requestStop()
    }

    func pollCapture(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        checkRunningCapture(at: now)
        reapStoppedCapture()
        guard !isRetired, demand > 0, now >= nextRecoveryTime else { return }
        if case .idle = captureState {
            do {
                try startCapture()
            } catch {
                nextRecoveryTime = now + recoveryDelay
                log.error("Cannot restart camera: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func sendFrame(_ bytes: UnsafePointer<UInt8>, width frameWidth: Int, height frameHeight: Int,
                   stride: Int, hostTime: UInt64) {
        guard frameWidth == width, frameHeight == height, stride >= width * 3 else {
            log.error("Discarding a frame with unexpected dimensions or stride.")
            return
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
            bufferPool, bufferLimits, &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer else { return }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return
        }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        copyRGB24ToBGRA(bytes, sourceStride: stride, destination: destination,
                       destinationStride: destinationStride, width: width, height: height)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard hostTime <= UInt64(Int64.max) else { return }
        let timestamp = CMTime(value: Int64(hostTime), timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: timestamp,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        streamSource.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTime)
    }
}

final class QuickCamStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private weak var device: QuickCamDevice?
    private let format: CMIOExtensionStreamFormat

    init(device: QuickCamDevice, streamID: UUID, format: CMIOExtensionStreamFormat) {
        self.device = device
        self.format = format
        super.init()
        stream = CMIOExtensionStream(localizedName: "QuickCam Video", streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let values = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { values.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { values.frameDuration = frameDuration }
        return values
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index != 0 {
            throw captureError(2, message: "This camera has one stream format.")
        }
        if let duration = streamProperties.frameDuration, CMTimeCompare(duration, frameDuration) != 0 {
            throw captureError(3, message: "This camera supports five frames per second.")
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws {
        guard let device else { throw captureError(4, message: "This camera is disconnected.") }
        try device.startStream()
    }
    func stopStream() throws { device?.stopStream() }
}
