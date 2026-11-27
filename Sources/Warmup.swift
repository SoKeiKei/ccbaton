// 额度预热：账号的 5 小时窗口要等第一条消息才开始计时。开启后，账号一空闲就给它发一条极小的消息，
// 让倒计时先走起来；"错开"让各账号的重置时间尽量均匀分开，避免一起用完、一起干等。
// 这个功能默认关闭：它会消耗极少量额度，而且是自动发消息（README 里写了风险）。

import Foundation

enum Warmup {
    static let window: TimeInterval = 5 * 3600
    /// 过了重置时间再等这么久才算空闲，免得消息落在旧窗口里
    static let grace: TimeInterval = 60
    /// 做决定时，额度数据最多这么旧
    static let fresh: TimeInterval = 150
    /// Claude Code 的额度缓存 60 秒内不会重写，发完消息至少隔这么久再核对
    static let confirmAfter: TimeInterval = 70
    static let confirmGiveUp: TimeInterval = 600
    /// 没成功时多久后再试；连续失败 maxFails 次后改成一个窗口才试一次
    static let retry: TimeInterval = 30 * 60
    static let maxFails = 3
    /// 读不到最新额度（比如刚唤醒还没联网）时先放一放
    static let noDataHold: TimeInterval = 5 * 60

    /// 错开时两次开窗之间至少隔多久
    static func gap(_ accounts: Int) -> TimeInterval { window / Double(max(accounts, 1)) }
}

struct WarmupRecord: Codable, Equatable {
    enum Status: String, Codable {
        case sent           // 消息发出去了，还没核对倒计时
        case confirmed      // 核对过，倒计时开始了
        case failed
    }
    var at: Date
    var status: Status
    var fails: Int
}

enum WarmupPlan: Equatable {
    case ping(String)                   // 现在就激活这个账号
    case wait(String, until: Date)      // 这个账号空闲，到这个时间再激活
    case counting(next: Date?)          // 都在计时，next 是最早的重置时间
    case none                           // 没有能预热的账号
}

/// 能预热的账号：登录有效、读得到 5 小时额度、周额度没用完
func warmupEligible(_ s: AccountState, now: Date) -> Bool {
    guard s.loggedIn, s.fiveHour != nil, !s.noFiveHour else { return false }     // 没有 5 小时窗口的账号没得预热
    if let w = s.sevenDay, w >= 100, s.sevenReset.map({ $0 > now }) ?? true { return false }
    return true
}

/// 没在计时：服务器明确说没有窗口，或者重置时间已经过了一会儿
func warmupIdle(_ s: AccountState, now: Date) -> Bool {
    if s.fiveIdle { return true }
    guard let r = s.fiveReset else { return false }     // 时间读不懂时不当成空闲，免得乱发
    return now.timeIntervalSince(r) >= Warmup.grace
}

/// 纯计算：现在该做什么。一次最多挑一个账号。
func warmupPlan(accounts: [Account], states: [String: AccountState], records: [String: WarmupRecord],
                holds: [String: Date] = [:], stagger: Bool, now: Date = Date()) -> WarmupPlan {
    let usable = accounts.filter { states[$0.id].map { warmupEligible($0, now: now) } ?? false }
    guard !usable.isEmpty else { return .none }
    // 刚发过、还在等核对的账号先不算空闲
    let idle = usable.filter { warmupIdle(states[$0.id]!, now: now) && records[$0.id]?.status != .sent }
    // 周额度剩得多的先激活
    let order = idle.enumerated().sorted {
        let a = states[$0.element.id]?.sevenDay ?? 0, b = states[$1.element.id]?.sevenDay ?? 0
        return a != b ? a < b : $0.offset < $1.offset
    }.map { $0.element }

    let gap = Warmup.gap(usable.count)
    var soonest: (id: String, at: Date)?
    for a in order {
        var t = now
        if let r = records[a.id] { t = max(t, r.at.addingTimeInterval(r.fails >= Warmup.maxFails ? Warmup.window : Warmup.retry)) }
        if let h = holds[a.id] { t = max(t, h) }
        if stagger {
            // 离其他账号最近一次开窗至少隔 gap
            for o in usable where o.id != a.id {
                if let reset = states[o.id]?.fiveReset, reset > now { t = max(t, reset.addingTimeInterval(gap - Warmup.window)) }
                if let r = records[o.id], r.status != .failed, now.timeIntervalSince(r.at) < Warmup.window {
                    t = max(t, r.at.addingTimeInterval(gap))
                }
            }
        }
        if t <= now { return .ping(a.id) }
        if soonest.map({ t < $0.at }) ?? true { soonest = (a.id, t) }
    }
    if let s = soonest { return .wait(s.id, until: s.at) }
    return .counting(next: usable.compactMap { states[$0.id]?.fiveReset }.filter { $0 > now }.min())
}

