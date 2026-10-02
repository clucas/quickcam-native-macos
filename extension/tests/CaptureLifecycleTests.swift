import CoreMedia
import Foundation

private let pro = qc_device_info(vendor_id: 0x046d, product_id: 0x08b2, location_id: 100, registry_id: 1000)
private let stx = qc_device_info(vendor_id: 0x046d, product_id: 0x08d7, location_id: 200, registry_id: 2000)

private func connected(_ cameras: [qc_device_info]) {
    cameras.withUnsafeBufferPointer { test_capture_devices($0.baseAddress, $0.count) }
}

private func finish(_ camera: QuickCamDevice, location: UInt32, at time: TimeInterval) {
    camera.retire()
    if !camera.isQuiescent {
        test_capture_complete_shutdown(location)
        camera.pollCapture(at: time)
    }
    precondition(camera.isQuiescent)
}

private func twoCamerasAndMultipleClients() throws {
    test_capture_reset()
    let a = try QuickCamDevice(info: pro)
    let b = try QuickCamDevice(info: stx)
    try a.startStream(at: 0)
    try a.startStream(at: 0)
    try b.startStream(at: 0)
    precondition(test_capture_outstanding() == 2)
    precondition(test_capture_starts(pro.location_id) == 1)
    a.stopStream()
    precondition(a.demand == 1 && test_capture_stop_requests(pro.location_id) == 0)
    a.stopStream()
    precondition(a.demand == 0 && test_capture_stop_requests(pro.location_id) == 1)
    a.pollCapture(at: 1)
    precondition(!a.isQuiescent && test_capture_finishes(pro.location_id) == 0)

    try b.startStream(at: 1)
    b.stopStream()
    b.pollCapture(at: 2)
    precondition(b.demand == 1 && test_capture_stop_requests(stx.location_id) == 0)
    precondition(test_capture_starts(stx.location_id) == 1)
    test_capture_complete_shutdown(pro.location_id)
    a.pollCapture(at: 3)
    precondition(a.isQuiescent && test_capture_starts(pro.location_id) == 1)
    finish(b, location: stx.location_id, at: 4)
    precondition(test_capture_outstanding() == 0)
}

private func failurePreservesClientDemand() throws {
    test_capture_reset()
    let camera = try QuickCamDevice(info: pro)
    try camera.startStream(at: 0)
    test_capture_status(pro.location_id, -5)
    camera.pollCapture(at: 10)
    precondition(camera.demand == 1 && test_capture_stop_requests(pro.location_id) == 1)
    try camera.startStream(at: 10.5)
    precondition(camera.demand == 2 && test_capture_starts(pro.location_id) == 1)
    camera.stopStream()
    precondition(camera.demand == 1)
    test_capture_complete_shutdown(pro.location_id)
    camera.pollCapture(at: 11)
    precondition(test_capture_starts(pro.location_id) == 1)
    camera.pollCapture(at: 12)
    precondition(camera.demand == 1 && test_capture_starts(pro.location_id) == 2)
    camera.stopStream()
    precondition(test_capture_stop_requests(pro.location_id) == 2)
    test_capture_complete_shutdown(pro.location_id)
    camera.pollCapture(at: 13)
    precondition(camera.isQuiescent && test_capture_finishes(pro.location_id) == 2)
}

private func recoveryIsRateLimited() throws {
    test_capture_reset()
    let camera = try QuickCamDevice(info: pro)
    try camera.startStream(at: 0)
    test_capture_status(pro.location_id, -5)
    camera.pollCapture(at: 5)
    test_capture_start_error(pro.location_id, 1)
    test_capture_complete_shutdown(pro.location_id)
    camera.pollCapture(at: 7)
    precondition(test_capture_attempts(pro.location_id) == 2 && camera.demand == 1)
    camera.pollCapture(at: 7.5)
    camera.pollCapture(at: 8.9)
    precondition(test_capture_attempts(pro.location_id) == 2)
    do {
        try camera.startStream(at: 9)
        preconditionFailure("An immediate open failure must reject the new client.")
    } catch {}
    precondition(camera.demand == 1 && test_capture_attempts(pro.location_id) == 3)
    test_capture_start_error(pro.location_id, 0)
    camera.pollCapture(at: 10.9)
    precondition(test_capture_attempts(pro.location_id) == 3)
    camera.pollCapture(at: 11)
    precondition(test_capture_starts(pro.location_id) == 2)
    finish(camera, location: pro.location_id, at: 12)
    camera.pollCapture(at: 20)
    precondition(test_capture_starts(pro.location_id) == 2)
}

