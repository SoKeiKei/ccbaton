import SwiftUI
import AppKit

// 把 cc-switch 导入的账号搬进 CCBaton 自己的目录，之后不再依赖 ~/.cc-switch，也不用重新登录。
// 界面上只在需要时提 cc-switch：没装它、或账号已经迁完，就不出现相关内容。
// 钥匙串条目的名字由目录路径算出来，所以搬目录必须连登录一起搬。顺序：
//   1. 记日志，复制账号目录、复制登录到新位置并读回核对（旧的一点不动，任何一步失败就撤掉复制品）
//   2. 提交点：账号列表改指新位置并确认写进了磁盘
//   3. 清掉旧的：旧钥匙串条目、cc-switch 清单里的那一条、旧文件夹（进废纸篓）
// 中途崩溃或断电，下次启动按日志收尾（已提交就清旧的，没提交就撤新的）。

struct MigrationJournal: Codable, Equatable {
    var from: String        // 旧的账号目录
    var to: String          // 新的账号目录
}
let migrationJournalURL = URL(fileURLWithPath: supportDir + "/migrate-journal.json")

func saveMigrationJournal(_ j: MigrationJournal?) throws {
    guard let j else { try? FileManager.default.removeItem(at: migrationJournalURL); return }
    try FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    try JSONEncoder().encode(j).write(to: migrationJournalURL, options: .atomic)
}
func loadMigrationJournal() -> MigrationJournal? {
    (try? Data(contentsOf: migrationJournalURL)).flatMap { try? JSONDecoder().decode(MigrationJournal.self, from: $0) }
}

/// 现在有几个运行中的程序把这些目录当账号目录用（比如别的工具开的 claude）
func processesUsing(_ dirs: [String]) -> Int {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Axww", "-E", "-o", "command="]          // -E：带上环境变量
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return 0 }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text.split(separator: "\n").filter { line in
        let padded = line + " "
        return dirs.contains { padded.contains("CLAUDE_CONFIG_DIR=\($0) ") || padded.contains("CLAUDE_CONFIG_DIR=\($0)/ ") }
    }.count
}

/// 复制出来的账号目录里，和默认位置共用的内容改成链接到 ~/.claude（和"添加账号"建的目录一样）。
/// cc-switch 放的设置副本改名留底。
func relinkSharedItems(_ dir: String) throws {
    let fm = FileManager.default
    for name in [".oauth_refresh.lock", ".storage-write.lock", ".claude.json.lock"] { try? fm.removeItem(atPath: dir + "/" + name) }
    for name in sharedItems {
        let path = dir + "/" + name, shared = home + "/.claude/" + name
        guard fm.fileExists(atPath: shared) else { continue }     // 默认位置没有的，保留原样
        if let target = try? fm.destinationOfSymbolicLink(atPath: path) {
            if target.hasPrefix(ccSwitchRoot + "/") { try fm.removeItem(atPath: path) }
        } else if name == "settings.json" || name == "CLAUDE.md", fm.fileExists(atPath: path) {
            try fm.moveItem(atPath: path, toPath: path + ".from-cc-switch")
        }
    }
    try prepareAccountDir(dir)      // 缺的链接补上
}

extension Model {
    /// 还放在 cc-switch 目录里的账号
    var migratable: [Account] { store.accounts.filter { isFromCCSwitch($0) && accountFolder($0) != nil } }

    /// cc-switch 里登记着、还没加进列表的账号（和 importCCSwitch 的跳过规则一致）
    var importableAccounts: [String] {
        var known = Set(store.accounts.compactMap { identity(ofDir: $0.configDir)?.key })
        return ccSwitchAccounts().map { $0.1 }.filter { dir in
            guard !store.accounts.contains(where: { $0.configDir == dir }), let key = identity(ofDir: dir)?.key else { return false }
            return known.insert(key).inserted
        }
    }

    /// 设置里出不出现"导入"：装着 cc-switch，而且确实有可导入的账号
    var offersImport: Bool { ccSwitchInstalled() && !importableAccounts.isEmpty }

