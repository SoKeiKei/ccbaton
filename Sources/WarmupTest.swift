import AppKit

// 额度预热的测试：--warmuptest。先测纯计算（含模拟 48 小时），再在沙盒里用一个假的 claude 走完整流程。
// 假 claude 只改沙盒里的 .claude.json，不联网、不花任何额度。

private let fakeClaude = #"""
#!/usr/bin/python3
import json, os, sys, time, datetime
root = os.environ["CAB_TEST_ROOT"]
cfg = os.environ.get("CLAUDE_CONFIG_DIR")
key = cfg or "default"
args = sys.argv[1:]
def load(name):
    try: return json.load(open(root + "/" + name))
    except Exception: return {}
with open(root + "/claude.log", "a") as f:
    env = sorted(k for k in os.environ if k.startswith("ANTHROPIC_") or k.startswith("CLAUDE"))
    f.write(json.dumps({"args": args, "cfg": cfg or "", "env": env, "cwd": os.getcwd()}) + "\n")
windows = load("windows.json")
if args[:2] == ["-p", "/usage"]:
    if os.path.exists(root + "/offline"): sys.exit(1)
    profile = (cfg or root) + "/.claude.json"
    doc = json.load(open(profile))
    week = load("weekly.json").get(key, 10)
    doc["cachedUsageUtilization"] = {"fetchedAtMs": time.time() * 1000, "accountUuid": doc["oauthAccount"]["accountUuid"],
        "utilization": {"five_hour": {"utilization": 0, "resets_at": windows.get(key)},
                        "seven_day": {"utilization": week, "resets_at": "2099-01-01T00:00:00+00:00"}}}
    json.dump(doc, open(profile, "w"))
elif args[:2] == ["-p", "hi"]:
    if os.path.exists(root + "/pingfail"): sys.exit(1)
    end = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=5)
    windows[key] = end.isoformat()
    json.dump(windows, open(root + "/windows.json", "w"))