private func clientsLeavingDuringRecovery() throws {
    test_capture_reset()
    let camera = try QuickCamDevice(info: pro)
    try camera.startStream(at: 0)
    test_capture_status(pro.location_id, -5)
    camera.pollCapture(at: 1)
    camera.stopStream()
    precondition(camera.demand == 0 && test_capture_stop_requests(pro.location_id) == 1)
    test_capture_complete_shutdown(pro.location_id)
    camera.pollCapture(at: 5)
    precondition(camera.isQuiescent && test_capture_outstanding() == 0)
    precondition(test_capture_starts(pro.location_id) == 1)
}

private func newClientDuringNormalShutdown() throws {
    test_capture_reset()
    let camera = try QuickCamDevice(info: pro)
    try camera.startStream(at: 0)
    camera.stopStream()
    try camera.startStream(at: 0.5)
    precondition(camera.demand == 1 && test_capture_starts(pro.location_id) == 1)
    test_capture_complete_shutdown(pro.location_id)
    camera.pollCapture(at: 1)
    precondition(camera.demand == 1 && test_capture_starts(pro.location_id) == 2)
    finish(camera, location: pro.location_id, at: 2)
}

private func newClientsRespectRecoveryDelay() throws {
    test_capture_reset()
    let camera = try QuickCamDevice(info: pro)
    try camera.startStream(at: 0)
    test_capture_status(pro.location_id, -5)
    camera.pollCapture(at: 1)
    test_capture_complete_shutdown(pro.location_id)
    camera.pollCapture(at: 2)
    try camera.startStream(at: 2.5)
    precondition(camera.demand == 2 && test_capture_attempts(pro.location_id) == 1)
    camera.stopStream()
    camera.pollCapture(at: 2.9)
    precondition(camera.demand == 1 && test_capture_attempts(pro.location_id) == 1)
    camera.pollCapture(at: 3)
    precondition(test_capture_starts(pro.location_id) == 2)
    finish(camera, location: pro.location_id, at: 4)
}

