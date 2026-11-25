import AppKit

// 打开终端的测试：--terminaltest（沙盒）。生成的启动脚本用真的 zsh 跑一遍，claude 换成只记录参数的假程序；
// 沙盒里不会真的弹出"终端"应用。

@MainActor
func runTerminalTest() -> Int32 {
    guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    let fm = FileManager.default

    print("附加参数怎么拆：")
    check("空的就是没有参数", splitArguments("   ") == [])
    check("按空格拆开", splitArguments(" --continue   --model opus ") == ["--continue", "--model", "opus"])
    check("引号里的空格保留", splitArguments("--append-system-prompt \"简洁 回答\" -x 'a b'") == ["--append-system-prompt", "简洁 回答", "-x", "a b"])
    check("系统把引号变成“”也认得", splitArguments("--append-system-prompt “简洁 回答”") == ["--append-system-prompt", "简洁 回答"])
    check("系统把 -- 变成 — 也认得", splitArguments("—debug —model opus") == ["--debug", "--model", "opus"])
    check("引号里面的“”原样保留", splitArguments("\"说“好”\"") == ["说“好”"])
    check("空引号是一个空参数", splitArguments("--x \"\"") == ["--x", ""])
    check("引号没配对要拦下", splitArguments("--x \"abc") == nil && splitArguments("“abc") == nil)
    var list: [String] = []
    for i in 0..<14 { list = addRecent("/p/\(i)", to: list) }
    list = addRecent("/p/10", to: list)
    check("最近目录：新的在前、不重复、最多 \(recentDirLimit) 个", list.first == "/p/10" && list.count == recentDirLimit && Set(list).count == list.count)

    // 假 claude：记下参数、目录、账号目录和相关环境变量；"auth login" 时按 login-as.json 假装登录某个账号
    let fake = #"""
    #!/usr/bin/python3
    import json, os, sys, subprocess, hashlib
    root = os.environ["CAB_TEST_ROOT"]
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    args = sys.argv[1:]
    import time
    with open(root + "/ran.log", "a") as f:
        env = sorted(k for k in os.environ if k.startswith("ANTHROPIC_") or k.startswith("CLAUDE_CODE_"))
        f.write(json.dumps({"args": args, "cwd": os.path.realpath(os.getcwd()), "cfg": cfg, "env": env}) + "\n")
    if args[:1] == ["--settings"]:
        waited = 0
        while os.path.exists(root + "/hold") and waited < 40:
            time.sleep(0.1); waited += 0.1
    if args[:2] == ["auth", "login"]:
        who = json.load(open(root + "/login-as.json"))
        if not who: sys.exit(1)
        path = cfg + "/.claude.json"
        try: doc = json.load(open(path))
        except Exception: doc = {}
        doc["oauthAccount"] = {"accountUuid": "u" + who["id"], "organizationUuid": "o" + who["id"], "emailAddress": who["id"] + "@t.com"}
        json.dump(doc, open(path, "w"))
        secret = json.dumps({"claudeAiOauth": {"accessToken": "x", "refreshToken": "term-" + who["id"], "refreshTokenExpiresAt": 9999999999999},
                             "organizationUuid": "o" + who["id"]})
        service = "CABTEST-credentials-" + hashlib.sha256(cfg.encode()).hexdigest()[:8]
        subprocess.run(["/usr/bin/security", "add-generic-password", "-U", "-a", os.environ["USER"], "-s", service, "-X", secret.encode().hex()],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    """#
    let bin = home + "/.local/bin"
    try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try? fake.write(toFile: bin + "/claude", atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/claude")

    // 故意弄脏的终端配置：带第三方密钥和接口，还用同名函数、别名劫持 claude 和 cd
    let zdot = home + "/zdot"
    try? fm.createDirectory(atPath: zdot, withIntermediateDirectories: true)
    try? """
    export PATH=\(shQuote(bin)):$PATH
    export ANTHROPIC_API_KEY=sk-from-rc ANTHROPIC_BASE_URL=http://127.0.0.1:9 ANTHROPIC_SOMETHING_NEW=1
    export CLAUDE_CODE_OAUTH_TOKEN=from-rc CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CONFIG_DIR=/leftover
    claude() { touch "$CAB_TEST_ROOT/hijacked" }
    alias cd='touch "$CAB_TEST_ROOT/hijacked" #'

    """.write(toFile: zdot + "/.zshrc", atomically: true, encoding: .utf8)

    // 沙盒账号：A 在使用中，B 在自己的账号目录里有登录。默认配置里还故意配了第三方接口
    _ = NSApplication.shared
    func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    func wait(_ op: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await op(); done = true }
        while !done { pump(0.05) }
    }
    let m = Model()
    pump(0.3)
    let kc = KeychainStore()
    var accounts: [Account] = []
    for id in ["a", "b"] {
        let dir = home + "/accounts/\(id)/config"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? writeProfile(dir + "/.claude.json", account: ["accountUuid": "u\(id)", "organizationUuid": "o\(id)", "emailAddress": "\(id)@t.com"])
        accounts.append(Account(id: id, label: id.uppercased(), configDir: dir))
    }
    let a = accounts[0], b = accounts[1]
    func login(_ token: String, _ org: String) -> Secret { ["claudeAiOauth": ["accessToken": "x", "refreshToken": token, "refreshTokenExpiresAt": 9_999_999_999_999], "organizationUuid": org] }
    func writeJSON(_ path: String, _ o: Any) { try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: path)) }
    try? fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
    writeJSON(home + "/.claude.json", ["oauthAccount": ["accountUuid": "ua", "organizationUuid": "oa", "emailAddress": "a@t.com"],
                                       "theme": "dark", "mcpServers": ["shared": ["command": "x"]]])
    writeJSON(home + "/.claude/settings.json", ["apiKeyHelper": "echo sk", "env": ["ANTHROPIC_BASE_URL": "http://third.party", "KEEP_ME": "1"]])
    try? kc.write(.defaultSlot, login("switch-a", "oa"))
    try? kc.write(.account(b.configDir), login("switch-b", "ob"))
    defer {
        for s: Slot in [.defaultSlot, .account(a.configDir), .account(b.configDir), .account(terminalDir(a)), .account(terminalDir(b))] { try? kc.delete(s) }
        kc.deleteBackup()
    }
    m.store.accounts = accounts; m.reloadStates()

    let projectA = home + "/项目 甲", projectB = home + "/项目'乙 $(touch hacked)"
    for p in [projectA, projectB] { try? fm.createDirectory(atPath: p + "/.claude", withIntermediateDirectories: true) }
    writeJSON(projectB + "/.claude/settings.local.json", ["env": ["ANTHROPIC_PROJECT_ONLY": "x"]])

    let launchDir = supportDir + "/launch"
    func scripts() -> [String] { ((try? fm.contentsOfDirectory(atPath: launchDir)) ?? []).filter { $0.hasPrefix("open-") }.sorted() }
    struct Ran { let args: [String]; let cwd: String; let cfg: String; let env: [String] }
    var output = ""
    /// 像"终端"应用那样用交互登录 zsh 执行启动脚本，返回假 claude 每次被调用的情况
    func run(_ script: String, loginAs: String? = nil) -> [Ran] {
        try? fm.removeItem(atPath: home + "/ran.log")
        writeJSON(home + "/login-as.json", loginAs.map { ["id": $0] } ?? [:])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-il", launchDir + "/" + script]
        let real = ProcessInfo.processInfo.environment
        p.environment = ["HOME": real["HOME"] ?? "", "USER": NSUserName(), "ZDOTDIR": zdot, "PATH": "/usr/bin:/bin", "CAB_TEST_ROOT": home]
        p.currentDirectoryURL = URL(fileURLWithPath: home)
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return ((try? String(contentsOfFile: home + "/ran.log", encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            guard let o = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] else { return nil }
            let args = o["args"] as? [String] ?? []
            guard args.first != "-p" else { return nil }          // 后台查额度的调用不算
            return Ran(args: args, cwd: o["cwd"] as? String ?? "", cfg: o["cfg"] as? String ?? "", env: o["env"] as? [String] ?? [])
        }
    }
    func real(_ p: String) -> String { p.withCString { c in realpath(c, nil).map { String(cString: $0) } ?? p } }
    /// 让程序生成启动脚本（还没执行）
    func make(_ acc: Account, _ prefs: TerminalPrefs, independent: Bool = false) -> String? {
        for s in scripts() { try? fm.removeItem(atPath: launchDir + "/" + s) }
        guard m.openTerminal(acc, prefs, independent: independent) == nil else { return nil }
        return scripts().first
    }
    func open(_ acc: Account, _ prefs: TerminalPrefs, independent: Bool = false, loginAs: String? = nil) -> [Ran] {
        guard let s = make(acc, prefs, independent: independent) else { return [] }
        return run(s, loginAs: loginAs)
    }
    func overrides(_ r: Ran?) -> [String: Any] {
        guard let a = r?.args, a.count > 1, a[0] == "--settings" else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: Data(a[1].utf8))) as? [String: Any]) ?? [:]
    }
    func plain(_ dir: String) -> TerminalPrefs { TerminalPrefs(dir: dir, skipPermissions: false, args: "") }

    print("\n默认：沿用现有登录，不用再登录：")
    check("B（没在使用）用账号自己的登录，A（使用中）走默认位置", m.terminalMode(b) == .shared && m.terminalMode(a) == .live)
    // B 的账号目录像是从 cc-switch 导入的（不在本程序目录下）：不该被改动
    let bProfileBefore = FileManager.default.contents(atPath: b.configDir + "/.claude.json")
    let tricky = "--append-system-prompt \"回答; touch hacked && echo $(whoami)\" *"
    let first = open(b, TerminalPrefs(dir: projectB, skipPermissions: true, args: tricky))
    check("B：直接启动，没有登录步骤", first.count == 1 && first[0].args.first == "--settings")
    check("用 B 自己的账号目录，进入所选目录", first.first?.cfg == b.configDir && first.first?.cwd == real(projectB))
    check("终端配置里的密钥、接口、令牌、Bedrock 变量全部清掉", first.first?.env.isEmpty == true)
    check("同名的别名和函数劫持不了", !fm.fileExists(atPath: home + "/hijacked"))
    check("参数原样传给 claude，特殊字符不会被当命令执行",
          Array((first.first?.args ?? []).dropFirst(2)) == ["--dangerously-skip-permissions", "--append-system-prompt", "回答; touch hacked && echo $(whoami)", "*"]
          && !fm.fileExists(atPath: home + "/hacked") && !fm.fileExists(atPath: projectB + "/hacked"))
    let env = overrides(first.first)["env"] as? [String: String] ?? [:]
    check("带上覆盖设置：能改走别处的键全部置空，取密钥脚本也关掉",
          overrides(first.first)["apiKeyHelper"] as? String == "" && (routingKeys + modelKeys).allSatisfy { env[$0] == "" } && env["CLAUDE_CONFIG_DIR"] == b.configDir)
    check("项目设置里出现的其他 ANTHROPIC_ 键也压掉，无关的键不动", env["ANTHROPIC_PROJECT_ONLY"] == "" && env["KEEP_ME"] == nil)
    check("能发现设置里配了第三方接口（窗口里提示）", scanSettings(settingsFiles(cwd: projectA)).redirects)
    check("默认的设置文件没有被改动", (readProfile(home + "/.claude/settings.json")?["env"] as? [String: String])?["ANTHROPIC_BASE_URL"] == "http://third.party")
    check("从 cc-switch 导入那样的账号目录不被改动", FileManager.default.contents(atPath: b.configDir + "/.claude.json") == bProfileBefore)
    check("脚本执行后自己删掉", scripts().isEmpty)
    let liveRun = open(a, plain(projectA))
    let liveEnv = overrides(liveRun.first)["env"] as? [String: String] ?? [:]
    check("A：走默认位置（不带账号目录），照样直接启动并带覆盖设置",
          liveRun.count == 1 && liveRun[0].cfg == "" && liveEnv["ANTHROPIC_BASE_URL"] == "" && liveEnv["CLAUDE_CONFIG_DIR"] == nil)
    let dashed = open(b, TerminalPrefs(dir: projectB, skipPermissions: false, args: "-- 你好"))
    check("附加参数里有 -- 时，覆盖设置排在它前面", dashed.first.map { $0.args.first == "--settings" && Array($0.args.suffix(2)) == ["--", "你好"] } ?? false)
    check("附加参数里带 --settings 会被拦下",
          m.openTerminal(b, TerminalPrefs(dir: projectB, skipPermissions: false, args: "--settings x.json")) != nil
          && m.openTerminal(b, TerminalPrefs(dir: projectB, skipPermissions: false, args: "--settings={}")) != nil)

    print("\n启动前核对账号：")
    let stale = make(b, plain(projectB))
    try? writeProfile(b.configDir + "/.claude.json", account: ["accountUuid": "uz", "organizationUuid": "oz", "emailAddress": "z@t.com"])
    let staleRun = stale.map { run($0) } ?? [Ran]()
    check("账号目录里换成了别人：不启动", stale != nil && staleRun.isEmpty && output.contains("没有启动 claude"))
    try? writeProfile(b.configDir + "/.claude.json", account: ["accountUuid": "ub", "organizationUuid": "ob", "emailAddress": "b@t.com"])
    let staleLive = make(a, plain(projectA))
    let defaultProfile = FileManager.default.contents(atPath: home + "/.claude.json")
    try? writeProfile(home + "/.claude.json", account: ["accountUuid": "uz", "organizationUuid": "oz", "emailAddress": "z@t.com"])
    let staleLiveRun = staleLive.map { run($0) } ?? [Ran]()
    check("默认位置在开窗口后换了人：不启动", staleLive != nil && staleLiveRun.isEmpty)
    try? defaultProfile?.write(to: URL(fileURLWithPath: home + "/.claude.json"))
    m.reloadStates()

    print("\n可选的完全独立（多登录一次）：")
    let wrong = open(a, plain(projectA), independent: true, loginAs: "b")
    check("浏览器里授权成了别的账号：不启动 claude，并说明原因",
          wrong.count == 1 && wrong[0].args == ["auth", "login", "--claudeai", "--email", "a@t.com"] && output.contains("没有启动 claude"))
    check("这时 A 仍按原来的方式开", m.terminalMode(a) == .live)
    let cancelled = open(a, plain(projectA), independent: true)
    check("登录取消或失败：不启动 claude", cancelled.count == 1 && cancelled[0].args.first == "auth")
    let ok = open(a, plain(projectA), independent: true, loginAs: "a")
    check("登录对了就启动，用独立目录", ok.count == 2 && ok.last?.cfg == terminalDir(a) && ok.last?.args.first == "--settings" && terminalDir(a) != a.configDir)
    let again = open(a, plain(projectA))
    check("以后不用勾也自动走完全独立，不再登录", m.terminalMode(a) == .dedicated && again.count == 1 && again[0].cfg == terminalDir(a))

    print("\n切换前提醒：")
    check("没开着终端时不提醒", runningTerminals().isEmpty && switchWarning(target: b, name: "B", terminals: []) == nil)
    check("开着完全独立的终端也不提醒", switchWarning(target: b, name: "B", terminals: [RunningTerminal(mode: .dedicated, accountId: "b")]) == nil)
    check("开着别的账号自己登录的终端不提醒", switchWarning(target: b, name: "B", terminals: [RunningTerminal(mode: .shared, accountId: "c")]) == nil)
    try? fm.removeItem(atPath: terminalDir(a)); try? kc.delete(.account(terminalDir(a)))     // A 退回默认方式，下面要一个跟随默认的终端
    fm.createFile(atPath: home + "/hold", contents: nil)
    var held: [Process] = []
    for (acc, dir) in [(b, projectB), (a, projectA)] {
        guard let s = make(acc, plain(dir)) else { continue }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-il", launchDir + "/" + s]
        p.environment = ["HOME": ProcessInfo.processInfo.environment["HOME"] ?? "", "USER": NSUserName(), "ZDOTDIR": zdot, "PATH": "/usr/bin:/bin", "CAB_TEST_ROOT": home]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); held.append(p)
        let until = Date().addingTimeInterval(10)
        while runningTerminals().count < held.count && Date() < until { pump(0.1) }
    }
    check("认得出开着的两个终端", Set(runningTerminals().map { "\($0.mode.rawValue)|\($0.accountId)" }) == ["shared|b", "live|a"])
    var asked: [String] = []
    m.confirmSwitch = { _, message in asked.append(message); return false }
    m.switchTo(b); pump(0.5)
    check("切到 B 前提醒：一个会掉线、一个会换号", asked.count == 1 && asked[0].contains("1 个用「B」开着的终端会掉线") && asked[0].contains("1 个跟着默认登录"))
    check("点取消：什么都不动", !m.switching && defaultOwner()?.key == "ua:oa" && terminalLoginMatches(dir: b.configDir, key: "ub:ob"))
    check("没有多做一份独立登录时，B 仍是账号自己的登录", m.terminalMode(b) == .shared)
    // 给 B 再放一份完全独立的登录（直接写进沙盒，避免和还开着的终端互相等），验证切换动不到它
    try? prepareTerminalDir(terminalDir(b))
    try? writeProfile(terminalDir(b) + "/.claude.json", account: ["accountUuid": "ub", "organizationUuid": "ob", "emailAddress": "b@t.com"])
    try? kc.write(.account(terminalDir(b)), login("term-b", "ob"))
    let before = (try? kc.read(.account(terminalDir(b))) ?? nil).map(fingerprint)
    m.confirmSwitch = { _, message in asked.append(message); return true }
    m.switchTo(b)
    let until = Date().addingTimeInterval(20)
    while (m.switching || defaultOwner()?.key != "ub:ob") && Date() < until { pump(0.1) }
    m.reloadStates()
    check("点仍然切换：默认位置换成 B", asked.count == 2 && m.states["b"]?.live == true)
    check("B 账号目录里的登录确实搬走了（所以会掉线）", !terminalLoginMatches(dir: b.configDir, key: "ub:ob"))
    check("完全独立的登录一个字节都没动，照样可用",
          before != nil && (try? kc.read(.account(terminalDir(b))) ?? nil).map(fingerprint) == before && m.terminalMode(b) == .dedicated)
    check("切走后 A 用回自己账号目录里的登录", m.terminalMode(a) == .shared)
    try? fm.removeItem(atPath: home + "/hold")
    for p in held { p.waitUntilExit() }
    check("终端关掉后记录自动清掉", runningTerminals().isEmpty && ((try? fm.contentsOfDirectory(atPath: runningDir)) ?? []).isEmpty)
    let afterSwitch = open(b, plain(projectB))
    check("切成使用中的 B，完全独立的终端照样直接打开", afterSwitch.count == 1 && afterSwitch[0].cfg == terminalDir(b))

    print("\n工作环境：")
    let tdir = terminalDir(b), profile = tdir + "/.claude.json"
    func servers() -> [String] { ((readProfile(profile)?["mcpServers"] as? [String: Any]) ?? [:]).keys.sorted() }
    check("设置、对话记录链接到默认目录", (try? fm.destinationOfSymbolicLink(atPath: tdir + "/settings.json")) == home + "/.claude/settings.json"
          && (try? fm.destinationOfSymbolicLink(atPath: tdir + "/projects")) == home + "/.claude/projects")
    check("默认配置的 MCP 服务器带过来了", servers() == ["shared"])
    var doc = readProfile(profile) ?? [:]
    doc["mcpServers"] = ["shared": ["command": "x"], "mine": ["command": "y"]]; writeJSON(profile, doc)
    var def = readProfile(home + "/.claude.json") ?? [:]
    def["mcpServers"] = ["newer": ["command": "z"]]; writeJSON(home + "/.claude.json", def)
    try? prepareTerminalDir(tdir)
    check("默认配置增删服务器会同步，终端里自己加的保留", servers() == ["mine", "newer"])
    check("终端自己的登录资料没有被覆盖", identity(ofDir: tdir)?.key == "ub:ob")
    let own = Account(id: "c", label: "C", configDir: supportDir + "/accounts/c/config")
    try? fm.createDirectory(atPath: own.configDir, withIntermediateDirectories: true)
    try? writeProfile(own.configDir + "/.claude.json", account: ["accountUuid": "uc", "organizationUuid": "oc", "emailAddress": "c@t.com"])
    try? kc.write(.account(own.configDir), login("switch-c", "oc"))
    m.store.accounts.append(own); m.reloadStates()
    _ = make(own, plain(projectA))
    check("本程序自己添加的账号，开终端时也带上默认的 MCP 服务器",
          ((readProfile(own.configDir + "/.claude.json")?["mcpServers"] as? [String: Any]) ?? [:]).keys.contains("newer")
          && identity(ofDir: own.configDir)?.key == "uc:oc")
    try? kc.delete(.account(own.configDir)); m.store.accounts.removeLast()

    print("\n登录续期：")
    try? fm.removeItem(atPath: home + "/ran.log")
    m.store.terminalKept = nil
    let wasRefreshing = Date().addingTimeInterval(20)
    while m.refreshing && Date() < wasRefreshing { pump(0.1) }
    wait { await m.keepTerminalLogins() }
    wait { await m.keepTerminalLogins() }
    let kept = ((try? String(contentsOfFile: home + "/ran.log", encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("terminals") }
    check("完全独立的登录查一次额度续期，12 小时内不重复", kept.count == 1 && kept.allSatisfy { $0.contains("/usage") })

    print("\n记录：")
    check("两个账号各记各的", m.store.terminalPrefs?["a"]?.dir == projectA && m.store.terminalPrefs?["b"]?.dir == projectB)
    check("最近用过：两个目录都在，后开的在前", Array(m.recentDirs.prefix(2)) == [projectA, projectB])
    let saved = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
    check("记录存进了设置文件，重开程序还在", saved?.terminalPrefs?["b"] == m.store.terminalPrefs?["b"] && saved?.recentDirs == m.store.recentDirs)
    let old = Data("{\"accounts\":[],\"workDir\":\"/tmp\"}".utf8)
    check("旧版设置文件照样能读", (try? JSONDecoder().decode(Store.self, from: old)).map { $0.terminalPrefs == nil && $0.recentDirs == nil } ?? false)
    m.removeRecent(projectB)
    check("能从最近用过里去掉一个（文件夹还在）", !m.recentDirs.contains(projectB) && isDirectory(projectB))

    for s in scripts() { try? fm.removeItem(atPath: launchDir + "/" + s) }
    check("目录不存在：不打开", m.openTerminal(a, TerminalPrefs(dir: home + "/没有这个", skipPermissions: false, args: "")) != nil && scripts().isEmpty)
    check("引号没配对：不打开", m.openTerminal(a, TerminalPrefs(dir: projectA, skipPermissions: false, args: "\"x")) != nil && scripts().isEmpty)
    let gone = home + "/马上删掉"
    try? fm.createDirectory(atPath: gone, withIntermediateDirectories: true)
    _ = m.openTerminal(b, TerminalPrefs(dir: gone, skipPermissions: true, args: ""))
    try? fm.removeItem(atPath: gone)
    check("脚本运行前目录没了：不会换个地方启动 claude", scripts().count == 1 && run(scripts().first ?? "").isEmpty)
    for s in scripts() { try? fm.removeItem(atPath: launchDir + "/" + s) }

    print("\n窗口：")
    func views<T: NSView>(_ v: NSView?, _ type: T.Type) -> [T] {
        guard let v else { return [] }
        return ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, type) }
    }
    /// 在窗口里按一个键：回车对应「打开终端」，Esc 对应「取消」
    func press(_ characters: String, _ code: UInt16) {
        guard let w = TerminalController.shared.window,
              let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: code) else { return }
        if !w.performKeyEquivalent(with: e) { w.sendEvent(e) }
    }
    m.store.terminalPrefs = ["b": TerminalPrefs(dir: projectB, skipPermissions: false, args: "--continue")]
    TerminalController.shared.open(m, account: b); pump(0.8)
    check("窗口打开，填着这个账号上次的内容", TerminalController.shared.window?.isVisible == true
          && views(TerminalController.shared.window?.contentView, NSTextField.self).contains { $0.stringValue == "--continue" })
    check("没点打开之前什么都不做", scripts().isEmpty)
    press("\r", 36); pump(0.8)
    check("直接按回车（打开终端）：生成脚本并关掉窗口", scripts().count == 1 && TerminalController.shared.window?.isVisible != true)
    let rw = run(scripts().first ?? "")
    check("打开的就是窗口里那一套", rw.count == 1 && rw[0].cwd == real(projectB) && rw[0].args.last == "--continue" && rw[0].cfg == terminalDir(b))
    TerminalController.shared.open(m, account: a); pump(0.5)
    press("\u{1b}", 53); pump(0.5)
    check("按 Esc（取消）：关窗口，不开终端", TerminalController.shared.window?.isVisible != true && scripts().isEmpty)

    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
