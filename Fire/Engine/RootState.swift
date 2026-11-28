//
//  RootState.swift
//  Fire
//
//  Created by qwertyyb on 2026/8/1.
//
import Carbon

class RootState: InputState {
    func didEnter(_ context: inout any InputContext) {
        
    }
    
    func willExit(_ context: inout any InputContext) {
        
    }
    
    init(subState: (any InputState)? = nil,
         dict: some EngineDictManager,
         config: some EngineConfig,
         store: some EngineStore = DefaultEngineStore.shared,
         engine: Engine = Engine.shared,
         punctuationTransformer: any PunctuationTransformer
    ) {
        self.subState = subState
        self.dict = dict
        self.config = config
        self.store = store
        self.engine = engine
        self.punctuationHandler = PunctuationHandler(transformer: punctuationTransformer)
    }

    
    var subState: (any InputState)?
    
    let dict: any EngineDictManager
    
    let config: any EngineConfig
    
    var store: any EngineStore
    
    var punctuationHandler: PunctuationHandler
    
    var engine: Engine
    
    func refetchCandidates(_ context: inout any InputContext) {
        if context.origin.isEmpty {
            context.candidates = []
            context.hasNext = false
        } else {
            let candidatesData = self.dict.query(context.origin, page: context.curPage)
            context.candidates = candidatesData.candidates
            context.hasNext = candidatesData.hasNext
        }
    }
    
    func setSubState(_ subState: (any InputState)?, context: inout any InputContext) {
        self.subState?.willExit(&context)
        if let subState = subState {
            self.subState = subState
            self.subState?.didEnter(&context)
        } else {
            self.subState = nil
            refetchCandidates(&context)
        }
    }
    
    func updateCandidates(_ context: inout any InputContext, origin: String? = nil, page: Int? = nil, selectedIndex: Int? = nil) {
        var shouldQuery = false
        if let origin = origin {
            context.origin = origin
            shouldQuery = true
        }
        if let page = page {
            context.curPage = page
            shouldQuery = true
        }
        if let selectedIndex = selectedIndex {
            context.selectedIndex = selectedIndex
        }
        if shouldQuery {
            refetchCandidates(&context)
        }
    }
    
    func commitText(_ context: inout any InputContext, _ text: String) {
        store.recentCommittedTexts.append(text)
        context.commit(text)
        updateCandidates(&context, origin: "", page: 1, selectedIndex: 0)
    }
    
    func commitCandidate(_ context: inout any InputContext, _ candidate: Candidate, reason: CandidateCommitReason = .keyEvent) {
        store.recentCommittedTexts.append(candidate.text)
        context.commitCandidate(candidate, reason: reason)
        updateCandidates(&context, origin: "", page: 1, selectedIndex: 0)
    }
    
    func commitSelected(_ context: inout any InputContext, reason: CandidateCommitReason = .keyEvent) {
        if context.selectedIndex < context.candidates.count && context.candidates[context.selectedIndex].type != .placeholder {
            commitCandidate(&context, context.candidates[context.selectedIndex], reason: reason)
        }
    }
    
    @discardableResult
    func prevPage(_ context: inout any InputContext) -> Bool {
        guard context.curPage > 1 else { return false }
        updateCandidates(&context, page: context.curPage - 1, selectedIndex: 0)
        return true
    }
    @discardableResult
    func nextPage(_ context: inout any InputContext) -> Bool {
        guard context.hasNext else { return false }
        updateCandidates(&context, page: context.curPage + 1, selectedIndex: 0)
        return true
    }
    
    func selectPrev(_ context: inout any InputContext) {
        if context.selectedIndex > 0 {
            updateCandidates(&context, selectedIndex: context.selectedIndex - 1)
        } else if context.curPage > 1 {
            updateCandidates(&context, page: context.curPage - 1)
            context.selectedIndex = context.candidates.count - 1
        }
    }
    func selectNext(_ context: inout any InputContext) {
        if context.selectedIndex < context.candidates.count - 1 {
            updateCandidates(&context, selectedIndex: context.selectedIndex + 1)
        } else if context.hasNext {
            nextPage(&context)
        }
    }

