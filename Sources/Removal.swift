import SwiftUI
import AppKit

// 移除账号 = 彻底移除，不分来源（添加的、cc-switch 导入的都一样）：
//   钥匙串里它的登录（正式的一份、两处备份副本、"完全独立"终端那份）删掉，账号文件夹移到废纸篓，
//   cc-switch 账号清单里它那一条也去掉（改之前先备份清单）。cc-switch 的数据库不动。
// 账号目录里的对话记录、技能等是链接到 ~/.claude 的，移走链接不影响原件。

/// 确认框里写什么
struct RemovalPrompt: Equatable {
    let title: String
    let message: String
    let button: String
}

/// 移到废纸篓。沙盒测试放进沙盒自己的废纸篓，不碰真的
func moveToTrash(_ path: String) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return }
    if testRoot != nil {
        let bin = home + "/.Trash"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try fm.moveItem(atPath: path, toPath: bin + "/" + newLocalId())
    } else {
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}

/// cc-switch 的账号清单里去掉指向这个目录的那一条。改之前把原清单备份到本程序的目录里。
/// 没有清单、看不懂清单、或里面本来就没有它，都什么也不做。
func forgetInCCSwitch(_ configDir: String) throws {
    let fm = FileManager.default, path = ccSwitchRoot + "/claude_accounts.json"
    guard let data = fm.contents(atPath: path), var doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          var accounts = doc["accounts"] as? [String: Any] else { return }
    let localId = ((configDir as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let gone = accounts.filter { ($0.value as? [String: Any])?["localId"] as? String == localId }.map { $0.key }
    guard !gone.isEmpty else { return }
    gone.forEach { accounts[$0] = nil }
    doc["accounts"] = accounts

    let backups = supportDir + "/backups"
    try fm.createDirectory(atPath: backups, withIntermediateDirectories: true)
    let backup = "\(backups)/cc-switch-claude_accounts-\(Int(Date().timeIntervalSince1970))-\(newLocalId().prefix(4)).json"
    try data.write(to: URL(fileURLWithPath: backup))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup)

    let out = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let tmp = path + ".cab-tmp"
    try out.write(to: URL(fileURLWithPath: tmp))
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
    if rename(tmp, path) != 0 { throw SwitchError("改不了旧的账号清单") }
}

/// 确认框。取消键是 Esc。删东西的那种（destructive）不给确认按钮回车快捷键，免得顺手一敲就删了
@MainActor
func removalAlert(_ p: RemovalPrompt, destructive: Bool = true) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = destructive ? .critical : .informational
    alert.messageText = p.title
    alert.informativeText = p.message
    let go = alert.addButton(withTitle: p.button)
    if destructive { go.hasDestructiveAction = true; go.keyEquivalent = "" }
    alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
    return alert
}

extension Model {
    func isFromCCSwitch(_ a: Account) -> Bool {
        (a.configDir as NSString).standardizingPath.hasPrefix((ccSwitchRoot as NSString).standardizingPath + "/")
    }

    /// 列表里还有别的条目用着同一个账号目录：那这份登录和文件不能删
    func sharesFolder(_ a: Account) -> Bool { store.accounts.contains { $0.id != a.id && $0.configDir == a.configDir } }

    /// 账号在磁盘上的文件夹。只认两个地方：本程序的账号目录和 cc-switch 的账号目录；别的位置一律不动
    func accountFolder(_ a: Account) -> String? {
        let dir = (a.configDir as NSString).standardizingPath
        let folder = (dir as NSString).deletingLastPathComponent
        let roots = [supportDir + "/accounts", ccSwitchRoot + "/claude-accounts"].map { ($0 as NSString).standardizingPath }
        guard (dir as NSString).lastPathComponent == "config", roots.contains((folder as NSString).deletingLastPathComponent) else { return nil }
        return folder
    }

    /// 本程序为它单独建的"完全独立"终端目录
    private func terminalFolder(_ a: Account) -> String? {
        guard !a.id.isEmpty, !a.id.contains("/"), !a.id.contains("..") else { return nil }
        let folder = "\(supportDir)/terminals/\(a.id)"
        return FileManager.default.fileExists(atPath: folder) ? folder : nil
    }

    /// 这个账号现在能不能移除；不能就返回原因
    func removalBlocker(_ a: Account) -> String? {
        guard states[a.id]?.live == true else { return nil }
        // 同一个号在列表里有两条时，去掉多余的那条不影响正在用的登录
        if let key = identity(ofDir: a.configDir)?.key,
           store.accounts.contains(where: { $0.id != a.id && identity(ofDir: $0.configDir)?.key == key }) { return nil }
        return "使用中的账号不能移除，先切换到别的账号"
    }

    /// 程序正在对账号做事时先别删：claude 还在跑的话，可能把刚删掉的登录又写回来
    var removalBusy: String? {
        if switching { return "正在切换账号，几秒后再试" }
        if warming != nil { return "正在预热账号，几秒后再试" }
        if refreshing { return "正在读取额度，几秒后再试" }
        return nil
    }

