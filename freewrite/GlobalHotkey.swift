import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via Carbon's RegisterEventHotKey. Posts
/// `Notification.Name.freewriteOpenAddPrompt` and activates the app when the
/// hotkey is pressed. Default chord: ⌘⇧P.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// Registers the default chord (⌘⇧P).
    func registerDefault() {
        register(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey))
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        // Install the application-level event handler once.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let handlerCallback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef = eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard status == noErr else { return status }

            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                }
                NotificationCenter.default.post(name: .freewriteOpenAddPrompt, object: nil)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handlerCallback, 1, &eventType, nil, &eventHandler)

        // Register the hotkey.
        let hotKeyID = EventHotKeyID(signature: OSType(0x46575250), id: 1) // 'FWRP'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}
