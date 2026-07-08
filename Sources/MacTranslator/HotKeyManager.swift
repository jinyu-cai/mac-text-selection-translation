import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey via the Carbon Event Manager.
/// This works without Accessibility permission and is reliably global.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    // 'MTRK' — an arbitrary signature identifying our hotkey.
    private let hotKeyID: EventHotKeyID

    init(id: UInt32) {
        hotKeyID = EventHotKeyID(signature: 0x4D54_524B, id: id)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister()
        guard modifiers != 0 else { return false }
        self.handler = handler

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

                var firedID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )

                if firedID.id == manager.hotKeyID.id {
                    DispatchQueue.main.async { manager.handler?() }
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandler
        )
        guard installStatus == noErr else {
            self.handler = nil
            return false
        }

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            return false
        }

        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
    }

    deinit { unregister() }
}