private func discoveryHotplugAndModelReplacement(_ source: QuickCamProvider) throws {
    test_capture_reset()
    connected([pro, stx])
    test_capture_initialization_failures(1)
    source.refreshDevices(at: 0)
    precondition(source.devices.isEmpty)
    source.refreshDevices(at: 1)
    precondition(source.devices.count == 2)
    precondition(test_capture_outstanding() == 0)
    let proID = CameraIdentity(pro)
    let stxID = CameraIdentity(stx)
    precondition(source.devices[proID]!.device.localizedName == "Logitech QuickCam Pro 4000")
    precondition(source.devices[stxID]!.device.localizedName == "Logitech QuickCam Communicate STX")
    precondition(source.devices[proID]!.device.deviceID != source.devices[stxID]!.device.deviceID)
    let stream = source.devices[proID]!.device.streams[0].source!
    let dimensions = CMVideoFormatDescriptionGetDimensions(stream.formats[0].formatDescription)
    precondition(dimensions.width == 640 && dimensions.height == 480)
    precondition(CMTimeCompare(stream.formats[0].minFrameDuration, CMTime(value: 1, timescale: 5)) == 0)

    test_capture_discovery_error(1)
    source.refreshDevices(at: 2)
    precondition(source.devices.count == 2)
    test_capture_discovery_error(0)
    try source.devices[proID]!.startStream(at: 3)
    try source.devices[stxID]!.startStream(at: 3)
    weak var removedCamera = source.devices[proID]
    connected([stx])
    source.refreshDevices(at: 4)
    precondition(source.devices[proID] == nil && source.retiringDevices.count == 1)
    precondition(removedCamera != nil)
    test_capture_deliver_invalid_frame(pro.location_id)
    do {
        try removedCamera!.startStream(at: 4)
        preconditionFailure("A disconnected camera must reject a start.")
    } catch {}

    connected([pro, stx])
    source.refreshDevices(at: 5)
    precondition(source.devices.count == 1 && test_capture_starts(pro.location_id) == 1)
    try source.devices[stxID]!.startStream(at: 5)
    source.devices[stxID]!.stopStream()
    precondition(source.devices[stxID]!.demand == 1)
    test_capture_complete_shutdown(pro.location_id)
    source.refreshDevices(at: 6)
    precondition(source.devices.count == 2 && source.retiringDevices.isEmpty)
    precondition(removedCamera == nil)
    precondition(source.devices[proID]!.demand == 0)

    try source.devices[proID]!.startStream(at: 6.5)
    try stream.stopStream()
    precondition(source.devices[proID]!.demand == 1)
    removedCamera = source.devices[proID]
    let replacement = qc_device_info(vendor_id: 0x046d, product_id: 0x08d7, location_id: pro.location_id, registry_id: 3000)
    let replacementID = CameraIdentity(replacement)
    connected([replacement, stx])
    source.refreshDevices(at: 7)
    precondition(source.devices[proID] == nil && source.devices[replacementID] == nil)
    precondition(source.retiringDevices.count == 1)
    precondition(removedCamera != nil)
    test_capture_complete_shutdown(pro.location_id)
    source.refreshDevices(at: 8)
    precondition(removedCamera == nil)
    precondition(source.devices[replacementID]!.device.localizedName == "Logitech QuickCam Communicate STX")
    precondition(source.devices[replacementID]!.demand == 0)
    precondition(test_capture_starts(pro.location_id) == 2)

    connected([])
    source.refreshDevices(at: 9)
    test_capture_complete_shutdown(stx.location_id)
    source.refreshDevices(at: 10)
    precondition(source.devices.isEmpty && source.retiringDevices.isEmpty)
    precondition(test_capture_outstanding() == 0)
}

private func idlePreparationAndReconnect(_ source: QuickCamProvider) throws {
    test_capture_reset()
    let c270 = qc_device_info(vendor_id: 0x046d, product_id: 0x0825, location_id: 300, registry_id: 3000)
    connected([pro, stx, c270])
    test_capture_initialization_failures(1)
    source.refreshDevices(at: 0)
    precondition(test_capture_preparations(pro.location_id) == 0)
    test_capture_prepare_error(pro.location_id, 1)
    source.refreshDevices(at: 1)
    let camera = source.devices[CameraIdentity(pro)]!
    let stableID = camera.device.deviceID
    precondition(source.devices.count == 2 && test_capture_outstanding() == 0)
    precondition(test_capture_preparations(pro.location_id) == 1)
    precondition(test_capture_preparations(stx.location_id) == 0)
    precondition(test_capture_preparations(c270.location_id) == 0)
    source.refreshDevices(at: 2)
    test_capture_discovery_error(1)
    source.refreshDevices(at: 3)
    precondition(test_capture_preparations(pro.location_id) == 1)
    test_capture_discovery_error(0)
    source.refreshDevices(at: 3)
    precondition(test_capture_preparations(pro.location_id) == 2)

    try camera.startStream(at: 3.1)
    precondition(test_capture_starts(pro.location_id) == 1)
    source.refreshDevices(at: 6)
    precondition(test_capture_preparations(pro.location_id) == 2)
    camera.stopStream()
    source.refreshDevices(at: 7)
    precondition(test_capture_preparations(pro.location_id) == 2)
    test_capture_complete_shutdown(pro.location_id)
    source.refreshDevices(at: 8)
    precondition(test_capture_preparations(pro.location_id) == 2)

    var replacement = pro
    replacement.registry_id += 1
    connected([replacement, stx])
    source.refreshDevices(at: 9)
    precondition(camera.isRetired && source.devices[CameraIdentity(pro)] == nil)
    precondition(source.devices[CameraIdentity(replacement)]!.device.deviceID == stableID)
    precondition(test_capture_preparations(pro.location_id) == 3)
    precondition(test_capture_prepared_registry(pro.location_id) == replacement.registry_id)
    replacement.registry_id += 1
    connected([replacement, stx])
    source.refreshDevices(at: 9.5)
    precondition(test_capture_preparations(pro.location_id) == 4)
    precondition(test_capture_prepared_registry(pro.location_id) == replacement.registry_id)
    test_capture_prepare_error(pro.location_id, 0)
    source.refreshDevices(at: 11)
    precondition(test_capture_preparations(pro.location_id) == 4)
    source.refreshDevices(at: 12)
    source.refreshDevices(at: 30)
    precondition(test_capture_preparations(pro.location_id) == 5)
    precondition(test_capture_starts(pro.location_id) == 1)
    connected([])
    source.refreshDevices(at: 31)
    camera.prepareIdleDevice(at: 32)
    precondition(test_capture_preparations(pro.location_id) == 5)
}