    func removalPrompt(_ a: Account, terminals: [RunningTerminal]) -> RemovalPrompt {
        let name = shortDisplayName(a)
        if sharesFolder(a) {
            return RemovalPrompt(title: "从列表移除「\(name)」？", message: "另一个条目还在用同一份登录，这次只把它从列表里去掉，不删登录和文件。", button: "移除")
        }
        let ccSwitch = isFromCCSwitch(a) && ccSwitchInstalled()      // 没装 cc-switch 就不提它
        var lines = [accountFolder(a) != nil ? "这台 Mac 上它的登录会被删除（无法撤销），账号文件夹移到废纸篓。"
                         : "这台 Mac 上它的登录会被删除（无法撤销）。它的文件夹不在账号目录里，保留不动。",
                     ccSwitch ? "这份登录是和 cc-switch 共用的，移除后 cc-switch 里也会失效。以后在 CCBaton、cc-switch 或终端里再用这个账号，都要重新登录。"
                         : "以后想再用它（CCBaton、终端），需要重新登录。"]
        let off = terminals.filter { $0.accountId == a.id && $0.mode != .live }.count
        if off > 0 { lines.append("有 \(off) 个用它开着的终端会掉线。") }
        if ccSwitch && ccSwitchRunning() { lines.append("检测到 cc-switch 正在运行，建议先退出它再移除。") }
        lines.append("不受影响：Claude 账号和订阅、对话记录、Claude 设置。")
        return RemovalPrompt(title: "彻底移除「\(name)」？", message: lines.joined(separator: "\n\n"), button: "彻底移除")
    }

    /// 切换前的整份备份（钥匙串里只有一份）里存的是不是这个账号
    private func backupBelongs(_ a: Account, _ keychain: KeychainStore) -> Bool {
        guard let backup = keychain.readBackup() else { return false }
        for slot in [Slot.account(a.configDir), backupSlot(a.configDir)] {
            if let s = (try? keychain.read(slot)) ?? nil, hasLogin(s), accountFingerprint(s) == accountFingerprint(backup) { return true }
        }
        // 令牌可能续过期、指纹对不上：看切换时记下的备份主人
        guard let key = identity(ofDir: a.configDir)?.key else { return false }
        if let owner = keychain.backupOwner() { return owner == key }
        // 旧版本留下的备份没有记录，只能按组织认。同一个组织（Team）里还有别的账号时认不准，留着不删
        guard let org = backup["organizationUuid"] as? String, !org.isEmpty, key.hasSuffix(":" + org) else { return false }
        return !store.accounts.contains { other in
            guard other.id != a.id, let k = identity(ofDir: other.configDir)?.key else { return false }
            return k != key && k.hasSuffix(":" + org)
        }
    }

    /// 真正动手（不再询问）。成功返回 nil，失败返回原因，账号留在列表里
    func removeAccount(_ a: Account) -> String? {
        if let why = removalBlocker(a) ?? removalBusy { return why }
        guard store.accounts.contains(where: { $0.id == a.id }) else { return nil }
        let keychain = KeychainStore()
        let shared = sharesFolder(a)
        do {
            // 改清单有备份、能还原，放最前面：改不了就整个取消，什么都还没删
            if !shared && isFromCCSwitch(a) { try forgetInCCSwitch(a.configDir) }
            if let folder = terminalFolder(a) {
                try keychain.delete(.account(terminalDir(a)))
                try moveToTrash(folder)
            }
            if !shared {
                if backupBelongs(a, keychain) { keychain.deleteBackup() }
                // 先删钥匙串（可能失败，比如钥匙串锁着），成功了才挪文件夹
                try keychain.delete(.account(a.configDir))
                try keychain.delete(backupSlot(a.configDir))
                if let folder = accountFolder(a) { try moveToTrash(folder) }
            }
        } catch { return "移除失败：\(error)" }
        fillColorSlots()                    // 剩下的账号颜色保持不变
        store.accounts.removeAll { $0.id == a.id }
        store.warmupRecords?[a.id] = nil
        store.terminalPrefs?[a.id] = nil
        store.terminalKept?[a.id] = nil
        warmupHolds[a.id] = nil
        lastRun[a.id] = nil
        states[a.id] = nil
        save()
        return nil
    }

    /// 右键菜单和编辑窗口都走这里：先弹警告，确认了才动手。返回是否真的移除了
    @discardableResult
    func requestRemoval(_ a: Account) -> Bool {
        if let why = removalBlocker(a) ?? removalBusy { tellUser("现在不能移除", why); return false }
        let prompt = removalPrompt(a, terminals: runningTerminals())
        guard confirmRemoval(prompt) else { return false }
        let name = shortDisplayName(a)
        if let why = removeAccount(a) { tellUser("没有移除「\(name)」", why); return false }
        AccountEditor.shared.window?.close()
        TerminalController.shared.window?.close()
        notice = "已移除「\(name)」"
        return true
    }
}
