// CCBaton — 菜单栏里的 Claude Code 多账号小工具
// 读额度、添加账号、一键切换 Claude Code 登录、给某个账号开终端、可选的额度预热。
// 令牌只在钥匙串里被 /usr/bin/security 搬动（见 Switcher.swift），本程序的文件里不存令牌。

import SwiftUI
import AppKit

// MARK: - 路径（CAB_TEST_ROOT 只给自检用：把所有路径和钥匙串条目名都换成沙盒的）

let testRoot: String? = ProcessInfo.processInfo.environment["CAB_TEST_ROOT"]
let home: String = testRoot ?? FileManager.default.homeDirectoryForCurrentUser.path
let servicePrefix: String = testRoot == nil ? "Claude Code-credentials" : "CABTEST-credentials"
let supportDir = home + "/Library/Application Support/ClaudeAccountBar"
let storeURL = URL(fileURLWithPath: supportDir + "/accounts.json")
let ccSwitchRoot = home + "/.cc-switch"
let ccSwitchBundleId = "com.ccswitch.desktop"

/// 版本号只在项目根目录的 VERSION 文件里维护，build.sh 编译时写进 Info.plist，这里读出来
let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - 数据

struct Account: Codable, Identifiable, Equatable {
    var id: String            // 目录名（32 位 hex）
    var label: String         // 用户起的名字，可为空
    var configDir: String     // 这个账号的 CLAUDE_CONFIG_DIR
}

struct AccountState {
    var live = false          // 登录现在就在默认位置（Claude Code 默认用的就是它）
    var loggedIn = false      // 能用：在用中，或自己的钥匙串槽位里有登录
    var email = ""
    var plan = ""
    var orgName = ""
    var fiveHour: Double?
    var sevenDay: Double?
    var fiveReset: Date?
    var fiveIdle = false      // 服务器明确说现在没有 5 小时窗口（还没开始计时）
    var sevenReset: Date?
    var fetchedAt: Date?
}

struct Store: Codable {
    var accounts: [Account]
    var workDir: String
    var widgetVisible: Bool?
    var widgetOrigin: [Double]?
    var widgetSize: String?     // small / medium / large，默认 medium
    var alertsEnabled: Bool?    // 额度告急时弹系统通知，默认开
    var alerted: [String]?      // 已经提醒过的记号（id|窗口|重置时间|档位），避免重复弹
    var warmupEnabled: Bool?    // 额度预热，默认关
    var warmupStagger: Bool?    // 预热时错开各账号的重置时间，默认开
    var warmupRecords: [String: WarmupRecord]?   // 每个账号上次预热的时间和结果
    var recentDirs: [String]?   // 最近在哪些目录开过终端
    var terminalPrefs: [String: TerminalPrefs]?  // 每个账号上次开终端的目录和参数
    var terminalKept: [String: Date]?            // 每个账号的终端登录上次续期的时间
    var colorSlots: [String: Int]?               // 每个账号的头像颜色号，调整顺序后不变
    var autoUpdateCheck: Bool?                   // 自动检查更新，默认开
    var updateCheckedAt: Date?                   // 上次查到版本信息的时间
    var updateRelease: AppRelease?               // 查到的新版本（有它就在版本号前显示红点）

    init(accounts: [Account], workDir: String) { self.accounts = accounts; self.workDir = workDir }

