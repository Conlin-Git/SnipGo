import AppKit
import Carbon.HIToolbox

/// 基于 Carbon RegisterEventHotKey 的全局快捷键（无需辅助功能权限）
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false
    private let signature: OSType = 0x534E_4750 // 'SNGP'

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if status == noErr {
                let id = hk.id
                DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }

    /// 注册；返回是否成功（被其他应用占用时失败）
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                         EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }
}
