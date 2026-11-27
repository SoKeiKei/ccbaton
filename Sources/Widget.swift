import SwiftUI
import AppKit
import Combine

// CCBaton 桌面小组件：贴在桌面上的半透明面板（在桌面图标上方、普通窗口下方）。
// 尺寸和位置完全对齐 macOS 系统桌面小组件的网格：一格 180×180（窗口里留 7.5pt 透明边，
// 看到的卡片是 165×165），小号 1×1、中号 2×1、大号 2×2；拖动松手时自动吸附到系统小组件的格子上。

enum WidgetSize: String, CaseIterable {
    case small, medium, large
    var title: String { self == .small ? "小号" : (self == .medium ? "中号" : "大号") }
    var cols: CGFloat { self == .small ? 1 : 2 }
    var rows: CGFloat { self == .large ? 2 : 1 }
    static let cell: CGFloat = 180
    static let inset: CGFloat = 7.5
    var width: CGFloat { cols * WidgetSize.cell }
    var height: CGFloat { rows * WidgetSize.cell }
}

// MARK: - 小部件

/// 账号前面的切换按钮：在用的是绿色对勾，其他账号是"切换"图标，点一下就切换
struct SwitchBadge: View {
    let live: Bool
    let usable: Bool
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: { if !live && usable { action() } }) {
            ZStack {
                Circle().fill(live ? Color.green : (!usable ? Color.orange.opacity(0.25) : (hover ? Color.accentColor : Color.primary.opacity(0.14))))
                Image(systemName: live ? "checkmark" : (usable ? "arrow.left.arrow.right" : "exclamationmark"))
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(live || (hover && usable) ? Color.white : (usable ? Color.primary : Color.orange))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(live ? "正在使用" : (usable ? "切换到这个账号" : "登录已失效，需要重新登录"))
    }
}

/// 上下两行的小进度条：上面是标题和百分比，下面是条
struct StackMeter: View {
    let title: String
    let value: Double?        // 已用百分比
    let remaining: Bool
    var body: some View {
        let shown = quotaShown(value, remaining: remaining)
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(remaining ? title + "剩" : title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(quotaText(value, remaining: remaining))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle((value ?? 0) >= 80 ? levelColor(value) : .primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.13))
                    Capsule().fill(levelColor(value))
                        .frame(width: max(value == nil ? 0 : 4, g.size.width * CGFloat(min(max(shown ?? 0, 0), 100) / 100)))
                        .animation(.easeOut(duration: 0.7), value: shown)
                }
            }.frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 小号：双环（外圈 5 小时、内圈 7 天）
struct DualRing: View {
    let five: Double?
    let seven: Double?
    let remaining: Bool
    var weeklyOnly = false       // 没有 5 小时窗口：只有一圈周额度
    var body: some View {
        ZStack {
            if weeklyOnly {
                ringLayer(value: seven, diameter: 78, width: 8)
            } else {
                ringLayer(value: five, diameter: 78, width: 8)
                ringLayer(value: seven, diameter: 55, width: 8)
            }
            VStack(spacing: 0) {
                Text(quotaText(weeklyOnly ? seven : five, remaining: remaining))
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(weeklyOnly ? (remaining ? "7天剩余" : "7 天") : (remaining ? "5时剩余" : "5 小时")).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    func ringLayer(value: Double?, diameter: CGFloat, width: CGFloat) -> some View {
        let shown = quotaShown(value, remaining: remaining)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.13), lineWidth: width)
            Circle().trim(from: 0, to: CGFloat(min(max(shown ?? 0, 0), 100)) / 100)
                .stroke(levelColor(value), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: shown)
        }.frame(width: diameter, height: diameter)
    }
}

struct WidgetView: View {
    @ObservedObject var model: Model
    var onHide: () -> Void = {}
    var onSwitch: (Account) -> Void = { _ in }
    var onResize: (WidgetSize) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    /// 告警光晕看正在使用的账号
    var glowLevel: Int { model.live.flatMap { model.states[$0.id] }?.level ?? 0 }