/// 发一条最小的消息，让这个账号的 5 小时窗口开始计时。会消耗极少量额度（实测约 630 token，Haiku）。
/// 不带工具、插件、钩子和用户设置，不保存对话。
func runPing(claude: String, configDir: String?) async -> Bool {
    let dir = supportDir + "/warmup"                 // 空文件夹，不会读到任何项目说明
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return await runClaude(claude, ["-p", "hi", "--model", "haiku", "--system-prompt", "Reply with: ok", "--tools", "",
                                    "--strict-mcp-config", "--setting-sources", "", "--safe-mode", "--no-session-persistence"],
                           configDir: configDir, extraEnv: ["MAX_THINKING_TOKENS": "0"], cwd: dir, timeout: 60) == 0
}

func clockText(_ d: Date, now: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let cal = Calendar.current
    let day = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
    return (day == 0 ? "" : (day == 1 ? "明天 " : "\(day) 天后 ")) + f.string(from: d)
}

// MARK: - 执行

extension Model {
    var warmupOn: Bool { store.warmupEnabled ?? false }
    var staggerOn: Bool { store.warmupStagger ?? true }

    func setWarmup(_ on: Bool) {
        store.warmupEnabled = on
        warmupHolds = [:]
        save()
        if on { Task { await warmupTick() } }
    }

    func setStagger(_ on: Bool) {
        store.warmupStagger = on
        save()
        if warmupOn { Task { await warmupTick() } }
    }

    func currentWarmupPlan(now: Date = Date()) -> WarmupPlan {
        warmupPlan(accounts: store.accounts, states: states, records: store.warmupRecords ?? [:],
                   holds: warmupHolds, stagger: staggerOn, now: now)
    }

    /// 面板和设置窗口里显示的一行状态
    var warmupStatus: String {
        guard warmupOn else { return "未开启" }
        func name(_ id: String) -> String { store.accounts.first { $0.id == id }.map { shortDisplayName($0) } ?? "账号" }
        if let id = warming { return "正在激活「\(name(id))」…" }
        if let id = (store.warmupRecords ?? [:]).first(where: { r in r.value.status == .sent && store.accounts.contains { $0.id == r.key } })?.key {
            return "已发给「\(name(id))」，一两分钟后核对倒计时"
        }
        switch currentWarmupPlan() {
        case .ping(let id): return "马上激活「\(name(id))」"
        case .wait(let id, let t):
            if let r = store.warmupRecords?[id], r.status == .failed { return "「\(name(id))」上次没成功，\(clockText(t)) 再试" }
            if warmupHolds[id].map({ $0 > Date() }) ?? false { return "暂时读不到「\(name(id))」的额度，\(clockText(t)) 再看" }
            return "「\(name(id))」为了和其他账号错开，约 \(clockText(t)) 自动开始计时"
        case .counting(let next): return "各账号都在计时" + (next.map { "，最早 \(clockText($0)) 重置" } ?? "")
        case .none: return "没有可预热的账号（未登录、周额度用完或还没读到额度）"
        }
    }

