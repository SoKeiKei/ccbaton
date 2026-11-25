import Foundation
import AppKit

// 迁移的测试。只在沙盒里跑（必须设 CAB_TEST_ROOT）：假账号、钥匙串条目名带 CABTEST，不碰真实登录。

@MainActor
func runMigrationTest() -> Int32 {
    guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    _ = NSApplication.shared
    let fm = FileManager.default, keychain = KeychainStore()
    var slots: [String] = []
    defer { for d in slots { try? keychain.delete(.account(d)) }; try? keychain.delete(.defaultSlot); keychain.deleteBackup() }

    func write(_ path: String, _ text: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func link(_ path: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: path) }
    func secret(_ u: String, _ token: String) -> Secret {
        ["claudeAiOauth": ["accessToken": "at-" + token, "refreshToken": token, "refreshTokenExpiresAt": 9_999_999_999_999], "organizationUuid": "o-" + u]
    }
    func account(_ u: String) -> [String: Any] { ["accountUuid": u, "organizationUuid": "o-" + u, "emailAddress": u + "@t.com", "organizationType": "claude_pro"] }
    func registry() -> Set<String> {
        let d = fm.contents(atPath: ccSwitchRoot + "/claude_accounts.json").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return Set(((d?["accounts"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? [String: Any])?["localId"] as? String })
    }
    func disk() -> Store? { (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } }

    // 默认位置：账号 A 在用
    write(home + "/.claude/settings.json", "{\"model\":\"default-model\"}")
    write(home + "/.claude/CLAUDE.md", "default instructions")
    write(home + "/.claude/projects/chat.jsonl", "keep")
    write(home + "/.claude/skills/s.md", "skill")
    try? writeProfile(home + "/.claude.json", account: account("uA"))
    try? keychain.write(.defaultSlot, secret("uA", "A-live"))

    // 三个 cc-switch 账号，仿照真实结构
    let hex = ["a", "b", "c"].map { String(repeating: $0, count: 32) }
    func ccDir(_ h: String) -> String { ccSwitchRoot + "/claude-accounts/\(h)/config" }
    write(ccSwitchRoot + "/skills/x.md", "cc")
    var accounts: [[String: Any]] = []
    for (i, h) in hex.enumerated() {
        let d = ccDir(h), u = ["uA", "uB", "uC"][i]
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        try? writeProfile(d + "/.claude.json", account: account(u))
        write(d + "/settings.json", "{\"model\":\"copy-\(i)\"}")
        write(d + "/CLAUDE.md", "@import-\(i)")
        write(d + "/history.jsonl", "history-\(i)")
        write(d + "/sessions/one.json", "session-\(i)")
        try? fm.createSymbolicLink(atPath: d + "/projects", withDestinationPath: home + "/.claude/projects")
        try? fm.createSymbolicLink(atPath: d + "/skills", withDestinationPath: ccSwitchRoot + "/skills")
        slots += [d, d + ".prev"]
        if i != 0 { try? keychain.write(.account(d), secret(u, "token-" + u)) }
        if i == 1 { try? keychain.write(backupSlot(d), secret(u, "spare-" + u)) }
        accounts.append(["localId": h, "email": u + "@t.com"])
    }
    func writeRegistry() {
        let dict = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ("k\($0.offset)", $0.element) })
        try? JSONSerialization.data(withJSONObject: ["version": 1, "accounts": dict]).write(to: URL(fileURLWithPath: ccSwitchRoot + "/claude_accounts.json"))
    }
    writeRegistry()
    let originals = hex.enumerated().map { Account(id: $0.element, label: "号\($0.offset)", configDir: ccDir($0.element)) }
    for h in hex { slots += ["\(supportDir)/accounts/\(h)/config", "\(supportDir)/accounts/\(h)/config.prev"] }

    Model.readOnly = true           // 不启动定时器
    let m = Model()
    Model.readOnly = false
    m.store.accounts = originals; m.store.colorSlots = nil
    m.store.terminalPrefs = [hex[1]: TerminalPrefs(dir: home, skipPermissions: false, args: "--continue")]
    m.save(); m.reloadStates()
    let colors = m.store.colorSlots
    var asked = 0, told: [String] = []
    m.confirmMigration = { _ in asked += 1; return true }
    m.tellUser = { _, why in told.append(why) }

    func untouched() -> Bool {
        m.store.accounts == originals && disk()?.accounts == originals && registry() == Set(hex)
            && hex.allSatisfy { read(ccDir($0) + "/history.jsonl") != nil && link(ccDir($0) + "/settings.json") == nil }
            && keychain.exists(.account(ccDir(hex[1]))) && keychain.exists(.account(ccDir(hex[2]))) && keychain.exists(backupSlot(ccDir(hex[1])))
            && hex.allSatisfy { !keychain.exists(.account("\(supportDir)/accounts/\($0)/config")) && !fm.fileExists(atPath: "\(supportDir)/accounts/\($0)") }
    }

    print("— 认出别处正在用账号目录的程序（真起一个进程来认）")
    let child = Process()
    child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--idle-for-test"]
    child.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CONFIG_DIR": ccDir(hex[1])]) { $1 }
    child.standardOutput = FileHandle.nullDevice
    try? child.run()
    Thread.sleep(forTimeInterval: 0.6)
    check("认得出正在用某个账号目录的进程", processesUsing([ccDir(hex[1])]) == 1)
    check("没人用的目录是 0（名字只是开头相同的也不算）", processesUsing([ccDir(hex[2])]) == 0 && processesUsing([String(ccDir(hex[1]).dropLast(3))]) == 0)
    child.terminate(); child.waitUntilExit()

    print("— 什么时候提 cc-switch")
    func mentions(_ s: String) -> Bool { s.lowercased().contains("cc-switch") }
    func allTexts(_ installed: Bool) -> [String] {
        m.ccSwitchInstalled = { installed }
        let t = m.migrationTexts(installed: installed)
        return [t.title, t.line, t.note, m.migrationPrompt.title, m.migrationPrompt.message,
                m.removalPrompt(m.store.accounts[1], terminals: []).message]
    }
    check("装着时：迁移和移除的说明里会提到它", allTexts(true).contains(where: mentions))
    check("没装时：这些说明一个字都不提它", !allTexts(false).contains(where: mentions))
    check("任何情况下都不劝人卸载", !(allTexts(true) + allTexts(false)).contains { $0.contains("卸载") })
    m.ccSwitchInstalled = { true }
    check("账号都已导入：不出现导入", !m.offersImport)
    m.store.accounts = Array(originals.dropLast())
    check("装着且有没导入的账号：出现导入", m.offersImport)
    m.ccSwitchInstalled = { false }
    check("没装：即使清单里有账号也不出现导入", !m.offersImport)
    m.store.accounts = originals

    print("— 不该动手的时候")
    check("认出 3 个待迁移的账号", m.migratable.count == 3 && m.states[hex[0]]?.live == true)
    m.ccSwitchRunning = { true }
    check("cc-switch 开着：不迁，说明原因", m.requestMigration() == "还没有迁移" && told.last?.contains("退出 cc-switch") == true && asked == 0 && untouched())
    m.ccSwitchRunning = { false }
    check("有终端在用账号目录：不迁", m.migrationBlocker(terminals: [RunningTerminal(mode: .shared, accountId: hex[1])]) != nil)
    check("跟随默认登录或完全独立的终端不挡路", m.migrationBlocker(terminals: [RunningTerminal(mode: .live, accountId: hex[0]), RunningTerminal(mode: .dedicated, accountId: hex[1])]) == nil)
    m.processUsingDirs = { _ in 1 }
    check("别处开的 claude 在用旧目录：不迁", m.migrationBlocker(terminals: []) != nil && m.migrateAll().moved == 0 && untouched())
    m.processUsingDirs = { _ in 0 }
    m.refreshing = true
    check("正在读额度：不迁", m.migrationBlocker(terminals: []) != nil)
    m.refreshing = false
    m.confirmMigration = { _ in asked += 1; return false }
    check("确认框点取消：什么都不动", m.requestMigration() == "还没有迁移" && asked == 1 && untouched())
    m.confirmMigration = { _ in asked += 1; return true }

    print("— 中途失败要能完全撤回")
    try? fm.createDirectory(atPath: supportDir + "/accounts", withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportDir + "/accounts")
    let r1 = m.migrateAll()
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportDir + "/accounts")
    check("复制不了：旧的原样不动", r1.moved == 0 && r1.problem != nil && untouched() && loadMigrationJournal() == nil)
    try? fm.removeItem(at: storeURL)
    try? fm.createDirectory(at: storeURL, withIntermediateDirectories: true)          // 让账号列表写不进去
    try? fm.createDirectory(atPath: storeURL.path + "/x", withIntermediateDirectories: true)
    let r2 = m.migrateAll()
    try? fm.removeItem(at: storeURL); m.save()
    check("登录已经复制过去、但列表写不进磁盘：复制品全部撤掉", r2.moved == 0 && r2.problem?.contains("写不进磁盘") == true && untouched() && loadMigrationJournal() == nil)

    print("— 正常迁移")
    let before = hex.map { (try? keychain.read(.account(ccDir($0)))) ?? nil }
    let result = m.requestMigration()
    let new = m.store.accounts.map { $0.configDir }
    check("三个都迁好了", result.contains("已迁移 3 个账号") && m.migratable.isEmpty && !result.contains("卸载"))
    m.ccSwitchInstalled = { true }
    let after = m.migrationTexts(installed: true)
    check("迁完后即使还装着：不再出现导入，说明里也不提它", !m.offersImport && !mentions(after.title + after.line + after.note)
          && !m.store.accounts.contains { mentions(m.removalPrompt($0, terminals: []).message) })
    check("账号编号、名字、顺序不变，目录换到 CCBaton 里", m.store.accounts.map { $0.id } == hex && m.store.accounts.map { $0.label } == ["号0", "号1", "号2"]
          && new == hex.map { "\(supportDir)/accounts/\($0)/config" })
    check("新列表已经存盘", disk()?.accounts == m.store.accounts)
    check("颜色和终端偏好保留", disk()?.colorSlots == colors && disk()?.terminalPrefs?[hex[1]]?.args == "--continue")
    check("登录原样搬到新位置（和原来逐字一致）", [1, 2].allSatisfy { i in
        (((try? keychain.read(.account(new[i]))) ?? nil).map(fingerprint)) == before[i].map(fingerprint) })
    check("备份副本也搬过去了", ((try? keychain.read(backupSlot(new[1]))) ?? nil).map(fingerprint) == fingerprint(secret("uB", "spare-uB")))
    check("旧位置的钥匙串条目都删了", hex.allSatisfy { !keychain.exists(.account(ccDir($0))) && !keychain.exists(backupSlot(ccDir($0))) })
    check("命令历史和会话跟着过来", (0..<3).allSatisfy { read(new[$0] + "/history.jsonl") == "history-\($0)" && read(new[$0] + "/sessions/one.json") == "session-\($0)" })
    check("设置改用默认的（链接）", new.allSatisfy { link($0 + "/settings.json") == home + "/.claude/settings.json" && link($0 + "/CLAUDE.md") == home + "/.claude/CLAUDE.md" })
    check("原来的设置副本改名留底", (0..<3).allSatisfy { read(new[$0] + "/settings.json.from-cc-switch") == "{\"model\":\"copy-\($0)\"}" && read(new[$0] + "/CLAUDE.md.from-cc-switch") == "@import-\($0)" })
    check("指向 cc-switch 的链接改指默认位置", new.allSatisfy { link($0 + "/skills") == home + "/.claude/skills" && link($0 + "/projects") == home + "/.claude/projects" })
    check("没有把锁文件带过来", new.allSatisfy { !fm.fileExists(atPath: $0 + "/.oauth_refresh.lock") && !fm.fileExists(atPath: $0 + "/.storage-write.lock") })
    check("旧文件夹进了废纸篓，cc-switch 清单清空", hex.allSatisfy { !fm.fileExists(atPath: ccSwitchRoot + "/claude-accounts/\($0)") } && registry().isEmpty && loadMigrationJournal() == nil)
    check("默认位置的内容原样没动", read(home + "/.claude/projects/chat.jsonl") == "keep" && read(home + "/.claude/settings.json") == "{\"model\":\"default-model\"}")

    print("— 迁完照常能用，且和 cc-switch 文件夹脱钩")
    try? fm.removeItem(atPath: ccSwitchRoot)
    m.reloadStates()
    check("删掉整个 cc-switch 文件夹后账号都还在", m.states[hex[0]]?.live == true && m.states[hex[1]]?.loggedIn == true && m.states[hex[2]]?.loggedIn == true)
    check("能给迁过来的账号开终端", terminalLoginMatches(dir: new[1], key: identity(ofDir: new[1])?.key ?? ""))
    let list = m.store.accounts
    let switcher = Switcher(dirOf: { k in list.first { identity(ofDir: $0.configDir)?.key == k }?.configDir })
    do {
        _ = try switcher.checkOut(target: identity(ofDir: new[1])!.key, targetDir: new[1])
        m.reloadStates()
        check("切换到迁过来的账号", m.states[hex[1]]?.live == true && ((try? keychain.read(.defaultSlot)) ?? nil)?["organizationUuid"] as? String == "o-uB")
        _ = try switcher.checkOut(target: identity(ofDir: new[0])!.key, targetDir: new[0])
        m.reloadStates()
        check("再切回来", m.states[hex[0]]?.live == true && ((try? keychain.read(.defaultSlot)) ?? nil)?["organizationUuid"] as? String == "o-uA")
    } catch { check("切换没有报错（\(error)）", false) }

    print("— 迁移中途断电，下次启动收尾")
    let lonely = "\(supportDir)/accounts/lonely/config"
    slots.append(lonely)
    try? fm.createDirectory(atPath: lonely, withIntermediateDirectories: true); try? keychain.write(.account(lonely), secret("uL", "only-copy"))
    try? saveMigrationJournal(MigrationJournal(from: ccDir(String(repeating: "f", count: 32)), to: lonely))
    m.recoverMigration()
    check("旧的已经不在、新的是唯一一份：绝不删", keychain.exists(.account(lonely)) && fm.fileExists(atPath: lonely))
    try? saveMigrationJournal(nil)
    let old = ccDir(String(repeating: "d", count: 32)), half = "\(supportDir)/accounts/half/config"
    slots += [old, half]
    func prepare() {
        for d in [old, half] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true); try? writeProfile(d + "/.claude.json", account: account("uD")); try? keychain.write(.account(d), secret("uD", "token-uD")) }
        try? saveMigrationJournal(MigrationJournal(from: old, to: half))
    }
    prepare()
    m.store.accounts = list + [Account(id: "d", label: "", configDir: old)]
    m.recoverMigration()
    check("还没提交：撤掉复制品，旧的保留", !keychain.exists(.account(half)) && !fm.fileExists(atPath: supportDir + "/accounts/half") && keychain.exists(.account(old)) && loadMigrationJournal() == nil)
    prepare()
    m.store.accounts = list + [Account(id: "d", label: "", configDir: half)]
    m.recoverMigration()
    check("已经提交：清掉旧的，新的保留", keychain.exists(.account(half)) && !keychain.exists(.account(old)) && !fm.fileExists(atPath: (old as NSString).deletingLastPathComponent) && loadMigrationJournal() == nil)
    try? saveMigrationJournal(MigrationJournal(from: old, to: home + "/.claude"))
    m.recoverMigration()
    check("日志里的路径不是账号目录时，什么都不删", fm.fileExists(atPath: home + "/.claude/settings.json") && loadMigrationJournal() == nil)

    Model.readOnly = true
    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
