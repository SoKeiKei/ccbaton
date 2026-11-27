import SwiftUI
@preconcurrency import UserNotifications

// 额度告警：颜色分两级，卡片 / 小组件 / 菜单栏图标带淡淡的光晕，只对"正在使用"的账号弹系统通知。
// 原则是提醒但不打扰：吃紧（≥80%）静态淡橙光，告急（≥95%）才缓慢呼吸；通知每个重置周期最多两次。

extension AccountState {
    /// 0 正常，1 吃紧（≥80%），2 告急（≥95%）。看 5 小时和 7 天里更高的那个；
    /// 已经过了重置时间的读数是旧缓存，不算。
    var level: Int {
        func eff(_ v: Double?, _ r: Date?) -> Double {
            guard let v else { return 0 }
            if let r, r < Date() { return 0 }
            return v
        }
        let m = max(eff(fiveHour, fiveReset), eff(sevenDay, sevenReset))
        return m >= 95 ? 2 : (m >= 80 ? 1 : 0)
    }
}

func glowColor(_ level: Int) -> Color { level >= 2 ? .red : .orange }

/// 边沿光晕：吃紧是静态的淡橙边，告急是红边 + 缓慢呼吸的红光。系统开了"减弱动态效果"就不呼吸。
struct AlertGlow: ViewModifier {
    let level: Int
    var corner: CGFloat = 12
    var radius: CGFloat = 9
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var edge: Double { level == 0 ? 0 : (level >= 2 ? (pulse ? 0.95 : 0.55) : 0.55) }
    private var glow: Double { level == 0 ? 0 : (level >= 2 ? (pulse ? 0.7 : 0.3) : 0.25) }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(glowColor(level).opacity(level == 0 ? 0 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(glowColor(level).opacity(edge), lineWidth: 1.3)
                    .shadow(color: glowColor(level).opacity(glow), radius: radius)
            )
            .animation(.easeInOut(duration: 0.6), value: level)
            .onAppear { updatePulse() }
            .onChange(of: level) { updatePulse() }
    }

    private func updatePulse() {
        if level >= 2 && !reduceMotion {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { pulse = false }
        }
    }
}

extension View {
    func alertGlow(_ level: Int, corner: CGFloat = 12, radius: CGFloat = 9) -> some View {
        modifier(AlertGlow(level: level, corner: corner, radius: radius))
    }
}

// MARK: - 什么时候提醒

struct AlertItem {
    let keys: [String]      // 这次提醒覆盖的"已提醒"记号，存起来避免重复弹
    let title: String
    let body: String
}

/// 只看"正在使用"的账号：某个窗口用量到 90% 提醒一次，用完（100%）再提醒一次。
/// 同一个重置周期内不重复；读数已过重置时间（旧缓存）不提醒；一次跳过两档只弹最高的那条。
func alertsToFire(accounts: [Account], states: [String: AccountState], alerted: Set<String>,
                  name: (Account) -> String, remaining: Bool = false, also: [String] = [], now: Date = Date()) -> [AlertItem] {
    // "正在使用"的账号：终端里在用的，加上桌面端在用的（also）
    var inUse: [Account] = []
    if let live = accounts.first(where: { states[$0.id]?.live == true }) { inUse.append(live) }
    for id in also { if let a = accounts.first(where: { $0.id == id }), !inUse.contains(where: { $0.id == a.id }) { inUse.append(a) } }
    var items: [AlertItem] = []
    for live in inUse {
        guard let st = states[live.id] else { continue }
        for (label, value, reset) in [("5 小时", st.fiveHour, st.fiveReset), ("7 天", st.sevenDay, st.sevenReset)] {
            guard let v = value else { continue }
            if let r = reset, r < now { continue }
            let epoch = Int(reset?.timeIntervalSince1970 ?? 0)
            let reached = [90, 100].filter { v >= Double($0) }
            let keys = reached.map { "\(live.id)|\(label)|\(epoch)|\($0)" }
            guard let top = reached.last, !alerted.contains(keys.last!) else { continue }

            // 找一个还有空的账号当建议（和面板上的"推荐"同一个规则）
            let better = recommendedAccount(accounts: accounts, states: states, now: now)
            let resetLine = reset.map { resetText($0) } ?? ""
            let suggest = better.map { "「\(name($0.account))」还有空（\(quotaWords($0.used, remaining: remaining))），可以在 CCBaton 里一键切换。" } ?? "其他账号也不太宽裕，注意节省。"
            let title = top >= 100 ? "\(name(live)) 的\(label)额度已用完" : "\(name(live)) 的\(label)额度快用完了（\(remaining ? "剩 " : "")\(quotaText(v, remaining: remaining))）"
            items.append(AlertItem(keys: keys, title: title, body: [resetLine, suggest].filter { !$0.isEmpty }.joined(separator: "，")))
        }
    }
    return items
}

// MARK: - 发系统通知

@MainActor
enum Alerter {
    /// 测试模式和只读模式不发
    static var enabled: Bool { testRoot == nil && !Model.readOnly && Bundle.main.bundlePath.hasSuffix(".app") }

    static func post(title: String, body: String) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized, .provisional:
                send(center, title, body)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    if ok { send(center, title, body) } else { fallback(title, body) }
                }
            default:
                fallback(title, body)
            }
        }
    }

    private nonisolated static func send(_ center: UNUserNotificationCenter, _ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            if err != nil { fallback(title, body) }
        }
    }

    /// 系统通知没授权或发送失败时，用 osascript 弹一条
    private nonisolated static func fallback(_ title: String, _ body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }
}
