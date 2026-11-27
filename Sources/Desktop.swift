import SwiftUI
import AppKit
import SQLite3

// Claude 桌面应用（Claude.app）的账号切换。
//
// 桌面端的登录就是两样东西：数据目录里 config.json 的三个键（oauth:tokenCache、oauth:tokenCacheV2、lastKnownAccountUuid）
// 加上网页登录用的 Cookies 文件。令牌是 Claude 自己加密过的密文，本程序整段复制，不解密、不联网。
// 每个账号的桌面端登录存在 ~/Library/Application Support/ClaudeAccountBar/desktop/<账号目录名>/ 下（权限 0600）。
// 只动登录：Claude 标签里的聊天和项目在服务器上，不碰；桌面端 Code 标签的对话列表同步以后再做。
//
// 几条不能破的规矩（在真机上试过、也经过审核）：
//  1. 改文件前必须让 Claude 正常退出并确认进程已经没了；退不掉就什么都不改，绝不强杀（强杀会丢掉还没写盘的登录）。
//  2. 切走一个账号之前，先把当前登录存回它自己名下（令牌会刷新，旧副本会过期）。
//  3. 恢复登录时，档案里没有的键要删掉，不然上一个账号遗留的旧令牌会留在新账号上。
//  4. 桌面端现在登录的账号不在 CCBaton 里时不切走，免得丢掉那个登录。
//  5. 改之前备份，写完核对，失败就回滚；备份只留一份，成功就删。

let desktopBundleId = "com.anthropic.claudefordesktop"
var desktopDataDir: String { home + "/Library/Application Support/Claude" }
var desktopProfilesRoot: String { supportDir + "/desktop" }
var desktopBackupDir: String { supportDir + "/desktop-backup" }
func desktopSlot(_ a: Account) -> String { desktopProfilesRoot + "/" + a.id }
let desktopAuthKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
let desktopCookieFiles = ["Cookies", "Cookies-journal"]

// MARK: - 文件

enum DesktopFiles {
    private static var fm: FileManager { .default }

    static func configPath(_ dir: String) -> String { dir + "/config.json" }

    /// 桌面端现在登录的账号标识；没登录（或读不到）是 nil
    static func activeUuid(_ dir: String = desktopDataDir) -> String? {
        guard let c = readProfile(configPath(dir)), c["oauth:tokenCacheV2"] != nil,
              let u = c["lastKnownAccountUuid"] as? String, !u.isEmpty else { return nil }
        return u
    }

    /// 档案里存的是哪个账号
    static func slotUuid(_ slot: String) -> String? {
        guard let c = readProfile(slot + "/config.json"), c["oauth:tokenCacheV2"] != nil else { return nil }
        return c["lastKnownAccountUuid"] as? String
    }

    private static func writeConfig(_ cfg: [String: Any], _ dir: String) throws {
        let path = configPath(dir)
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmp = path + ".cab-tmp"
        let perm = (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber) ?? NSNumber(value: 0o600)
        try data.write(to: URL(fileURLWithPath: tmp))
        try fm.setAttributes([.posixPermissions: perm], ofItemAtPath: tmp)
        if rename(tmp, path) != 0 { throw SwitchError("写入 \(path) 失败") }
    }

