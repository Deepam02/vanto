import AppKit
import ApplicationServices

/// Thin helpers over the Accessibility C API.
enum AX {
    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let v = value else { return nil }
        return v as? T
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as String? }
    static func bool(_ el: AXUIElement, _ name: String) -> Bool? { (attr(el, name) as NSNumber?)?.boolValue }
    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let v = value,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (attr(el, name) as [AXUIElement]?) ?? []
    }

    static func point(_ el: AXUIElement, _ name: String = kAXPositionAttribute) -> CGPoint? {
        guard let v: AXValue = attr(el, name) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }
    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }
    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }
    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)   // a hung app must not stall the snapshot
        return el
    }

    static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }()

    static func focusedElement() -> AXUIElement? { element(systemWide, kAXFocusedUIElementAttribute) }

    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    /// Is this element something we can type into?
    static func isEditable(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute) ?? ""
        if textRoles.contains(role) { return true }
        if bool(el, "AXEditable") == true { return true }      // contenteditable in web views
        if role == "AXWebArea" || role == kAXGroupRole { return isSettable(el, kAXSelectedTextRangeAttribute) && isSettable(el, kAXValueAttribute) }
        return false
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        string(el, kAXSubroleAttribute) == "AXSecureTextField" || string(el, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// Chromium-based apps build no AX tree until asked. Electron's documented switch.
    static func enableElectronAccessibility(_ pid: pid_t) {
        let el = app(pid)
        if bool(el, "AXManualAccessibility") != true {
            set(el, "AXManualAccessibility", kCFBooleanTrue)
        }
    }
}
