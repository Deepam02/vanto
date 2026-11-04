import AppKit
import CoreGraphics

/// Detects a tap of the Fn/🌐 key with a listen-only CGEventTap (needs Input Monitoring).
///
/// A tap counts only if no keyDown happened between press and release, and the press was
/// short; laptop arrow and F-keys also set the Fn flag (Final review point 19).
/// Holding Fn alone past `holdThreshold` is a hold (dictation): `onHoldStart`, then
/// `onHoldEnd` on release.
final class FnKeyMonitor {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    /// Called with true when the tap is healthy, false when macOS disabled it and it couldn't be re-enabled.
    var onHealthChange: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var fnDownAt: CFAbsoluteTime?
    private var chordUsed = false
    private var holding = false
    private var holdWork: DispatchWorkItem?
    private var healthy = true

    private static let fnKeyCode: Int64 = 63          // kVK_Function
    /// Shorter than this is a tap; held this long with no other key, it's a hold.
    private static let holdThreshold: TimeInterval = 0.4

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask), callback: fnTapCallback, userInfo: refcon) else {
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // Cursor's Secure Input leak and slow callbacks can make macOS disable the tap.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkHealth() }
        return true
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; source = nil
    }

    private func checkHealth() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        let ok = CGEvent.tapIsEnabled(tap: tap)
        if ok != healthy {
            healthy = ok
            onHealthChange?(ok)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if fnDownAt != nil { chordUsed = true }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode else {
                // Another modifier changed while Fn is held: it's a chord.
                if fnDownAt != nil { chordUsed = true }
                return
            }
            let fnDown = event.flags.contains(.maskSecondaryFn)
            let others: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            if fnDown {
                fnDownAt = CFAbsoluteTimeGetCurrent()
                chordUsed = !event.flags.intersection(others).isEmpty
                holdWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.fnDownAt != nil, !self.chordUsed else { return }
                    self.holding = true
                    self.onHoldStart?()
                }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: work)
            } else if let down = fnDownAt {
                holdWork?.cancel()
                holdWork = nil
                fnDownAt = nil
                if holding {
                    holding = false
                    DispatchQueue.main.async { self.onHoldEnd?() }
                } else if CFAbsoluteTimeGetCurrent() - down < Self.holdThreshold && !chordUsed {
                    DispatchQueue.main.async { self.onTap?() }
                }
            }
        default:
            break
        }
    }
}

private func fnTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