"""#

@MainActor
func runWarmupTest() -> Int32 {
    guard let root = testRoot else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    let fm = FileManager.default

    // MARK: 1. 纯计算
    print("预热规则：")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let A = Account(id: "a", label: "A", configDir: "/x/a"), B = Account(id: "b", label: "B", configDir: "/x/b"), C = Account(id: "c", label: "C", configDir: "/x/c")
    let accs = [A, B, C]
    func idle(_ week: Double = 10) -> AccountState {
        var s = AccountState(); s.loggedIn = true; s.fiveHour = 0; s.fiveIdle = true; s.sevenDay = week; return s
    }
    func counting(_ reset: Date) -> AccountState { var s = idle(); s.fiveIdle = false; s.fiveReset = reset; return s }
    func plan(_ s: [String: AccountState], _ r: [String: WarmupRecord] = [:], holds: [String: Date] = [:], stagger: Bool = true, now: Date = t0) -> WarmupPlan {
        warmupPlan(accounts: accs, states: s, records: r, holds: holds, stagger: stagger, now: now)
    }
    func rec(_ ago: TimeInterval, _ status: WarmupRecord.Status, fails: Int = 0) -> WarmupRecord {
        WarmupRecord(at: t0.addingTimeInterval(-ago), status: status, fails: fails)
    }
    let all = ["a": idle(50), "b": idle(10), "c": idle(20)]

    let probe = root + "/probe.json"
    func parsed(_ resets: String) -> AccountState {
        try? "{\"oauthAccount\":{\"accountUuid\":\"u\"},\"cachedUsageUtilization\":{\"utilization\":{\"five_hour\":{\"utilization\":0,\"resets_at\":\(resets)}}}}"
            .write(toFile: probe, atomically: true, encoding: .utf8)
        return readState(path: probe)
    }
    check("读数据：重置时间为空 = 没开始计时", parsed("null").fiveIdle)
    let p2 = parsed("\"2026-11-25T13:50:00.203503+00:00\"")
    check("读数据：服务器返回的时间格式读得出来", !p2.fiveIdle && p2.fiveReset != nil)
    let p3 = parsed("\"看不懂的时间\"")
    check("读数据：时间读不懂时不当成空闲", !warmupIdle(p3, now: t0))

    check("全部空闲：先激活周额度剩得最多的 B", plan(all) == .ping("b"))
    check("错开：B 刚发过，下一个 C 要等 1 小时 40 分", plan(all, ["b": rec(0, .sent)]) == .wait("c", until: t0.addingTimeInterval(6000)))
    check("错开：别的账号刚开始计时（用户自己用的）也要等", plan(["a": counting(t0.addingTimeInterval(Warmup.window - 600)), "b": idle(), "c": idle(20)])
          == .wait("b", until: t0.addingTimeInterval(6000 - 600)))
    check("错开：隔够了就激活", plan(["a": counting(t0.addingTimeInterval(Warmup.window - 6000)), "b": idle(), "c": idle(20)]) == .ping("b"))
    check("不错开：不等，接着激活下一个", plan(all, ["b": rec(0, .sent)], stagger: false) == .ping("c"))
    check("没成功的记录不挡别的账号", plan(all, ["b": rec(0, .failed, fails: 1)]) == .ping("c"))
    var two = all; two["b"] = idle(100); two["b"]?.sevenReset = t0.addingTimeInterval(86400)
    check("周额度用完的账号跳过，剩两个号时间隔变成 2 小时 30 分", plan(two, ["c": rec(0, .sent)]) == .wait("a", until: t0.addingTimeInterval(9000)))
    two["b"]?.sevenReset = t0.addingTimeInterval(-60)
    check("周额度已过重置时间就不再算用完", warmupEligible(two["b"]!, now: t0))
    var off = idle(); off.loggedIn = false
    var noData = idle(); noData.fiveHour = nil
    check("没登录、读不到额度的账号不预热", plan(["a": off, "b": noData]) == .none)
    check("都在计时：给出最早的重置时间", plan(["a": counting(t0.addingTimeInterval(900)), "b": counting(t0.addingTimeInterval(300)), "c": counting(t0.addingTimeInterval(600))])
          == .counting(next: t0.addingTimeInterval(300)))
    check("重置时间刚过 30 秒还不动", !warmupIdle(counting(t0.addingTimeInterval(-30)), now: t0))
    check("重置时间过了 90 秒算空闲", warmupIdle(counting(t0.addingTimeInterval(-90)), now: t0))
    let only = ["a": idle()]
    check("没成功：30 分钟内不重试", plan(only, ["a": rec(600, .failed, fails: 1)]) == .wait("a", until: t0.addingTimeInterval(1200)))
    check("没成功：30 分钟后重试", plan(only, ["a": rec(1801, .failed, fails: 1)]) == .ping("a"))
    check("连续失败 3 次：5 小时才试一次", plan(only, ["a": rec(3600, .failed, fails: 3)]) == .wait("a", until: t0.addingTimeInterval(Warmup.window - 3600)))
    check("暂时放一放的账号让给别人", plan(all, holds: ["b": t0.addingTimeInterval(300)]) == .ping("c"))
    check("发出去还没核对的账号不重复发", plan(only, ["a": rec(3600, .sent)]) == .counting(next: nil))

    // MARK: 2. 模拟 48 小时
    print("\n模拟 48 小时（每分钟判断一次，窗口起点按 10 分钟向下取整）：")
    func simulate(initial: [String: Date], stagger: Bool) -> [(id: String, minute: Int)] {
        var resets = initial, records: [String: WarmupRecord] = [:], pings: [(String, Int)] = []
        for minute in 0..<(48 * 60) {
            let now = t0.addingTimeInterval(Double(minute) * 60)
            for _ in 0..<3 {
                var s: [String: AccountState] = [:]
                for a in accs { if let r = resets[a.id], r > now { s[a.id] = counting(r) } else { s[a.id] = idle() } }
                guard case .ping(let id) = warmupPlan(accounts: accs, states: s, records: records, stagger: stagger, now: now) else { break }
                let start = (now.timeIntervalSince1970 / 600).rounded(.down) * 600
                resets[id] = Date(timeIntervalSince1970: start + Warmup.window)
                records[id] = WarmupRecord(at: now, status: .confirmed, fails: 0)
                pings.append((id, minute))
            }
        }
        return pings
    }
    for (title, initial) in [("一开始全部空闲", [String: Date]()),
                             ("一开始三个号同时被用起来（重置时间扎堆）", Dictionary(uniqueKeysWithValues: accs.map { ($0.id, t0.addingTimeInterval(Warmup.window)) }))] {
        let p = simulate(initial: initial, stagger: true)
        let gaps = zip(p.dropFirst(), p).map { $0.minute - $1.minute }
        let steady = zip(p.dropFirst(), p).filter { $0.0.minute > 12 * 60 }.map { $0.0.minute - $0.1.minute }
        print("    \(title)：前 6 次激活在第 \(p.prefix(6).map { "\($0.minute)" }.joined(separator: "、")) 分钟")
        check("两次激活至少隔 100 分钟（最短 \(gaps.min() ?? 0)）", (gaps.min() ?? 0) >= 100)
        check("稳定后最多 \(steady.max() ?? 0) 分钟就有一个号开始新窗口（不超过 115）", (steady.max() ?? 999) <= 115)
        check("三个号轮得到，次数相差不超过 1", Set(p.map { $0.id }).count == 3 && accs.map { a in p.filter { $0.id == a.id }.count }.sorted().last! - accs.map { a in p.filter { $0.id == a.id }.count }.min()! <= 1)
    }
    let together = simulate(initial: [:], stagger: false)
    check("关掉错开：一开始三个号同一分钟全部激活", together.prefix(3).allSatisfy { $0.minute == 0 } && together.count >= 27)

    // MARK: 3. 沙盒里走完整流程
    print("\n完整流程（假 claude）：")
    let bin = home + "/.local/bin"
    try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try? fakeClaude.write(toFile: bin + "/claude", atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/claude")
    setenv("ANTHROPIC_API_KEY", "sk-should-not-leak", 1)
    setenv("CLAUDE_CODE_USE_BEDROCK", "1", 1)

    func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func wait(_ op: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await op(); done = true }
        while !done { pump(0.05) }
    }
    let m = Model()
    pump(0.5)
    let kc = KeychainStore()
    var list: [Account] = []
    for id in ["a", "b", "c"] {
        let dir = home + "/accounts/\(id)/config"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? writeProfile(dir + "/.claude.json", account: ["accountUuid": "u\(id)", "organizationUuid": "o\(id)", "emailAddress": "\(id)@t.com"])
        list.append(Account(id: id, label: id.uppercased(), configDir: dir))
    }
    let dirs = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.configDir) })
    try? fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
    try? writeProfile(home + "/.claude.json", account: ["accountUuid": "ua", "organizationUuid": "oa", "emailAddress": "a@t.com"])
    for id in ["b", "c"] {
        try? kc.write(.account(dirs[id]!), ["claudeAiOauth": ["accessToken": "x", "refreshToken": "r", "refreshTokenExpiresAt": 9_999_999_999_999], "organizationUuid": "o\(id)"])
    }
    defer { for id in ["b", "c"] { try? kc.delete(.account(dirs[id]!)) } }

    func writeJSON(_ name: String, _ obj: [String: Any]) {
        try? JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: home + "/" + name))
    }
    writeJSON("weekly.json", ["default": 50, dirs["b"]!: 10, dirs["c"]!: 20])
    func calls() -> [[String: Any]] {
        ((try? String(contentsOfFile: home + "/claude.log", encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
    func pings() -> [[String: Any]] { calls().filter { ($0["args"] as? [String])?.prefix(2) == ["-p", "hi"] } }
    /// 假装额度缓存是 seconds 秒前读的
    func age(_ seconds: TimeInterval) {
        for path in [home + "/.claude.json"] + list.map({ $0.configDir + "/.claude.json" }) {
            guard var doc = readProfile(path), var c = doc["cachedUsageUtilization"] as? [String: Any] else { continue }
            c["fetchedAtMs"] = (Date().timeIntervalSince1970 - seconds) * 1000
            doc["cachedUsageUtilization"] = c
            try? JSONSerialization.data(withJSONObject: doc).write(to: URL(fileURLWithPath: path))
        }
        m.reloadStates()
    }
    /// 回到"三个号都空闲、没有任何记录"
    func reset() {
        for f in ["windows.json", "claude.log", "pingfail", "offline"] { try? fm.removeItem(atPath: home + "/" + f) }
        m.store.warmupRecords = nil; m.warmupHolds = [:]
        wait { await m.refreshAll(force: true) }
        try? fm.removeItem(atPath: home + "/claude.log")
    }

    m.store.accounts = list; m.reloadStates()
    reset()
    check("沙盒就绪：三个号都能用、都没开始计时", list.allSatisfy { m.states[$0.id]?.loggedIn == true && m.states[$0.id]?.fiveIdle == true })
    wait { await m.warmupTick() }
    check("开关没开时什么都不发", pings().isEmpty && m.warmupStatus == "未开启")

    m.store.warmupEnabled = true
    wait { await m.warmupTick() }
    check("开启后只激活一个号：B", pings().count == 1 && pings().first?["cfg"] as? String == dirs["b"])
    let args = pings().first?["args"] as? [String] ?? []
    check("用最小的请求：Haiku、安全模式、不存对话、不带工具",
          args.contains("haiku") && args.contains("--safe-mode") && args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"))
    let env = pings().first?["env"] as? [String] ?? []
    check("测试前提：本进程环境里确实有 API 密钥变量", ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil)
    check("API 密钥等环境变量没有带给 claude", !env.contains("ANTHROPIC_API_KEY") && !env.contains("CLAUDE_CODE_USE_BEDROCK") && env.contains("CLAUDE_CONFIG_DIR"))
    check("在空文件夹里运行", (pings().first?["cwd"] as? String)?.hasSuffix("/warmup") == true)
    check("记录为已发送，面板显示等待核对", m.store.warmupRecords?["b"]?.status == .sent && m.warmupStatus.contains("核对") && m.warming == nil && !m.refreshing)
    wait { await m.warmupTick() }
    check("紧接着再跑一次：不会重复发", pings().count == 1)

    m.store.warmupRecords?["b"]?.at = Date().addingTimeInterval(-80)
    age(100)
    wait { await m.warmupTick() }
    check("一分钟后核对：确认 B 已开始计时", m.store.warmupRecords?["b"]?.status == .confirmed && (m.states["b"]?.fiveReset ?? .distantPast) > Date())
    let waiting: Bool = { if case .wait(let id, let t) = m.currentWarmupPlan() { return id == "c" && t.timeIntervalSinceNow > 5880 && t.timeIntervalSinceNow <= 6001 }; return false }()
    check("错开中：下一个是 C，约 1 小时 40 分后", waiting && pings().count == 1 && m.warmupStatus.contains("错开"))
    check("记录存进了设置文件", (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }.map { $0.warmupRecords?["b"]?.status == .confirmed && $0.warmupEnabled == true } ?? false)

    m.store.warmupStagger = false
    wait { await m.warmupTick() }
    check("关掉错开：C 和 A 马上也激活", pings().count == 3)
    check("正在使用的 A 走默认位置（不带账号目录）", pings().last?["cfg"] as? String == "" && !((pings().last?["env"] as? [String]) ?? []).contains("CLAUDE_CONFIG_DIR"))

    m.store.warmupStagger = true
    reset()
    fm.createFile(atPath: home + "/pingfail", contents: nil)
    wait { await m.warmupTick() }
    check("发送失败：三个号各试一次，记为失败", pings().count == 3 && m.store.warmupRecords?.values.allSatisfy { $0.status == .failed && $0.fails == 1 } == true)
    wait { await m.warmupTick() }
    check("失败后不马上重试，面板说明什么时候再试", pings().count == 3 && m.warmupStatus.contains("没成功"))

    reset()
    age(1000)
    fm.createFile(atPath: home + "/offline", contents: nil)
    wait { await m.warmupTick() }
    check("读不到最新额度（断网）：一条都不发", pings().isEmpty && m.warmupHolds.count == 3 && m.warmupStatus.contains("读不到"))

    reset()
    age(1000)
    writeJSON("windows.json", [dirs["b"]!: "2099-01-01T00:00:00+00:00"])
    wait { await m.warmupTick() }
    check("发之前先重新读额度：发现 B 其实已在计时，不给它发", !pings().contains { $0["cfg"] as? String == dirs["b"] })

    reset()
    m.store.warmupRecords = ["b": WarmupRecord(at: Date().addingTimeInterval(-Warmup.window - 60), status: .sent, fails: 0)]
    m.store.warmupStagger = false
    wait { await m.warmupTick() }
    check("很久以前没核对的记录不算失败，账号照常激活", m.store.warmupRecords?["b"]?.fails == 0 && pings().contains { $0["cfg"] as? String == dirs["b"] })

    m.warming = "b"
    m.switchTo(list[1])
    check("正在预热时不切换账号", !m.switching && m.notice?.contains("预热") == true)
    m.warming = nil

    // MARK: 4. 设置窗口里真的点开关
    print("\n设置窗口：")
    _ = NSApplication.shared
    func views<T: NSView>(_ v: NSView?, _ type: T.Type) -> [T] {
        guard let v else { return [] }
        return ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, type) }
    }
    reset()
    m.store.warmupEnabled = false
    m.store.warmupStagger = true
    SettingsController.shared.open(m)
    pump(1.0)
    let w = SettingsController.shared.window
    // 从上到下：开机启动、自动开始倒计时、错开、系统通知、显示小组件、自动检查更新（"额度显示"是已用 / 剩余的分段选择，不是开关）
    let switches = views(w?.contentView, NSSwitch.self).sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
    let quota = views(w?.contentView, NSSegmentedControl.self).first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "已用" && $0.label(forSegment: 1) == "剩余" }
    func pickQuota(_ i: Int) { guard let q = quota else { return }; q.selectedSegment = i; _ = q.sendAction(q.action, to: q.target) }
    check("设置窗口打开，有 6 个开关（实际 \(switches.count) 个）和\"额度显示\"的已用 / 剩余选择", w?.isVisible == true && switches.count == 6 && quota != nil)
    if switches.count == 6, let quota {
        check("额度显示默认选着\"已用\"", !m.showRemaining && quota.selectedSegment == 0)
        pickQuota(1); pump(0.8)
        check("选\"剩余\"：改成显示剩余额度，并且存进设置文件", m.showRemaining && loadStore(readOnly: true).store.showRemaining == true && w?.attachedSheet == nil)
        pickQuota(0); pump(0.8)
        check("选回\"已用\"：回到显示已用额度", !m.showRemaining)
        func confirmButton(_ title: String) -> NSButton? { views(w?.attachedSheet?.contentView, NSButton.self).first { $0.title == title } }
        switches[1].performClick(nil); pump(1.0)
        check("点预热开关：先弹确认框，还没开启", confirmButton("开启") != nil && !m.warmupOn)
        confirmButton("取消")?.performClick(nil); pump(1.0)
        check("点取消：保持关闭", w?.attachedSheet == nil && !m.warmupOn)
        switches[1].performClick(nil); pump(1.0)
        confirmButton("开启")?.performClick(nil); pump(1.5)
        check("点开启：预热打开，并马上激活一个账号", m.warmupOn && pings().count == 1)
        switches[2].performClick(nil); pump(1.5)
        check("点错开开关：关掉错开，其余账号接着激活", !m.staggerOn && pings().count == 3)
        switches[1].performClick(nil); pump(0.8)
        check("再点预热开关：直接关闭，不弹框", !m.warmupOn && w?.attachedSheet == nil)
    }
    w?.close()

    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
