import SwiftUI
import AppKit

// 账号一多时界面怎么办，规则都在这里：
//   面板：5 个以内全是大卡片；6 个起，使用中的在原位显示大卡片，其他每个一行；超出屏幕才滚动。
//   小组件：大小固定对齐系统格子，放不下的收进"+N / 还有 N 个"菜单。
//   顺序完全由用户决定（拖动，或右键上移 / 下移），程序从不自动挪位置；推荐只做标记。

/// 面板里账号超过这么多个就换紧凑布局
let panelFullLimit = 5

// MARK: - 顺序

/// 把第 from 个挪到第 to 个的位置
func moved<T>(_ list: [T], from: Int, to: Int) -> [T] {
    guard list.indices.contains(from) else { return list }
    var out = list
    let x = out.remove(at: from)
    out.insert(x, at: min(max(to, 0), out.count))
    return out
}

/// 拖动排序的落点。frames 是各项原来的位置（按现在的顺序），source 是被拖的那个，offset 是往下拖了多远（往上为负）。
/// 往上拖时上沿越过谁的中线就排到谁前面，往下拖时下沿越过谁的中线就排到谁后面。
func dropIndex(frames: [CGRect], source: Int, offset: CGFloat) -> Int {
    guard frames.indices.contains(source) else { return source }
    var target = source
    if offset < 0 {
        let edge = frames[source].minY + offset
        for i in stride(from: source - 1, through: 0, by: -1) where edge < frames[i].midY { target = i }
    } else {
        let edge = frames[source].maxY + offset
        for i in (source + 1)..<frames.count where edge > frames[i].midY { target = i }
    }
    return target
}

// MARK: - 头像颜色

/// 十个拉得开的颜色；账号超过十个才会重复
let avatarPalette: [Color] = [0.07, 0.58, 0.36, 0.76, 0.95, 0.48, 0.14, 0.65, 0.26, 0.86]
    .map { Color(hue: $0, saturation: 0.55, brightness: 0.78) }

/// 每个账号一个固定的颜色号：分到过的不变（调整顺序也不变），新账号拿用得最少的最小号
func assignColorSlots(_ ids: [String], _ old: [String: Int]) -> [String: Int] {
    var out = old.filter { ids.contains($0.key) }
    var used = [Int](repeating: 0, count: avatarPalette.count)
    for v in out.values where used.indices.contains(v) { used[v] += 1 }
    for id in ids where out[id] == nil {
        let slot = used.indices.min { used[$0] < used[$1] } ?? 0
        out[id] = slot
        used[slot] += 1
    }
    return out
}

// MARK: - 换号推荐

/// 使用中的账号用到这么多就建议换号
let switchAdviceAt = 90.0
/// 用量低于这么多的账号才值得推荐
let roomyBelow = 70.0

/// 某个窗口现在实际用了多少：已经过了重置时间的读数是旧缓存，按 0 算
func effectiveUse(_ value: Double?, _ reset: Date?, now: Date = Date()) -> Double {
    guard let value else { return 0 }
    if let reset, reset < now { return 0 }
    return value
}

/// 推荐换到哪个账号：没在用、登录有效、读得到额度，5 小时和 7 天里更高的那个最低（且低于 70%）
func recommendedAccount(accounts: [Account], states: [String: AccountState], now: Date = Date()) -> (account: Account, used: Double)? {
    accounts.compactMap { a -> (account: Account, used: Double)? in
        guard let s = states[a.id], !s.live, s.loggedIn, s.fiveHour != nil else { return nil }
        let used = max(effectiveUse(s.fiveHour, s.fiveReset, now: now), effectiveUse(s.sevenDay, s.sevenReset, now: now))
        return used < roomyBelow ? (a, used) : nil
    }
    .min { $0.used < $1.used }
}

struct SwitchAdvice {
    let text: String
    let target: Account?        // nil：没有够空的账号可推荐
}

