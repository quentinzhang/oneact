import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Recording is the one state you need to control while looking at some other
/// app: the whole point of a screen recording is that OneAct is not what you
/// are doing. Carbon's hot key API is the only system-wide shortcut mechanism
/// that needs no Accessibility grant — `NSEvent.addGlobalMonitorForEvents`
/// would put a permission prompt between the user and the stop button.
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let identifier: UInt32

    /// Returns nil when the combination is already claimed by another app, which
    /// is not worth failing a launch over — the buttons still work.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installDispatcherIfNeeded()
        identifier = Self.nextID
        Self.nextID += 1

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F41_4354), id: identifier) // 'OACT'
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return nil }
        hotKeyRef = reference
        Self.handlers[identifier] = handler
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.handlers[identifier] = nil
    }

    private static func installDispatcherIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                // Carbon delivers on the main thread; the handlers all touch UI.
                MainActor.assumeIsolated {
                    GlobalHotKey.handlers[hotKeyID.id]?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }
}