    // MARK: - 子状态
    // 处理子状态
    private func subStateHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        guard self.subState != nil else { return nil }
        let subStateResult = self.subState!.handle(event, context: &context)
        switch subStateResult {
        case .stay(let result):
            return result
        case .exit(let result):
            setSubState(nil, context: &context)
            return result
        case .transition(let newState, let result):
            setSubState(newState, context: &context)
            return result
        }
    }
    
    // 是否进入子状态处理：临时英文、删除候选词、快速组词
    private func enterTempEnHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        if (!config.disableTempEnMode && store.inputMode == .zhhans && TempEnState.shouldEnter(event, context: context)) {
            setSubState(
                TempEnState(store: self.store, config: config, punctuationHandler: punctuationHandler),
                context: &context
            )
            return true
        }
        return nil
    }
    
    private func enterDeleteCandidateHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        if store.inputMode == .zhhans,
           let shortcut = config.deleteCandidateShortcut,
           DeleteCandidateState.shouldEnter(event, context: context, shortcut: shortcut) {
            let targetIndex = (InputShortcut.digitByKeyCode[event.keyCode] ?? 1) - 1
            setSubState(DeleteCandidateState(candidate: context.candidates[targetIndex], dict: self.dict), context: &context)
            return true
        }
        return nil
    }
    
    private func enterQuickCombineHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        if store.inputMode == .zhhans,
           let shortcut = config.quickCombineShortcut,
           shortcut.matches(event),
           context.origin.isEmpty {
            if store.recentCommittedTexts.count >= 2 {
                setSubState(QuickCombineState(count: 2, dict: self.dict, store: self.store), context: &context)
            } else {
                context.showMessage("请先输入至少两个字，再按 \(shortcut.displayLabel) 组词")
            }
            return true
        }
        return nil
    }
    
    // MARK: - 简单处理不再单独为英文输入模式开一个状态

    func flagsChangeHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        FireLog.input.debug("flagChangedHandler")
        // 只有在shift keyup时，才切换中英文输入, 否则会导致shift+[a-z]大写的功能失效
        if config.toggleInputModeKey != .disabled && event.type == .modifierPress && config.toggleInputModeKey.keyCodes().contains(Int(event.keyCode)) {
            let inputMode = store.inputMode
            FireLog.input.info("toggle mode: \(String(describing: inputMode), privacy: .public)")

            // 把当前未上屏的原始code上屏处理（原码为空时不必走提交/清理链）
            if !context.origin.isEmpty {
                commitText(&context, context.origin)
            }
            setSubState(nil, context: &context)

            engine.toggleInputMode()
            
            return true
        }
        // 监听.flagsChanged事件只为切换中英文，其它情况不处理需要返回 false 以避免快捷键不生效
        // 放行规则：先把 Shift / CapsLock 这类不属于"快捷键修饰键"的位剔除，再要求剩余位
        //   - 为空(无修饰键，如 a、,、.)，或
        //   - 恰好是 .numericPad|.function (方向键、用于翻页)
        // 其它情况（含 Cmd/Ctrl/Option/单独 .function 的 F 键、单独 .numericPad 的数字小键盘等）
        // 全部交给系统处理，避免无谓的 handler 链空跑(predictorHandler 会读 client 的 IPC 状态)。
        // Shift / CapsLock 必须放行的原因：
        //   - Shift+标点是常规中文标点输入路径(Shift+1=! 等)，需要继续走到 postCodingEngineHandler 的标点决策完成全角转换
        //   - Shift+字母由 charKeyHandler 处理(commit 0b51393 起，大写字母会被附加到原码而不直接上屏)
        // .deviceIndependentFlagsMask 用来过滤低位"设备相关"标志，避免极少数键盘场景下的脏数据误判。
        // 关联 issue #149 #152，回归源 commit 2d66064。
        FireLog.input.debug("flagChangeHandler, modifiers: \(String(describing: event.modifiers))")
        let modifiers = event.modifiers
            .subtracting([.shift, .capsLock])
        if event.type == .flagsChanged || (
            !modifiers.isEmpty
            && modifiers != .init(arrayLiteral: .numericPad, .function)
        ) {
            FireLog.input.debug("flagChangedHandler no need handle")
            return false
        }
        return nil
    }
    
    private func enModeHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        FireLog.input.debug("enModeHandler")
        // 英文输入模式, 不做任何处理
        if store.inputMode == .enUS {
            // issue #207 自愈：当前英文模式是被安全输入(SecureEventInput)强制切换的，
            // 且系统安全输入状态已消失（泄漏进程退出后无需注销即可恢复），
            // 此时切回中文，并让本次按键继续按中文流程处理
            if engine.secureEventEnforcedAt > engine.userToggledAt,
               !IsSecureEventInputEnabled() {
                FireLog.input.info("secure event ended, restore zhhans (issue #207)")
                engine.toggleInputMode(.zhhans)
                return nil
            }
            return false
        }
        return nil
    }
    
    // MARK: - 中文输入模式下的按键处理: 翻页键、删除键、字符键、数字键、esc键、enter键、space键
    private func pinCandidateHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        FireLog.input.debug("pinCandidateHandler")
        guard let shortcut = config.pinCandidateShortcut,
              shortcut.matches(event),
              let num = InputShortcut.digitByKeyCode[event.keyCode],
              num > 0, num <= context.candidates.count else {
            return nil
        }
        FireLog.input.debug("pinCandidate: \(shortcut.displayLabel) + \(num)")
        self.dict.setCandidateToFirst(context.origin, candidate: context.candidates[num - 1])
        updateCandidates(&context, page: 1, selectedIndex: 0)
        return true
    }
    
    private func pageKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        if context.origin.count > 0 {
            // 翻页
            if EngineUtils.isNextPageKey(event, config: config) {
                nextPage(&context)
                return true
            }

            if EngineUtils.isPrevPageKey(event, config: config) {
                prevPage(&context)
                return true
            }

            // 移动高亮
            if EngineUtils.isNextSelectKey(event, config: config) {
                selectNext(&context)
                return true
            }
            if EngineUtils.isPrevSelectKey(event, config: config){
                selectPrev(&context)
                return true
            }
        }
        return nil
    }
    
    private func predictorHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        // 原来**每次按键**都先调用 getTextBefore(1)（一次 selectedRange/markedRange
        // + attributedSubstring 的跨进程 IPC），哪怕这个键跟小数点/冒号毫无关系。
        // 先按开关和 keyCode 过滤，只有真正需要时才读前文。
        let wantsDot = config.enableDotAfterNumber && event.keyCode == kVK_ANSI_Period
        let wantsColon = config.enableColonAfterNumber && event.keyCode == kVK_ANSI_Semicolon
        guard wantsDot || wantsColon else { return nil }

        let textBefore = context.getTextBefore(1)
        guard let scalar = textBefore.unicodeScalars.last,
              scalar.value >= 48, scalar.value <= 57 else { return nil }

        if wantsDot {
            context.commit(".")
            return true
        }
        context.commit(":")
        return true
    }

    private func deleteKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        FireLog.input.debug("deleteKeyHandler: \(EngineUtils.isDeleteKey(event))")
        // 删除键删除字符
        if EngineUtils.isDeleteKey(event) {
            if context.origin.count > 0 {
                updateCandidates(&context, origin: String(context.origin.dropLast()), page: 1, selectedIndex: 0)
                return true
            }
            return false
        }
        return nil
    }
    
    private func zRepetKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        if context.origin.isEmpty && event.modifiers.isEmpty && event.keyCode == kVK_ANSI_Z {
            context.origin = "z"
            context.curPage = 1
            context.selectedIndex = 0
            context.hasNext = false
            var text = store.recentCommittedTexts.last ?? ""
            text = text == "" ? "业火输入法" : text
            context.candidates = [Candidate(code: "z", text: text, type: .user)]
            return true
        }
        return nil
    }
    
    @inline(__always)
    private static func isAsciiLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private func charKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        // 获取输入的字符
        guard let string = event.characters else { return nil }

        // 原实现每次字母键都跑一次 NSRegularExpression.firstMatch。
        // 编码只有 ASCII a-z/A-Z，直接按 UTF-8 字节判断，省掉正则引擎开销。
        let bytes = Array(string.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ Self.isAsciiLetter($0) }) else { return nil }
        let isUppercase = bytes.allSatisfy { $0 >= 65 && $0 <= 90 }

        // 输入大写字母，则自动 commit 首个候选词
        if isUppercase {
            if let first = context.candidates.first, first.type != .placeholder {
                commitSelected(&context, reason: .auto)
            }
            context.commit(string)
            return true
        }
        
        var origin = context.origin
        // 第五码顶字上屏：五笔方案下，当已有≥4码时，先上屏首选词，再以当前键开始新编码
        if config.wubiFifthCommit,
           config.codeMode == .wubi,
           context.origin.count >= 4,
           let firstCandidate = context.candidates.first,
           firstCandidate.type != .placeholder {
            commitCandidate(&context, firstCandidate, reason: .auto)
            // 第五码作为下个编码的首码
            origin = string
        } else {
            origin += string
        }
        
        updateCandidates(&context, origin: origin, page: 1, selectedIndex: 0)
        
        if config.wubiAutoCommit && context.curPage == 1 && context.candidates.count == 1 && context.origin.count >= 4,
           let candidate = context.candidates.first, candidate.type != .placeholder {
            // 满4码唯一候选词自动上屏
            commitCandidate(&context, candidate, reason: .auto)
        }

        return true
    }

    private func numberKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        // 获取输入的字符
        guard let char = event.characters else { return nil }
        // 当前输入的是数字,选择当前候选列表中的第N个字符 v
        if let pos = Int(char) {
            if context.origin.count > 0 {
                let index = pos - 1
                if index >= 0 && index < context.candidates.count {
                    commitCandidate(&context, context.candidates[index])
                } else {
                    updateCandidates(&context, origin: context.origin + char, page: 1, selectedIndex: 0)
                }
                return true
            }
            // 原码为空，输入数字，为了让中英文之间的空白配置生效，此处不要交给系统处理
            context.commit(char)
            return true
        }
        return nil
    }
    
    private func extraCandidateKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        guard context.origin.count > 0,
              let index = EngineUtils.extraCandidateIndex(for: event, config: config),
              index < context.candidates.count else {
            return nil
        }

        commitCandidate(&context, context.candidates[index])
        return true
    }

    private func escKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        // ESC键取消所有输入
        if EngineUtils.isEscapeKey(event), context.origin.count > 0 {
            updateCandidates(&context, origin: "", page: 1, selectedIndex: 0)
            return true
        }
        return nil
    }
    
    private func enterKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        // 回车键输入原字符
        if event.keyCode == kVK_Return && context.origin.count > 0 {
            commitText(&context, context.origin)
            return true
        }
        return nil
    }

    private func spaceKeyHandler(_ event: KeyInput, context: inout any InputContext) -> Bool? {
        FireLog.input.debug("spaceKeyHandler")
        if event.keyCode == kVK_Space && context.origin.count > 0 {
            if context.candidates.count > 0 {
                commitSelected(&context)
            } else {
                context.origin += " "
                updateCandidates(&context, origin: context.origin, page: 1, selectedIndex: 0)
            }
            return true
        }
        return nil
    }
    
    func punctuationKeyHandler(event: KeyInput, context: inout any InputContext) -> Bool? {
        FireLog.input.debug("punctuationKeyHandler")
        // 获取输入的字符
        guard let string = event.characters else { return nil }

        // 如果输入的字符是标点符号，转换标点符号为中文符号
        guard let result = punctuationHandler.handle(string, config: config) else { return nil }
        switch result {
        case .commit(let text):
            commitSelected(&context)
            context.commit(text)
            return true
        case .candidates(let list):
            commitSelected(&context)
            context.origin = string
            let candidates = list.map { Candidate(code: "", text: $0, type: .unknown) }
            setSubState(PunctuationCandidateState(candidates, config: config), context: &context)
            return true
        }
    }
    
    /// handler 链提为静态常量。原来每次按键都在栈上创建一个 18 元素的方法数组，
    /// 每个元素还要捕获 self；高频输入下这些临时对象都是实打实的分配。
    private static let codingHandlers: [(RootState, KeyInput, inout any InputContext) -> Bool?] = [
        { $0.subStateHandler($1, context: &$2) },

        { $0.enterTempEnHandler($1, context: &$2) },
        { $0.enterDeleteCandidateHandler($1, context: &$2) },
        { $0.enterQuickCombineHandler($1, context: &$2) },
        { $0.pinCandidateHandler($1, context: &$2) },

        { $0.flagsChangeHandler($1, context: &$2) },
        { $0.enModeHandler($1, context: &$2) },

        { $0.pageKeyHandler($1, context: &$2) },
        { $0.predictorHandler($1, context: &$2) },
        { $0.deleteKeyHandler($1, context: &$2) },
        { $0.zRepetKeyHandler($1, context: &$2) },
        { $0.charKeyHandler($1, context: &$2) },
        { $0.numberKeyHandler($1, context: &$2) },
        { $0.extraCandidateKeyHandler($1, context: &$2) },
        { $0.escKeyHandler($1, context: &$2) },
        { $0.enterKeyHandler($1, context: &$2) },
        { $0.spaceKeyHandler($1, context: &$2) },
        // 需要放在 extraCandidateKeyHandler 后面
        { $0.punctuationKeyHandler(event: $1, context: &$2) },
    ]

    func handle(_ event: KeyInput, context: inout any InputContext) -> HandleResult {
        for handler in Self.codingHandlers {
            if let result = handler(self, event, &context) {
                return .stay(result)
            }
        }
        return .stay(false)
    }
}
