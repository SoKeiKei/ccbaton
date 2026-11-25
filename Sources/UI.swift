import SwiftUI
import AppKit

// MARK: - 小工具

func levelColor(_ v: Double?) -> Color {
    guard let v else { return .secondary }
    return v >= 95 ? .red : (v >= 80 ? .orange : .accentColor)
}

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = d.timeIntervalSinceNow
    if s <= 0 { return "已到重置时间，待刷新" }
    let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
    return h >= 24 ? "\(h / 24)天\(h % 24)小时后重置" : (h > 0 ? "\(h)小时\(m)分后重置" : "\(m)分钟后重置")
}

func agoText(_ d: Date?) -> String {
    guard let d else { return "尚未更新" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "刚刚更新" }
    if s < 3600 { return "\(s / 60)分钟前更新" }
    return "\(s / 3600)小时前更新"
}

// MARK: - 菜单栏图标：外圈 5 小时、内圈 7 天

/// 正常时用模板图（系统自动适配深浅色菜单栏）；吃紧（alert=1）或告急（alert=2）时用彩色，并在外圈加一层淡淡的光晕。
func ringIcon(five: Double?, seven: Double?, alert: Int, size: CGFloat = 18) -> NSImage {
    let hot = alert > 0
    let canvas = size + 6                       // 留出光晕的位置；大小固定，菜单栏图标不会因告警而跳动
    let img = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let lw = size * 0.115
        if hot {
            let glow: NSColor = alert >= 2 ? .systemRed : .systemOrange
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = glow.withAlphaComponent(alert >= 2 ? 0.95 : 0.7)
            sh.shadowBlurRadius = alert >= 2 ? 4.5 : 3
            sh.shadowOffset = .zero
            sh.set()
            let halo = NSBezierPath()
            halo.appendArc(withCenter: c, radius: size * 0.40, startAngle: 0, endAngle: 360)
            halo.lineWidth = lw
            glow.withAlphaComponent(0.9).setStroke()
            halo.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        func ring(_ radius: CGFloat, _ value: Double?) {
            // 模板模式只看透明度，用黑色；彩色模式里没超标的那圈用中灰，深浅菜单栏都看得清
            let calm: NSColor = hot ? NSColor(white: 0.62, alpha: 1) : .black
            let color: NSColor = {
                guard hot, let v = value else { return calm }
                return v >= 95 ? .systemRed : (v >= 80 ? .systemOrange : calm)
            }()
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lw
            (hot ? NSColor.gray.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.28)).setStroke()
            track.stroke()
            guard let v = value, v > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: radius, startAngle: 90,
                          endAngle: 90 - CGFloat(min(v, 100)) / 100 * 360, clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }
        ring(size * 0.40, five)
        ring(size * 0.20, seven)
        return true
    }
    img.isTemplate = !hot
    return img
}

struct BarLabel: View {
    @ObservedObject var model: Model
    var body: some View {
        let st = model.live.flatMap { model.states[$0.id] }
        HStack(spacing: 4) {
            Image(nsImage: ringIcon(five: st?.fiveHour, seven: st?.sevenDay, alert: st?.level ?? 0))
            if let f = st?.fiveHour { Text("\(Int(f))%").monospacedDigit() }
        }
    }
}

// MARK: - 面板

struct Meter: View {
    let title: String
    let value: Double?
    let reset: Date?
    var idle = false          // 5 小时窗口还没开始计时
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle((value ?? 0) >= 80 ? levelColor(value) : .primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(levelColor(value))
                        .frame(width: max(value == nil ? 0 : 5, g.size.width * CGFloat(min(max(value ?? 0, 0), 100) / 100)))
                        .animation(.easeOut(duration: 0.7), value: value)
                }
            }.frame(height: 5)
            Text(value == nil ? "暂无数据" : (idle ? "未开始计时" : resetText(reset)))
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Tag: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }
}

struct AccountCard: View {
    @ObservedObject var model: Model
    let account: Account
    var recommended = false
    var st: AccountState { model.states[account.id] ?? AccountState() }
    var isActive: Bool { st.live }

    var body: some View {
        let full = model.displayName(account)
        let name = model.shortDisplayName(account)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(model: model, account: account)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(full)
                        Button { AccountEditor.shared.open(model, account: account) } label: {
                            Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("修改显示名称")
                    }
                    HStack(spacing: 5) {
                        if isActive { Tag(text: "使用中", tint: .green) }
                        if !st.plan.isEmpty { Tag(text: st.plan) }
                        if recommended { Tag(text: "推荐", tint: .accentColor) }
                    }
                }
                Spacer(minLength: 4)
                if !isActive && st.loggedIn {
                    Button { model.switchTo(account) } label: {
                        Label("切换", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.switching)
                    .help("把 Claude Code 的登录换成这个账号（新开的和正在运行的普通 claude 都会用它）")
                }
                if st.loggedIn {
                    Button { TerminalController.shared.open(model, account: account) } label: {
                        Label("终端", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("选目录和参数，用这个账号开终端")
                } else {
                    Button { model.relogin(account) } label: { Label("重新登录", systemImage: "person.badge.key") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if st.loggedIn {
                HStack(alignment: .top, spacing: 14) {
                    Meter(title: "5 小时", value: st.fiveHour, reset: st.fiveReset, idle: st.fiveIdle)
                    Meter(title: "7 天", value: st.sevenDay, reset: st.sevenReset)
                }
            } else {
                Label("登录已失效或还没登录，点右上角「重新登录」，授权完成后点刷新", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color.green.opacity(0.09) : Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? Color.green.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: isActive ? 1.2 : 0.8)
        )
        .alertGlow(st.level, corner: 12, radius: 9)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isActive)
        .contextMenu { AccountMenu(model: model, account: account) }
    }
}

struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: icon).lineLimit(1).fixedSize() }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
    }
}