    /// 设置里迁移那一块写什么。没装 cc-switch、或者已经迁完，就不提它
    func migrationTexts(installed: Bool) -> (title: String, line: String, note: String) {
        let n = migratable.count
        let title = "账号文件位置"
        if n == 0 { return (title, "账号文件都在 CCBaton 里了", "") }
        let note = "搬到 CCBaton 自己的目录，不用重新登录。"
        return installed ? (title, "\(n) 个账号的文件在 cc-switch 目录里", note + "迁移前请退出 cc-switch。")
                         : (title, "\(n) 个账号的文件还在旧目录里", note)
    }

    /// 现在为什么不能迁移；能迁返回 nil
    func migrationBlocker(terminals: [RunningTerminal]) -> String? {
        if let busy = removalBusy { return busy }
        let list = migratable
        if ccSwitchRunning() { return "请先退出 cc-switch（点它的菜单栏图标选退出），再来迁移。两个程序同时动登录会出错。" }
        let open = terminals.filter { t in t.mode == .shared && list.contains { $0.id == t.accountId } }.count
        if open > 0 { return "有 \(open) 个终端正在用要迁移的账号，先关掉它们。" }
        if processUsingDirs(list.map { $0.configDir }) > 0 { return "有正在运行的程序在用这些账号的旧目录（多半是别处打开的 claude），先关掉它。" }
        if let j = loadJournal(), j.step == "committed", list.contains(where: { $0.configDir == j.targetDir }) {
            return "上一次账号切换还没收尾，退出 CCBaton 再打开一次，然后迁移。"
        }
        return nil
    }

    var migrationPrompt: RemovalPrompt {
        RemovalPrompt(title: "把 \(migratable.count) 个账号迁移到 CCBaton？", message: [
            "把这些 Claude 账号的登录和文件搬到 CCBaton 自己的目录，不用重新登录。",
            (ccSwitchInstalled() ? "迁移后 cc-switch 里不再显示这些账号。" : "") + "原来的文件夹移到废纸篓。",
            "账号目录里原有的设置副本（settings.json、CLAUDE.md）改名留底，改用你的默认设置（~/.claude）。在某个账号里单独改过的设置（比如默认模型）会变回默认的。",
        ].joined(separator: "\n\n"), button: "迁移")
    }

    /// 写盘并确认写进去了。搬账号时不能用"写失败也无所谓"的 save()
    private func saveOrThrow() throws {
        guard !Model.readOnly else { throw SwitchError("只读模式下不能迁移") }
        fillColorSlots()
        try JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }

    /// 撤掉复制出来的东西。只动本程序账号目录里的
    private func discardCopy(_ to: String) {
        guard accountFolder(Account(id: "", label: "", configDir: to)) != nil, to.hasPrefix(supportDir + "/accounts/"),
              !store.accounts.contains(where: { $0.configDir == to }) else { return }
        let keychain = KeychainStore()
        try? keychain.delete(.account(to))
        try? keychain.delete(backupSlot(to))
        try? FileManager.default.removeItem(atPath: (to as NSString).deletingLastPathComponent)
    }

    /// 提交之后清掉旧的。返回没清干净的地方；全清掉了才删日志（没删的下次启动接着清）
    private func cleanUpOld(_ j: MigrationJournal) -> [String] {
        let keychain = KeychainStore()
        var left: [String] = []
        // 同一份登录只留一份：旧位置的先删
        do { try keychain.delete(.account(j.from)); try keychain.delete(backupSlot(j.from)) }
        catch { left.append("旧位置的钥匙串条目没删掉（\(error)）") }
        do { try forgetInCCSwitch(j.from) } catch { left.append("旧的账号清单没改成（\(error)）") }
        let folder = (j.from as NSString).deletingLastPathComponent
        if folder.hasPrefix(ccSwitchRoot + "/claude-accounts/") {
            do { try moveToTrash(folder) } catch { left.append("旧文件夹没移走：\(folder)") }
        }
        if left.isEmpty { try? saveMigrationJournal(nil) }
        return left
    }

