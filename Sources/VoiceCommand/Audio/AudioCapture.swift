import AVFoundation
import CoreAudio
import AudioToolbox

/// Microphone capture at 16 kHz mono Float32.
///
/// One serial queue owns the AVAudioEngine. Device and configuration notifications are
/// debounced (~500 ms) on that queue, never acted on while macOS is still publishing devices
/// (the FluidVoice AirPods crash). Starting the mic itself triggers such notifications, so a
/// change is only reported when the mic in use is gone or (when following the system
/// default) replaced; if macOS merely stopped the engine to reconfigure, it restarts on the
/// same mic.
final class AudioCapture {
    let queue = DispatchQueue(label: "VoiceCommand.Audio", qos: .userInitiated)
    /// 16 kHz mono samples, delivered on `queue`.
    var onSamples: (([Float]) -> Void)?
    /// The mic in use went away or was replaced (delivered on main).
    var onDeviceChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var configObserver: NSObjectProtocol?
    private var deviceChangeWork: DispatchWorkItem?
    private var listenerInstalled = false
    private var useBuiltIn = true
    private var currentDevice: AudioDeviceID?
    private var followsDefault = false
    private var restarts = 0
    private(set) var deviceName = ""

    enum CaptureError: Error, CustomStringConvertible {
        case noInput, formatUnsupported, startFailed(String)
        var description: String {
            switch self {
            case .noInput: return "No microphone found"
            case .formatUnsupported: return "Microphone format not supported"
            case .startFailed(let m): return "Microphone failed to start: \(m)"
            }
        }
    }

    func start(useBuiltIn: Bool) throws {
        try queue.sync {
            guard engine == nil else { return }
            self.useBuiltIn = useBuiltIn
            restarts = 0
            try startEngine()
            installDeviceListener()
        }
    }

    func stop() {
        queue.sync {
            deviceChangeWork?.cancel()
            teardownEngine()
            currentDevice = nil
        }
    }

    var isRunning: Bool { queue.sync { engine != nil } }

    /// Build and start the engine on the chosen mic. On `queue`.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if useBuiltIn, let builtIn = Self.builtInInputDevice(), let unit = input.audioUnit {
            var id = builtIn
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            currentDevice = builtIn
            followsDefault = false
            deviceName = Self.name(of: builtIn) ?? "Built-in Microphone"
        } else {
            currentDevice = Self.defaultInputDevice()
            followsDefault = true
            deviceName = currentDevice.flatMap(Self.name(of:)) ?? "Default input"
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        guard let conv = AVAudioConverter(from: format, to: target) else { throw CaptureError.formatUnsupported }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let samples = self.convert(buffer) else { return }
            self.queue.async { self.onSamples?(samples) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.startFailed(error.localizedDescription)
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.scheduleDeviceCheck()
        }
    }

    /// On `queue`.
    private func teardownEngine() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    // MARK: Device changes

    private func scheduleDeviceCheck() {
        queue.async {
            self.deviceChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.checkDevice() }
            self.deviceChangeWork = work
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// After notifications settle: end only if our mic is gone or replaced. On `queue`.
    private func checkDevice() {
        guard let engine, let device = currentDevice else { return }
        let present = Self.allDevices().contains(device) && Self.hasInput(device)
        let replaced = followsDefault && Self.defaultInputDevice() != device
        if !present || replaced {
            DispatchQueue.main.async { self.onDeviceChange?() }
            return
        }
        if engine.isRunning { return }   // same mic, still running: nothing changed for us
        // macOS stopped the engine to reconfigure: restart on the same mic (bounded).
        guard restarts < 5 else {
            DispatchQueue.main.async { self.onDeviceChange?() }
            return
        }
        restarts += 1
        teardownEngine()
        do { try startEngine() } catch {
            DispatchQueue.main.async { self.onDeviceChange?() }
        }
    }

    private func installDeviceListener() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
                self?.scheduleDeviceCheck()
            }
        }
    }

    // MARK: CoreAudio helpers

    static func allDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func builtInInputDevice() -> AudioDeviceID? {
        allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }
}
