//
//  FireInputServer.swift
//  Fire
//
//  Created by marchyang on 2022/7/13.
//  Copyright © 2022 qwertyyb. All rights reserved.
//

import Foundation
import Carbon
import Defaults

extension FireInputController {
    /**
    * 根据当前输入的应用改变输入模式
    */
    private func restoreCurrentClientInputMode() -> Bool {
        let currentMode = Fire.engine.inputMode
        guard let identifier = client()?.bundleIdentifier() else { return false }
        if let appSetting = Defaults[.appSettings][identifier],
         let mode = InputMode(rawValue: appSetting.inputModeSetting.rawValue) {
            FireLog.input.info("restoreClientInputMode from setting: \(identifier, privacy: .public), \(String(describing: mode), privacy: .public)")
            Fire.engine.toggleInputMode(mode)
            return currentMode != Fire.engine.inputMode
        }
        // 启用APP缓存设置
        if Defaults[.keepAppInputMode], let mode = InputModeCache.shared.get(identifier) {
            FireLog.input.info("restoreClientInputMode from cache: \(identifier, privacy: .public), \(String(describing: mode), privacy: .public)")
            Fire.engine.toggleInputMode(mode)
            return currentMode != Fire.engine.inputMode
        }
        return false
    }

    private func savePreviousClientInputMode() {
        if Defaults[.keepAppInputMode],
           let controller = CandidatesWindow.shared.inputController,
           let identifier = controller.client()?.bundleIdentifier(),
           Defaults[.appSettings][identifier] == nil {
            FireLog.input.debug("saveClientInputMode \(identifier, privacy: .public), \(String(describing: Fire.engine.inputMode), privacy: .public)")
            // 缓存当前输入模式
            InputModeCache.shared.put(identifier, Fire.engine.inputMode)
        }
    }

    override func activateServer(_ sender: Any!) {
        FireLog.input.info("activate server: \(self.client()?.bundleIdentifier() ?? sender.debugDescription, privacy: .public)")
        
        // 这个保存动作之所以不在 deactivateServer 中做，主要是因为 activateServer 和 deactivateServer 的调用顺序不固定
        // 而 inputMode 是全局的，如果是 activateServer 先调用，则会写入 inputMode
        // 在后调用 deactivateServer 中保存 inputMode 时，保存的已经不是之前的 inputMode 了
        savePreviousClientInputMode()

        // 新客户端的 markedText 状态是空的，必须让我们本地缓存失效，
        // 否则 markText() 的「内容未变就跳过」优化会漏发第一次标记。
        resetMarkedTextState()
        CandidatesWindow.shared.inputController = self

        if IsSecureEventInputEnabled() {
            /** 安全事件输入模式指输入密码的场景
             * 一般情况下系统会自动切换到 ABC 输入法，在输入过程中不会调用第三方输入法
             * 但在删除系统 ABC 输入法的情况下，仍然有可能会调用到第三方输入法 https://github.com/qwertyyb/Fire/issues/158
             * 在这种情况下，输入法需要切换到英文模式，避免影响用户输入密码
             *
             * issue #207: IsSecureEventInputEnabled() 反映系统全局状态，任意进程
             * 泄漏该状态（开启后未释放）时，此处会在每次 activateServer 强制切回英文，
             * 用户手动切换被反复覆盖，表现为"怎么切都只出英文"，注销才恢复。
             * 修复：若用户在本轮安全输入期间已手动切回过中文，则尊重用户意图不再强制；
             * 强制发生时记录时间戳，供安全输入消失后自愈（见下方 else 分支与 enModeHandler）。
             */
            if Fire.engine.userToggledAt > Fire.engine.secureEventEnforcedAt {
                FireLog.input.info("secure event active, but user manually toggled — keep current mode")
                return
            }
            Fire.engine.secureEventEnforcedAt = Date()
            Fire.engine.toggleInputMode(.enUS)
            return
        }

        // 安全输入已结束：若此前是被安全输入强制切到英文的（且用户未手动切换过），
        // 自愈恢复为中文，避免泄漏进程退出后仍卡在英文模式（issue #207）
        if Fire.engine.secureEventEnforcedAt > Fire.engine.userToggledAt {
            Fire.engine.toggleInputMode(.zhhans)
        }

        let changed = restoreCurrentClientInputMode()

        if (changed && Defaults[.appInputModeTipShowTime] != .none) || Defaults[.appInputModeTipShowTime] == .always {
            // 在 MacOS 15.1 上当切换应用时，如果目标应用没有输入框聚焦，直接调用 toastCurrentMode 会卡顿 3 秒左右
            // 经过验证在 async 中调用才不会卡顿
            DispatchQueue.main.async {
                Fire.shared.toastCurrentMode()
            }
        }
    }
    override func deactivateServer(_ sender: Any!) {
        insertOriginText()
        clean()
//        saveClientInputMode()
        FireLog.input.info("deactivate server: \(self.client()?.bundleIdentifier() ?? "no client deactivate", privacy: .public)")
    }
}