    // 兼容旧版文件：旧版的账号里 configDir 可为空（默认登录），旧版有 activeId
    private struct Legacy: Codable { var id: String; var label: String; var configDir: String? }
    private enum K: String, CodingKey {
        case accounts, workDir, widgetVisible, widgetOrigin, widgetSize, alertsEnabled, alerted, warmupEnabled, warmupStagger, warmupRecords
        case recentDirs, terminalPrefs, terminalKept, colorSlots, autoUpdateCheck, updateCheckedAt, updateRelease
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        var list: [Account] = []
        for old in (try? c.decode([Legacy].self, forKey: .accounts)) ?? [] {
            guard let dir = old.configDir else { continue }     // 旧版的"默认登录"条目丢掉，由程序重新收录
            list.append(Account(id: old.id, label: old.label == "默认登录" ? "" : old.label, configDir: dir))
        }
        accounts = list
        workDir = (try? c.decode(String.self, forKey: .workDir)) ?? home
        widgetVisible = try? c.decode(Bool.self, forKey: .widgetVisible)
        widgetOrigin = try? c.decode([Double].self, forKey: .widgetOrigin)
        widgetSize = try? c.decode(String.self, forKey: .widgetSize)
        alertsEnabled = try? c.decode(Bool.self, forKey: .alertsEnabled)
        alerted = try? c.decode([String].self, forKey: .alerted)
        warmupEnabled = try? c.decode(Bool.self, forKey: .warmupEnabled)
        warmupStagger = try? c.decode(Bool.self, forKey: .warmupStagger)
        warmupRecords = try? c.decode([String: WarmupRecord].self, forKey: .warmupRecords)
        recentDirs = try? c.decode([String].self, forKey: .recentDirs)
        terminalPrefs = try? c.decode([String: TerminalPrefs].self, forKey: .terminalPrefs)
        terminalKept = try? c.decode([String: Date].self, forKey: .terminalKept)
        colorSlots = try? c.decode([String: Int].self, forKey: .colorSlots)
        autoUpdateCheck = try? c.decode(Bool.self, forKey: .autoUpdateCheck)
        updateCheckedAt = try? c.decode(Date.self, forKey: .updateCheckedAt)
        updateRelease = try? c.decode(AppRelease.self, forKey: .updateRelease)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(workDir, forKey: .workDir)
        try c.encodeIfPresent(widgetVisible, forKey: .widgetVisible)
        try c.encodeIfPresent(widgetOrigin, forKey: .widgetOrigin)
        try c.encodeIfPresent(widgetSize, forKey: .widgetSize)
        try c.encodeIfPresent(alertsEnabled, forKey: .alertsEnabled)
        try c.encodeIfPresent(alerted, forKey: .alerted)
        try c.encodeIfPresent(warmupEnabled, forKey: .warmupEnabled)
        try c.encodeIfPresent(warmupStagger, forKey: .warmupStagger)
        try c.encodeIfPresent(warmupRecords, forKey: .warmupRecords)
        try c.encodeIfPresent(recentDirs, forKey: .recentDirs)
        try c.encodeIfPresent(terminalPrefs, forKey: .terminalPrefs)
        try c.encodeIfPresent(terminalKept, forKey: .terminalKept)
        try c.encodeIfPresent(colorSlots, forKey: .colorSlots)
        try c.encodeIfPresent(autoUpdateCheck, forKey: .autoUpdateCheck)
        try c.encodeIfPresent(updateCheckedAt, forKey: .updateCheckedAt)
        try c.encodeIfPresent(updateRelease, forKey: .updateRelease)
    }
}

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
let isoPlain = ISO8601DateFormatter()
func parseDate(_ s: Any?) -> Date? {
    guard let s = s as? String else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

/// 从一个 .claude.json 读账号资料和 Claude Code 缓存的额度
func readState(path: String) -> AccountState {
    var st = AccountState()
    guard let doc = readProfile(path), let oauth = doc["oauthAccount"] as? [String: Any] else { return st }
    st.email = oauth["emailAddress"] as? String ?? ""
    st.orgName = oauth["organizationName"] as? String ?? ""
    let org = oauth["organizationType"] as? String ?? ""
    let plans = ["claude_pro": "Pro", "claude_max": "Max", "claude_team": "Team", "claude_enterprise": "Enterprise"]
    st.plan = plans[org] ?? org
    if let cached = doc["cachedUsageUtilization"] as? [String: Any],
       let util = cached["utilization"] as? [String: Any] {
        // 缓存跟账号走，账号对不上就不信
        let same = (cached["accountUuid"] as? String).map { $0 == (oauth["accountUuid"] as? String) } ?? true
        if same {
            if let ms = cached["fetchedAtMs"] as? Double { st.fetchedAt = Date(timeIntervalSince1970: ms / 1000) }
            if let w = util["five_hour"] as? [String: Any] {
                st.fiveHour = (w["utilization"] as? NSNumber)?.doubleValue
                st.fiveReset = parseDate(w["resets_at"])
                st.fiveIdle = w["resets_at"] is NSNull
            }
            if let w = util["seven_day"] as? [String: Any] {
                st.sevenDay = (w["utilization"] as? NSNumber)?.doubleValue
                st.sevenReset = parseDate(w["resets_at"])
            }
        }
    }
    return st
}

// MARK: - 账号目录

/// 和 cc-switch 一样：把用户 ~/.claude 里的 agents、skills、命令、对话记录等接进来，
/// 这样用任何账号开的终端，工作环境都一样，对话也能用 `claude --resume` 接力。
let sharedItems = ["agents", "commands", "file-history", "output-styles", "plans", "plugins", "projects",
                   "rules", "skills", "todos", "workflows", "CLAUDE.md", "settings.json"]

func prepareAccountDir(_ cfg: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: cfg, withIntermediateDirectories: true)
    let shared = home + "/.claude"
    try fm.createDirectory(atPath: shared + "/projects", withIntermediateDirectories: true)
    for name in sharedItems {
        let src = shared + "/" + name, dst = cfg + "/" + name
        if fm.fileExists(atPath: src), (try? fm.destinationOfSymbolicLink(atPath: dst)) == nil, !fm.fileExists(atPath: dst) {
            try? fm.createSymbolicLink(atPath: dst, withDestinationPath: src)
        }
    }
}

