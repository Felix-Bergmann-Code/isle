import AppKit
import AudioToolbox
import CoreAudio
import CoreBluetooth
import IOBluetooth
import IOKit.ps
import Observation

// MARK: - Battery

@Observable
final class BatteryService {
    var level = 100
    var isCharging = false
    var isPluggedIn = false
    var hasBattery = false

    @ObservationIgnored var onPowerChange: ((_ pluggedIn: Bool, _ level: Int) -> Void)?
    @ObservationIgnored var onLowBattery: ((Int) -> Void)?
    @ObservationIgnored private var source: CFRunLoopSource?

    func start() {
        read(notify: false)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue().read(notify: true)
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
    }

    private func read(notify: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = mx > 0 ? Int((Double(cur) / Double(mx) * 100).rounded()) : cur
            let plugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false

            let pluggedChanged = plugged != isPluggedIn
            let crossedLow = !plugged && level > 20 && newLevel <= 20
            hasBattery = true
            level = newLevel
            isPluggedIn = plugged
            isCharging = charging
            if notify && pluggedChanged { onPowerChange?(plugged, newLevel) }
            if notify && crossedLow { onLowBattery?(newLevel) }
            return
        }
        hasBattery = false
    }
}

// MARK: - Volume (CoreAudio)

final class VolumeService {
    var onChange: ((Float, Bool) -> Void)?
    private var device = AudioDeviceID(0)
    private var lastValue: (Float, Bool)?
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fire() }

    func start() {
        device = Self.defaultOutput()
        attach()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self else { return }
            self.detach()
            self.device = Self.defaultOutput()
            self.attach()
            self.lastValue = (self.volume, self.isMuted)
        }
        lastValue = (volume, isMuted)
    }

    private func fire() {
        let v = (volume, isMuted)
        if let last = lastValue, abs(last.0 - v.0) < 0.001, last.1 == v.1 { return }
        lastValue = v
        onChange?(v.0, v.1)
    }

    private func addresses() -> [AudioObjectPropertyAddress] {
        [AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                    mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
         AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                    mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)]
    }

    private func attach() {
        for var a in addresses() where AudioObjectHasProperty(device, &a) {
            AudioObjectAddPropertyListenerBlock(device, &a, .main, listener)
        }
    }

    private func detach() {
        for var a in addresses() where AudioObjectHasProperty(device, &a) {
            AudioObjectRemovePropertyListenerBlock(device, &a, .main, listener)
        }
    }

    static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    var canSetVolume: Bool {
        var addr = addresses()[0]
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr) else { return false }
        AudioObjectIsPropertySettable(device, &addr, &settable)
        return settable.boolValue
    }

    var volume: Float {
        get {
            var addr = addresses()[0]
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(device, &addr) else { return 0 }
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v)
            return v
        }
        set {
            var addr = addresses()[0]
            var v = Float32(min(1, max(0, newValue)))
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    var isMuted: Bool {
        get {
            var addr = addresses()[1]
            var m = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectHasProperty(device, &addr) else { return false }
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &m)
            return m != 0
        }
        set {
            var addr = addresses()[1]
            var m = UInt32(newValue ? 1 : 0)
            guard AudioObjectHasProperty(device, &addr) else { return }
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}

// MARK: - Brightness (built-in display, via DisplayServices)

enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    /// The active built-in panel, if the lid is open.
    static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count = UInt32(0)
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var current: Float? {
        guard let d = builtInDisplay, let getFn else { return nil }
        var v: Float = 0
        return getFn(d, &v) == 0 ? v : nil
    }

    static func set(_ value: Float) {
        guard let d = builtInDisplay, let setFn else { return }
        _ = setFn(d, min(1, max(0, value)))
    }
}

// MARK: - Media key tap (opt-in HUD replacement; needs Accessibility)

enum MediaKey: Int {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

final class MediaKeyTap {
    /// Return true to swallow the key (so the system HUD doesn't appear).
    var handler: ((MediaKey, _ isDown: Bool, _ fine: Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trustPoll: Timer?
    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start(prompt: Bool) {
        guard tap == nil else { return }
        guard Self.isTrusted else {
            if prompt { Self.requestTrust() }
            // Start automatically once the user grants access.
            trustPoll?.invalidate()
            trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if Self.isTrusted { t.invalidate(); self?.start(prompt: false) }
            }
            return
        }
        let mask = CGEventMask(1 << 14) // NSEventTypeSystemDefined
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
                                              guard let refcon else { return Unmanaged.passUnretained(event) }
                                              let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                                              return me.handle(type: type, event: event)
                                          }, userInfo: refcon) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        trustPoll?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let flags = ns.data1 & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        guard let key = MediaKey(rawValue: code) else { return Unmanaged.passUnretained(event) }
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        if handler?(key, isDown, fine) == true { return nil }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Bluetooth

final class BluetoothWatcher: NSObject, CBCentralManagerDelegate {
    var onEvent: ((_ name: String, _ icon: String, _ connected: Bool) -> Void)?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [IOBluetoothUserNotification] = []
    private var startDate = Date()
    private var authManager: CBCentralManager?
    private var wanted = false

    /// IOBluetooth blocks the calling thread until Bluetooth permission is
    /// resolved, so ask through CoreBluetooth (async) first.
    func start() {
        wanted = true
        switch CBManager.authorization {
        case .allowedAlways: register()
        case .notDetermined:
            if authManager == nil { authManager = CBCentralManager(delegate: self, queue: .main) }
        default: break
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if CBManager.authorization == .allowedAlways, wanted { register() }
    }

    private func register() {
        guard connectNote == nil else { return }
        startDate = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
    }

    func stop() {
        wanted = false
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.forEach { $0.unregister() }
        disconnectNotes.removeAll()
    }

    @objc private func didConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let n = device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:))) {
            disconnectNotes.append(n)
        }
        // Registration replays already-connected devices; ignore those.
        guard Date().timeIntervalSince(startDate) > 3 else { return }
        onEvent?(device.name ?? "Bluetooth device", Self.icon(for: device), true)
    }

    @objc private func didDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotes.removeAll { $0 === note }
        onEvent?(device.name ?? "Bluetooth device", Self.icon(for: device), false)
    }

    static func icon(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("mouse") { return "magicmouse" }
        if name.contains("controller") || name.contains("dualsense") || name.contains("xbox") { return "gamecontroller" }
        if device.deviceClassMajor == kBluetoothDeviceClassMajorAudio { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}