    /// 用 src 换掉 dst；src 不存在就把 dst 删掉（档案里没有这份文件，就该没有）
    private static func replaceFile(_ src: String, _ dst: String) throws {
        if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
        guard fm.fileExists(atPath: src) else { return }
        try fm.copyItem(atPath: src, toPath: dst)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst)
    }

    /// 把 dir 里当前的登录存进 slot。桌面端必须已经退出。先写到旁边的新目录再整体换上，不会留下半份。
    static func capture(from dir: String, to slot: String) throws {
        guard let c = readProfile(configPath(dir)) else { throw SwitchError("读不到桌面端的 config.json") }
        guard c["oauth:tokenCacheV2"] != nil, c["lastKnownAccountUuid"] != nil else { throw SwitchError("桌面端现在没有登录") }
        var saved: [String: Any] = [:]
        for k in desktopAuthKeys { if let v = c[k] { saved[k] = v } }
        let tmp = slot + ".new"
        try? fm.removeItem(atPath: tmp)
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let data = try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys])
            guard fm.createFile(atPath: tmp + "/config.json", contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw SwitchError("写入档案失败")
            }
            for f in desktopCookieFiles { try replaceFile(dir + "/" + f, tmp + "/" + f) }
            if fm.fileExists(atPath: slot) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: slot), withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try fm.createDirectory(atPath: (slot as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try fm.moveItem(atPath: tmp, toPath: slot)
            }
        } catch {
            try? fm.removeItem(atPath: tmp)
            throw error
        }
    }

    /// 把 slot 里的登录写回 dir：档案里有的键写入，没有的键删除；Cookies 同样。桌面端必须已经退出。
    static func restore(from slot: String, into dir: String, expecting uuid: String) throws {
        guard let saved = readProfile(slot + "/config.json"), saved["oauth:tokenCacheV2"] != nil else {
            throw SwitchError("这个账号还没有保存过桌面端登录")
        }
        guard saved["lastKnownAccountUuid"] as? String == uuid else { throw SwitchError("保存的桌面端登录不属于这个账号，没有改动") }
        guard var cfg = readProfile(configPath(dir)) else { throw SwitchError("读不到桌面端的 config.json") }
        for k in desktopAuthKeys {
            if let v = saved[k] { cfg[k] = v } else { cfg.removeValue(forKey: k) }
        }
        for f in desktopCookieFiles { try replaceFile(slot + "/" + f, dir + "/" + f) }
        try writeConfig(cfg, dir)
    }

    /// 清除本地的桌面端登录（不是退出登录，不会让令牌作废），桌面端重开会停在登录界面
    static func clearLogin(in dir: String) throws {
        guard var cfg = readProfile(configPath(dir)) else { throw SwitchError("读不到桌面端的 config.json") }
        for k in desktopAuthKeys { cfg.removeValue(forKey: k) }
        for f in desktopCookieFiles where fm.fileExists(atPath: dir + "/" + f) { try fm.removeItem(atPath: dir + "/" + f) }
        try writeConfig(cfg, dir)
    }

    // MARK: 备份和回滚

    static func backup(dir: String, to bdir: String) throws {
        try? fm.removeItem(atPath: bdir)
        try fm.createDirectory(atPath: bdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for f in ["config.json"] + desktopCookieFiles where fm.fileExists(atPath: dir + "/" + f) {
            try fm.copyItem(atPath: dir + "/" + f, toPath: bdir + "/" + f)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bdir + "/" + f)
        }
    }

    static func rollback(from bdir: String, into dir: String) throws {
        for f in desktopCookieFiles { try replaceFile(bdir + "/" + f, dir + "/" + f) }
        if fm.fileExists(atPath: bdir + "/config.json") {
            let data = try Data(contentsOf: URL(fileURLWithPath: bdir + "/config.json"))
            let tmp = configPath(dir) + ".cab-tmp"
            try data.write(to: URL(fileURLWithPath: tmp))
            if rename(tmp, configPath(dir)) != 0 { throw SwitchError("回滚 config.json 失败") }
        }
    }

    static func dropBackup(_ bdir: String) { try? fm.removeItem(atPath: bdir) }

    // MARK: Code 标签的对话列表

    struct SessionSync { var copied = 0; var refreshed = 0 }

    private static func subdirs(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    }
    private static func activity(_ path: String) -> Double? {
        guard let d = readProfile(path), d["sessionId"] != nil || d["cliSessionId"] != nil else { return nil }       // 不是对话记录的不要
        return (d["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0
    }

    /// 桌面端 Code 标签侧边栏的对话列表按账号分开存：claude-code-sessions/<账号>/<组织>/local_<id>.json。
    /// 对话内容本身在 ~/.claude/projects 里，所有账号共用；这里只把其他账号的列表记录补进这个账号的目录，
    /// 换号后侧边栏就还能看到。只补缺和刷新，**从不删除**；对话被删除时留下的 deleted_ 记号会被尊重（不再复制回来）。
    /// 桌面端必须已经退出。目录里没有这个账号（还没登录过）就什么都不做。
    @discardableResult
    static func syncSessions(into uuid: String, dir: String = desktopDataDir) throws -> SessionSync {
        let root = dir + "/claude-code-sessions"
        var result = SessionSync()
        guard fm.fileExists(atPath: root + "/" + uuid) else { return result }
        func mtime(_ p: String) -> Date { ((try? fm.attributesOfItem(atPath: p)[.modificationDate]) as? Date) ?? .distantPast }
        guard let target = subdirs(root + "/" + uuid).max(by: { mtime($0) < mtime($1) }) else { return result }
        let others = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0 != uuid }.flatMap { subdirs(root + "/" + $0) }
        // 被删除的对话：记号文件叫 deleted_<id>（扩展名不限）。任何一个账号的目录里有，就不再复制
        var deleted = Set<String>()
        for d in others + [target] {
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasPrefix("deleted_") {
                var id = String(f.dropFirst("deleted_".count))
                if let dot = id.lastIndex(of: "."), id.hasSuffix(".json") { id = String(id[..<dot]) }
                deleted.insert(id.hasPrefix("local_") ? String(id.dropFirst("local_".count)) : id)
            }
        }
        // 每个对话取各来源里最近活动的那份
        var best: [String: (path: String, at: Double)] = [:]
        for d in others {
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
                let id = String(f.dropFirst("local_".count).dropLast(".json".count))
                guard !deleted.contains(id), let at = activity(d + "/" + f) else { continue }
                if best[id] == nil || at > best[id]!.at { best[id] = (d + "/" + f, at) }
            }
        }
        for (id, src) in best.sorted(by: { $0.key < $1.key }) {
            let dst = target + "/local_" + id + ".json"
            let exists = fm.fileExists(atPath: dst)
            if exists { guard let have = activity(dst), src.at > have else { continue } }
            let tmp = dst + ".cab-tmp"
            try? fm.removeItem(atPath: tmp)
            try fm.copyItem(atPath: src.path, toPath: tmp)
            try? fm.setAttributes([.modificationDate: mtime(src.path)], ofItemAtPath: tmp)
            if rename(tmp, dst) != 0 { try? fm.removeItem(atPath: tmp); throw SwitchError("写入对话记录失败") }
            if exists { result.refreshed += 1 } else { result.copied += 1 }
        }
        return result
    }

    // MARK: Cookies 里有没有网页登录

    /// 登录用的 sessionKey 已经写进 Cookies 了吗？在副本上查（连同日志文件一起复制），只看名字，不碰值。
    static func hasSessionCookie(in dir: String) -> Bool {
        let tmp = NSTemporaryDirectory() + "ccb-ck-" + newLocalId()
        guard (try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return false }
        defer { try? fm.removeItem(atPath: tmp) }
        for f in desktopCookieFiles where fm.fileExists(atPath: dir + "/" + f) {
            try? fm.copyItem(atPath: dir + "/" + f, toPath: tmp + "/" + f)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp + "/Cookies", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM cookies WHERE name = 'sessionKey'", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW && sqlite3_column_int(st, 0) > 0
    }
}