    /// 额度数据够不够新：不超过 fresh 秒，而且不是重置之前读的
    private func warmupDataFresh(_ id: String, now: Date = Date()) -> Bool {
        guard let s = states[id], let t = s.fetchedAt, now.timeIntervalSince(t) < Warmup.fresh else { return false }
        if let r = s.fiveReset, r <= now, t < r { return false }
        return true
    }

    private func refreshOne(_ a: Account, claude: String) async {
        lastRun[a.id] = Date()
        await runUsage(claude: claude, configDir: states[a.id]?.live == true ? nil : a.configDir)
        reloadStates()
    }

    private func record(_ id: String, _ r: WarmupRecord) {
        var all = store.warmupRecords ?? [:]
        all[id] = r
        store.warmupRecords = all
        save()
    }

    private func verificationsDue(now: Date = Date()) -> [Account] {
        store.accounts.filter { a in
            guard let r = store.warmupRecords?[a.id], r.status == .sent else { return false }
            return now.timeIntervalSince(r.at) >= Warmup.confirmAfter
        }
    }

    /// 核对发过消息的账号是不是真的开始计时了
    private func verifyWarmup(_ a: Account, claude: String) async {
        guard let sent = store.warmupRecords?[a.id] else { return }
        // 发出去超过一个窗口还没核对过（中间关了开关或退出了程序）：现在查不出结果，不算失败
        if Date().timeIntervalSince(sent.at) >= Warmup.window {
            record(a.id, WarmupRecord(at: sent.at, status: .confirmed, fails: 0))
            return
        }
        func counting() -> Bool {
            guard let s = states[a.id], let t = s.fetchedAt, t > sent.at, let r = s.fiveReset else { return false }
            return r > Date()
        }
        let lateEnough = sent.at.addingTimeInterval(60)
        if !counting(), (states[a.id]?.fetchedAt ?? .distantPast) < lateEnough { await refreshOne(a, claude: claude) }
        if counting() {
            record(a.id, WarmupRecord(at: sent.at, status: .confirmed, fails: 0))
        } else if (states[a.id]?.fetchedAt ?? .distantPast) >= lateEnough || Date().timeIntervalSince(sent.at) > Warmup.confirmGiveUp {
            record(a.id, WarmupRecord(at: sent.at, status: .failed, fails: sent.fails + 1))
        }
    }

    /// 每分钟跑一次（排在额度刷新后面）：先核对上次发的，再看现在该不该激活谁
    func warmupTick() async {
        guard warmupOn, !Model.readOnly, !refreshing, !switching, let claude = await locateClaude(),
              warmupOn, !refreshing, !switching else { return }     // 找 claude 可能花几秒，回来再看一遍
        let due = verificationsDue()
        if due.isEmpty { guard case .ping = currentWarmupPlan() else { return } }
        refreshing = true
        defer { refreshing = false }
        for a in due { await verifyWarmup(a, claude: claude) }

        for _ in 0..<store.accounts.count {
            guard warmupOn, !switching, case .ping = currentWarmupPlan() else { break }
            // 决定之前把各账号的数据弄新：别的账号可能刚被用过，会影响错开的时机
            for a in store.accounts where states[a.id]?.loggedIn == true && !warmupDataFresh(a.id) {
                await refreshOne(a, claude: claude)
            }
            reloadStates()
            guard warmupOn, !switching, case .ping(let id) = currentWarmupPlan(),
                  let a = store.accounts.first(where: { $0.id == id }) else { break }
            guard warmupDataFresh(id) else {
                warmupHolds[id] = Date().addingTimeInterval(Warmup.noDataHold)
                continue
            }
            let fails = store.warmupRecords?[id]?.fails ?? 0
            warming = id                            // 这期间不让切换账号（见 switchTo）
            let ok = await runPing(claude: claude, configDir: states[id]?.live == true ? nil : a.configDir)
            record(id, WarmupRecord(at: Date(), status: ok ? .sent : .failed, fails: ok ? fails : fails + 1))
            warming = nil
        }
    }
}