struct MenuView: View {
    @ObservedObject var model: Model
    @State private var showAdd = false
    @State private var newLabel = ""
    @State private var shown = true          // 弹出动效：false → true 时整个面板弹出、卡片依次浮现

    /// 每次打开面板就重播一遍弹出动效
    private func replay() {
        if Model.readOnly { return }        // 截图时不播动效，拍到的才是稳定画面
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { shown = true }
    }

    var newest: Date? { model.states.values.compactMap { $0.fetchedAt }.max() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text("CCBaton").font(.system(size: 15, weight: .bold))
                Spacer()
                Text(agoText(newest)).font(.caption2).foregroundStyle(.tertiary)
                Button {
                    Task { model.reloadStates(); await model.refreshAll(force: true) }
                } label: {
                    if model.refreshing { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                    else { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
                }
                .buttonStyle(.borderless).disabled(model.refreshing).help("刷新所有账号的额度")
            }

            if let advice = model.switchAdvice {
                HStack(spacing: 8) {
                    Label(advice.text, systemImage: "arrow.triangle.swap")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let t = advice.target {
                        Button("切换") { model.switchTo(t) }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(model.switching)
                            .help("切换到「\(model.shortDisplayName(t))」")
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            AccountList(model: model, shown: shown)

            if let n = model.notice {
                Text(n).font(.caption).foregroundStyle(.secondary)
            }

            if model.warmupOn {
                Button { SettingsController.shared.open(model) } label: {
                    Label("预热：" + model.warmupStatus, systemImage: "timer")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).help("点一下打开设置")
            }

            Divider().opacity(0.5)
            HStack(spacing: 14) {
                FooterButton(title: "添加账号", icon: "plus.circle") { showAdd = true }
                FooterButton(title: "设置", icon: "gearshape") { SettingsController.shared.open(model) }
                    .help("开机启动、额度预热、提醒、小组件")
                Spacer()
                VersionTag(model: model)
                FooterButton(title: "退出", icon: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
        .scaleEffect(shown ? 1 : 0.95, anchor: .top)
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: shown)
        .onAppear { if !Model.readOnly { model.notice = nil; model.reloadStates() }; replay() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            // 点菜单栏图标弹出面板时，面板窗口会成为 key 窗口：重播弹出动效（小组件和本程序的其他窗口不算）
            let others = [WidgetController.shared.panel, AccountEditor.shared.window, SettingsController.shared.window, TerminalController.shared.window]
            guard let w = n.object as? NSWindow, !others.contains(where: { $0 === w }), w.sheetParent == nil else { return }
            model.notice = nil; model.reloadStates(); replay()
        }
        .alert("添加 Claude 账号", isPresented: $showAdd) {
            TextField("名字（可不填，如：工作）", text: $newLabel)
            Button("在终端里登录") { model.addAccount(label: newLabel); newLabel = "" }
            Button("取消", role: .cancel) { newLabel = "" }
        } message: {
            Text("会打开终端，用 Claude 官方的登录流程，在浏览器里授权。")
        }
    }
}

// MARK: - 离屏截图（不需要屏幕录制权限），用来检查界面

/// 截图用的窗口：当成当前活动窗口来画，主按钮才是实际使用时的蓝色
private final class ShotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// 控件进窗口后可能比量出来的矮一两个点，边上会留一条透明缝：裁掉
private func trimClearEdges(_ rep: NSBitmapImageRep, scale: CGFloat) -> NSBitmapImageRep {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    func clear(_ x: Int, _ y: Int) -> Bool { (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.5 }
    var top = 0, bottom = h, left = 0, right = w
    while top < bottom && clear(w / 2, top) { top += 1 }
    while bottom > top && clear(w / 2, bottom - 1) { bottom -= 1 }
    while left < right && clear(left, h / 2) { left += 1 }
    while right > left && clear(right - 1, h / 2) { right -= 1 }
    guard right > left, bottom > top,
          let cut = rep.cgImage?.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else { return rep }
    let out = NSBitmapImageRep(cgImage: cut)
    out.size = NSSize(width: CGFloat(cut.width) / scale, height: CGFloat(cut.height) / scale)
    return out
}

@MainActor
func renderPNG<V: View>(_ view: V, dark: Bool, scale: CGFloat = 2, path: String) {
    let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let win = ShotWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    try? trimClearEdges(rep, scale: scale).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// 把系统警告框画成图片（离屏时它的毛玻璃底是透明的，垫一层窗口底色）
@MainActor
func renderAlert(_ alert: NSAlert, scale: CGFloat = 2, path: String) {
    alert.layout()
    let window = alert.window
    window.appearance = NSAppearance(named: .darkAqua)
    guard let content = window.contentView else { return }
    content.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
    content.cacheDisplay(in: content.bounds, to: rep)
    let image = NSImage(size: content.bounds.size)
    image.addRepresentation(rep)
    renderPNG(Image(nsImage: image)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6).padding(28)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.28, blue: 0.50), Color(red: 0.42, green: 0.26, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)),
        dark: true, scale: scale, path: path)
}

/// README 用的演示数据：虚构的账号、邮箱和用量，不含任何真实信息
@MainActor
func applyDemo(_ model: Model, live five: Double = 42, liveSeven: Double = 61, second: Double = 8) {
    Model.demo = true
    func st(_ email: String, _ plan: String, live: Bool, _ f: Double, _ s: Double, _ fr: TimeInterval, _ sr: TimeInterval) -> AccountState {
        var a = AccountState()
        a.live = live; a.loggedIn = true; a.email = email; a.plan = plan; a.orgName = email
        a.fiveHour = f; a.sevenDay = s
        a.fiveReset = Date().addingTimeInterval(fr); a.sevenReset = Date().addingTimeInterval(sr)
        a.fetchedAt = Date().addingTimeInterval(-20)
        return a
    }
    model.store.accounts = [Account(id: "d1", label: "工作", configDir: "/demo/1"),
                            Account(id: "d2", label: "个人", configDir: "/demo/2"),
                            Account(id: "d3", label: "备用", configDir: "/demo/3")]
    model.store.workDir = home + "/Projects/my-app"
    model.store.warmupEnabled = false
    model.store.warmupRecords = nil
    model.store.autoUpdateCheck = true
    model.store.updateRelease = nil
    model.store.updateCheckedAt = Date().addingTimeInterval(-3600)
    model.updatePhase = .idle
    model.store.recentDirs = ["my-app", "website", "scripts", "notes"].map { home + "/Projects/" + $0 }
    model.store.terminalPrefs = ["d2": TerminalPrefs(dir: home + "/Projects/website", skipPermissions: false, args: "--continue")]
    model.states = [
        "d1": st("alex.work@example.com", "Max", live: true, five, liveSeven, 2 * 3600 + 35 * 60, 2 * 86400 + 5 * 3600),
        "d2": st("alex@example.com", "Pro", live: false, second, 23, 3 * 3600 + 10 * 60, 4 * 86400 + 17 * 3600),
        "d3": st("alex.backup@example.com", "Pro", live: false, 0, 12, 4 * 3600 + 50 * 60, 5 * 86400 + 2 * 3600),
    ]
}

/// 多账号的演示数据：第一个在用，有一个吃紧、一个周额度用完、（够多时）一个登录失效
@MainActor
func applyManyDemo(_ model: Model, count: Int) {
    applyDemo(model)
    let names = ["工作", "个人", "备用", "团队", "客户项目", "实验", "副号", "夜间任务", "测试", "临时", "课程", "归档"]
    let five: [Double] = [42, 8, 0, 85, 27, 63, 12, 96, 5, 33, 55, 18]
    let seven: [Double] = [61, 23, 12, 44, 100, 31, 8, 72, 19, 50, 66, 4]
    model.store.accounts = (0..<count).map { i in
        Account(id: "d\(i + 1)", label: names[i % names.count] + (i < names.count ? "" : "\(i + 1)"), configDir: "/demo/\(i + 1)")
    }
    var states: [String: AccountState] = [:]
    for (i, a) in model.store.accounts.enumerated() {
        var s = AccountState()
        s.live = i == 0; s.loggedIn = i != 5; s.email = "alex\(i + 1)@example.com"; s.plan = i == 0 ? "Max" : "Pro"; s.orgName = s.email
        s.fiveHour = five[i % five.count]; s.sevenDay = seven[i % seven.count]
        s.fiveReset = Date().addingTimeInterval(Double(3600 + i * 900)); s.sevenReset = Date().addingTimeInterval(Double(86400 * 2 + i * 7200))
        s.fetchedAt = Date().addingTimeInterval(-20)
        states[a.id] = s
    }
    model.states = states
}

/// README 截图：总览、面板、设置、终端、小组件三个尺寸、告警状态、编辑窗口、菜单栏图标。全部用演示数据。
@MainActor
func renderReadmeShots(to dir: String) {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let model = Model()
    applyDemo(model)

    let wall = LinearGradient(colors: [Color(red: 0.16, green: 0.28, blue: 0.50), Color(red: 0.42, green: 0.26, blue: 0.52)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    let wallLight = LinearGradient(colors: [Color(red: 0.80, green: 0.88, blue: 1.0), Color(red: 0.96, green: 0.84, blue: 0.90)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
    // 菜单栏弹出面板：圆角 + 阴影，放在一块壁纸色背景上
    func popover(dark: Bool) -> some View {
        MenuView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            .padding(30)
            .background(dark ? wall : wallLight)
    }
    // 主界面把提醒都摆出来：使用中的账号 96%（红）、另一个 85%（橙）、顶部换号建议；
    // 预热开着，第三个账号还没开始计时，底部是预热状态
    func applyShowcase() {
        applyDemo(model, live: 96, liveSeven: 61, second: 85)
        model.states["d3"]?.fiveReset = nil
        model.states["d3"]?.fiveIdle = true
        model.states["d2"]?.fiveReset = Date().addingTimeInterval(4 * 3600 + 30 * 60)
        model.store.warmupEnabled = true     // 只改内存里的，不保存
        model.store.warmupStagger = true
    }
    applyShowcase()
    renderPNG(popover(dark: true), dark: true, path: dir + "/panel-dark.png")
    renderPNG(popover(dark: false), dark: false, path: dir + "/panel-light.png")

    // 设置窗口
    model.store.widgetVisible = true         // 只改内存里的，不保存
    model.store.widgetSize = "medium"
    model.store.alertsEnabled = true
    func settings(dark: Bool) -> some View {
        SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6).padding(28).background(dark ? wall : wallLight)
    }
    renderPNG(settings(dark: true), dark: true, path: dir + "/settings.png")
    applyDemo(model)

    renderPNG(TerminalLaunchView(model: model, account: model.store.accounts[1], close: {}).background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).shadow(color: .black.opacity(0.3), radius: 14, y: 6).padding(28).background(wall),
        dark: true, path: dir + "/terminal.png")

    for s in WidgetSize.allCases {
        model.store.widgetSize = s.rawValue
        renderPNG(WidgetView(model: model).padding(16).background(wall), dark: true, path: dir + "/widget-\(s.rawValue).png")
    }
    model.store.widgetSize = "medium"
    renderPNG(WidgetView(model: model).padding(16).background(wallLight), dark: false, path: dir + "/widget-medium-light.png")

    let other = model.store.accounts[1]
    renderPNG(EditView(model: model, account: other, close: {}).background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).shadow(color: .black.opacity(0.3), radius: 14, y: 6).padding(28).background(wall),
        dark: true, path: dir + "/editor.png")

    // 移除账号的确认框（演示一个用"添加账号"加的号，会删登录的那种）
    model.store.accounts[1].configDir = supportDir + "/accounts/demo/config"
    renderAlert(removalAlert(model.removalPrompt(model.store.accounts[1], terminals: [])), path: dir + "/remove.png")

    // 迁移：设置里的入口和确认框（演示账号放在 cc-switch 目录里，当作装着它）
    model.ccSwitchInstalled = { true }
    applyDemo(model)
    for i in model.store.accounts.indices { model.store.accounts[i].configDir = ccSwitchRoot + "/claude-accounts/demo\(i)/config" }
    model.store.warmupEnabled = false; model.store.widgetVisible = true; model.store.widgetSize = "medium"
    renderPNG(settings(dark: true), dark: true, path: dir + "/settings-migrate.png")
    renderAlert(removalAlert(model.migrationPrompt, destructive: false), path: dir + "/migrate.png")

    // 软件更新：面板右下角的红点，和设置里发现新版时的样子
    applyDemo(model)
    model.store.updateRelease = AppRelease(version: "1.4.0", page: releasesPageURL, zip: releasesPageURL, signature: releasesPageURL)
    renderPNG(popover(dark: true), dark: true, path: dir + "/panel-update.png")
    renderPNG(UpdateSettings(model: model).padding(20).frame(width: 420).background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).shadow(color: .black.opacity(0.3), radius: 14, y: 6).padding(28).background(wall),
        dark: true, path: dir + "/update.png")

    // 告警：使用中的账号 96%（红），另一个 85%（橙）
    applyDemo(model, live: 96, liveSeven: 61, second: 85)
    renderPNG(WidgetView(model: model).padding(16).background(wall), dark: true, path: dir + "/alert-widget.png")
    model.store.widgetSize = "small"
    renderPNG(WidgetView(model: model).padding(16).background(wall), dark: true, path: dir + "/alert-widget-small.png")

    // 总览大图：面板 + 中号小组件 + 大号小组件，摆在同一块壁纸上
    applyShowcase()
    model.store.widgetSize = "medium"
    struct Hero: View {
        @ObservedObject var model: Model
        let wall: LinearGradient
        var body: some View {
            HStack(alignment: .top, spacing: 26) {
                MenuView(model: model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 9)
                VStack(alignment: .leading, spacing: 8) {
                    WidgetView(model: model, forceSize: .medium)
                    WidgetView(model: model, forceSize: .large)
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 40)
            .background(wall)
        }
    }
    renderPNG(Hero(model: model, wall: wall), dark: true, path: dir + "/hero.png")

    // 账号多时：面板换成紧凑布局（让使用中的快用完，带出换号建议和"推荐"）
    applyManyDemo(model, count: 8)
    model.states["d1"]?.fiveHour = 96
    renderPNG(popover(dark: true), dark: true, path: dir + "/panel-many.png")
    // 拖动排序：把第 5 个往上拖，蓝线是松手后的位置
    applyManyDemo(model, count: 7)
    AccountList.shotDrag = AccountDrag(id: "d5", offset: -86)
    renderPNG(popover(dark: true), dark: true, path: dir + "/panel-reorder.png")
    AccountList.shotDrag = nil
    // 小组件
    applyManyDemo(model, count: 8)
    struct Many: View {
        @ObservedObject var model: Model
        let wall: LinearGradient
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                // 小组件会撑满给它的空间，这里按系统格子给定大小
                ForEach(WidgetSize.allCases, id: \.self) { s in
                    WidgetView(model: model, forceSize: s).frame(width: s.width, height: s.height)
                }
            }
            .padding(16).background(wall)
        }
    }
    renderPNG(Many(model: model, wall: wall), dark: true, path: dir + "/widget-many.png")

    // 菜单栏图标：正常 / 吃紧 / 告急
    struct Strip: View {
        let dark: Bool
        let wall: LinearGradient
        var body: some View {
            HStack(spacing: 26) {
                ForEach([(42.0, 61.0, 0), (85.0, 61.0, 1), (96.0, 61.0, 2)], id: \.0) { p in
                    HStack(spacing: 5) {
                        Image(nsImage: ringIcon(five: p.0, seven: p.1, alert: p.2)).resizable().frame(width: 40, height: 40)
                        Text("\(Int(p.0))%").font(.system(size: 28, weight: .medium)).monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .foregroundStyle(dark ? Color.white : Color.black)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(14).background(wall)
        }
    }
    renderPNG(Strip(dark: true, wall: wall), dark: true, path: dir + "/menubar-dark.png")
    renderPNG(Strip(dark: false, wall: wallLight), dark: false, path: dir + "/menubar-light.png")
    print("已生成 README 截图到 \(dir)")
}

@MainActor
func renderSnapshots(to dir: String) {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    func png<V: View>(_ view: V, dark: Bool, scale: CGFloat = 2, file: String) {
        renderPNG(view, dark: dark, scale: scale, path: "\(dir)/\(file)")
    }

    let model = Model()
    let panel = MenuView(model: model).background(Color(nsColor: .windowBackgroundColor))
    png(panel, dark: true, file: "panel-dark.png")
    png(MenuView(model: model).background(Color(nsColor: .windowBackgroundColor)), dark: false, file: "panel-light.png")

    if let first = model.store.accounts.first(where: { model.states[$0.id]?.live == true }) ?? model.store.accounts.first {
        png(EditView(model: model, account: first, close: {}).background(Color(nsColor: .windowBackgroundColor)), dark: true, file: "editor-dark.png")
        png(EditView(model: model, account: first, close: {}).background(Color(nsColor: .windowBackgroundColor)), dark: false, file: "editor-light.png")
    }
    for (i, a) in model.store.accounts.prefix(2).enumerated() {      // 打开终端的窗口：在用和没在用的说明不一样
        png(TerminalLaunchView(model: model, account: a, close: {}).background(Color(nsColor: .windowBackgroundColor)), dark: i == 0, file: "terminal-\(i).png")
    }
    // 设置窗口（按实际设置）和"预热开着"时的面板
    png(SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)), dark: true, file: "settings-dark.png")
    png(SettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)), dark: false, file: "settings-light.png")
    let savedWarmup = model.store.warmupEnabled
    model.store.warmupEnabled = true         // 只改内存里的，不保存
    png(MenuView(model: model).background(Color(nsColor: .windowBackgroundColor)), dark: true, file: "panel-warmup-dark.png")
    model.store.warmupEnabled = savedWarmup
    for s in WidgetSize.allCases {
        model.store.widgetSize = s.rawValue      // 只改内存里的，不保存
        png(WidgetView(model: model).padding(14).background(LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.5, green: 0.3, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)), dark: true, file: "widget-\(s.rawValue)-dark.png")
    }
    model.store.widgetSize = "medium"
    png(WidgetView(model: model).padding(14).background(LinearGradient(colors: [Color(red: 0.85, green: 0.9, blue: 1), Color(red: 0.95, green: 0.85, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)), dark: false, file: "widget-medium-light.png")

    // 菜单栏图标放大看：深/浅两种底色 × 三种用量
    struct Icons: View {
        let dark: Bool
        var body: some View {
            HStack(spacing: 18) {
                ForEach([(7.0, 55.0), (85.0, 40.0), (97.0, 90.0)], id: \.0) { p in
                    HStack(spacing: 4) {
                        Image(nsImage: ringIcon(five: p.0, seven: p.1, alert: p.0 >= 95 ? 2 : (p.0 >= 80 ? 1 : 0))).resizable().frame(width: 72 * 24 / 18, height: 72 * 24 / 18)
                        Text("\(Int(p.0))%").font(.system(size: 52)).monospacedDigit()
                    }
                }
            }
            .padding(20)
            .foregroundStyle(dark ? Color.white : Color.black)
            .background(dark ? Color(white: 0.15) : Color(white: 0.92))
        }
    }
    // 告警示例：在内存里把在用账号调到 96%、另一个调到 85%，看光晕效果（不保存）
    if let li = model.store.accounts.first(where: { model.states[$0.id]?.live == true }) {
        model.states[li.id]?.fiveHour = 96
        model.states[li.id]?.fiveReset = Date().addingTimeInterval(7200)
        if let o = model.store.accounts.first(where: { $0.id != li.id }) {
            model.states[o.id]?.fiveHour = 85
            model.states[o.id]?.fiveReset = Date().addingTimeInterval(7200)
        }
        png(MenuView(model: model).background(Color(nsColor: .windowBackgroundColor)), dark: true, file: "panel-alert-dark.png")
        for s in ["medium", "small"] {
            model.store.widgetSize = s
            png(WidgetView(model: model).padding(14).background(LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.5, green: 0.3, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)), dark: true, file: "widget-\(s)-alert.png")
        }
    }
    png(Icons(dark: true), dark: true, scale: 1, file: "icons-dark.png")
    png(Icons(dark: false), dark: false, scale: 1, file: "icons-light.png")
}

// MARK: - 入口

@main
struct ClaudeAccountBarApp: App {
    @StateObject private var model = Model()
    init() {
        let args = CommandLine.arguments
        // 启动脚本用它核对独立终端登录的是不是所选账号：0 是，1 不是
        if let i = args.firstIndex(of: "--check-terminal-login") {
            exit(i + 2 < args.count && terminalLoginMatches(dir: args[i + 1], key: args[i + 2]) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--login-item") { exit(LoginItem.runCLI(i + 1 < args.count ? args[i + 1] : "status")) }
        if args.contains("--version") { print("CCBaton \(appVersion) (构建 \(appBuild))"); exit(0) }
        // 截图、预检、查看状态只读：绝不把设置写回文件（导入 --import 和 --widgettest 例外，后者只在沙盒里跑）
        if args.contains("--snapshot") || args.contains("--check") || args.contains("--dump") || args.contains("--readme-shots") { Model.readOnly = true }
        if let i = args.firstIndex(of: "--readme-shots") {
            let dir = i + 1 < args.count ? args[i + 1] : "docs/screenshots"
            MainActor.assumeIsolated { renderReadmeShots(to: dir) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
            MainActor.assumeIsolated { renderSnapshots(to: dir) }
            exit(0)
        }
        if args.contains("--idle-for-test"), testRoot != nil { Thread.sleep(forTimeInterval: 4); exit(0) }
        if args.contains("--finish-update-for-test"), testRoot != nil {      // 更新测试里"打开新版"走到这
            MainActor.assumeIsolated { Model.readOnly = true; let m = Model(); Model.readOnly = false; m.finishPendingUpdate() }
            exit(0)
        }
        // 只读：真的去问一次 GitHub，打印结果（不下载、不安装、不写设置）
        if args.contains("--check-update") { exit(runUpdateCheckCLI()) }
        if args.contains("--selftest") { exit(runSelfTest()) }
        if args.contains("--warmuptest") { exit(MainActor.assumeIsolated { runWarmupTest() }) }
        if args.contains("--terminaltest") { exit(MainActor.assumeIsolated { runTerminalTest() }) }
        if args.contains("--multitest") { exit(MainActor.assumeIsolated { runMultiTest() }) }
        if args.contains("--migratetest") { exit(MainActor.assumeIsolated { runMigrationTest() }) }
        if args.contains("--updatetest") { exit(MainActor.assumeIsolated { runUpdateTest() }) }
        if args.contains("--renametest") {
            guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); exit(2) }
            var failed = 0
            func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                let m = Model()
                let cfg = home + "/accounts/a/config"
                try? FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
                try? writeProfile(cfg + "/.claude.json", account: ["accountUuid": "u1", "organizationUuid": "o1", "emailAddress": "real@test.com",
                                                                   "organizationType": "claude_pro", "organizationName": "Real Org"])
                let a = Account(id: "a", label: "", configDir: cfg)
                m.store.accounts = [a]; m.reloadStates()
                check("没改名时显示真实邮箱", m.displayName(a) == "real@test.com" && m.shortDisplayName(a) == "real")
                check("真实登录信息读得到（套餐 Pro、组织 Real Org）", m.states["a"]?.plan == "Pro" && m.states["a"]?.orgName == "Real Org")
                m.rename(a, to: "  工作账号  ")
                let a2 = m.store.accounts[0]
                check("改名后显示新名字（首尾空格被去掉）", m.displayName(a2) == "工作账号" && m.shortDisplayName(a2) == "工作账号")
                let onDisk = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
                check("名字已存盘，重新加载还在", onDisk?.accounts.first?.label == "工作账号")
                check("真实登录没有被改动", identity(ofDir: cfg)?.email == "real@test.com")
                m.rename(a2, to: "带@符号的名字")
                check("自定义名字里有 @ 也原样显示", m.shortDisplayName(m.store.accounts[0]) == "带@符号的名字")
                m.rename(a2, to: String(repeating: "长", count: 40))
                check("超长名字被截到 24 个字", m.store.accounts[0].label.count == 24)
                m.rename(a2, to: "")
                check("留空恢复显示邮箱", m.displayName(m.store.accounts[0]) == "real@test.com")
                AccountEditor.shared.open(m, account: m.store.accounts[0])
                let w = AccountEditor.shared.window
                check("编辑窗口打开了，标题和宽度正确", w?.isVisible == true && w?.title == "修改账号名称" && abs((w?.contentView?.frame.width ?? 0) - 400) < 1)
                w?.close()
            }
            print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
            exit(failed == 0 ? 0 : 1)
        }
        if args.contains("--alerttest") {
            // 告警逻辑测试：纯计算，不发任何通知
            var failed = 0
            func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
            let later = Date().addingTimeInterval(7200)
            func st(_ five: Double?, seven: Double? = 10, live: Bool = false, reset: Date? = later) -> AccountState {
                var s = AccountState(); s.live = live; s.loggedIn = true; s.fiveHour = five; s.sevenDay = seven
                s.fiveReset = reset; s.sevenReset = later; return s
            }
            let A = Account(id: "a", label: "AB", configDir: "/x/a"), B = Account(id: "b", label: "LK", configDir: "/x/b"), C = Account(id: "c", label: "ZJ", configDir: "/x/c")
            let accs = [A, B, C]
            func run(_ sa: AccountState, b: AccountState = st(10), c: AccountState = st(20), alerted: Set<String> = []) -> [AlertItem] {
                alertsToFire(accounts: accs, states: ["a": sa, "b": b, "c": c], alerted: alerted, name: { $0.label })
            }
            check("等级：79%→0，80%→1，95%→2", st(79).level == 0 && st(80).level == 1 && st(94.9).level == 1 && st(95).level == 2)
            check("等级：7 天用量高也算", st(10, seven: 96).level == 2)
            var stale = st(99, seven: 10); stale.fiveReset = Date().addingTimeInterval(-60)
            check("等级：5 小时窗口已过重置时间，旧的 99% 不触发告急", stale.level == 0)
            check("85% 不弹通知", run(st(85, live: true)).isEmpty)
            let r92 = run(st(92, live: true))
            check("92% 弹一条，标题带账号名和百分比", r92.count == 1 && r92[0].title.contains("AB") && r92[0].title.contains("92%"))
            check("建议切到用得最少的账号（LK 10%，不是 ZJ 20%）", r92.first?.body.contains("「LK」") == true)
            check("同一周期已提醒过就不再弹", run(st(93, live: true), alerted: Set(r92[0].keys)).isEmpty)
            let r100 = run(st(100, live: true))
            check("直接到 100%：只弹一条（用完），标题说已用完", r100.count == 1 && r100[0].title.contains("已用完"))
            check("100% 的记号同时覆盖 90 和 100 两档", r100.first?.keys.count == 2)
            check("90% 提醒过之后涨到 100%，再弹一条（用完）", run(st(100, live: true), alerted: Set(r92[0].keys)).count == 1)
            check("100% 也提醒过就不再弹", run(st(100, live: true), alerted: Set(r100[0].keys)).isEmpty)
            let nextWindow = alertsToFire(accounts: accs, states: ["a": st(92, live: true, reset: later.addingTimeInterval(18000)), "b": st(10), "c": st(20)], alerted: Set(r92[0].keys), name: { $0.label })
            check("下一个重置周期里再到 90%，会重新提醒", nextWindow.count == 1)
            check("过期的旧读数（已过重置时间）不弹", run(st(99, live: true, reset: Date().addingTimeInterval(-60))).isEmpty)
            check("没在用的账号用量再高也不弹", run(st(10, live: true), b: st(99)).isEmpty)
            check("其他账号都不宽裕时，建议里不乱推荐", run(st(92, live: true), b: st(80), c: st(75)).first?.body.contains("不太宽裕") == true)
            check("7 天窗口到 91% 也会提醒", run(st(10, seven: 91, live: true)).first?.title.contains("7 天") == true)
            print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
            exit(failed == 0 ? 0 : 1)
        }
        if args.contains("--widgettest") {
            // 小组件测试：吸附计算、点击切换按钮、拖动窗口。只在沙盒里跑，用合成的鼠标事件。
            guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); exit(2) }
            var failed = 0
            func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                // 1. 吸附的计算（用假的系统小组件位置：一个中号加两个小号，和你桌面上的排布一样）
                let sys = [CGRect(x: 8, y: 38, width: 360, height: 180), CGRect(x: 8, y: 218, width: 180, height: 180), CGRect(x: 188, y: 218, width: 180, height: 180)]
                check("靠近格子时吸附（20,230 → 8,218）", snapToGrid(CGPoint(x: 20, y: 230), systemFrames: sys) == CGPoint(x: 8, y: 218))
                check("下一行的格子也吸附（200,405 → 188,398）", snapToGrid(CGPoint(x: 200, y: 405), systemFrames: sys) == CGPoint(x: 188, y: 398))
                check("离格线太远就不吸附（100,130 不动）", snapToGrid(CGPoint(x: 100, y: 130), systemFrames: sys) == CGPoint(x: 100, y: 130))
                check("没有系统小组件时不动", snapToGrid(CGPoint(x: 55, y: 77), systemFrames: []) == CGPoint(x: 55, y: 77))

                // 2. 搭一个沙盒：A 在用、B 可切换、C 登录失效
                let m = Model()
                let kc = KeychainStore()
                var accs: [Account] = []
                for (id, u, o) in [("a", "uA", "oA"), ("b", "uB", "oB"), ("c", "uC", "oC")] {
                    let dir = home + "/accounts/\(id)/config"
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    try? writeProfile(dir + "/.claude.json", account: ["accountUuid": u, "organizationUuid": o, "emailAddress": "\(id)@t.com", "organizationType": "claude_pro"])
                    accs.append(Account(id: id, label: "", configDir: dir))
                }
                try? FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
                try? writeProfile(home + "/.claude.json", account: ["accountUuid": "uA", "organizationUuid": "oA", "emailAddress": "a@t.com", "organizationType": "claude_pro"])
                try? kc.write(.account(accs[1].configDir), ["claudeAiOauth": ["accessToken": "x", "refreshToken": "B-ref", "refreshTokenExpiresAt": 9_999_999_999_999], "organizationUuid": "oB"])
                m.store.accounts = accs; m.reloadStates()
                check("沙盒就绪：A 在用、B 可切换、C 不可用", m.states["a"]?.live == true && m.states["b"]?.loggedIn == true && m.states["c"]?.loggedIn == false)

                let c = WidgetController.shared
                c.framesProvider = { [] }
                var hits = Set<String>()
                c.switchHook = { hits.insert($0.id) }
                m.store.widgetSize = "medium"
                c.show(m)
                guard let p = c.panel, let h = c.host else { print("失败：小组件没有出现"); failed += 1; return }
                check("中号窗口大小和系统一致（360×180）", abs(p.frame.width - 360) < 1 && abs(p.frame.height - 180) < 1)
                // 真实使用时点击发生在窗口显示很久之后，界面早已布局完成；测试里要先让它跑一轮布局
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                p.contentView?.layoutSubtreeIfNeeded()

                // 3. 点击：在整个窗口上每隔 6pt 点一下，看哪些点会触发切换
                func ev(_ t: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                                       windowNumber: p.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                var y: CGFloat = 3
                while y < p.frame.height {
                    var x: CGFloat = 3
                    while x < p.frame.width {
                        p.sendEvent(ev(.leftMouseDown, x, y)); p.sendEvent(ev(.leftMouseUp, x, y))
                        x += 6
                    }
                    y += 6
                }
                check("点 B 前面的切换按钮会触发切换 B", hits.contains("b"))
                check("点在用的 A 不会触发切换", !hits.contains("a"))
                check("点登录失效的 C 不会触发切换", !hits.contains("c"))

                // 4. 拖动：在顶部标题处按下、拖 (+30,+20)、松开
                let o0 = p.frame.origin
                h.mouseDown(with: ev(.leftMouseDown, 40, p.frame.height - 22))
                h.mouseDragged(with: ev(.leftMouseDragged, 70, p.frame.height - 2))
                h.mouseUp(with: ev(.leftMouseUp, 70, p.frame.height - 2))
                let o1 = p.frame.origin
                check("拖动后窗口跟着移动 (+30,+20)", abs(o1.x - o0.x - 30) < 0.5 && abs(o1.y - o0.y - 20) < 0.5)
                check("松开后位置已保存", m.store.widgetOrigin.map { abs($0[0] - Double(o1.x)) < 0.5 && abs($0[1] - Double(p.frame.maxY)) < 0.5 } ?? false)

                // 5. 吸附接线：假的系统小组件格线比当前位置偏 (+10,-7)，调用后窗口应该对齐过去
                let ph = NSScreen.screens.first?.frame.height ?? 0
                let top = CGPoint(x: p.frame.minX, y: ph - p.frame.maxY)
                c.framesProvider = { [CGRect(x: top.x + 10, y: top.y - 7, width: 360, height: 180)] }
                c.snap(p)
                let top2 = CGPoint(x: p.frame.minX, y: ph - p.frame.maxY)
                check("松手吸附：窗口左上角对齐到系统格线", abs(top2.x - (top.x + 10)) < 0.5 && abs(top2.y - (top.y - 7)) < 0.5)

                // 6. 三种尺寸的窗口大小
                for (s, w, hgt) in [("small", 180.0, 180.0), ("large", 360.0, 360.0), ("medium", 360.0, 180.0)] {
                    m.store.widgetSize = s
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    c.fit()
                    check("\(s) 尺寸 = \(Int(w))×\(Int(hgt))（实际 \(Int(p.frame.width))×\(Int(p.frame.height))）", abs(p.frame.width - w) < 1 && abs(p.frame.height - hgt) < 1)
                }
                // 7. 换尺寸的动效时序：先保持并集大小让动画有地方画，动画结束后收缩
                m.store.widgetSize = "large"
                RunLoop.current.run(until: Date().addingTimeInterval(0.4)); c.fit()
                c.changeSize(m, to: .small)
                check("换尺寸时窗口先保持 360×360（新旧尺寸的并集）", abs(p.frame.width - 360) < 1 && abs(p.frame.height - 360) < 1)
                check("尺寸设置已改成小号", m.store.widgetSize == "small")
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                check("动画结束后窗口收缩到 180×180", abs(p.frame.width - 180) < 1 && abs(p.frame.height - 180) < 1)
                c.hide(m)
                try? kc.delete(.account(accs[1].configDir))
            }
            print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
            exit(failed == 0 ? 0 : 1)
        }
        if args.contains("--check") {
            MainActor.assumeIsolated {
                let m = Model()
                let accs = m.store.accounts
                let sw = Switcher(dirOf: { k in accs.first { identity(ofDir: $0.configDir)?.key == k }?.configDir })
                for a in accs {
                    let live = m.states[a.id]?.live == true
                    let r = live ? "已在使用中（登录在默认位置）" : sw.preflight(target: identity(ofDir: a.configDir)?.key ?? "", targetDir: a.configDir)
                    print("\(m.displayName(a)): \(r)")
                }
            }
            exit(0)
        }
        if args.contains("--import") {
            MainActor.assumeIsolated {
                let r = Model().importCCSwitch()
                r.added.forEach { print("已导入: \($0)") }
                r.skipped.forEach { print("跳过: \($0)") }
            }
            exit(0)
        }
        if args.contains("--dump") {
            MainActor.assumeIsolated { Model().dump() }
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            BarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