private func reconnectPreparationWaitsForShutdown(_ source: QuickCamProvider) throws {
    test_capture_reset()
    connected([pro, stx])
    source.refreshDevices(at: 0)
    let oldCamera = source.devices[CameraIdentity(pro)]!
    let stableID = oldCamera.device.deviceID
    try oldCamera.startStream(at: 0)
    try source.devices[CameraIdentity(stx)]!.startStream(at: 0)
    var replacement = pro
    replacement.registry_id += 1
    connected([replacement, stx])
    source.refreshDevices(at: 1)
    source.refreshDevices(at: 2)
    precondition(source.devices[CameraIdentity(replacement)] == nil)
    precondition(test_capture_preparations(pro.location_id) == 1)
    precondition(test_capture_stop_requests(stx.location_id) == 0)
    test_capture_complete_shutdown(pro.location_id)
    source.refreshDevices(at: 3)
    precondition(source.devices[CameraIdentity(replacement)]!.device.deviceID == stableID)
    precondition(test_capture_preparations(pro.location_id) == 2)
    precondition(test_capture_starts(pro.location_id) == 1)
    oldCamera.prepareIdleDevice(at: 4)
    precondition(test_capture_preparations(pro.location_id) == 2)
    connected([])
    source.refreshDevices(at: 5)
    test_capture_complete_shutdown(stx.location_id)
    source.refreshDevices(at: 6)
    precondition(test_capture_outstanding() == 0)
}

private func failedCaptureDoesNotSkipIdlePreparation() throws {
    test_capture_reset()
    let camera = try QuickCamDevice(info: pro)
    test_capture_start_error(pro.location_id, 1)
    do {
        try camera.startStream(at: 0)
        preconditionFailure("The injected capture failure must reject the start.")
    } catch {}
    try camera.startStream(at: 1)
    camera.prepareIdleDevice(at: 1)
    precondition(camera.demand == 1 && test_capture_preparations(pro.location_id) == 0)
    camera.stopStream()
    camera.prepareIdleDevice(at: 1)
    precondition(test_capture_preparations(pro.location_id) == 1)
    precondition(test_capture_starts(pro.location_id) == 0)
    camera.retire()
}

@main
struct CaptureLifecycleTests {
    static func main() throws {
        try autoreleasepool { try twoCamerasAndMultipleClients() }
        try autoreleasepool { try failurePreservesClientDemand() }
        try autoreleasepool { try recoveryIsRateLimited() }
        try autoreleasepool { try clientsLeavingDuringRecovery() }
        try autoreleasepool { try newClientDuringNormalShutdown() }
        try autoreleasepool { try newClientsRespectRecoveryDelay() }
        let provider = QuickCamProvider(startPolling: false)
        try autoreleasepool { try discoveryHotplugAndModelReplacement(provider) }
        try autoreleasepool { try idlePreparationAndReconnect(provider) }
        try autoreleasepool { try reconnectPreparationWaitsForShutdown(provider) }
        try autoreleasepool { try failedCaptureDoesNotSkipIdlePreparation() }
        print("Two-device capture, recovery, asynchronous stop, USB reconnect, and idle activity-light tests passed.")
    }
}
