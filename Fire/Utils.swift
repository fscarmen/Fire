//
//  checkShiftUp.swift
//  Fire
//
//  Created by 虚幻 on 2020/8/15.
//  Copyright © 2020 qwertyyb. All rights reserved.
//

import AppKit
import Defaults
import InputMethodKit
import SwiftUI

class Utils {
    // 中英文边界判断原本用四个 NSRegularExpression 做 numberOfMatches，
    // 每次上屏都要在 UTF-16 上跑正则；这里改成标量比较，语义完全一致且零分配。
    @inline(__always)
    private static func isAsciiAlnum(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
    }

    @inline(__always)
    private static func isCjk(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v >= 0x4e00 && v <= 0x9fa5
    }

    /// 上屏文本是否**可能**触发中英文边界加空格。
    /// 标点、emoji 等直接返回 false，调用方因此可以跳过取前文的 IPC。
    static func mayNeedWhitespace(before text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return isCjk(first) || isAsciiAlnum(first)
    }

    var toast: ToastWindowProtocol?

    // 用于删除/组词等操作的小字文本提示，独立于中英文切换提示，不受 inputModeTipWindowType 影响
    // 低频操作，按需创建、隐藏后释放
    private var messageToast: ToastWindow?

    // 显示一段小字文本提示(居中)，提示消失后释放窗口
    func showMessage(_ text: String) {
        if messageToast == nil {
            messageToast = ToastWindow()
        }
        messageToast?.showToast(text, duration: 3.0) { [weak self] in
            self?.messageToast = nil
        }
    }

    private func initToastWindow() {
        toast = Defaults[.inputModeTipWindowType] == .centerScreen
            ? ToastWindow()
           : Defaults[.inputModeTipWindowType] == .followInput
               ? TipsWindow()
               : nil
    }
    init() {
        Defaults.observe(keys: .inputModeTipWindowType, .candidateCount) { () in
            self.initToastWindow()
        }.tieToLifetime(of: self)
    }
    func processHandlers<T>(
        handlers: [(NSEvent) -> T?]
    ) -> ((NSEvent) -> T?) {
        func handleFn(event: NSEvent) -> T? {
            for handler in handlers {
                if let result = handler(event) {
                    return result
                }
            }
            return nil
        }
        return handleFn
    }

    func getScreenFromPoint(_ point: NSPoint) -> NSScreen? {
        // find current screen
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return NSScreen.main
    }
    
    // 根据上次输入的字符，判断插入的新字符是否要前加空格
    func shouldConcatWithWhitespace(_ lastText: String, _ nextText: String) -> Bool {
        FireLog.utils.debug("shouldConcatWithWhitespace, lastText: \(lastText), nextText: \(nextText)")
        if lastText.isEmpty || nextText.isEmpty {
            return false
        }
        guard let last = lastText.unicodeScalars.last,
              let next = nextText.unicodeScalars.first else { return false }
        if Utils.isAsciiAlnum(last) && Utils.isCjk(next) { return true }
        return Utils.isCjk(last) && Utils.isAsciiAlnum(next)
    }

    static let shared = Utils()

    /// 在主线程重复执行 callback，直到返回 true 或超过 timeout。
    /// 首次在下一个 runloop 执行；返回 false 时按 interval 重试；超时后不再执行。
    static func retryUntil(
        interval: TimeInterval,
        timeout: TimeInterval,
        callback: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        func attempt() {
            if callback() { return }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: attempt)
        }

        DispatchQueue.main.async(execute: attempt)
    }
}

// MARK: - SQLite 公共辅助函数

/// 安全读取可为 NULL 的 SQLite 文本列
/// 当列值为 NULL 时返回 nil，避免 String(cString:) 传入 NULL 指针崩溃
func optString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cStr)
}

/// 安全获取 SQLite 错误信息，database 为 nil 时返回 "nil"
func dbErrMsg(_ db: OpaquePointer?) -> String {
    guard let db = db, let cStr = sqlite3_errmsg(db) else { return "nil" }
    return String(cString: cStr)
}

/// 准备 SQL 语句，失败时返回 nil
func sqlitePrepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    return stmt
}

/// 执行 SQL 查询，每行回调，自动 finalize
/// - Parameters:
///   - bind: 可选参数绑定闭包，在 prepare 后调用
///   - row: 每行回调，step 返回 SQLITE_ROW 时调用
func sqliteQuery(_ db: OpaquePointer?, _ sql: String,
                 bind: ((OpaquePointer) -> Void)? = nil,
                 row: (OpaquePointer) -> Void) {
    guard let stmt = sqlitePrepare(db, sql) else {
        FireLog.utils.error("SQLite prepare failed: \(sql) — \(dbErrMsg(db), privacy: .public)")
        return
    }
    defer { sqlite3_finalize(stmt) }
    bind?(stmt)
    while sqlite3_step(stmt) == SQLITE_ROW {
        row(stmt)
    }
}

// MARK: - NSApplication 扩展

extension NSApplication {
    /// 激活为 accessory 模式并置前，用于菜单栏触发的模态窗口（关于、更新、字根表）
    /// 若偏好设置窗口正在显示则跳过切换，保持 Dock 图标可见
    func activateAsAccessory() {
        if !FirePreferencesController.shared.isVisible {
            setActivationPolicy(.accessory)
        }
        activate(ignoringOtherApps: true)
    }
}
