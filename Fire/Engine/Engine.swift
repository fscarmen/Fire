//
//  Engine.swift
//  Fire
//
//  Created by qwertyyb on 2026/8/4.
//

import Foundation

class Engine {
    static let shared = Engine()
    
    static func isPair(_ text: String) -> Bool {
        return PunctuationHandler.isPair(text)
    }
    
    static let inputModeChanged = Notification.Name("Fire.inputModeChanged")
    
    var store: any EngineStore = DefaultEngineStore.shared
    func createSession(dict: some EngineDictManager, config: some EngineConfig, punctuationTransformer: any PunctuationTransformer) -> RootState {
        return RootState(
            dict: dict,
            config: config,
            store: store,
            punctuationTransformer: punctuationTransformer
        )
    }
    var inputMode: InputMode {
        self.store.inputMode
    }

    /// 上次因安全输入(SecureEventInput)被强制切到英文的时间。
    /// issue #207: IsSecureEventInputEnabled() 反映的是系统全局的安全输入状态，
    /// 任意进程（密码管理器 / Electron 应用 / 网银控件等）开启后未释放（崩溃或 bug 泄漏）
    /// 都会让该状态全局为 true，直到泄漏进程退出。此时 activateServer 会在每次
    /// 触发时把输入模式强制切回英文，用户手动切换也被覆盖，表现为"怎么切都只出英文"。
    /// 这里记录强制发生的时间，与 userToggledAt 比较来判断"本轮安全输入期间
    /// 用户是否手动切回过中文"，以尊重用户意图并在安全输入消失后自愈。
    var secureEventEnforcedAt = Date.distantPast
    /// 用户最后一次手动切换中英文的时间（Shift / 菜单等无参 toggle 调用）。
    var userToggledAt = Date.distantPast

    func toggleInputMode(_ nextInputMode: InputMode? = nil) {
        if nextInputMode != nil, self.store.inputMode == nextInputMode {
            return
        }

        // 无参调用 = 用户手动切换（Shift / 菜单），记录时间戳并解除安全输入强制标记
        if nextInputMode == nil {
            self.userToggledAt = Date()
        }

        let oldVal = store.inputMode
        if let nextInputMode = nextInputMode, nextInputMode != store.inputMode {
            store.inputMode = nextInputMode
        } else {
            store.inputMode = store.inputMode == .enUS ? .zhhans : .enUS
        }
        NotificationCenter.default.post(name: Self.inputModeChanged, object: nil, userInfo: [
            "oldVal": oldVal,
            "val": store.inputMode,
            "label": store.inputMode == .enUS ? "英" : "中"
        ])
    }
}