    /// 指定尺寸（只用于生成总览截图，正常使用时跟随设置）
    var forceSize: WidgetSize? = nil
    var size: WidgetSize { forceSize ?? WidgetSize(rawValue: model.store.widgetSize ?? "") ?? .medium }
    var inset: CGFloat { WidgetSize.inset }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
        ZStack(alignment: .topLeading) {
            Group {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
            .id(size)                                  // 换尺寸时旧内容淡出、新内容淡入
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
        }
        .padding(size == .small ? 14 : 15)
        .frame(width: size.width - inset * 2, alignment: .topLeading)
        .frame(minHeight: size.height - inset * 2, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(scheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.22))   // 和系统小组件的深色玻璃一致
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8))
        .alertGlow(glowLevel, corner: 25, radius: 6)
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // 窗口比卡片大时（切换尺寸的动画中），卡片固定在左上角
        .contextMenu {
            ForEach(WidgetSize.allCases, id: \.self) { s in
                Button { onResize(s) } label: {
                    Text(s == size ? "✓ \(s.title)" : "   \(s.title)")
                }
            }
            Divider()
            Button("刷新额度") { Task { model.reloadStates(); await model.refreshAll(force: true) } }
            let desktop = model.desktopMenuEntries()
            if !desktop.isEmpty {
                Menu("桌面端") {
                    ForEach(desktop) { e in Button(e.title) { model.desktopButton(e.account) }.disabled(!e.enabled) }
                }
            }
            Button("设置…") { SettingsController.shared.open(model) }
            Button("隐藏小组件") { onHide() }
        }
    }

    // 顶部一行：名字 + 状态（切换结果 / 更新时间）
    func header(_ pt: CGFloat = 11) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: pt + 1, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text("CCBaton").font(.system(size: pt, weight: .bold))
            if model.showRemaining { Text("剩余额度").font(.system(size: pt - 2, weight: .medium)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 4)
            if model.switching {
                ProgressView().controlSize(.mini)
                Text("切换中…").font(.system(size: 9)).foregroundStyle(.secondary)
            } else if let t = model.toast {
                Text(t).font(.system(size: 9, weight: .medium)).foregroundStyle(t.hasPrefix("已切换") ? Color.green : Color.orange).lineLimit(1)
            } else {
                if model.refreshing { ProgressView().controlSize(.mini) }
                Text(agoText(model.states.values.compactMap { $0.fetchedAt }.max()))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    func usable(_ st: AccountState) -> Bool { st.loggedIn }

    // 小号：在用的账号双环；底部是其他账号的头像，点一下切换
    var small: some View {
        let a = model.live
        let st = a.flatMap { model.states[$0.id] }
        // 右下角最多放三个头像的位置；更多时放两个加一个"+N"
        let others = widgetSelection(model.store.accounts.filter { $0.id != a?.id }, liveId: nil, capacity: 3)
        return VStack(spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(a.map { model.shortDisplayName($0) } ?? "CCBaton").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let a { DesktopMark(model: model, account: a) }
                Spacer(minLength: 0)
                if let r = a.flatMap({ model.renewal($0) }) { renewalLabel(r) }
            }
            Spacer(minLength: 0)
            DualRing(five: st?.fiveHour, seven: st?.sevenDay, remaining: model.showRemaining, weeklyOnly: st?.noFiveHour ?? false)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Group {
                    if st?.showsNoFiveHour ?? false {
                        ViewThatFits(in: .horizontal) {      // 右边头像多的时候放不下，换短一点的说法
                            Text("无 5 小时限制")
                            Text("无 5 时限制")
                            Text("仅周额度")
                        }
                    } else {
                        Text("7 天\(model.showRemaining ? "剩" : "") \(quotaText(st?.sevenDay, remaining: model.showRemaining))")
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                ForEach(others.shown) { o in
                    let os = model.states[o.id] ?? AccountState()
                    Button { if os.loggedIn { onSwitch(o) } } label: {
                        Text(String(model.shortDisplayName(o).prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(os.loggedIn ? model.avatarColor(of: o) : Color.gray.opacity(0.5)))
                            .overlay(alignment: .topTrailing) { if model.renewal(o) != nil { renewalDot } }
                            .overlay(alignment: .bottomTrailing) { DesktopMark(model: model, account: o, dot: true) }
                    }
                    .buttonStyle(.plain).help("切换到 \(model.shortDisplayName(o))" + (model.renewal(o).map { "（\($0.text)）" } ?? ""))
                }
                if !others.hidden.isEmpty {
                    Button { showMore(others.hidden) } label: {
                        Text("+\(others.hidden.count)").font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22).background(Circle().fill(Color.primary.opacity(0.16)))
                            .overlay(alignment: .topTrailing) { if others.hidden.contains(where: { model.renewal($0) != nil }) { renewalDot } }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("其他账号")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 名字下面那行：套餐或"使用中"；快续期时改说续期（在用的账号前面还有绿色对勾，认得出）。高度不变
    func subtitle(_ a: Account, _ st: AccountState, size: CGFloat) -> some View {
        let due = model.renewal(a)
        return Text(due?.text ?? (st.live ? "使用中" : (st.plan.isEmpty ? " " : st.plan)))
            .font(.system(size: size, weight: due != nil || st.live ? .semibold : .regular))
            .foregroundStyle(due != nil ? Color.orange : (st.live ? Color.green : Color.secondary))
            .lineLimit(1)
    }

    func renewalLabel(_ r: RenewalNotice) -> some View {
        Text(r.text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange).lineLimit(1).fixedSize()
    }

    var renewalDot: some View {
        Circle().fill(Color.orange).frame(width: 8, height: 8).overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.8)).offset(x: 2, y: -2)
    }

    func showMore(_ hidden: [Account]) {
        AccountPopup.present(AccountPopup.menu(model, accounts: hidden, onSwitch: onSwitch))
    }

    /// "还有 N 个"：点开菜单挑一个
    func moreButton(_ hidden: [Account], _ text: String) -> some View {
        let due = hidden.contains { model.renewal($0) != nil }
        return Button { showMore(hidden) } label: {
            HStack(spacing: 3) {
                Text(due ? text + " · 有续期" : text).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(due ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 一行：切换按钮 + 名字 + 两条进度
    func accountLine(_ a: Account, badge: CGFloat) -> some View {
        let st = model.states[a.id] ?? AccountState()
        return HStack(spacing: 9) {
            SwitchBadge(live: st.live, usable: usable(st), size: badge) { onSwitch(a) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(model.shortDisplayName(a)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    DesktopMark(model: model, account: a)
                }
                subtitle(a, st, size: 9)
            }
            .frame(width: 70, alignment: .leading)
            if st.loggedIn {
                if !st.noFiveHour { StackMeter(title: "5 小时", value: st.fiveHour, remaining: model.showRemaining) }
                StackMeter(title: "7 天", value: st.sevenDay, remaining: model.showRemaining)
            } else {
                Text("登录已失效，需要重新登录").font(.system(size: 10)).foregroundStyle(.orange)
                Spacer(minLength: 0)
            }
        }
    }

    // 中号：3 个以内每个账号一行；更多时两列，最多 6 格
    @ViewBuilder var medium: some View {
        if model.store.accounts.count <= 3 {
            VStack(alignment: .leading, spacing: 0) {
                header()
                Spacer(minLength: 6)
                VStack(spacing: 8) {
                    ForEach(model.store.accounts) { a in accountLine(a, badge: 26) }
                }
                Spacer(minLength: 0)
            }
        } else {
            let pick = widgetSelection(model.store.accounts, liveId: model.live?.id, capacity: 6)
            let cells = pick.shown.count + (pick.hidden.isEmpty ? 0 : 1)
            VStack(alignment: .leading, spacing: 0) {
                header()
                Spacer(minLength: 5)
                VStack(spacing: 5) {
                    ForEach(Array(stride(from: 0, to: cells, by: 2)), id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(row..<(row + 2), id: \.self) { i in
                                Group {
                                    if i < pick.shown.count { tile(pick.shown[i]) }
                                    else if i == pick.shown.count && !pick.hidden.isEmpty { moreButton(pick.hidden, "还有 \(pick.hidden.count) 个") }
                                    else { Color.clear }
                                }
                                .frame(maxWidth: .infinity).frame(height: 33)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 中号两列布局里的一格
    func tile(_ a: Account) -> some View {
        let st = model.states[a.id] ?? AccountState()
        return HStack(spacing: 7) {
            SwitchBadge(live: st.live, usable: usable(st), size: 24) { onSwitch(a) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(model.shortDisplayName(a)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(st.live ? Color.green : Color.primary)
                    DesktopMark(model: model, account: a)
                    Spacer(minLength: 0)
                    if let r = model.renewal(a) { renewalLabel(r) }
                }
                if st.loggedIn {
                    HStack(spacing: 6) {
                        if !st.noFiveHour { MiniMeter(title: "5时", value: st.fiveHour, remaining: model.showRemaining) }
                        MiniMeter(title: "7天", value: st.sevenDay, remaining: model.showRemaining)
                    }
                } else {
                    Text("需要重新登录").font(.system(size: 9)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // 大号：3 个以内每个账号一块（带重置倒计时）；更多时每个一行，最多 8 行
    @ViewBuilder var large: some View {
        if model.store.accounts.count <= 3 {
            VStack(alignment: .leading, spacing: 0) {
                header(12)
                Spacer(minLength: 10)
                VStack(spacing: 14) {
                    ForEach(model.store.accounts) { a in
                        let st = model.states[a.id] ?? AccountState()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 9) {
                                SwitchBadge(live: st.live, usable: usable(st), size: 28) { onSwitch(a) }
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(model.shortDisplayName(a)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                        DesktopMark(model: model, account: a)
                                    }
                                    subtitle(a, st, size: 10)
                                }
                                Spacer(minLength: 0)
                            }
                            if st.loggedIn {
                                QuotaMeters(st: st, remaining: model.showRemaining, spacing: 16)
                            } else {
                                Text("登录已失效，需要重新登录").font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            let pick = widgetSelection(model.store.accounts, liveId: model.live?.id, capacity: 8)
            VStack(alignment: .leading, spacing: 0) {
                header(12)
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    ForEach(pick.shown) { a in accountLine(a, badge: 24).frame(height: 28) }
                    if !pick.hidden.isEmpty { moreButton(pick.hidden, "还有 \(pick.hidden.count) 个账号") }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 承载视图：既要让按钮能点，又要能按住空白处拖动窗口

/// 小组件窗口的内容视图（普通 AppKit 视图，里面再放 SwiftUI 承载视图）。
/// 面板不抢焦点，窗口不是 key 窗口时，AppKit 问内容视图"要不要接受第一下点击"，必须答要，否则按钮点不动。
final class WidgetContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class WidgetHostingView: NSHostingView<WidgetView> {
    var onDragEnd: (() -> Void)?
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // 面板不抢焦点，第一下点击就要生效

    private func screenPoint(_ e: NSEvent) -> NSPoint { window?.convertPoint(toScreen: e.locationInWindow) ?? .zero }

    override func mouseDown(with event: NSEvent) {
        startMouse = screenPoint(event)
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
        super.mouseDown(with: event)             // 让 SwiftUI 的按钮能收到点击
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let p = screenPoint(event)
        if !dragging, hypot(p.x - startMouse.x, p.y - startMouse.y) < 4 { return }   // 小抖动不算拖动
        dragging = true
        w.setFrameOrigin(NSPoint(x: startOrigin.x + p.x - startMouse.x, y: startOrigin.y + p.y - startMouse.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; onDragEnd?() }
        else { super.mouseUp(with: event) }      // 没拖动：当作点击交给按钮
    }
}

// MARK: - 吸附到系统小组件的网格

/// 屏幕坐标（左上角为原点）。以最近的一个系统小组件为基准，横竖各自吸到格子线上。
func snapToGrid(_ p: CGPoint, systemFrames: [CGRect], pitch: CGFloat = WidgetSize.cell, threshold: CGFloat = 36) -> CGPoint {
    guard let ref = systemFrames.min(by: { hypot($0.minX - p.x, $0.minY - p.y) < hypot($1.minX - p.x, $1.minY - p.y) }) else { return p }
    var q = p
    let sx = ref.minX + ((p.x - ref.minX) / pitch).rounded() * pitch
    let sy = ref.minY + ((p.y - ref.minY) / pitch).rounded() * pitch
    if abs(sx - p.x) <= threshold { q.x = sx }
    if abs(sy - p.y) <= threshold { q.y = sy }
    return q
}

/// 现在屏幕上系统桌面小组件的窗口（通知中心画的，在桌面图标上一层）
func systemWidgetFrames() -> [CGRect] {
    let base = Int(CGWindowLevelForKey(.desktopIconWindow))
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        guard owner.contains("通知中心") || owner.contains("Notification"),
              (w[kCGWindowLayer as String] as? Int) == base + 2,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double, let wd = b["Width"] as? Double, let ht = b["Height"] as? Double,
              wd >= 150, wd <= 800, ht >= 150, ht <= 800 else { return nil }
        return CGRect(x: x, y: y, width: wd, height: ht)
    }
}

@MainActor
final class WidgetController {
    static let shared = WidgetController()
    private(set) var panel: NSPanel?
    private(set) var host: WidgetHostingView?
    private weak var model: Model?
    private var bag = Set<AnyCancellable>()
    /// 测试时可以替换
    var framesProvider: () -> [CGRect] = systemWidgetFrames
    var switchHook: ((Account) -> Void)?
    private var resizing = false       // 切换尺寸的动画进行中，先别调整窗口大小

    var isVisible: Bool { panel != nil }

    /// 启动时按上次的选择恢复
    func apply(_ model: Model) { if model.store.widgetVisible == true { show(model) } }

    func toggle(_ model: Model) { isVisible ? hide(model) : show(model) }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// 量一下小组件内容现在需要多大。用一个不挂在任何窗口上的临时视图去量：
    /// 窗口里的视图不再把"理想尺寸"变化反馈给窗口的布局约束，否则动画期间窗口和内容互相牵扯，
    /// 会触发 AppKit 的布局死循环保护（"Update Constraints in Window pass" 异常）而崩溃。
    func desiredSize(_ model: Model) -> NSSize {
        NSHostingView(rootView: WidgetView(model: model)).fittingSize
    }

    /// 把窗口吸到系统小组件的格子上（左上角对齐）
    func snap(_ p: NSPanel) {
        let top = CGPoint(x: p.frame.minX, y: primaryHeight - p.frame.maxY)
        let q = snapToGrid(top, systemFrames: framesProvider())
        guard q != top else { return }
        p.setFrameOrigin(NSPoint(x: q.x, y: primaryHeight - q.y - p.frame.height))
    }

    func show(_ model: Model) {
        guard panel == nil else { return }
        let view = WidgetView(model: model,
                              onHide: { [weak self] in self?.hide(model) },
                              onSwitch: { [weak self] a in
                                  if let h = self?.switchHook { h(a) } else { model.switchTo(a) }
                              },
                              onResize: { [weak self] s in self?.changeSize(model, to: s) })
        let host = WidgetHostingView(rootView: view)
        host.sizingOptions = []                  // 不参与窗口的约束布局，窗口大小完全由我们自己控制
        let size = desiredSize(model)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 不让 SwiftUI 的承载视图直接当窗口的内容视图：套一层普通的 AppKit 容器，承载视图跟着容器伸缩。
        // 承载视图一旦是 contentView，SwiftUI 会在窗口布局的通知里自己调整窗口大小，和我们手动调整互相打架，
        // 触发 AppKit 的布局死循环保护而崩溃（"Update Constraints in Window pass" 异常）。
        let container = WidgetContainerView(frame: NSRect(origin: .zero, size: size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        p.contentView = container
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false                      // 毛玻璃本身有边，不再叠系统阴影
        p.isMovableByWindowBackground = false    // 拖动由 WidgetHostingView 自己处理
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // 桌面图标上一层：在所有普通窗口下面，像真正的桌面小组件
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if let o = model.store.widgetOrigin, o.count == 2, NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: o[0] + 20, y: o[1] - 20)) }) {
            // 存的是左上角位置，换尺寸后保持左上角不动
            p.setFrameOrigin(NSPoint(x: o[0], y: o[1] - size.height))
        } else if let s = NSScreen.main {
            let f = s.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16))
        }
        snap(p)
        p.alphaValue = 0                                     // 淡入
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            p.animator().alphaValue = 1
        }
        panel = p
        self.host = host
        self.model = model

        // 松开鼠标：吸附到格子，并记住位置（左上角）
        host.onDragEnd = { [weak self, weak model, weak p] in
            guard let self, let model, let p else { return }
            self.snap(p)
            model.store.widgetOrigin = [Double(p.frame.origin.x), Double(p.frame.maxY)]
            model.save()
        }
        // 账号增减、切换尺寸、数据变化后自动调整大小（保持左上角不动）
        model.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.fit() }
            .store(in: &bag)

        model.store.widgetVisible = true
        model.save()
    }

    /// 换尺寸：先把窗口放大到新旧尺寸的并集（左上角不动），让内容有地方做动画；
    /// 内容用弹簧动画变形并淡入淡出，动画结束后再把窗口收缩到实际大小。
    func changeSize(_ model: Model, to s: WidgetSize) {
        guard let p = panel else { model.store.widgetSize = s.rawValue; model.save(); return }
        guard model.store.widgetSize != s.rawValue else { return }
        resizing = true
        var f = p.frame
        let w = max(f.width, s.width), h = max(f.height, s.height)
        f.origin.y += f.height - h
        f.size = NSSize(width: w, height: h)
        p.setFrame(f, display: true)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) { model.store.widgetSize = s.rawValue }
        model.save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.resizing = false
            self?.fit()
        }
    }

    func fit() {
        guard !resizing, let p = panel, let model = model else { return }
        let new = desiredSize(model)
        var f = p.frame
        guard abs(f.height - new.height) > 0.5 || abs(f.width - new.width) > 0.5 else { return }
        f.origin.y += f.height - new.height
        f.size = new
        p.setFrame(f, display: true)
    }

    func hide(_ model: Model) {
        if let old = panel {                                 // 淡出后再真正关掉
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                old.animator().alphaValue = 0
            }, completionHandler: { old.orderOut(nil) })
        }
        panel = nil
        host = nil
        self.model = nil
        bag.removeAll()
        model.store.widgetVisible = false
        model.save()
    }
}
