// 沙盒自检：只有设了 CAB_TEST_ROOT 才会运行。所有路径都在测试目录里，钥匙串条目名带 CABTEST，
// 不会碰到真实的 Claude 登录。用法：CAB_TEST_ROOT=/某个空目录 ClaudeAccountBar --selftest

import Foundation

func runSelfTest() -> Int32 {
    guard let root = testRoot, !root.isEmpty else {
        print("拒绝运行：必须设置 CAB_TEST_ROOT，避免动到真实登录"); return 2
    }
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", name); if !ok { failed += 1 } }
    let fm = FileManager.default
    let kc = KeychainStore()
    let aDir = root + "/accounts/a/config", bDir = root + "/accounts/b/config"
    let keyA = "uA:orgA", keyB = "uB:orgB"

    func cleanup() {
        for s in [Slot.defaultSlot, .account(aDir), .account(bDir), .account(aDir + ".prev"), .account(bDir + ".prev")] { try? kc.delete(s) }
        kc.deleteBackup()
    }
    func prof(_ uuid: String, _ org: String, _ email: String) -> [String: Any] {
        ["oauthAccount": ["accountUuid": uuid, "organizationUuid": org, "emailAddress": email, "organizationType": "claude_pro"]]
    }
    func writeJSON(_ path: String, _ obj: Any) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
    }
    func sec(_ name: String, org: String, extra: Secret = [:]) -> Secret {
        var s: Secret = ["claudeAiOauth": ["accessToken": "\(name)-acc", "refreshToken": "\(name)-ref",
                                           "expiresAt": 9_999_999_999_999, "refreshTokenExpiresAt": 9_999_999_999_999],
                         "organizationUuid": org]
        for (k, v) in extra { s[k] = v }
        return s
    }
    func refresh(_ s: Secret?) -> String? { ((s?["claudeAiOauth"]) as? [String: Any])?["refreshToken"] as? String }
    let sw = Switcher(dirOf: { $0 == keyA ? aDir : ($0 == keyB ? bDir : nil) })

    cleanup()
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
    var defProfile = prof("uA", "orgA", "a@test")
    defProfile["userID"] = "keep-user-id"
    defProfile["cachedUsageUtilization"] = ["fetchedAtMs": 1, "utilization": [:]]
    writeJSON(root + "/.claude.json", defProfile)
    writeJSON(aDir + "/.claude.json", prof("uA", "orgA", "a@test"))
    writeJSON(bDir + "/.claude.json", prof("uB", "orgB", "b@test"))
    do {
        try kc.write(.defaultSlot, sec("A", org: "orgA", extra: ["mcpOAuth": ["srv": "keep-me"]]))
        try kc.write(.account(bDir), sec("B", org: "orgB"))
    } catch { print("准备数据失败：\(error)"); return 1 }

    print("场景 1：A 在用，切到 B")
    do {
        let out = try sw.checkOut(target: keyB, targetDir: bDir)
        if case .switched(let prev) = out { check("返回切换成功，原来的号是 A", prev == keyA) } else { check("返回切换成功", false) }
    } catch { check("切到 B 不报错（\(error)）", false) }
    let d1 = try? kc.read(.defaultSlot)
    check("默认位置的登录变成 B", refresh(d1) == "B-ref")
    check("默认位置的组织变成 B", (d1?["organizationUuid"] as? String) == "orgB")
    check("机器相关的 mcpOAuth 留在默认位置", ((d1?["mcpOAuth"]) as? [String: Any])?["srv"] as? String == "keep-me")
    check("默认的 .claude.json 里账号变成 B", defaultOwner()?.key == keyB)
    check("默认 .claude.json 里账号缓存被清掉", readProfile(root + "/.claude.json")?["cachedUsageUtilization"] == nil)
    check("默认 .claude.json 里其他内容保留", readProfile(root + "/.claude.json")?["userID"] as? String == "keep-user-id")
    check("A 的登录收回到了 A 自己的槽位", refresh(try? kc.read(.account(aDir))) == "A-ref")
    check("A 的槽位里没有带 mcpOAuth（只搬账号键）", (try? kc.read(.account(aDir)))?["mcpOAuth"] == nil)
    check("B 自己的槽位已清空（令牌只留一份）", (try? kc.read(.account(bDir))) == nil)
    check("日志状态是 done", loadJournal()?.step == "done")
    check("提交前备份了原来的整份登录", ((try? runSecurity(["find-generic-password", "-a", keychainAccount, "-s", "CABTEST-backup"]))?.code ?? -1) == 0)

    print("场景 2：B 已经在用，再切 B")
    do {
        let out = try sw.checkOut(target: keyB, targetDir: bDir)
        if case .alreadyLive = out { check("识别为已在用，不动", true) } else { check("识别为已在用", false) }
    } catch { check("不报错（\(error)）", false) }
    check("默认位置没有被改动", refresh(try? kc.read(.defaultSlot)) == "B-ref")

    print("场景 3：切回 A")
    do { _ = try sw.checkOut(target: keyA, targetDir: aDir) } catch { check("切回 A 不报错（\(error)）", false) }
    let d3 = try? kc.read(.defaultSlot)
    check("默认位置的登录变回 A", refresh(d3) == "A-ref")
    check("mcpOAuth 仍在", ((d3?["mcpOAuth"]) as? [String: Any])?["srv"] as? String == "keep-me")
    check("默认 .claude.json 账号变回 A", defaultOwner()?.key == keyA)
    check("B 收回到 B 自己的槽位", refresh(try? kc.read(.account(bDir))) == "B-ref")
    check("A 自己的槽位已清空", (try? kc.read(.account(aDir))) == nil)

    print("场景 4：出错路径")
    try? kc.delete(.account(bDir))
    do { _ = try sw.checkOut(target: keyB, targetDir: bDir); check("目标没有登录时应拒绝", false) }
    catch { check("目标没有登录时拒绝切换：\(error)", true) }
    check("拒绝后默认位置原样不动（仍是 A）", refresh(try? kc.read(.defaultSlot)) == "A-ref" && defaultOwner()?.key == keyA)

    try? kc.write(.account(bDir), sec("X", org: "orgX"))    // B 的目录里登了别的号
    do { _ = try sw.checkOut(target: keyB, targetDir: bDir); check("目录里登的不是它时应拒绝", false) }
    catch { check("目录里登的不是它时拒绝切换：\(error)", true) }
    check("拒绝后默认位置原样不动", refresh(try? kc.read(.defaultSlot)) == "A-ref")

    try? kc.write(.account(bDir), sec("B", org: "orgB"))
    try? kc.write(.account(bDir), sec("B", org: "orgB", extra: ["claudeAiOauth": ["refreshToken": "B-old", "refreshTokenExpiresAt": 1000]]))
    do { _ = try sw.checkOut(target: keyB, targetDir: bDir); check("登录已过期时应拒绝", false) }
    catch { check("登录已过期时拒绝切换", true) }

    print("场景 5：Claude Code 正持有刷新锁时")
    try? kc.write(.account(bDir), sec("B", org: "orgB"))
    let lockDir = root + "/.claude/.oauth_refresh.lock"
    mkdir(lockDir, 0o755)
    let t0 = Date()
    do { _ = try sw.checkOut(target: keyB, targetDir: bDir); check("锁被占用时应放弃", false) }
    catch { check("锁被占用时等待后放弃（约 10 秒）：\(error)", Date().timeIntervalSince(t0) > 9) }
    rmdir(lockDir)
    check("放弃后默认位置原样不动", refresh(try? kc.read(.defaultSlot)) == "A-ref")

    print("场景 6：切到一半崩溃后补完")
    // 模拟：默认位置的登录已是 B，但 .claude.json 还是 A，日志停在 committed
    do {
        _ = try sw.checkOut(target: keyB, targetDir: bDir)
        let bProfile = readProfile(bDir + "/.claude.json")!
        try writeProfile(root + "/.claude.json", account: (readProfile(aDir + "/.claude.json")!["oauthAccount"] as! [String: Any]))
        try kc.write(.account(bDir), sec("B", org: "orgB"))
        _ = bProfile
        saveJournal(Journal(target: keyB, targetDir: bDir, targetAccount: accountFingerprint(sec("B", org: "orgB")), step: "committed"))
        check("模拟出崩溃现场：资料是 A、登录是 B", defaultOwner()?.key == keyA && refresh(try? kc.read(.defaultSlot)) == "B-ref")
        sw.recover()
        check("启动补完后资料变成 B", defaultOwner()?.key == keyB)
        check("补完后 B 自己的槽位被清空", (try? kc.read(.account(bDir))) == nil)
        check("补完后日志是 done", loadJournal()?.step == "done")
    } catch { check("崩溃补完场景不报错（\(error)）", false) }

    print("场景 7：切换时两边的额度缓存跟着账号走")
    do {
        func usage(_ uuid: String, _ at: Int, _ five: Int) -> [String: Any] {
            ["accountUuid": uuid, "fetchedAtMs": at, "utilization": ["five_hour": ["utilization": five]]]
        }
        func setUsage(_ path: String, _ u: [String: Any]) {
            var doc = readProfile(path) ?? [:]; doc["cachedUsageUtilization"] = u; writeJSON(path, doc)
        }
        func five(_ path: String) -> Double? { readState(path: path).fiveHour }
        let defPath = root + "/.claude.json", aPath = aDir + "/.claude.json", bPath = bDir + "/.claude.json"

        _ = try sw.checkOut(target: keyA, targetDir: aDir)
        setUsage(defPath, usage("uA", 2000, 98))      // A 在用时读到的最新额度
        setUsage(aPath, usage("uA", 1000, 0))         // A 目录里是很久以前的旧缓存
        setUsage(bPath, usage("uB", 1500, 12))
        _ = try sw.checkOut(target: keyB, targetDir: bDir)
        check("切走的号仍显示最后读到的 98%", five(aPath) == 98)
        check("切上来的号带着自己的 12%", five(defPath) == 12)

        setUsage(defPath, usage("uB", 1000, 40))      // 默认位置的缓存反而比目录里的旧
        setUsage(bPath, usage("uB", 3000, 55))
        _ = try sw.checkOut(target: keyA, targetDir: aDir)
        check("两份缓存取读取时间新的（切走）", five(bPath) == 55)
        check("切回来的号带着 98%", five(defPath) == 98)

        setUsage(defPath, usage("uB", 9000, 77))      // 默认位置混进了别的号的缓存
        _ = try sw.checkOut(target: keyB, targetDir: bDir)
        check("别的号的缓存不会写到切走的号上", five(aPath) == 98)
    } catch { check("额度缓存场景不报错（\(error)）", false) }

    cleanup()
    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
