import Foundation
import AppKit

// 少见但后果重的情况：账号列表文件坏了、找 claude 时终端配置卡住、只读模式、查钥匙串条目、认整份备份是谁的。
// 只在沙盒里跑（必须设 CAB_TEST_ROOT）：假账号、假 claude，钥匙串条目名带 CABTEST。

@MainActor
func runRobustTest() -> Int32 {
    guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    _ = NSApplication.shared
    let fm = FileManager.default, keychain = KeychainStore()
    var slots: [Slot] = [.defaultSlot]
    defer { for s in slots { try? keychain.delete(s) }; keychain.deleteBackup() }

    func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    func wait(_ op: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await op(); done = true }
        while !done { pump(0.02) }
    }
    func write(_ path: String, _ text: String, mode: Int? = nil) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
    }
    func bytes(_ path: String) -> Data? { fm.contents(atPath: path) }
    func broken() -> [String] { ((try? fm.contentsOfDirectory(atPath: supportDir)) ?? []).filter { $0.hasPrefix("accounts.json.broken-") }.map { supportDir + "/" + $0 } }
    func resetStore() { for p in [storeURL.path, storeBackupURL.path] + broken() { try? fm.removeItem(atPath: p) } }
    func tree() -> [String: Data] {
        var out: [String: Data] = [:]
        for case let p as String in fm.enumerator(atPath: home) ?? FileManager.DirectoryEnumerator() { out[p] = bytes(home + "/" + p) ?? Data() }
        return out
    }
    func account(_ u: String, org: String? = nil) -> [String: Any] {
        ["accountUuid": u, "organizationUuid": org ?? "o-" + u, "emailAddress": u + "@t.com", "organizationType": "claude_pro"]
    }
    func secret(_ token: String, org: String) -> Secret {
        ["claudeAiOauth": ["accessToken": "at-" + token, "refreshToken": token, "refreshTokenExpiresAt": 9_999_999_999_999], "organizationUuid": org]
    }
    write(home + "/.local/bin/claude", "#!/bin/sh\nexit 0\n", mode: 0o755)      // 假 claude：任何情况下都不去跑真的

    print("— 账号列表文件")
    try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    var good = Store(accounts: [Account(id: "a", label: "工作", configDir: home + "/a/config", renewalDay: 8, note: "备注甲"),
                                Account(id: "b", label: "个人", configDir: home + "/b/config")], workDir: home)
    good.widgetSize = "large"
    resetStore()
    check("没有文件：空列表，不提示", loadStore(readOnly: false).store.accounts.isEmpty && loadStore(readOnly: false).problem == nil && broken().isEmpty)
    try? writeStore(good)
    check("存盘同时留一份内容相同的备份", bytes(storeURL.path) != nil && bytes(storeURL.path) == bytes(storeBackupURL.path))
    try? fm.removeItem(at: storeBackupURL)
    let normal = loadStore(readOnly: false)
    check("正常读取，旧版没有备份的顺手补上", normal.store.accounts == good.accounts && normal.problem == nil && bytes(storeBackupURL.path) == bytes(storeURL.path))

    let half = String(decoding: bytes(storeURL.path) ?? Data(), as: UTF8.self).prefix(40)
    write(storeURL.path, String(half))
    let before = tree()
    let ro = loadStore(readOnly: true)
    check("只读模式遇到坏文件：看备份里的内容，什么文件都不动", ro.store.accounts == good.accounts && !ro.writable && ro.problem == nil && tree() == before)
    let rec = loadStore(readOnly: false)
    check("写到一半的坏文件：用备份恢复，名字、续期日、备注、小组件尺寸都在",
          rec.store.accounts == good.accounts && rec.store.widgetSize == "large" && rec.writable && rec.problem?.title.contains("恢复") == true)
    check("坏掉的原文件复制留底，内容一字不差", broken().count == 1 && bytes(broken()[0]) == Data(half.utf8))
    check("提示里说了留底文件在哪", rec.problem?.message.contains(((broken().first ?? "?") as NSString).lastPathComponent) == true)
    check("恢复后的列表已写回", loadStore(readOnly: false).store.accounts == good.accounts && loadStore(readOnly: false).problem == nil)

    // 恢复时偏偏写不进去（比如磁盘满）：坏文件和备份都还在，下次启动还能恢复
    resetStore()
    try? writeStore(good)
    write(storeURL.path, "broken again")
    try? fm.setAttributes([.immutable: true], ofItemAtPath: storeURL.path)
    let full = loadStore(readOnly: false)
    try? fm.setAttributes([.immutable: false], ofItemAtPath: storeURL.path)
    for p in broken() { try? fm.setAttributes([.immutable: false], ofItemAtPath: p) }
    check("恢复时写不进去：备份没被动过，下次启动照样恢复",
          full.store.accounts == good.accounts && bytes(storeURL.path) == Data("broken again".utf8) && loadStore(readOnly: false).store.accounts == good.accounts)

    resetStore()
    write(storeURL.path, "{\"accounts\":[{\"id\":1}],\"workDir\":\"/x\"}")
    let wrong = loadStore(readOnly: false)
    check("格式合法但账号部分不对：当坏文件处理，不是悄悄变空", wrong.problem != nil && broken().count == 1 && wrong.store.accounts.isEmpty)

    // 整个程序走一遍：坏文件、没有备份、默认位置有账号在用
    resetStore()
    write(storeURL.path, "not json {{{")
    try? writeProfile(home + "/.claude.json", account: account("live"))
    Model.readOnly = false
    let m = Model()
    check("没有备份时：原文件留底没被覆盖", broken().count == 1 && bytes(broken().first ?? "") == Data("not json {{{".utf8))
    check("正在使用的账号重新收录进新列表，并带着要告诉用户的话", m.store.accounts.count == 1 && m.storeProblem?.message.contains("accounts.json.broken-") == true)
    var told: [String] = []
    m.tellUser = { title, _ in told.append(title) }
    pump(1.4)
    check("启动后弹出提示（只一次）", told == [m.storeProblem?.title ?? ""])

    // 坏文件挪不走：宁可不保存
    resetStore()
    write(storeURL.path, "broken")
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportDir)
    let stuck = Model()
    stuck.store.accounts = good.accounts
    stuck.save()
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportDir)
    stuck.save()
    check("原文件改不了名：之后的保存都不做，原文件不动", !stuck.storeWritable && bytes(storeURL.path) == Data("broken".utf8) && stuck.storeProblem != nil)

    print("— 只读模式")
    resetStore()
    try? fm.removeItem(atPath: supportDir)
    try? writeProfile(home + "/.claude.json", account: account("new"))
    try? keychain.write(.defaultSlot, secret("new-token", org: "o-new"))
    let pending = home + "/pending/config"
    slots += [.account(pending), .account(pending + ".prev")]
    try? writeProfile(home + "/pending/config/.claude.json", account: account("new"))
    saveJournal(Journal(target: "new:o-new", targetDir: pending, targetAccount: accountFingerprint(secret("new-token", org: "o-new")), step: "committed"))
    let untouched = tree()
    Model.readOnly = true
    let reader = Model()
    reader.save()
    check("默认位置有没收录的账号、还有没补完的切换：一个文件都不写、不改", tree() == untouched)
    check("上次切换的日志和钥匙串原样", loadJournal()?.step == "committed" && keychain.exists(.defaultSlot) && reader.store.accounts.isEmpty)
    saveJournal(nil)

    print("— 找 claude")
    let zdot = home + "/zdot", tools = home + "/我的 工具"
    write(tools + "/claude", "#!/bin/sh\nexit 0\n", mode: 0o755)
    func find(_ rc: String, timeout: TimeInterval = 10, logout: String = "") -> (path: String?, seconds: TimeInterval) {
        write(zdot + "/.zshrc", rc)
        write(zdot + "/.zlogout", logout)
        let start = Date()
        let p = findClaude(candidates: [], environment: ["HOME": zdot, "ZDOTDIR": zdot, "PATH": "/usr/bin:/bin"], timeout: timeout)
        return (p, Date().timeIntervalSince(start))
    }
    let add = "export PATH=\(shQuote(tools)):$PATH\n"
    check("常见位置有就直接用，不问 zsh", findClaude(candidates: [home + "/没有", tools + "/claude"]) == tools + "/claude")
    check("从用户的终端配置里找到（路径带空格和中文）", find(add).path == tools + "/claude")
    check("配置里打印的欢迎语、退出时打印的内容不会混进路径", find(add + "echo welcome\nprintf 'no newline'", logout: "echo bye").path == tools + "/claude")
    check("同名的别名和函数不算数，认真正的程序", find(add + "alias claude='echo x'\nfunction claude { : }").path == tools + "/claude")
    check("没装 claude：返回没找到", find("export PATH=/usr/bin:/bin\necho /bin/ls").path == nil)
    let stuckRc = find("sleep 8", timeout: 1.5)
    check("配置卡住：到时间就放弃（\(String(format: "%.1f", stuckRc.seconds)) 秒）", stuckRc.path == nil && stuckRc.seconds < 5)
    let replaced = find("exec sleep 8", timeout: 1.5)
    check("配置把 zsh 换成了别的程序（比如自动进 tmux）：也能结束", replaced.path == nil && replaced.seconds < 5)
    let background = find(add + "sleep 6 &", timeout: 5)
    check("配置里留下后台程序：不用等它（\(String(format: "%.1f", background.seconds)) 秒）", background.path == tools + "/claude" && background.seconds < 4)

    print("— 记住找到的结果")
    final class Counter: @unchecked Sendable { var n = 0; var answer: String? }
    let counter = Counter()
    let finder = Model()
    finder.searchClaude = { Thread.sleep(forTimeInterval: 0.3); counter.n += 1; return counter.answer }
    var got: [String?] = []
    wait { got.append(await finder.locateClaude()); got.append(await finder.locateClaude()) }
    check("没找到时，几分钟内不反复找", got == [nil, nil] && counter.n == 1)
    counter.answer = tools + "/claude"
    got = []
    wait { got.append(await finder.locateClaude(searchNow: true)) }
    check("手动刷新时马上再找，装好后不用重启程序", got == [tools + "/claude"] && counter.n == 2)
    wait { _ = await finder.locateClaude(searchNow: true) }
    check("找到过就直接用", counter.n == 2)
    try? fm.moveItem(atPath: tools + "/claude", toPath: tools + "/claude-new")
    counter.answer = tools + "/claude-new"
    got = []
    wait { got.append(await finder.locateClaude()) }
    check("原来的位置没有了会重新找", got == [tools + "/claude-new"] && counter.n == 3)
    let both = Model()
    counter.n = 0
    both.searchClaude = finder.searchClaude
    var answers = 0, ticks = 0
    for _ in 0..<2 { Task { @MainActor in if await both.locateClaude() != nil { answers += 1 } } }
    while answers < 2 && ticks < 200 { pump(0.01); ticks += 1 }
    check("两处同时要：只找一次；找的时候主线程照常运转", counter.n == 1 && answers == 2 && ticks > 5)
    counter.answer = nil
    let again = Model(); again.searchClaude = both.searchClaude; again.claudeRetryAfter = 0; counter.n = 0
    wait { _ = await again.locateClaude(); _ = await again.locateClaude() }
    check("过了等待时间会再找", counter.n == 2)

    print("— 查钥匙串条目")
    let slot = Slot.account(home + "/exists/config")
    slots.append(slot)
    var consistent = true
    for i in 0..<6 {
        try? keychain.write(slot, secret("t\(i)", org: "o"))
        consistent = consistent && keychain.exists(slot)
        try? keychain.delete(slot)
        consistent = consistent && !keychain.exists(slot)
    }
    check("刚写入、刚删掉都能马上查对（来回 6 次）", consistent)
    write(slot.credentialsFile, "{}")
    check("钥匙串里没有但有登录文件，也算有", keychain.exists(slot))
    try? fm.removeItem(atPath: slot.credentialsFile)
    try? keychain.write(slot, secret("t", org: "o"))
    let start = Date()
    var all = true
    for _ in 0..<100 { all = all && keychain.exists(slot) }
    let spent = Date().timeIntervalSince(start)
    check("查 100 次用时 \(String(format: "%.0f", spent * 1000)) 毫秒（原来每查一次起一个进程）", all && spent < 1)

    print("— 认整份备份是谁的（同一个 Team 组织里两个账号）")
    resetStore()
    try? writeProfile(home + "/.claude.json", account: account("boss"))
    Model.readOnly = false
    let t = Model()
    func teammate(_ id: String) -> Account {
        let a = Account(id: id, label: id, configDir: supportDir + "/accounts/\(id)/config")
        try? fm.createDirectory(atPath: a.configDir, withIntermediateDirectories: true)
        try? writeProfile(a.configDir + "/.claude.json", account: account(id, org: "team"))
        slots.append(.account(a.configDir)); slots.append(backupSlot(a.configDir))
        try? keychain.write(.account(a.configDir), secret("tok-" + id, org: "team"))
        return a
    }
    func remove(_ a: Account) -> Bool { t.states[a.id] = AccountState(); return t.removeAccount(a) == nil }
    var x = teammate("x"), y = teammate("y")
    t.store.accounts = [x, y]
    try? keychain.writeBackup(secret("rotated", org: "team"), owner: "y:team")
    check("移除 x：备份记着是 y 的，保留", remove(x) && keychain.readBackup() != nil && keychain.backupOwner() == "y:team")
    check("移除 y：它自己的备份一起删（令牌续过期、指纹对不上也认得出）", remove(y) && keychain.readBackup() == nil && keychain.backupOwner() == nil)
    x = teammate("x"); y = teammate("y"); t.store.accounts = [x, y]
    try? keychain.writeBackup(secret("rotated", org: "team"))
    check("旧版留下的备份没有记录，组织里还有别人：认不准，不删", remove(x) && keychain.readBackup() != nil)
    check("旧版备份、组织里只剩它：照旧删掉", remove(y) && keychain.readBackup() == nil)
    x = teammate("x"); y = teammate("y"); t.store.accounts = [x, y]
    try? keychain.writeBackup(secret("tok-x", org: "team"))
    check("指纹完全对得上：删", remove(x) && keychain.readBackup() == nil)

    // 真的切换一次，看记录写得对不对
    let from = teammate("from"), to = teammate("to")
    try? writeProfile(home + "/.claude.json", account: account("from", org: "team"))
    try? keychain.write(.defaultSlot, secret("live-from", org: "team"))
    try? keychain.delete(.account(from.configDir))
    let sw = Switcher(dirOf: { $0 == "from:team" ? from.configDir : nil })
    let switched = (try? sw.checkOut(target: "to:team", targetDir: to.configDir)) != nil
    check("切换时记下备份是原来那个账号的", switched && keychain.backupOwner() == "from:team" && keychain.readBackup() != nil)
    saveJournal(nil)
    Model.readOnly = true

    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
