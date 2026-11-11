import CoreAudio
import CoreMediaIO
import Foundation
import Observation
import SwiftUI

/// Whether some app is using the microphone or a camera right now: the signal behind macOS's
/// orange and green privacy indicators. Purely event driven; CoreAudio and CoreMediaIO call
/// back when capture starts or stops and when devices or processes come and go.
///
/// Microphone: input devices' `DeviceIsRunningSomewhere` and the audio processes' run state
/// are listened to, but the answer is read per process (`IsRunningInput`, other processes
/// only). A device's running flag covers its outputs too, so playing music through a headset
/// or a virtual device that also has inputs (Teams, Serato…) would otherwise light the mic.
/// Camera: every CoreMediaIO device's `DeviceIsRunningSomewhere`.
@Observable
final class CaptureMonitor {
    private(set) var micInUse = false
    private(set) var cameraInUse = false
    /// Called after a debounced change of either value.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var running = false
    @ObservationIgnored private var micWork: DispatchWorkItem?
    @ObservationIgnored private var cameraWork: DispatchWorkItem?
    @ObservationIgnored private var inputDevices = Set<AudioObjectID>()
    /// Audio process objects of other processes.
    @ObservationIgnored private var processes = Set<AudioObjectID>()
    @ObservationIgnored private var cameras = Set<CMIOObjectID>()

    @ObservationIgnored private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshMic()
        // The device can report running a beat before the process that started it does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refreshMic() }
    }
    @ObservationIgnored private lazy var processListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshMic()
    }
    @ObservationIgnored private lazy var audioListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.syncAudio()
    }
    @ObservationIgnored private lazy var cameraListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshCamera()
    }
    @ObservationIgnored private lazy var cameraListListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.syncCameras()
    }

    func start() {
        guard !running else { return }
        running = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for var a in [Self.deviceListAddress, Self.processListAddress] {
            AudioObjectAddPropertyListenerBlock(system, &a, .main, audioListListener)
        }
        var cameraList = Self.cameraListAddress
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, .main, cameraListListener)
        syncAudio()
        syncCameras()
    }

    func stop() {
        guard running else { return }
        running = false
        let system = AudioObjectID(kAudioObjectSystemObject)
        for var a in [Self.deviceListAddress, Self.processListAddress] {
            AudioObjectRemovePropertyListenerBlock(system, &a, .main, audioListListener)
        }
        var cameraList = Self.cameraListAddress
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, .main, cameraListListener)
        Self.relisten(inputDevices, to: [], [Self.deviceRunningAddress], deviceListener)
        Self.relisten(processes, to: [], Self.processRunningAddresses, processListener)
        var cam = Self.cameraRunningAddress
        for c in cameras { CMIOObjectRemovePropertyListenerBlock(c, &cam, .main, cameraListener) }
        inputDevices = []
        processes = []
        cameras = []
        micWork?.cancel()
        cameraWork?.cancel()
        micWork = nil
        cameraWork = nil
        if micInUse || cameraInUse {
            withAnimation(Anim.micro) { micInUse = false; cameraInUse = false }
            onChange?()
        }
    }

    // MARK: Microphone

    /// Listen to devices and processes that appeared, drop the ones that went away.
    private func syncAudio() {
        guard running else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devices = Set(Self.audioIDs(system, Self.deviceListAddress).filter(Self.hasInput))
        Self.relisten(inputDevices, to: devices, [Self.deviceRunningAddress], deviceListener)
        inputDevices = devices

        let me = UInt32(bitPattern: getpid())
        let procs = Set(Self.audioIDs(system, Self.processListAddress).filter { Self.audioUInt32($0, Self.pidAddress) != me })
        Self.relisten(processes, to: procs, Self.processRunningAddresses, processListener)
        processes = procs
        refreshMic()
    }

    private func refreshMic() {
        guard running else { return }
        settle(micInUse, \.micWork, read: { [weak self] in
            self?.processes.contains { Self.audioUInt32($0, Self.inputAddress) ?? 0 != 0 } ?? false
        }, apply: { [weak self] in self?.micInUse = $0 })
    }

    // MARK: Camera

    private func syncCameras() {
        guard running else { return }
        let now = Set(Self.cameraIDs())
        var cam = Self.cameraRunningAddress
        for c in cameras.subtracting(now) { CMIOObjectRemovePropertyListenerBlock(c, &cam, .main, cameraListener) }
        for c in now.subtracting(cameras) { CMIOObjectAddPropertyListenerBlock(c, &cam, .main, cameraListener) }
        cameras = now
        refreshCamera()
    }

    private func refreshCamera() {
        guard running else { return }
        settle(cameraInUse, \.cameraWork, read: { [weak self] in
            self?.cameras.contains(where: Self.cameraIsRunning) ?? false
        }, apply: { [weak self] in self?.cameraInUse = $0 })
    }

    // MARK: Debounce

    /// Shows a change only once it has held for a moment (0.5 s on, 1 s off), so an app that
    /// briefly probes a device, or a gap between two calls, doesn't flash the indicator.
    /// The state is read again when the delay ends; the listeners restart the wait on change.
    private func settle(_ shown: Bool, _ work: ReferenceWritableKeyPath<CaptureMonitor, DispatchWorkItem?>,
                        read: @escaping () -> Bool, apply: @escaping (Bool) -> Void) {
        let now = read()
        guard now != shown else { self[keyPath: work]?.cancel(); self[keyPath: work] = nil; return }
        // Already waiting to show this value: let the wait run out instead of restarting it.
        guard self[keyPath: work] == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self[keyPath: work] = nil
            guard self.running, read() == now else { return }
            withAnimation(Anim.micro) { apply(now) }
            self.onChange?()
        }
        self[keyPath: work] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0.5 : 1.0), execute: item)
    }

    // MARK: CoreAudio / CoreMediaIO plumbing

    private static func audioAddress(_ selector: AudioObjectPropertySelector,
                                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static let deviceListAddress = audioAddress(kAudioHardwarePropertyDevices)
    private static let processListAddress = audioAddress(kAudioHardwarePropertyProcessObjectList)
    private static let deviceRunningAddress = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private static let inputAddress = audioAddress(kAudioProcessPropertyIsRunningInput)
    private static let pidAddress = audioAddress(kAudioProcessPropertyPID)
    /// `IsRunning` is what CoreAudio reliably notifies when a process starts or stops IO;
    /// `IsRunningInput` is listened to as well in case it is notified on its own.
    private static let processRunningAddresses = [audioAddress(kAudioProcessPropertyIsRunning), inputAddress]

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    private static let cameraListAddress = cmioAddress(kCMIOHardwarePropertyDevices)
    private static let cameraRunningAddress = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)

    /// Moves `listener` from the objects in `old` to those in `new` (only the difference).
    private static func relisten(_ old: Set<AudioObjectID>, to new: Set<AudioObjectID>,
                                 _ addresses: [AudioObjectPropertyAddress], _ listener: @escaping AudioObjectPropertyListenerBlock) {
        for var a in addresses {
            for o in old.subtracting(new) { AudioObjectRemovePropertyListenerBlock(o, &a, .main, listener) }
            for o in new.subtracting(old) { AudioObjectAddPropertyListenerBlock(o, &a, .main, listener) }
        }
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var a = audioAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr && size > 0
    }

    private static func audioIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func audioUInt32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var a = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func cameraIDs() -> [CMIOObjectID] {
        var a = cameraListAddress
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &a, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func cameraIsRunning(_ device: CMIOObjectID) -> Bool {
        var a = cameraRunningAddress
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(device, &a, 0, nil, size, &used, &value) == noErr else { return false }
        return value != 0
    }
}