extension Model {
    /// 使用中的账号快用完时的提示
    var switchAdvice: SwitchAdvice? {
        guard let cur = live, let s = states[cur.id] else { return nil }
        let five = effectiveUse(s.fiveHour, s.fiveReset), seven = effectiveUse(s.sevenDay, s.sevenReset)
        let worst = max(five, seven)
        guard worst >= switchAdviceAt else { return nil }
        let head = "当前账号 \(seven > five ? "7 天" : "5 小时")额度\(showRemaining ? "只" : "")\(quotaWords(worst, remaining: showRemaining))"
        guard let r = recommendedAccount(accounts: store.accounts, states: states) else { return SwitchAdvice(text: head, target: nil) }
        return SwitchAdvice(text: "\(head)\n「\(shortDisplayName(r.account))」还有空（\(quotaWords(r.used, remaining: showRemaining))）", target: r.account)
    }

    func avatarColor(of a: Account) -> Color {
        let slot = assignColorSlots(store.accounts.map { $0.id }, store.colorSlots ?? [:])[a.id] ?? 0
        return avatarPalette[((slot % avatarPalette.count) + avatarPalette.count) % avatarPalette.count]
    }

    /// 记下每个账号分到的颜色，之后调整顺序颜色也不跟着变
    func fillColorSlots() {
        let slots = assignColorSlots(store.accounts.map { $0.id }, store.colorSlots ?? [:])
        if slots != store.colorSlots { store.colorSlots = slots }
    }

    func moveAccount(_ id: String, to index: Int) {
        guard let from = store.accounts.firstIndex(where: { $0.id == id }) else { return }
        fillColorSlots()
        let list = moved(store.accounts, from: from, to: index)
        guard list != store.accounts else { return }
        store.accounts = list
        save()
    }
}

// MARK: - 面板：账号列表

/// 右键菜单：改名、调整顺序、移除
struct AccountMenu: View {
    @ObservedObject var model: Model
    let account: Account
    var body: some View {
        let i = model.store.accounts.firstIndex { $0.id == account.id } ?? 0
        Button("编辑账号…") { AccountEditor.shared.open(model, account: account) }
        Divider()
        Button("上移") { model.moveAccount(account.id, to: i - 1) }.disabled(i == 0)
        Button("下移") { model.moveAccount(account.id, to: i + 1) }.disabled(i >= model.store.accounts.count - 1)
        Button("移到最前") { model.moveAccount(account.id, to: 0) }.disabled(i == 0)
        Divider()
        if model.removalBlocker(account) == nil {
            // 等菜单收起来再弹警告框
            Button("移除账号…", role: .destructive) { DispatchQueue.main.async { model.requestRemoval(account) } }
        } else {
            Button("移除账号（使用中，先切换到别的账号）") {}.disabled(true)
        }
    }
}

struct Avatar: View {
    @ObservedObject var model: Model
    let account: Account
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            Circle().fill(model.avatarColor(of: account))
            Text(String(model.shortDisplayName(account).prefix(1)).uppercased())
                .font(.system(size: size * 0.43, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// 窄的小进度条：左边标题，右边百分数，下面一条
struct MiniMeter: View {
    let title: String
    let value: Double?        // 已用百分比
    let remaining: Bool
    var body: some View {
        let shown = quotaShown(value, remaining: remaining)
        return VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(quotaText(value, remaining: remaining))
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).fixedSize()
                    .foregroundStyle((value ?? 0) >= 80 ? levelColor(value) : .primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(levelColor(value))
                        .frame(width: max(value == nil ? 0 : 3, g.size.width * CGFloat(min(max(shown ?? 0, 0), 100) / 100)))
                        .animation(.easeOut(duration: 0.7), value: shown)
                }
            }.frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }
}

let accountRowHeight: CGFloat = 44

/// 紧凑布局里没在用的账号：一行
struct AccountRow: View {
    @ObservedObject var model: Model
    let account: Account
    var recommended = false
    var st: AccountState { model.states[account.id] ?? AccountState() }

    /// 名字下面那行：一般是 5 小时的重置时间；周额度更紧时改说周额度；快续期时改说续期
    private var detail: String {
        if let r = model.renewal(account) { return r.text }
        if !st.loggedIn { return "需要重新登录" }
        if let w = st.sevenDay, w >= 80, w >= (st.fiveHour ?? 0) { return "周 " + resetText(st.sevenReset) }
        if st.fiveHour == nil { return "暂无数据" }
        return st.fiveIdle ? "未开始计时" : resetText(st.fiveReset)
    }

