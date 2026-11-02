import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts through Carbon, which needs no Accessibility permission. Registered only while
/// the island has something to answer, so the keys stay free for other apps the rest of the time.
@MainActor
final class HotKeys {
    struct Key: Hashable {
        let code: UInt32
        let modifiers: UInt32
        static func controlOption(_ code: Int) -> Key { Key(code: UInt32(code), modifiers: UInt32(controlKey | optionKey)) }
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private static var shared: HotKeys?

    func register(_ bindings: [(Key, () -> Void)]) {
        unregister()
        installHandler()
        for (index, (key, action)) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5344_4541), id: id)
            if RegisterEventHotKey(key.code, key.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                handlers[id] = action
            }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
    }

    private func installHandler() {
        guard eventHandler == nil else { return }
        Self.shared = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = id.id
            // Carbon delivers on the main thread: the action is looked up now, so keys registered after the press
            // (a request arriving meanwhile reuses the ids) can't receive it. It runs once this callback returns.
            MainActor.assumeIsolated {
                guard let action = HotKeys.shared?.handlers[pressed] else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
            }
            return noErr
        }, 1, &type, nil, &eventHandler)
    }
}
