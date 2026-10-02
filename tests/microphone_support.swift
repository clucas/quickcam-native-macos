import Foundation
import CoreAudio

@main
struct MicrophoneSupportTests {
    static func source(_ id: UInt32, uid: String = "opaque physical microphone A",
                       product: String = "08B2") -> QuickCamAudioSnapshot {
        QuickCamAudioSnapshot(id: id, uid: uid, modelUID: "AppleUSBAudioDevice:046D:\(product)",
            transport: kAudioDeviceTransportTypeUSB, inputChannels: 1, outputChannels: 0,
            nominalRate: 16000, isRunning: false)
    }

    static func aggregate(_ id: UInt32, source: QuickCamAudioSnapshot) -> QuickCamAudioSnapshot {
        QuickCamAudioSnapshot(id: id,
            uid: QuickCamMicrophones.aggregateUID(model: source.microphoneModel!, sourceUID: source.uid),
            modelUID: "", transport: kAudioDeviceTransportTypeAggregate, inputChannels: 1,
            outputChannels: 0, nominalRate: source.nominalRate, isRunning: false,
            composition: QuickCamMicrophoneComposition(subdeviceUIDs: [source.uid],
                fullSubdeviceUIDs: [source.uid], mainUID: source.uid, isPrivate: false, hasTaps: false))
    }

    static func expectConflict(_ snapshots: [QuickCamAudioSnapshot]) {
        do {
            _ = try QuickCamMicrophones.plan(snapshots)
            preconditionFailure("Conflicting configurations must fail closed.")
        } catch {}
    }

    static func main() throws {
        precondition(QuickCamMicrophoneError("read", status: kAudioHardwareBadObjectError).isMissingDevice(hasUID: false))
        precondition(QuickCamMicrophoneError("read", status: kAudioHardwareBadDeviceError).isMissingDevice(hasUID: false))
        precondition(QuickCamMicrophoneError("read", status: kAudioHardwareUnknownPropertyError).isMissingDevice(hasUID: false))
        precondition(!QuickCamMicrophoneError("read", status: kAudioHardwareUnknownPropertyError).isMissingDevice(hasUID: true))
        precondition(!QuickCamMicrophoneError("read", status: kAudioHardwareIllegalOperationError).isMissingDevice(hasUID: false))
        precondition(!QuickCamMicrophoneError("Configuration changed").isMissingDevice(hasUID: false))
        let pro = source(1)
        let stx = source(2, uid: "opaque physical microphone B", product: "08D7")
        let c270 = source(3, uid: "C270", product: "0825")
        var output = source(4, uid: "speaker")
        output.outputChannels = 2
        var empty = source(5, uid: "no microphone")
        empty.inputChannels = 0
        var builtIn = source(6, uid: "built-in")
        builtIn.transport = kAudioDeviceTransportTypeBuiltIn
        let initial = try QuickCamMicrophones.plan([pro, stx, c270, output, empty, builtIn])
        precondition(initial.connectedCount == 2 && initial.additions.count == 2)
        precondition(Set(initial.additions.map(\.name)) == ["QuickCam Pro 4000 Microphone", "QuickCam Communicate STX Microphone"])

        let proAlias = aggregate(10, source: pro)
        let stxAlias = aggregate(11, source: stx)
        let complete = try QuickCamMicrophones.plan([pro, stx, proAlias, stxAlias])
        precondition(complete.additions.isEmpty && complete.existingCount == 2)
        let partial = try QuickCamMicrophones.plan([pro, stx, proAlias])
        precondition(partial.additions.count == 1 && partial.additions[0].source.uid == stx.uid)

        var secondPro = pro
        secondPro.id = 7
        secondPro.uid = "same model at another port"
        let duplicates = try QuickCamMicrophones.plan([pro, secondPro])
        precondition(Set(duplicates.additions.map(\.uid)).count == 2)
        precondition(Set(duplicates.additions.map(\.name)).count == 2)
        precondition(duplicates.additions.allSatisfy { $0.name.hasPrefix("QuickCam Pro 4000 Microphone (") })
        precondition(QuickCamMicrophones.aggregateUID(model: .pro4000, sourceUID: "abc") ==
            "org.quickcam-native.microphone.v1.08b2.ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        precondition(QuickCamMicrophones.aggregateUID(model: .stx, sourceUID: pro.uid) != proAlias.uid)
        var duplicateUID = pro
        duplicateUID.id = 100
        expectConflict([pro, duplicateUID])

        var unrelated = proAlias
        unrelated.uid = "third-party aggregate"
        precondition(QuickCamMicrophones.ownedModel(of: unrelated, among: [pro, unrelated]) == nil)
        let withUnrelated = try QuickCamMicrophones.plan([pro, unrelated])
        precondition(withUnrelated.additions.count == 1)

        var hostile = proAlias
        hostile.composition!.subdeviceUIDs.append(c270.uid)
        hostile.composition!.fullSubdeviceUIDs.append(c270.uid)
        precondition(QuickCamMicrophones.ownedModel(of: hostile, among: [pro, hostile, c270]) == nil)
        expectConflict([pro, hostile])

        var wrongFullList = proAlias
        wrongFullList.composition!.fullSubdeviceUIDs = [c270.uid]
        precondition(QuickCamMicrophones.ownedModel(of: wrongFullList, among: [pro, wrongFullList]) == nil)
        var wrongMain = proAlias
        wrongMain.composition!.mainUID = c270.uid
        precondition(QuickCamMicrophones.ownedModel(of: wrongMain, among: [pro, wrongMain]) == nil)
        var wrongHash = proAlias
        wrongHash.uid += "0"
        precondition(QuickCamMicrophones.ownedModel(of: wrongHash, among: [pro, wrongHash]) == nil)
        var privateAlias = proAlias
        privateAlias.composition!.isPrivate = true
        precondition(QuickCamMicrophones.ownedModel(of: privateAlias, among: [pro, privateAlias]) == nil)
        var tapAlias = proAlias
        tapAlias.composition!.hasTaps = true
        precondition(QuickCamMicrophones.ownedModel(of: tapAlias, among: [pro, tapAlias]) == nil)
        var outputAlias = proAlias
        outputAlias.outputChannels = 2
        precondition(QuickCamMicrophones.ownedModel(of: outputAlias, among: [pro, outputAlias]) == nil)

        var wrongModel = pro
        wrongModel.modelUID = "AppleUSBAudioDevice:046D:0825"
        precondition(QuickCamMicrophones.ownedModel(of: proAlias, among: [wrongModel, proAlias]) == nil)
        var disconnected = proAlias
        disconnected.inputChannels = 0
        precondition(QuickCamMicrophones.ownedModel(of: disconnected, among: [disconnected]) == .pro4000)
        let disconnectedPlan = try QuickCamMicrophones.plan([disconnected])
        precondition(disconnectedPlan.additions.isEmpty)
        let relocated = try QuickCamMicrophones.plan([disconnected, secondPro])
        precondition(relocated.additions.count == 1)
        precondition(relocated.additions[0].name.hasPrefix("QuickCam Pro 4000 Microphone ("))
        var opaque = pro
        opaque.uid = "not:046D:08B2:a:model:identifier"
        opaque.modelUID = "AppleUSBAudioDevice:046D:0825"
        precondition(opaque.microphoneModel == nil)
        precondition(QuickCamMicrophoneModel(modelUID: "AppleUSBAudioDevice:046D:08B2:other") == nil)
        print("Microphone allowlist, aggregate ownership, idempotence, duplicate, and disconnected-device tests passed.")
    }
}