func newLocalId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

// MARK: - 找 claude、刷新额度

func findClaude() -> String? {
    for p in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
    sh.arguments = ["-ilc", "command -v claude"]
    let pipe = Pipe(); sh.standardOutput = pipe; sh.standardError = Pipe()
    guard (try? sh.run()) != nil else { return nil }
    sh.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? nil : out
}

/// 跑一次 claude（不要输入输出），返回退出码；起不来返回 -1。configDir 为 nil 表示默认槽位。
/// 环境里的 ANTHROPIC_*、CLAUDE* 变量一律去掉：从终端启动本程序时，不能让 API 密钥之类改变走的是哪个账号。
func runClaude(_ claude: String, _ arguments: [String], configDir: String?, extraEnv: [String: String] = [:],
               cwd: String = home, timeout: TimeInterval = 45) async -> Int32 {
    await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = arguments
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE") }
            if let d = configDir { env["CLAUDE_CONFIG_DIR"] = d }
            env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
            env["DISABLE_TELEMETRY"] = "1"
            env["DISABLE_ERROR_REPORTING"] = "1"
            env["DISABLE_AUTOUPDATER"] = "1"
            env.merge(extraEnv) { _, new in new }
            p.environment = env
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { cont.resume(returning: -1); return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            p.waitUntilExit()
            killer.cancel()
            cont.resume(returning: p.terminationReason == .exit ? p.terminationStatus : -1)
        }
    }
}

/// 让 Claude Code 自己跑一次 /usage（它自己刷新令牌、自己写缓存，不问模型，0 token）。
func runUsage(claude: String, configDir: String?) async {
    _ = await runClaude(claude, ["-p", "/usage", "--output-format", "json", "--tools", "",
                                 "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence"], configDir: configDir)
}

// MARK: - 状态