    private var tip: String {
        var lines = [model.displayName(account) + (st.plan.isEmpty ? "" : "（\(st.plan)）")]
        if let r = model.renewal(account) { lines.append("续期：\(monthDayText(r.date))") }
        if st.loggedIn {
            lines.append("5 小时：" + (st.fiveIdle ? "未开始计时" : resetText(st.fiveReset)))
            lines.append("7 天：" + resetText(st.sevenReset))
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 8) {
            Avatar(model: model, account: account, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(model.shortDisplayName(account)).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if recommended { Tag(text: "推荐", tint: .accentColor).fixedSize() }
                }
                Text(detail).font(.system(size: 9, weight: model.renewal(account) == nil ? .regular : .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(st.loggedIn && model.renewal(account) == nil ? Color.secondary : Color.orange)
            }
            .frame(width: 86, alignment: .leading)
            .help(tip)
            if st.loggedIn {
                MiniMeter(title: "5时", value: st.fiveHour, remaining: model.showRemaining)
                MiniMeter(title: "7天", value: st.sevenDay, remaining: model.showRemaining)
                HStack(spacing: 5) {
                    Button { model.switchTo(account) } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 13, height: 13) }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.switching).help("切换到这个账号")
                    Button { TerminalController.shared.open(model, account: account) } label: { Image(systemName: "terminal").frame(width: 13, height: 13) }
                        .buttonStyle(.bordered).controlSize(.small).help("选目录和参数，用这个账号开终端")
                }
            } else {
                Spacer(minLength: 0)
                Button("重新登录") { model.relogin(account) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: accountRowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8))
        .alertGlow(st.level, corner: 10, radius: 6)
        .contextMenu { AccountMenu(model: model, account: account) }
    }
}

private struct AccountFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct AccountDrag: Equatable {
    var id: String
    var offset: CGFloat
}

/// 面板中间的账号列表：决定大卡片还是单行、要不要滚动，并处理按住拖动排序
struct AccountList: View {
    @ObservedObject var model: Model
    var shown = true                        // 面板弹出动效：false → true 时依次浮现
    @State private var frames: [String: CGRect] = [:]
    @GestureState private var drag: AccountDrag?

    /// 只用于 README 截图：摆出"正拖着某个账号"的样子
    static var shotDrag: AccountDrag?
    private var current: AccountDrag? { drag ?? AccountList.shotDrag }