// MARK: - 应用进程

enum DesktopApp {
    static func isRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleId).isEmpty }
    /// 主程序和它的辅助进程（渲染、网络等，包标识以主程序的开头）是不是都没了。写 Cookies 的可能是辅助进程，所以要等它们都退干净
    static func allGone() -> Bool {
        !NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "").hasPrefix(desktopBundleId) }
    }
    static func installed() -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleId) != nil }

    /// 让 Claude 正常退出并等进程消失。超时返回 false，不强杀。
    @MainActor static func quit(timeout: TimeInterval = 25) async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleId) { app.terminate() }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if allGone() { try? await Task.sleep(nanoseconds: 700_000_000); return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    static func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

// MARK: - 谁在用桌面端

enum DesktopOwner: Equatable {
    case none                   // 桌面端没登录
    case account(Account)       // 登录的是 CCBaton 里的这个账号
    case unknown(String)        // 登录的账号不在 CCBaton 里
    case ambiguous(String)      // CCBaton 里有几个账号对应它（同一个人的不同组织），分不清
}

enum DesktopAction { case hidden, busy, active, capture, switchTo, login }

struct DesktopMenuEntry: Identifiable, Equatable {
    let account: Account
    let title: String
    let enabled: Bool
    var id: String { account.id }
}

/// 小组件上的只读标记：桌面端正在用这个账号。dot 是头像右下角的小圆点，否则是名字后面的小图标。不能点
struct DesktopMark: View {
    @ObservedObject var model: Model
    let account: Account
    var dot = false
    var body: some View {
        if model.desktopAvailable, case .account(let o) = model.desktopOwnerState, o.id == account.id {
            if dot {
                Circle().fill(Color.indigo).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.8)).offset(x: 2, y: 2)
                    .help("Claude 桌面端正在用这个账号")
            } else {
                Image(systemName: "macwindow").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.indigo)
                    .help("Claude 桌面端正在用这个账号")
            }
        }
    }
}