@MainActor
final class Model: ObservableObject {
    @Published var store: Store
    @Published var states: [String: AccountState] = [:]
    @Published var refreshing = false
    @Published var switching = false
    @Published var notice: String?
    @Published var toast: String?          // 小组件顶部的短提示（切换结果），几秒后消失
    @Published var warming: String?        // 正在给哪个账号发预热消息
    var warmupHolds: [String: Date] = [:]  // 暂时放一放的账号（读不到最新额度）
    /// 切换会影响开着的终端时先问一下（测试里换掉）
    var confirmSwitch: (_ title: String, _ message: String) -> Bool = { title, message in
        if testRoot != nil { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "仍然切换")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 移除账号前的警告框；返回是否确认（测试里换掉）
    var confirmRemoval: (RemovalPrompt) -> Bool = { prompt in
        if testRoot != nil { return false }
        NSApp.activate(ignoringOtherApps: true)
        return removalAlert(prompt).runModal() == .alertFirstButtonReturn
    }
    /// cc-switch 现在开着没有（测试里换掉）
    var ccSwitchRunning: () -> Bool = {
        testRoot == nil && !NSRunningApplication.runningApplications(withBundleIdentifier: ccSwitchBundleId).isEmpty
    }
    /// cc-switch 现在装着没有（测试里换掉）。没装的话界面里不提它
    var ccSwitchInstalled: () -> Bool = {
        testRoot == nil && NSWorkspace.shared.urlsForApplications(withBundleIdentifier: ccSwitchBundleId)
            .contains { !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) }
    }
    /// 迁移前的确认框（测试里换掉）
    var confirmMigration: (RemovalPrompt) -> Bool = { prompt in
        if testRoot != nil { return false }
        NSApp.activate(ignoringOtherApps: true)
        return removalAlert(prompt, destructive: false).runModal() == .alertFirstButtonReturn
    }
    /// 有几个运行中的程序在用这些账号目录（测试里换掉）
    var processUsingDirs: ([String]) -> Int = { testRoot == nil ? processesUsing($0) : 0 }
    /// 只告诉用户一件事（测试里换掉）
    var tellUser: (_ title: String, _ message: String) -> Void = { title, message in
        if testRoot != nil { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // 软件更新（见 Update.swift）；下面这些函数和值在测试里换掉
    @Published var updatePhase: UpdatePhase = .idle
    var updateAttemptAt: Date?
    var currentVersion = appVersion
    var appBundlePath = Bundle.main.bundlePath
    var updateKey = updatePublicKey
    var bootTime: () -> Date = systemBootTime
    var openLink: (URL) -> Void = { url in if testRoot == nil { NSWorkspace.shared.open(url) } }
    var fetchData: (URL) async throws -> (Data, Int) = { url in
        guard testRoot == nil else { throw SwitchError("测试里不联网") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("CCBaton/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    var startUpdateHelper: (_ script: String, _ arguments: [String]) throws -> Void = { script, arguments in
        guard testRoot == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script] + arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()                     // 本程序退出后它接着干
    }
    var quitForUpdate: () -> Void = { if testRoot == nil { NSApp.terminate(nil) } }

    func showToast(_ t: String) {
        toast = t
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.toast == t { self.toast = nil }
        }
    }

    var lastRun: [String: Date] = [:]
    private var timer: Timer?
    lazy var claudePath: String? = findClaude()
    private let keychain = KeychainStore()

    var live: Account? { store.accounts.first { states[$0.id]?.live == true } }

    init() {
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: storeURL), let s = try? JSONDecoder().decode(Store.self, from: d) {
            store = s
        } else {
            store = Store(accounts: [], workDir: home)
        }
        Switcher(dirOf: { _ in nil }).recover()
        if !Model.readOnly { recoverMigration(); finishPendingUpdate() }
        ensureLiveManaged()
        reloadStates()
        if !Model.readOnly {            // 只读模式（截图、预检）不自动刷新，也不跑 claude
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.ensureLiveManaged()
                    self?.reloadStates()
                    await self?.refreshAll(force: false)
                    await self?.warmupTick()
                    await self?.keepTerminalLogins()
                    await self?.updateTick()
                }
            }
            Task { await refreshAll(force: false); await warmupTick(); await keepTerminalLogins() }
            Task { await updateTick() }
        }
        if !Model.readOnly { Task { @MainActor in WidgetController.shared.apply(self) } }
        if Driver.enabled { Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); Driver.start(self, seconds: 45) } }
    }

    /// 截图、预检、自检这类只读模式下为 true：不允许把任何设置写回文件，也不弹小组件
    static var readOnly = false

    /// 演示模式（只用于生成 README 截图）：界面里隐藏本机特有的入口
    static var demo = false

    func save() {
        if Model.readOnly { return }
        fillColorSlots()
        if let d = try? JSONEncoder().encode(store) { try? d.write(to: storeURL) }
    }

    // 默认位置里现在登录的号，必须有自己的账号目录（切走时登录要收回到那里）
    func ensureLiveManaged() {
        guard let owner = defaultOwner() else { return }
        if store.accounts.contains(where: { identity(ofDir: $0.configDir)?.key == owner.key }) { return }
        if let dir = ccSwitchDir(forKey: owner.key) {
            store.accounts.append(Account(id: ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                                          label: "", configDir: dir))
            save(); return
        }
        // 全新收录：建一个账号目录，资料从默认的 .claude.json 复制
        let id = newLocalId()
        let cfg = "\(supportDir)/accounts/\(id)/config"
        guard (try? prepareAccountDir(cfg)) != nil,
              let acc = readProfile(Slot.defaultSlot.globalConfig)?["oauthAccount"] as? [String: Any],
              (try? writeProfile(cfg + "/.claude.json", account: acc)) != nil else { return }
        store.accounts.append(Account(id: id, label: "", configDir: cfg))
        save()
    }

    private func ccSwitchDir(forKey key: String) -> String? {
        for (_, dir) in ccSwitchAccounts() where identity(ofDir: dir)?.key == key { return dir }
        return nil
    }

    /// cc-switch 里登记的账号：(邮箱, 目录)
    func ccSwitchAccounts() -> [(String, String)] {
        guard let data = FileManager.default.contents(atPath: ccSwitchRoot + "/claude_accounts.json"),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accs = doc["accounts"] as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        for (_, v) in accs.sorted(by: { $0.key < $1.key }) {
            guard let item = v as? [String: Any], let localId = item["localId"] as? String,
                  localId.count == 32, localId.allSatisfy({ $0.isHexDigit }) else { continue }
            out.append((item["email"] as? String ?? localId, "\(ccSwitchRoot)/claude-accounts/\(localId)/config"))
        }
        return out
    }

    func reloadStates() {
        let liveKey = defaultOwner()?.key
        for a in store.accounts {
            let idKey = identity(ofDir: a.configDir)?.key
            let isLive = idKey != nil && idKey == liveKey
            var st = readState(path: isLive ? Slot.defaultSlot.globalConfig : a.configDir + "/.claude.json")
            st.live = isLive
            st.loggedIn = isLive || (idKey != nil && keychain.exists(.account(a.configDir)))
            states[a.id] = st
        }
        checkAlerts()
    }

    var alertsOn: Bool { store.alertsEnabled ?? true }

    /// 额度告急时弹系统通知（只对正在使用的账号，每个重置周期最多两次）
    func checkAlerts() {
        guard alertsOn, Alerter.enabled else { return }
        var done = Set(store.alerted ?? [])
        let items = alertsToFire(accounts: store.accounts, states: states, alerted: done, name: { self.shortDisplayName($0) })
        guard !items.isEmpty else { return }
        for it in items {
            done.formUnion(it.keys)
            Alerter.post(title: it.title, body: it.body)
        }
        // 只留还没过期的记号（记号里第 3 段是重置时间戳）
        let cutoff = Int(Date().timeIntervalSince1970) - 86400
        store.alerted = done.filter { k in (Int(k.split(separator: "|").dropFirst(2).first ?? "0") ?? 0) > cutoff || k.contains("|0|") }.sorted()
        save()
    }

    func setAlerts(_ on: Bool) { store.alertsEnabled = on; save() }

    func sendTestAlert() {
        Alerter.post(title: "CCBaton 测试提醒", body: "能看到这条，说明额度告急时的提醒是通的。")
    }

    /// 修改显示名称。只改本程序里显示的名字，不动真实的 Claude 登录。留空 = 恢复显示邮箱。
    func rename(_ a: Account, to name: String) {
        guard let i = store.accounts.firstIndex(where: { $0.id == a.id }) else { return }
        store.accounts[i].label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        save()
    }

    /// 卡片和小组件里用的短名字：自定义名称原样显示；没改过名时显示邮箱 @ 前面的部分
    func shortDisplayName(_ a: Account) -> String {
        let n = displayName(a)
        return a.label.isEmpty && n.contains("@") ? String(n.split(separator: "@")[0]) : n
    }

    func displayName(_ a: Account) -> String {
        if !a.label.isEmpty { return a.label }
        if let e = states[a.id]?.email, !e.isEmpty { return e }
        return "新账号"
    }

    /// 额度由 Claude Code 自己更新；同一个账号 10 分钟内最多跑一次，除非手动刷新。
    func refreshAll(force: Bool) async {
        guard !refreshing, let claude = claudePath else {
            if claudePath == nil { notice = "找不到 claude 命令" }
            return
        }
        refreshing = true
        for a in store.accounts {
            guard let st = states[a.id], st.loggedIn else { continue }
            if !force, let t = lastRun[a.id], Date().timeIntervalSince(t) < 600 { continue }
            lastRun[a.id] = Date()
            await runUsage(claude: claude, configDir: st.live ? nil : a.configDir)
            reloadStates()
        }
        refreshing = false
    }

    // MARK: 切换

    func switchTo(_ a: Account) {
        guard !switching, let st = states[a.id], !st.live else { return }
        guard warming == nil else { notice = "正在预热账号，几秒后再点切换"; showToast("预热中，请稍后"); return }
        guard st.loggedIn else { notice = "这个账号的登录已失效，请先点「重新登录」"; return }
        guard let key = identity(ofDir: a.configDir)?.key else { notice = "读不到这个账号的资料"; return }
        if let warning = switchWarning(target: a, name: shortDisplayName(a), terminals: runningTerminals()),
           !confirmSwitch("切换到「\(shortDisplayName(a))」会影响开着的终端", warning) { return }
        switching = true
        notice = nil
        let accounts = store.accounts
        let name = displayName(a)
        let dir = a.configDir
        Task.detached {
            let sw = Switcher(dirOf: { k in accounts.first { identity(ofDir: $0.configDir)?.key == k }?.configDir })
            let failure: String?
            do { _ = try sw.checkOut(target: key, targetDir: dir); failure = nil } catch { failure = "\(error)" }
            await MainActor.run {
                self.switching = false
                self.reloadStates()
                if let f = failure {
                    self.notice = "没有切换：\(f)"
                    self.showToast("切换失败")
                } else {
                    self.showToast("已切换到 \(name)")
                    self.notice = "已切换到 \(name)。正在运行的普通 claude 会在下一条消息换成这个号，提示缓存会重建，第一条会慢一点。"
                    self.lastRun[a.id] = nil
                    Task { await self.refreshAll(force: false) }
                }
            }
        }
    }

    // MARK: 添加、导入、移除

    func addAccount(label: String) {
        let id = newLocalId()
        let cfg = "\(supportDir)/accounts/\(id)/config"
        do { try prepareAccountDir(cfg) } catch { notice = "创建账号目录失败：\(error.localizedDescription)"; return }
        store.accounts.append(Account(id: id, label: label, configDir: cfg))
        save()
        runLogin(dir: cfg, name: "login-\(id)")
        notice = "已在终端里开始登录，完成后点「刷新额度」"
    }

    func relogin(_ a: Account) {
        runLogin(dir: a.configDir, name: "login-\(a.id)")
        notice = "已在终端里开始登录，完成后点「刷新额度」"
    }

    private func runLogin(dir: String, name: String) {
        let script = """
        export CLAUDE_CONFIG_DIR=\(shQuote(dir))
        echo "=== 登录账号：按提示在浏览器里完成授权 ==="
        claude auth login
        echo
        echo "完成后回到菜单栏，点「刷新额度」。可以关掉这个窗口。"
        exec zsh -il
        """
        launchTerminal(name: name, body: script)
    }

    /// 导入 cc-switch 里的 Claude 账号：只登记它们的目录，不复制任何令牌。
    @discardableResult
    func importCCSwitch() -> (added: [String], skipped: [String]) {
        var added: [String] = [], skipped: [String] = []
        let found = ccSwitchAccounts()
        if found.isEmpty { notice = "cc-switch 里没有可导入的账号"; return (added, skipped) }
        var known = Set(store.accounts.compactMap { identity(ofDir: $0.configDir)?.key })
        for (email, cfg) in found {
            if store.accounts.contains(where: { $0.configDir == cfg }) { skipped.append("\(email)（已在列表里）"); continue }
            guard let idn = identity(ofDir: cfg) else { skipped.append("\(email)（目录里没有登录信息）"); continue }
            if known.contains(idn.key) { skipped.append("\(email)（和已有账号是同一个号）"); continue }
            let id = ((cfg as NSString).deletingLastPathComponent as NSString).lastPathComponent
            store.accounts.append(Account(id: id, label: "", configDir: cfg))
            known.insert(idn.key)
            added.append(email)
        }
        save(); reloadStates()
        notice = added.isEmpty ? "没有新账号可导入" : "已导入 \(added.count) 个账号，点「刷新额度」"
        return (added, skipped)
    }

    // MARK: 终端

    // 用 .command 文件让 Terminal 打开，不需要「自动化」权限
    @discardableResult
    func launchTerminal(name: String, body: String) -> Bool {
        let dir = supportDir + "/launch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(name).command"
        let content = "#!/bin/zsh -il\n" + body + "\n"
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch { notice = "写启动脚本失败：\(error.localizedDescription)"; return false }
        if testRoot != nil { return true }          // 沙盒测试只写脚本，不真的弹出终端
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", path]
        try? p.run()
        return true
    }

    /// 自检：不开界面，打印读到的账号状态
    func dump() {
        for a in store.accounts {
            let s = states[a.id] ?? AccountState()
            print("[\(a.id.prefix(8))] \(displayName(a)) live=\(s.live) 可用=\(s.loggedIn) plan=\(s.plan) 5h=\(s.fiveHour.map { "\($0)%" } ?? "-") 7d=\(s.sevenDay.map { "\($0)%" } ?? "-")")
            print("   终端脚本: " + terminalScript(a, terminalPrefs(a), terminalMode(a) ?? .shared).split(separator: "\n").joined(separator: " ; "))
        }
        print("claude 路径: \(claudePath ?? "未找到")")
    }
}