    /// 搬一个账号。失败就抛错，旧的原样不动；成功返回没清干净的地方（一般为空）
    func migrateAccount(_ a: Account) throws -> [String] {
        let fm = FileManager.default, keychain = KeychainStore()
        let old = a.configDir
        guard let owner = identity(ofDir: old) else { throw SwitchError("读不到它的账号资料") }
        var folder = "\(supportDir)/accounts/\(a.id)"
        if fm.fileExists(atPath: folder) { folder = "\(supportDir)/accounts/\(newLocalId())" }
        let new = folder + "/config"

        // 挡住 Claude Code 在我们复制期间刷新或改写登录
        let refresh = try RefreshLocks(.account(old))
        defer { refresh.a.release(); refresh.b.release() }
        let writing = try storageLock(.account(old))
        defer { writing.release() }

        let login = try keychain.read(.account(old))
        let spare = try keychain.read(backupSlot(old))

        let journal = MigrationJournal(from: old, to: new)
        try saveMigrationJournal(journal)
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try fm.copyItem(atPath: old, toPath: new)                 // 链接按链接复制，不会把指向的内容拷进来
            try relinkSharedItems(new)
            if let login { try writeVerified(keychain, .account(new), login, failed: "登录搬到新位置后读回不一致") }
            if let spare {
                try fm.createDirectory(atPath: new + ".prev", withIntermediateDirectories: true)
                try writeVerified(keychain, backupSlot(new), spare, failed: "备份副本搬到新位置后读回不一致")
            }
            guard identity(ofDir: new)?.key == owner.key else { throw SwitchError("复制出来的账号资料对不上") }

            // 提交点
            let before = store.accounts
            for i in store.accounts.indices where store.accounts[i].configDir == old { store.accounts[i].configDir = new }
            do { try saveOrThrow() } catch { store.accounts = before; throw SwitchError("账号列表写不进磁盘") }
        } catch {
            discardCopy(new)
            try? saveMigrationJournal(nil)
            throw error
        }
        return cleanUpOld(journal)
    }

    /// 上次迁移被打断：按账号列表现在指向哪边来收尾
    func recoverMigration() {
        guard let j = loadMigrationJournal() else { return }
        if store.accounts.contains(where: { $0.configDir == j.to }) { _ = cleanUpOld(j); return }
        guard j.to.hasPrefix(supportDir + "/accounts/") else { try? saveMigrationJournal(nil); return }    // 记的路径不对，作废
        // 只有旧的那份确实还完好，才撤掉复制品。拿不准（比如账号列表读坏了）就两边都留着
        let keychain = KeychainStore()
        guard FileManager.default.fileExists(atPath: j.from + "/.claude.json"),
              keychain.exists(.account(j.from)) || !keychain.exists(.account(j.to)) else { return }
        discardCopy(j.to)
        try? saveMigrationJournal(nil)
    }

    /// 把能迁的都迁了（不再询问）。一个失败就停下，已经迁好的保留
    func migrateAll() -> (moved: Int, problem: String?) {
        if let why = migrationBlocker(terminals: runningTerminals()) { return (0, why) }
        var done = 0, left: [String] = [], seen: Set<String> = []
        for a in migratable where !seen.contains(a.configDir) {
            seen.insert(a.configDir)
            // 上一个账号没清干净时日志还在，先别开始下一个，免得日志被覆盖
            if !left.isEmpty { break }
            do { left += try migrateAccount(a); done += 1 }
            catch { reloadStates(); return (done, "「\(shortDisplayName(a))」没有迁移（原样没动）：\(error)") }
        }
        reloadStates()
        return (done, left.isEmpty ? nil : "账号已经搬过来了，但旧的没清干净：" + left.joined(separator: "；") + "。重新打开 CCBaton 会再清一次。")
    }

    /// 设置里点"迁移"走这里：检查、确认、动手。返回一行结果给界面显示
    @discardableResult
    func requestMigration() -> String {
        if let why = migrationBlocker(terminals: runningTerminals()) { tellUser("现在不能迁移", why); return "还没有迁移" }
        guard !migratable.isEmpty else { return "没有需要迁移的账号" }
        guard confirmMigration(migrationPrompt) else { return "还没有迁移" }
        let result = migrateAll()
        if let problem = result.problem { tellUser(result.moved > 0 ? "迁移了 \(result.moved) 个账号，但有问题" : "没有迁移", problem) }
        let remaining = migratable.count
        return remaining == 0 ? "已迁移 \(result.moved) 个账号。" : "迁移了 \(result.moved) 个，还有 \(remaining) 个没迁。"
    }
}