struct DesktopFlow: Equatable {
    var text: String
    var cancellable = false
}

extension Model {
    /// 账号标识（桌面端的 lastKnownAccountUuid 对的就是它）
    func accountUuid(_ a: Account) -> String? {
        identity(ofDir: a.configDir)?.key.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init)
    }

    func ownerOfDesktop() -> DesktopOwner {
        guard let u = DesktopFiles.activeUuid() else { return .none }
        let hit = store.accounts.filter { accountUuid($0) == u }
        return hit.count == 1 ? .account(hit[0]) : (hit.isEmpty ? .unknown(u) : .ambiguous(u))
    }

    func reloadDesktop() {
        let fm = FileManager.default
        let there = fm.fileExists(atPath: desktopDataDir + "/config.json")
        desktopPresent = there && (testRoot != nil || DesktopApp.installed())
        desktopAvailable = desktopPresent && desktopOn
        // 总开关没打开：不读、不写桌面端的任何文件，界面里也不出现
        guard desktopAvailable else { desktopOwnerState = .none; desktopSaved = []; return }
        desktopOwnerState = ownerOfDesktop()
        desktopSaved = Set(store.accounts.filter { DesktopFiles.slotUuid(desktopSlot($0)) != nil }.map { $0.id })
    }

    /// 这个账号在桌面端的状态（不看有没有操作正在进行）
    func desktopStatus(for a: Account) -> DesktopAction {
        guard desktopAvailable, states[a.id]?.loggedIn == true else { return .hidden }
        let saved = desktopSaved.contains(a.id)
        if case .account(let o) = desktopOwnerState, o.id == a.id { return saved ? .active : .capture }
        return saved ? .switchTo : .login
    }

    /// 按钮现在能做什么：有桌面端操作或终端切换正在进行时一律是 busy（已在用的除外）
    func desktopAction(for a: Account) -> DesktopAction {
        let st = desktopStatus(for: a)
        if st == .hidden || st == .active { return st }
        return desktopFlow != nil || switching ? .busy : st
    }

    /// 右键菜单里「桌面端」子菜单的内容：每个登录有效的账号一项。总开关没打开时是空的
    func desktopMenuEntries() -> [DesktopMenuEntry] {
        guard desktopAvailable else { return [] }
        let busy = desktopFlow != nil || switching
        return store.accounts.compactMap { a in
            let name = shortDisplayName(a)
            switch desktopStatus(for: a) {
            case .active: return DesktopMenuEntry(account: a, title: "✓ \(name)（桌面端正在用）", enabled: false)
            case .capture: return DesktopMenuEntry(account: a, title: "\(name)：保存桌面端当前登录…", enabled: !busy)
            case .switchTo: return DesktopMenuEntry(account: a, title: "换到 \(name)", enabled: !busy)
            case .login: return DesktopMenuEntry(account: a, title: "\(name)：在桌面端登录一次…", enabled: !busy)
            default: return nil
            }
        }
    }

    func desktopButton(_ a: Account) {
        switch desktopAction(for: a) {
        case .switchTo: Task { await switchDesktop(to: a) }
        case .capture: Task { await captureDesktop(a) }
        case .login: Task { await loginDesktop(a) }
        default: break
        }
    }

    func cancelDesktopLogin() { desktopCancel = true }

    // MARK: 共用步骤

    /// 退出 Claude，再把现在的桌面登录存回它自己名下。抛出错误时什么都没改（Claude 可能已经退出，调用方负责重新打开）。
    /// wasRunning 是 inout：弹确认窗期间用户可能打开了 Claude，所以动手前再查一次，并把结果带回调用方（出错时据此决定要不要重新打开）
    private func quitAndKeepCurrent(wasRunning: inout Bool) async throws {
        wasRunning = wasRunning || desktopIsRunning()
        if desktopIsRunning(), !(await desktopQuit()) {
            throw SwitchError("Claude 没有退出（可能弹出了确认窗口，或有没保存的内容），没有改动。处理好以后再试")
        }
        switch ownerOfDesktop() {
        case .none: break
        case .account(let o): try DesktopFiles.capture(from: desktopDataDir, to: desktopSlot(o))
        case .unknown:
            throw SwitchError("桌面端现在登录的账号不在 CCBaton 里，换走会丢掉这个登录。请先把它添加成账号（在终端里用它登录一次 Claude Code），没有改动")
        case .ambiguous:
            throw SwitchError("CCBaton 里有几个账号对应桌面端现在的登录（同一个人的不同组织），分不清该存到哪个，没有改动")
        }
    }

    /// 写入这个账号的桌面登录：先备份，写完核对，不对就回滚
    private func restoreDesktop(_ a: Account, uuid: String) throws {
        try DesktopFiles.backup(dir: desktopDataDir, to: desktopBackupDir)
        do {
            try DesktopFiles.restore(from: desktopSlot(a), into: desktopDataDir, expecting: uuid)
            guard DesktopFiles.activeUuid() == uuid else { throw SwitchError("写入后核对不一致") }
        } catch {
            try? DesktopFiles.rollback(from: desktopBackupDir, into: desktopDataDir)
            DesktopFiles.dropBackup(desktopBackupDir)
            throw error
        }
        DesktopFiles.dropBackup(desktopBackupDir)
    }

    /// 补上其他账号的对话列表；失败不影响切换，只在提示里说一声
    private func syncSessionsNote(_ uuid: String) -> String {
        guard desktopSyncOn else { return "" }          // 子开关没打开：各账号的对话列表各管各的，一个都不复制
        do {
            let r = try DesktopFiles.syncSessions(into: uuid)
            return r.copied + r.refreshed > 0 ? "，补上了其他账号的 \(r.copied + r.refreshed) 个对话" : ""
        } catch { return "（对话列表没能同步：\(error)）" }
    }

    private func finish(_ message: String, ok: Bool) {
        desktopFlow = nil
        desktopCancel = false
        reloadStates()
        notice = message
        showToast(ok ? message : "桌面端操作没有完成")
    }

    // MARK: 切换到已保存桌面登录的账号

    func switchDesktop(to a: Account) async {
        guard desktopAvailable, desktopFlow == nil, !switching, desktopSaved.contains(a.id), let uuid = accountUuid(a) else { return }
        let name = shortDisplayName(a)
        var running = desktopIsRunning()
        desktopFlow = DesktopFlow(text: "等待确认…")             // 先占住，确认窗开着时别的点击不能再开一个流程
        if running, !confirmDesktop("把 Claude 桌面端换成「\(name)」", "需要先退出 Claude 再重新打开，正在进行的对话会被打断。") { desktopFlow = nil; return }
        desktopFlow = DesktopFlow(text: "正在把桌面端换成「\(name)」…")
        do {
            try await quitAndKeepCurrent(wasRunning: &running)
            try restoreDesktop(a, uuid: uuid)
            let synced = syncSessionsNote(uuid)
            if running { desktopLaunch() }
            finish((running ? "桌面端已换成「\(name)」" : "桌面端已换成「\(name)」，下次打开 Claude 就是它") + synced, ok: true)
        } catch {
            if running, !desktopIsRunning() { desktopLaunch() }
            finish("桌面端没有切换：\(error)", ok: false)
        }
    }

    // MARK: 收录当前的桌面登录（它已经是这个账号，只是还没保存）

    func captureDesktop(_ a: Account) async {
        guard desktopAvailable, desktopFlow == nil, !switching, case .account(let o) = desktopOwnerState, o.id == a.id, let uuid = accountUuid(a) else { return }
        let name = shortDisplayName(a)
        var running = desktopIsRunning()
        desktopFlow = DesktopFlow(text: "等待确认…")
        if running, !confirmDesktop("保存「\(name)」的桌面端登录", "需要短暂退出 Claude 再重新打开（保存时文件必须是完整的）。") { desktopFlow = nil; return }
        desktopFlow = DesktopFlow(text: "正在保存「\(name)」的桌面端登录…")
        do {
            try await quitAndKeepCurrent(wasRunning: &running)       // 这一步已经把它存进了它自己名下
            let synced = syncSessionsNote(uuid)
            if running { desktopLaunch() }
            finish("已保存「\(name)」的桌面端登录，之后可以一键切换" + synced, ok: true)
        } catch {
            if running, !desktopIsRunning() { desktopLaunch() }
            finish("没有保存：\(error)", ok: false)
        }
    }

    // MARK: 在桌面端登录一次，存给这个账号

    func loginDesktop(_ a: Account) async {
        guard desktopAvailable, desktopFlow == nil, !switching, accountUuid(a) != nil else { return }
        let name = shortDisplayName(a)
        let email = states[a.id]?.email ?? ""
        var running = desktopIsRunning()
        let msg = "会先退出 Claude，把现在登录的账号保存起来，然后打开登录界面。请用" + (email.isEmpty ? "这个账号" : " \(email) ") + "登录。\n\n登录好以后 CCBaton 会自动核对是不是这个账号并保存。保存时 Claude 会自动退出再重开一次，这是正常的（文件必须是完整的才能保存），请不要在这期间操作 Claude。"
        desktopFlow = DesktopFlow(text: "等待确认…")
        if !confirmDesktop("在桌面端登录「\(name)」", msg) { desktopFlow = nil; return }
        desktopFlow = DesktopFlow(text: "正在准备…")
        let previous: Account?
        do {
            try await quitAndKeepCurrent(wasRunning: &running)
            if case .account(let o) = ownerOfDesktop() { previous = o } else { previous = nil }
            try DesktopFiles.backup(dir: desktopDataDir, to: desktopBackupDir)
            do { try DesktopFiles.clearLogin(in: desktopDataDir) } catch {
                try? DesktopFiles.rollback(from: desktopBackupDir, into: desktopDataDir)
                DesktopFiles.dropBackup(desktopBackupDir)
                throw error
            }
            DesktopFiles.dropBackup(desktopBackupDir)
            desktopLaunch()
        } catch {
            if running, !desktopIsRunning() { desktopLaunch() }
            finish("没有开始：\(error)", ok: false)
            return
        }

        // 等你在桌面端登录。不设超时：你可能正在收验证码；想放弃就点"取消并恢复"
        desktopCancel = false
        desktopFlow = DesktopFlow(text: "请在桌面端登录" + (email.isEmpty ? "「\(name)」" : " \(email)"), cancellable: true)
        var seen: String?
        while !desktopCancel {
            if let u = DesktopFiles.activeUuid() { seen = u; break }
            try? await Task.sleep(nanoseconds: UInt64(desktopPollInterval * 1_000_000_000))
        }
        guard let uuid = seen else { await undoDesktopLogin(previous: previous, wasRunning: running); return }

        // 看到登录了，先等网页登录的 cookie 写进文件（最多约 90 秒），再让 Claude 退出、保存
        desktopFlow = DesktopFlow(text: "登录成功。接下来 Claude 会自动退出再重开一次，用来保存登录，请稍等…")
        var waited = 0.0
        while !DesktopFiles.hasSessionCookie(in: desktopDataDir), waited < desktopCookieWait {
            try? await Task.sleep(nanoseconds: UInt64(desktopPollInterval * 1_000_000_000))
            waited += desktopPollInterval
        }
        let hit = store.accounts.filter { accountUuid($0) == uuid }
        var owner: Account? = hit.count == 1 ? hit[0] : nil
        if let o = owner, o.id != a.id {
            let other = shortDisplayName(o)
            if !confirmDesktop("登录的是「\(other)」，不是「\(name)」", "要把这个登录保存到「\(other)」名下吗？选「取消」则不保存（桌面端会停在这个登录上）。") { owner = nil }
        } else if owner == nil {
            tellUser("没有保存", hit.isEmpty ? "你登录的账号不在 CCBaton 里，请先添加这个账号（在终端里用它登录一次 Claude Code）。桌面端先停在这个登录上。" : "CCBaton 里有几个账号对应你登录的账号（同一个人的不同组织），分不清该存到哪个，没有保存。")
        }
        guard let save = owner else { finish("没有保存桌面端登录", ok: false); return }
        do {
            if !(await desktopQuit()) { throw SwitchError("Claude 没有退出，没有保存（登录还在桌面端里，之后点「保存」再试）") }
            try DesktopFiles.capture(from: desktopDataDir, to: desktopSlot(save))
            let synced = accountUuid(save).map { syncSessionsNote($0) } ?? ""
            desktopLaunch()
            let complete = DesktopFiles.hasSessionCookie(in: desktopSlot(save))
            finish("已保存「\(shortDisplayName(save))」的桌面端登录，之后可以一键切换" + synced + (complete ? "" : "。注意：网页登录状态没有保存完整，切过去时可能要重新登录一次"), ok: true)
        } catch {
            if !desktopIsRunning() { desktopLaunch() }
            finish("没有保存：\(error)", ok: false)
        }
    }

    /// 取消登录：把原来的账号恢复回去
    private func undoDesktopLogin(previous: Account?, wasRunning: Bool) async {
        desktopFlow = DesktopFlow(text: "正在恢复原来的登录…")
        do {
            if desktopIsRunning(), !(await desktopQuit()) { throw SwitchError("Claude 没有退出，没有恢复") }
            if let p = previous, let uuid = accountUuid(p) { try restoreDesktop(p, uuid: uuid) }
            if wasRunning { desktopLaunch() }
            finish(previous.map { "已取消，桌面端恢复为「\(shortDisplayName($0))」" } ?? "已取消", ok: true)
        } catch {
            if wasRunning, !desktopIsRunning() { desktopLaunch() }
            finish("取消时出了问题：\(error)", ok: false)
        }
    }

    /// 启动时：改动途中被打断（崩溃、断电）会留下备份——成功的操作会立刻删掉它。
    /// Claude 没开着就回滚到改动之前（那是一个完整一致的状态）；开着的话不能动文件，只删备份并提示。
    func recoverDesktop() {
        guard FileManager.default.fileExists(atPath: desktopBackupDir) else { return }
        if desktopIsRunning() {
            DesktopFiles.dropBackup(desktopBackupDir)
            notice = "上次改桌面端登录时被打断了。Claude 正开着，没有自动处理；如果桌面端登录不对，用卡片上的按钮重新切换或登录一次"
            return
        }
        do {
            try DesktopFiles.rollback(from: desktopBackupDir, into: desktopDataDir)
            DesktopFiles.dropBackup(desktopBackupDir)
            notice = "上次改桌面端登录时被打断了，已恢复到改动之前"
        } catch {
            notice = "上次改桌面端登录时被打断了，自动恢复失败：\(error)。备份留在 \(desktopBackupDir)"
        }
    }

    /// 账号移除时，连同它保存的桌面端登录一起删掉
    func forgetDesktopLogin(_ a: Account) {
        try? FileManager.default.removeItem(atPath: desktopSlot(a))
        reloadDesktop()
    }
}