    /// 测试用：记下各账号在窗口里的位置
    static var probe: [String: CGRect] = [:]
    /// 测试用：假装屏幕只有这么高
    static var maxHeightOverride: CGFloat?
    /// 列表最多能有多高：屏幕可用高度减去标题、提示和底部按钮
    static var maxHeight: CGFloat { maxHeightOverride ?? max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 230) }

    private var compact: Bool { model.store.accounts.count > panelFullLimit }
    private var spacing: CGFloat { compact ? 6 : 10 }

    /// 估一下列表有多高（超过屏幕才套滚动视图；滚动视图自己没有固有高度，不能让它去量）
    private var estimatedHeight: CGFloat {
        let n = model.store.accounts.count
        let cards = compact ? (model.live == nil ? 0 : 1) : n
        let reminders = model.store.accounts.filter { model.renewal($0) != nil && (!compact || model.states[$0.id]?.live == true) }.count
        return CGFloat(cards) * 112 + CGFloat(reminders) * 26 + CGFloat(n - cards) * accountRowHeight + CGFloat(max(n - 1, 0)) * spacing
    }

    private func target(for d: AccountDrag) -> (from: Int, to: Int)? {
        let ids = model.store.accounts.map { $0.id }
        let list = ids.compactMap { frames[$0] }
        guard list.count == ids.count, let from = ids.firstIndex(of: d.id) else { return nil }
        return (from, dropIndex(frames: list, source: from, offset: d.offset))
    }

    private func item(_ i: Int, _ a: Account, recommended: Bool) -> some View {
        let dragging = current?.id == a.id
        let landing = current.flatMap { target(for: $0) }.flatMap { $0.from != $0.to && $0.to == i ? $0 : nil }
        return Group {
            if !compact || model.states[a.id]?.live == true { AccountCard(model: model, account: a, recommended: recommended) }
            else { AccountRow(model: model, account: a, recommended: recommended) }
        }
        .contentShape(Rectangle())
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 14)
        .animation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.04 * Double(min(i, 7) + 1)), value: shown)
        // 拎起来的这张垫一层不透明的底，不然和下面账号的字叠在一起看不清
        .background(RoundedRectangle(cornerRadius: !compact || model.states[a.id]?.live == true ? 12 : 10, style: .continuous)
            .fill(dragging ? Color(nsColor: .windowBackgroundColor) : Color.clear))
        .shadow(color: .black.opacity(dragging ? 0.45 : 0), radius: 8, y: 4)
        .offset(y: dragging ? (current?.offset ?? 0) : 0)
        // 量位置要放在 offset 外面：拖动时量到的仍是原来的位置
        .background(GeometryReader { g in Color.clear.preference(key: AccountFrames.self, value: [a.id: g.frame(in: .global)]) })
        .overlay(alignment: (landing.map { $0.to < $0.from } ?? true) ? .top : .bottom) {
            if let l = landing {                // 松手会落在哪：一条蓝线
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: l.to < l.from ? -spacing / 2 - 1.5 : spacing / 2 + 1.5)
            }
        }
        .zIndex(dragging ? 1 : 0)
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .updating($drag) { v, state, _ in state = AccountDrag(id: a.id, offset: v.translation.height) }
                .onEnded { v in
                    guard let t = target(for: AccountDrag(id: a.id, offset: v.translation.height)), t.from != t.to else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.moveAccount(a.id, to: t.to) }
                }
        )
    }

    var body: some View {
        let recommended = model.switchAdvice?.target?.id
        let list = VStack(spacing: spacing) {
            ForEach(Array(model.store.accounts.enumerated()), id: \.element.id) { i, a in
                item(i, a, recommended: a.id == recommended)
            }
        }
        .onPreferenceChange(AccountFrames.self) { f in
            frames = f
            if testRoot != nil { AccountList.probe = f }
        }
        if estimatedHeight > AccountList.maxHeight {
            ScrollViewReader { proxy in
                ScrollView { list.padding(.horizontal, 5).padding(.vertical, 3) }     // 留出告警光晕，别被裁掉
                    .frame(height: AccountList.maxHeight)
                    .padding(.horizontal, -5)
                    .onAppear { if let id = model.live?.id { proxy.scrollTo(id) } }
            }
        } else {
            list
        }
    }
}

// MARK: - 小组件放不下的账号

/// 小组件放不下时显示哪几个：按手动顺序取前面的，留一格给"还有 N 个"；使用中的排在后面时占最后一个位置
func widgetSelection(_ accounts: [Account], liveId: String?, capacity: Int) -> (shown: [Account], hidden: [Account]) {
    guard accounts.count > capacity else { return (accounts, []) }
    var shown = Array(accounts.prefix(max(capacity - 1, 1)))
    if let live = accounts.first(where: { $0.id == liveId }), !shown.contains(live) { shown[shown.count - 1] = live }
    return (shown, accounts.filter { !shown.contains($0) })
}

final class ActionMenuItem: NSMenuItem {
    private var run: () -> Void = {}
    convenience init(_ title: String, _ run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.run = run
        target = self
    }
    @objc func fire() { run() }
}

/// 点小组件上的"+N / 还有 N 个"弹出菜单，挑一个账号切换。
/// 用系统菜单而不是 SwiftUI 的 Menu：小组件窗口不抢焦点，普通按钮第一下点击就生效。
@MainActor
enum AccountPopup {
    /// 测试时换掉，不真的弹菜单
    static var present: (NSMenu) -> Void = { menu in
        DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    static func menu(_ model: Model, accounts: [Account], onSwitch: @escaping (Account) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let recommended = model.switchAdvice?.target?.id
        for a in accounts {
            let s = model.states[a.id] ?? AccountState()
            func pct(_ v: Double?) -> String { (model.showRemaining ? "剩 " : "") + quotaText(v, remaining: model.showRemaining) }
            let info = s.loggedIn ? "5 小时 \(pct(s.fiveHour)) · 7 天 \(pct(s.sevenDay))" : "需要重新登录"
            let due = model.renewal(a).map { "　\($0.text)" } ?? ""
            let item = ActionMenuItem("\(model.shortDisplayName(a))　\(info)\(a.id == recommended ? "　推荐" : "")\(due)") { onSwitch(a) }
            item.isEnabled = s.loggedIn && !s.live
            menu.addItem(item)
        }
        return menu
    }
}
