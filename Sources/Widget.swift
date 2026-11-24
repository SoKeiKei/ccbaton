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
    let value: Double?
    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle((value ?? 0) >= 80 ? levelColor(value) : .primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.13))
                    Capsule().fill(levelColor(value))
                        .frame(width: max(value == nil ? 0 : 4, g.size.width * CGFloat(min(max(value ?? 0, 0), 100) / 100)))
                        .animation(.easeOut(duration: 0.7), value: value)
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
    var body: some View {
        ZStack {
            ringLayer(value: five, diameter: 78, width: 8)
            ringLayer(value: seven, diameter: 55, width: 8)
            VStack(spacing: 0) {
                Text(five.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("5 小时").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    func ringLayer(value: Double?, diameter: CGFloat, width: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.13), lineWidth: width)
            Circle().trim(from: 0, to: CGFloat(min(max(value ?? 0, 0), 100)) / 100)
                .stroke(levelColor(value), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: value)
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

    var size: WidgetSize { WidgetSize(rawValue: model.store.widgetSize ?? "") ?? .medium }
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
            Button("隐藏小组件") { onHide() }
        }
    }

    // 顶部一行：名字 + 状态（切换结果 / 更新时间）
    func header(_ pt: CGFloat = 11) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: pt + 1, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text("CCBaton").font(.system(size: pt, weight: .bold))
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
        let others = model.store.accounts.filter { $0.id != a?.id }
        return VStack(spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(a.map { model.shortDisplayName($0) } ?? "CCBaton").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            DualRing(five: st?.fiveHour, seven: st?.sevenDay)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("7 天 \(st?.sevenDay.map { "\(Int($0))%" } ?? "—")").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ForEach(others.prefix(3)) { o in
                    let os = model.states[o.id] ?? AccountState()
                    Button { if os.loggedIn { onSwitch(o) } } label: {
                        Text(String(model.shortDisplayName(o).prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(os.loggedIn ? avatarColor(os.email.isEmpty ? o.id : os.email) : Color.gray.opacity(0.5)))
                    }
                    .buttonStyle(.plain).help("切换到 \(model.shortDisplayName(o))")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // 中号：每个账号一行：切换按钮 + 名字 + 两条进度
    var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
            Spacer(minLength: 6)
            VStack(spacing: 8) {
                ForEach(model.store.accounts) { a in
                    let st = model.states[a.id] ?? AccountState()
                    HStack(spacing: 9) {
                        SwitchBadge(live: st.live, usable: usable(st), size: 26) { onSwitch(a) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.shortDisplayName(a)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(st.live ? "使用中" : (st.plan.isEmpty ? " " : st.plan))
                                .font(.system(size: 9, weight: st.live ? .semibold : .regular))
                                .foregroundStyle(st.live ? Color.green : Color.secondary)
                        }
                        .frame(width: 70, alignment: .leading)
                        if st.loggedIn {
                            StackMeter(title: "5 小时", value: st.fiveHour)
                            StackMeter(title: "7 天", value: st.sevenDay)
                        } else {
                            Text("登录已失效，需要重新登录").font(.system(size: 10)).foregroundStyle(.orange)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // 大号：每个账号一块，带重置倒计时
    var large: some View {
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
                                Text(model.shortDisplayName(a)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(st.live ? "使用中" : (st.plan.isEmpty ? " " : st.plan))
                                    .font(.system(size: 10, weight: st.live ? .semibold : .regular))
                                    .foregroundStyle(st.live ? Color.green : Color.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        if st.loggedIn {
                            HStack(alignment: .top, spacing: 16) {
                                Meter(title: "5 小时", value: st.fiveHour, reset: st.fiveReset)
                                Meter(title: "7 天", value: st.sevenDay, reset: st.sevenReset)
                            }
                        } else {
                            Text("登录已失效，需要重新登录").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 承载视图：既要让按钮能点，又要能按住空白处拖动窗口

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
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
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
        guard !resizing, let p = panel, let host else { return }
        let new = host.fittingSize
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
        bag.removeAll()
        model.store.widgetVisible = false
        model.save()
    }
}
