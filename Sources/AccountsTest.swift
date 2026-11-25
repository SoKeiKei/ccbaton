import SwiftUI
import AppKit

// 多账号界面的测试：纯规则、各种账号数下面板和小组件的大小、拖动排序、"+N"菜单。
// 只在沙盒里跑（必须设 CAB_TEST_ROOT）。点击和拖动用合成的鼠标事件，运行时屏幕上会短暂出现小窗口。

/// 测试用的承载视图：窗口不在前台时第一下点击也生效
private final class FirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
func runMultiTest() -> Int32 {
    guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    _ = NSApplication.shared
    Model.readOnly = true
    let m = Model()

    print("— 顺序")
    check("把第 3 个挪到最前", moved([1, 2, 3, 4], from: 2, to: 0) == [3, 1, 2, 4])
    check("挪到超出范围时停在末尾", moved([1, 2, 3], from: 0, to: 9) == [2, 3, 1])
    // 一张大卡片（高 100）加三个行（高 40），间距 6
    let f = [CGRect(x: 0, y: 0, width: 300, height: 100), CGRect(x: 0, y: 106, width: 300, height: 40),
             CGRect(x: 0, y: 152, width: 300, height: 40), CGRect(x: 0, y: 198, width: 300, height: 40)]
    check("稍微动一下不换位置", dropIndex(frames: f, source: 2, offset: -10) == 2 && dropIndex(frames: f, source: 2, offset: 10) == 2)
    check("往上拖过一行", dropIndex(frames: f, source: 2, offset: -30) == 1)
    check("一路拖到最上面", dropIndex(frames: f, source: 3, offset: -190) == 0)
    check("行往下拖过一行", dropIndex(frames: f, source: 1, offset: 30) == 2)
    check("大卡片往下拖过第一个行", dropIndex(frames: f, source: 0, offset: 30) == 1)
    check("拖出下边界停在最后", dropIndex(frames: f, source: 0, offset: 900) == 3)

    print("— 头像颜色")
    let ids = ["a", "b", "c"]
    let s1 = assignColorSlots(ids, [:])
    check("三个账号三种颜色", Set(s1.values).count == 3)
    check("调整顺序颜色不变", assignColorSlots(["c", "a", "b"], s1) == s1)
    let s2 = assignColorSlots(["a", "c", "d"], s1)
    check("删掉一个再加一个：老账号不变，新账号拿空出来的颜色", s2["a"] == s1["a"] && s2["c"] == s1["c"] && s2["d"] == s1["b"])
    check("十个账号互不撞色", Set(assignColorSlots((0..<10).map { "x\($0)" }, [:]).values).count == 10)

    print("— 换号推荐")
    applyManyDemo(m, count: 8)
    func set(_ i: Int, _ five: Double?, _ seven: Double?) { m.states["d\(i)"]?.fiveHour = five; m.states["d\(i)"]?.sevenDay = seven }
    check("使用中的用量不高时不提示", m.switchAdvice == nil)
    set(1, 96, 61)
    check("5 小时用到 96%：推荐最空的那个", m.switchAdvice?.target?.id == "d3" && m.switchAdvice?.text.contains("5 小时") == true)
    set(3, 0, 100)
    check("7 天用完的账号不推荐（即使 5 小时是 0%）", m.switchAdvice?.target?.id != "d3" && m.switchAdvice?.target != nil)
    set(1, 10, 95)
    check("只有 7 天快用完也提示，并说明是 7 天", m.switchAdvice?.text.contains("7 天额度已用 95%") == true)
    check("登录失效的账号不推荐", recommendedAccount(accounts: [m.store.accounts[5]], states: m.states) == nil)
    check("使用中的账号不推荐自己", recommendedAccount(accounts: [m.store.accounts[0]], states: m.states) == nil)
    for i in 2...8 { set(i, 80, 75) }
    check("别的账号都不宽裕：只提示，不给推荐", m.switchAdvice != nil && m.switchAdvice?.target == nil)
    m.states["d2"]?.fiveReset = Date().addingTimeInterval(-60); set(2, 99, 20)
    check("已过重置时间的旧读数按 0 算", recommendedAccount(accounts: m.store.accounts, states: m.states)?.account.id == "d2")

    print("— 小组件放不下时显示谁")
    let list = (1...9).map { Account(id: "\($0)", label: "", configDir: "/x/\($0)") }
    func pick(_ n: Int, live: String?, cap: Int) -> ([String], [String]) {
        let r = widgetSelection(Array(list.prefix(n)), liveId: live, capacity: cap)
        return (r.shown.map { $0.id }, r.hidden.map { $0.id })
    }
    check("放得下就全显示", pick(6, live: "1", cap: 6) == (["1", "2", "3", "4", "5", "6"], []))
    check("放不下：按顺序取前 5 个，其余收起", pick(8, live: "1", cap: 6) == (["1", "2", "3", "4", "5"], ["6", "7", "8"]))
    check("使用中的排在后面：占最后一个位置", pick(8, live: "7", cap: 6) == (["1", "2", "3", "4", "7"], ["5", "6", "8"]))

    check("时间说明：100 分钟、50 分钟、1 小时", durationText(6000) == "1 小时 40 分" && durationText(3000) == "50 分钟" && durationText(3600) == "1 小时")

    print("— 小组件大小（账号再多也要对齐系统格子）")
    for size in WidgetSize.allCases {
        var wrong: [String] = []
        for n in 1...12 {
            for liveIndex in [1, n] {                   // 使用中的排第一和排最后
                applyManyDemo(m, count: n)
                for i in 1...n { m.states["d\(i)"]?.live = i == liveIndex }
                m.states["d\(liveIndex)"]?.loggedIn = true
                m.store.widgetSize = size.rawValue
                let d = WidgetController.shared.desiredSize(m)
                if abs(d.width - size.width) > 0.5 || abs(d.height - size.height) > 0.5 { wrong.append("\(n) 个→\(Int(d.width))×\(Int(d.height))") }
            }
        }
        check("\(size.title)：1～12 个账号都是 \(Int(size.width))×\(Int(size.height))\(wrong.isEmpty ? "" : "，不对的：" + wrong.joined(separator: "、"))", wrong.isEmpty)
    }

    print("— 面板高度")
    func panelHeight(_ n: Int) -> CGFloat {
        applyManyDemo(m, count: n)
        return NSHostingView(rootView: MenuView(model: m)).fittingSize.height
    }
    AccountList.maxHeightOverride = 5000
    let h = (1...12).map { panelHeight($0) }
    print("        各账号数的高度:", h.enumerated().map { "\($0.offset + 1)→\(Int($0.element))" }.joined(separator: "  "))
    check("6 个起换紧凑布局，比 5 个时矮", h[5] < h[4])
    check("12 个账号的紧凑面板不到 850 高（13 寸笔记本放得下）", h[11] < 850)
    AccountList.maxHeightOverride = 400
    let capped = panelHeight(12)
    check("屏幕不够高时中间滚动，面板不超过限制（\(Int(capped))）", capped < 400 + 230)
    check("放得下时不受限制影响", panelHeight(2) == h[1])
    AccountList.maxHeightOverride = nil

    print("— 拖动排序")
    func dragTest(_ n: Int, from: Int, to: Int) -> Bool {
        applyManyDemo(m, count: n)
        AccountList.maxHeightOverride = 5000
        AccountList.probe = [:]
        let host = FirstMouseHost(rootView: AccountList(model: m).frame(width: 332).padding(14))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: 60, y: 60))
        w.orderFrontRegardless()
        defer { w.orderOut(nil); AccountList.maxHeightOverride = nil }
        spin(0.5)
        let before = m.store.accounts.map { $0.id }
        let ok = performDrag(in: w, from: before[from], to: before[to])
        return ok && m.store.accounts.map { $0.id } == moved(before, from: from, to: to)
    }
    check("紧凑布局：把第 5 个拖到第 2 个的位置", dragTest(8, from: 4, to: 1))
    check("紧凑布局：把第 2 个拖到第 6 个的位置", dragTest(8, from: 1, to: 5))
    check("大卡片布局：把第 3 个拖到最前", dragTest(3, from: 2, to: 0))
    check("紧凑布局：把使用中的大卡片往下拖两格", dragTest(7, from: 0, to: 2))

    print("— 小组件上的按钮")
    let c = WidgetController.shared
    c.framesProvider = { [] }
    var switched = Set<String>()
    var menus: [NSMenu] = []
    c.switchHook = { switched.insert($0.id) }
    let realPresent = AccountPopup.present
    AccountPopup.present = { menus.append($0) }
    func clickEverywhere(_ n: Int, _ size: WidgetSize) {
        applyManyDemo(m, count: n)
        m.store.widgetSize = size.rawValue
        switched = []; menus = []
        c.show(m)
        guard let p = c.panel else { return }
        spin(0.5)
        p.contentView?.layoutSubtreeIfNeeded()
        var y: CGFloat = 3
        while y < p.frame.height {
            var x: CGFloat = 3
            while x < p.frame.width {
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    p.sendEvent(NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                                                   windowNumber: p.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                x += 6
            }
            y += 6
        }
        c.hide(m)
        spin(0.4)
    }
    for (n, size, direct, hidden) in [(8, WidgetSize.small, ["d2", "d3"], 5), (9, .medium, ["d2", "d3", "d4", "d5"], 4), (11, .large, ["d2", "d3", "d4", "d5", "d7"], 4)] {
        clickEverywhere(n, size)
        check("\(size.title) \(n) 个账号：能直接切换 \(direct.joined(separator: ","))（实际 \(switched.sorted().joined(separator: ","))）", Set(direct).isSubset(of: switched))
        check("\(size.title) \(n) 个账号：弹出菜单里是剩下的 \(hidden) 个（实际 \(menus.first?.items.count ?? 0)）", menus.first?.items.count == hidden)
    }
    applyManyDemo(m, count: 8)
    var chosen: [String] = []
    let menu = AccountPopup.menu(m, accounts: Array(m.store.accounts.suffix(4))) { chosen.append($0.id) }
    check("菜单里登录失效的账号点不了", menu.items.count == 4 && m.states["d6"]?.loggedIn == false
          && AccountPopup.menu(m, accounts: [m.store.accounts[5]]) { _ in }.items[0].isEnabled == false)
    (menu.items[0] as? ActionMenuItem)?.fire()
    check("点菜单项就切换到那个账号", chosen == ["d5"])
    AccountPopup.present = realPresent

    print("— 续期提醒和备注")
    renewalTests(m, check)

    print("— 移除账号")
    removalTests(m, check)

    print("— 存盘")
    Model.readOnly = false          // 定时器没有启动（上面是只读模式建的），这里只为了让保存生效
    m.store.accounts = (1...4).map { Account(id: "s\($0)", label: "号\($0)", configDir: home + "/s/\($0)") }
    m.store.colorSlots = nil
    let colorsBefore = assignColorSlots(m.store.accounts.map { $0.id }, [:])
    m.moveAccount("s4", to: 0)
    let disk = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
    check("新顺序存盘了", disk?.accounts.map { $0.id } == ["s4", "s1", "s2", "s3"])
    check("颜色跟着账号走，不跟着位置走", disk?.colorSlots == colorsBefore)
    Model.readOnly = true

    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}

/// 在窗口里按住账号 from，拖到账号 to 所在的位置（测试用）
@MainActor
func performDrag(in w: NSWindow, from: String, to: String) -> Bool {
    guard let a = AccountList.probe[from], let b = AccountList.probe[to] else { return false }
    let height = w.frame.height          // 量到的位置从窗口左上角算起（带标题栏的窗口包括标题栏）
    func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    // 从名字那一带按下（避开右边的按钮）；往上拖让上沿刚越过目标中线，往下拖让下沿刚越过
    let delta = b.midY < a.midY ? (b.midY - 4) - a.minY : (b.midY + 4) - a.maxY
    let x = a.minX + 70
    func send(_ t: NSEvent.EventType, _ y: CGFloat) {
        w.sendEvent(NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
    send(.leftMouseDown, a.midY)
    spin(0.05)
    for step in 1...12 { send(.leftMouseDragged, a.midY + delta * CGFloat(step) / 12); spin(0.03) }
    send(.leftMouseUp, a.midY + delta)
    spin(0.6)
    return true
}

/// 移除账号：删什么、留什么。全部在沙盒里，钥匙串条目名带 CABTEST
@MainActor
private func removalTests(_ m: Model, _ check: (String, Bool) -> Void) {
    let keychain = KeychainStore(), fm = FileManager.default
    var slots: [String] = []
    func profile(_ dir: String, _ u: String) {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? writeProfile(dir + "/.claude.json", account: ["accountUuid": u, "organizationUuid": "o-" + u, "emailAddress": u + "@t.com", "organizationType": "claude_pro"])
    }
    func secret(_ u: String) -> Secret { ["claudeAiOauth": ["accessToken": "x", "refreshToken": u, "refreshTokenExpiresAt": 9_999_999_999_999], "organizationUuid": "o-" + u] }
    func login(_ dir: String, _ u: String) { slots.append(dir); try? keychain.write(.account(dir), secret(u)) }
    func has(_ dir: String) -> Bool { keychain.exists(.account(dir)) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }
    func ids() -> [String] { m.store.accounts.map { $0.id } }
    func registry() -> Set<String> {
        let d = (fm.contents(atPath: ccSwitchRoot + "/claude_accounts.json")).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return Set(((d?["accounts"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? [String: Any])?["localId"] as? String })
    }
    defer { for d in slots { try? keychain.delete(.account(d)) }; keychain.deleteBackup(); Model.readOnly = true }

    let chat = home + "/.claude/projects/chat.jsonl"
    try? fm.createDirectory(atPath: home + "/.claude/projects", withIntermediateDirectories: true)
    try? Data("keep".utf8).write(to: URL(fileURLWithPath: chat))
    let hex = String(repeating: "c", count: 32), other = String(repeating: "e", count: 32)
    func ccDir(_ h: String) -> String { ccSwitchRoot + "/claude-accounts/\(h)/config" }
    let live = Account(id: "ra", label: "在用", configDir: supportDir + "/accounts/ra/config")
    let own = Account(id: "rb", label: "自己加的", configDir: supportDir + "/accounts/rb/config")
    let imported = Account(id: hex, label: "导入的", configDir: ccDir(hex))
    try? prepareAccountDir(own.configDir); try? prepareAccountDir(imported.configDir)
    profile(live.configDir, "uA"); profile(own.configDir, "uB"); profile(imported.configDir, "uC"); profile(ccDir(other), "uE"); profile(home, "uA")
    try? JSONSerialization.data(withJSONObject: ["version": 1, "accounts": ["x": ["localId": hex, "email": "uC@t.com", "addedAt": 1_795_000_000],
                                                                          "y": ["localId": other, "email": "uE@t.com"]]])
        .write(to: URL(fileURLWithPath: ccSwitchRoot + "/claude_accounts.json"))
    for a in [own, imported] {
        login(a.configDir, a.id == own.id ? "uB" : "uC"); login(a.configDir + ".prev", "old-" + a.id)
        try? prepareAccountDir(terminalDir(a)); profile(terminalDir(a), a.id); login(terminalDir(a), a.id)
    }
    login(ccDir(other), "uE")
    m.store.accounts = [live, own, imported]; m.store.colorSlots = nil
    m.store.terminalPrefs = [own.id: TerminalPrefs(dir: home, skipPermissions: false, args: "")]
    m.store.warmupRecords = [own.id: WarmupRecord(at: Date(), status: .confirmed, fails: 0)]
    m.reloadStates()
    check("沙盒就绪：一个在用，两个没在用", m.states["ra"]?.live == true && m.states["rb"]?.live == false && m.states[hex]?.live == false)
    check("使用中的账号不能移除", m.removalBlocker(live) != nil && m.removeAccount(live) != nil && ids().count == 3)

    let p1 = m.removalPrompt(own, terminals: [RunningTerminal(mode: .shared, accountId: own.id)])
    check("添加的账号的警告：重新登录、几个终端掉线，不提 cc-switch",
          p1.message.contains("需要重新登录") && p1.message.contains("1 个用它开着的终端会掉线") && !p1.message.contains("cc-switch 里") && p1.button == "彻底移除")
    m.ccSwitchInstalled = { true }; m.ccSwitchRunning = { true }
    let p2 = m.removalPrompt(imported, terminals: [])
    check("导入账号的警告：cc-switch 里也失效、任何方式都要重新登录", p2.message.contains("cc-switch 里也会失效") && p2.message.contains("都要重新登录") && p2.button == "彻底移除")
    check("cc-switch 开着时提醒先退出，没开就不提", p2.message.contains("正在运行") && { m.ccSwitchRunning = { false }; return !m.removalPrompt(imported, terminals: []).message.contains("正在运行") }())

    var asked = 0, told: [String] = []
    m.confirmRemoval = { _ in asked += 1; return false }
    m.tellUser = { _, why in told.append(why) }
    check("警告框点取消：什么都不动", !m.requestRemoval(imported) && asked == 1 && ids().count == 3 && has(imported.configDir) && exists(imported.configDir) && registry() == [hex, other])
    m.confirmRemoval = { _ in asked += 1; return true }
    m.refreshing = true
    check("正在读额度时不让删（免得删掉的登录又被写回来）", !m.requestRemoval(own) && asked == 1 && told.last?.contains("读取额度") == true && has(own.configDir))
    m.refreshing = false

    // 清单改不了时整个取消
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ccSwitchRoot)
    let blocked = m.requestRemoval(imported)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ccSwitchRoot)
    check("cc-switch 清单改不了：整个取消，什么都没删", !blocked && ids().count == 3 && has(imported.configDir) && has(terminalDir(imported)) && registry() == [hex, other])

    // 切换前的整份备份里是这个账号：一起删
    try? keychain.writeBackup(secret("uB"))
    let colors = assignColorSlots(ids(), [:])
    Model.readOnly = false
    check("确认后移除添加的账号", m.requestRemoval(own) && ids() == ["ra", hex])
    check("它的登录、备份副本、完全独立登录都从钥匙串删掉了", !has(own.configDir) && !has(own.configDir + ".prev") && !has(terminalDir(own)) && keychain.readBackup() == nil)
    check("账号文件夹和终端文件夹进了废纸篓", !exists(supportDir + "/accounts/rb") && !exists(supportDir + "/terminals/rb")
          && (try? fm.contentsOfDirectory(atPath: home + "/.Trash").count) == 2)
    check("链接指向的对话记录原样还在", (try? String(contentsOfFile: chat, encoding: .utf8)) == "keep")
    let disk = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
    check("存盘：列表、终端偏好、预热记录都清掉了", disk?.accounts.map { $0.id } == ["ra", hex] && disk?.terminalPrefs?[own.id] == nil && disk?.warmupRecords?[own.id] == nil)
    check("剩下账号的颜色没变", disk?.colorSlots?["ra"] == colors["ra"] && disk?.colorSlots?[hex] == colors[hex])

    try? keychain.writeBackup(secret("uZ"))      // 备份里是别的账号
    check("移除导入的账号", m.requestRemoval(imported) && ids() == ["ra"])
    check("导入账号的登录和备份副本也删了", !has(imported.configDir) && !has(imported.configDir + ".prev") && !has(terminalDir(imported)))
    check("它在 cc-switch 里的文件夹进了废纸篓", !exists(ccSwitchRoot + "/claude-accounts/\(hex)"))
    check("cc-switch 清单只去掉它这一条，别的账号没动", registry() == [other] && has(ccDir(other)) && exists(ccDir(other)))
    let saved = (try? fm.contentsOfDirectory(atPath: supportDir + "/backups")) ?? []
    check("改之前的清单留了备份", saved.contains { (try? String(contentsOfFile: supportDir + "/backups/" + $0, encoding: .utf8))?.contains(hex) == true })
    check("别人的整份备份没被误删", keychain.readBackup() != nil)
    m.importCCSwitch()
    check("移除后再点导入也不会冒出来", !ids().contains(hex))

    // 同一个号在列表里有两条：多出来的那条可以去掉，正在用的登录不受影响
    let twin = Account(id: "rd", label: "重复的", configDir: supportDir + "/accounts/rd/config")
    profile(twin.configDir, "uA"); login(twin.configDir, "uA2"); login(live.configDir, "uA")
    m.store.accounts = [live, twin]; m.reloadStates()
    check("重复添加的在用账号可以去掉一条", m.removalBlocker(twin) == nil && m.removeAccount(twin) == nil && ids() == ["ra"] && has(live.configDir) && !has(twin.configDir))

    let outside = Account(id: "re", label: "", configDir: home + "/somewhere/config")
    let sneaky = Account(id: "rf", label: "", configDir: supportDir + "/accounts/../../config")
    profile(outside.configDir, "uO"); login(outside.configDir, "uO")
    m.store.accounts = [live, outside]; m.reloadStates()
    check("目录在别处：认不出文件夹，不会去删", m.accountFolder(outside) == nil && m.accountFolder(sneaky) == nil)
    check("目录在别处：删登录，文件保留", m.removeAccount(outside) == nil && !has(outside.configDir) && exists(outside.configDir + "/.claude.json"))
    let a1 = Account(id: "rg", label: "", configDir: live.configDir + "x"), a2 = Account(id: "rh", label: "", configDir: live.configDir + "x")
    login(a1.configDir, "uS"); m.store.accounts = [live, a1, a2]; m.states[a1.id] = AccountState()
    check("两个条目共用一个目录：只移出列表，登录保留", m.removeAccount(a1) == nil && ids() == ["ra", "rh"] && has(a2.configDir))
}

/// 续期提醒的日期计算、存盘、界面和编辑窗口
@MainActor
private func renewalTests(_ m: Model, _ check: (String, Bool) -> Void) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
    func note(_ day: Int?, _ now: Date) -> String? { renewalNotice(day: day, from: now, calendar: cal)?.text }
    func next(_ day: Int, _ now: Date) -> DateComponents? { nextRenewal(day: day, from: now, calendar: cal).map { cal.dateComponents([.year, .month, .day], from: $0) } }
    func ymd(_ y: Int, _ mo: Int, _ d: Int) -> DateComponents { DateComponents(year: y, month: mo, day: d) }

    check("还有三天：不提醒", note(28, at(2026, 11, 25)) == nil)
    check("前两天起提醒：后天、明天、今天", note(28, at(2026, 11, 26, 0, 1)) == "后天续期" && note(28, at(2026, 11, 27)) == "明天续期" && note(28, at(2026, 11, 28, 23, 59)) == "今天续期")
    check("过了当天就不提醒，轮到下个月", note(28, at(2026, 11, 29, 0, 1)) == nil && next(28, at(2026, 11, 29)) == ymd(2026, 12, 28))
    check("跨月：月底提醒下月 1 号", note(1, at(2026, 11, 29)) == "后天续期" && next(1, at(2026, 11, 29)) == ymd(2026, 12, 1))
    check("跨年", note(1, at(2026, 12, 30)) == "后天续期" && next(1, at(2026, 12, 30)) == ymd(2027, 1, 1))
    check("2 月填 31 号按月底算（平年、闰年）", next(31, at(2027, 2, 26)) == ymd(2027, 2, 28) && note(31, at(2027, 2, 26)) == "后天续期" && next(30, at(2028, 2, 27)) == ymd(2028, 2, 29))
    check("小月填 31 号按 30 号算", next(31, at(2027, 4, 28)) == ymd(2027, 4, 30))
    check("月底那天过完，下个月仍按填的日子", next(31, at(2027, 3, 1)) == ymd(2027, 3, 31))
    check("没填或填得不对：不提醒", note(nil, at(2026, 11, 26)) == nil && note(0, at(2026, 11, 26)) == nil && note(32, at(2026, 11, 26)) == nil)

    applyManyDemo(m, count: 3)
    m.setDetails(m.store.accounts[0], renewalDay: 15, note: "  第一行\n第二行  \n")
    m.setDetails(m.store.accounts[1], renewalDay: 40, note: "   ")
    m.setDetails(m.store.accounts[2], renewalDay: nil, note: String(repeating: "长", count: 3000))
    let a = m.store.accounts
    check("保存时：备注去掉首尾空白、保留换行；空白当没写；超长截到 2000 字；日期超范围当没填",
          a[0].renewalDay == 15 && a[0].note == "第一行\n第二行" && a[1].renewalDay == nil && a[1].note == nil && a[2].note?.count == 2000)
    let saved = try? JSONDecoder().decode(Store.self, from: JSONEncoder().encode(m.store))
    check("重启后续期日和备注还在", saved?.accounts == m.store.accounts)
    let old = Data(#"{"accounts":[{"id":"x","label":"旧","configDir":"/x"}],"workDir":"/"}"#.utf8)
    let loaded = try? JSONDecoder().decode(Store.self, from: old)
    check("旧版的设置文件照样读得进来", loaded?.accounts.first?.label == "旧" && loaded?.accounts.first?.renewalDay == nil && loaded?.accounts.first?.note == nil)

    // 所有账号都在续期：小组件仍然是系统格子大小
    let today = Calendar.current.component(.day, from: Date())
    for size in WidgetSize.allCases {
        var wrong: [String] = []
        for n in 1...12 {
            applyManyDemo(m, count: n)
            for i in 0..<n { m.store.accounts[i].renewalDay = today; m.store.accounts[i].label = "名字特别长的账号\(i)" }
            m.store.widgetSize = size.rawValue
            let d = WidgetController.shared.desiredSize(m)
            if abs(d.width - size.width) > 0.5 || abs(d.height - size.height) > 0.5 { wrong.append("\(n) 个→\(Int(d.width))×\(Int(d.height))") }
        }
        check("带提醒的\(size.title)：1～12 个账号大小不变\(wrong.isEmpty ? "" : "，不对的：" + wrong.joined(separator: "、"))", wrong.isEmpty)
    }
    func panel(_ n: Int, due: Int?) -> CGFloat {
        applyManyDemo(m, count: n)
        if let due { m.store.accounts[due].renewalDay = today }
        return NSHostingView(rootView: MenuView(model: m)).fittingSize.height
    }
    AccountList.maxHeightOverride = 5000
    check("大卡片多一行提醒，紧凑行不加高", panel(3, due: 1) > panel(3, due: nil) + 10 && panel(8, due: 3) == panel(8, due: nil))
    AccountList.maxHeightOverride = nil

    // 编辑窗口：备注框里回车是换行，名称框里回车是保存
    applyManyDemo(m, count: 3)
    let target = m.store.accounts[1]
    func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    func find<T: NSView>(_ v: NSView?, _ type: T.Type, _ ok: (T) -> Bool = { _ in true }) -> T? {
        guard let v else { return nil }
        if let t = v as? T, ok(t) { return t }
        for sub in v.subviews { if let t = find(sub, type, ok) { return t } }
        return nil
    }
    AccountEditor.shared.open(m, account: target)
    spin(0.8)
    guard let w = AccountEditor.shared.window, let box = find(w.contentView, NSTextView.self, { !$0.isFieldEditor }),
          let field = find(w.contentView, NSTextField.self, { $0.isEditable }) else { check("编辑窗口里有名称框和备注框", false); return }
    check("编辑窗口：名称框、备注框都在，内容放得下", w.title == "编辑账号" && (w.contentView?.frame.height ?? 0) < 620 && box.frame.width > 300)
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                 context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    w.makeFirstResponder(box); spin(0.5)
    box.insertText("第一行", replacementRange: NSRange(location: NSNotFound, length: 0))
    let swallowed = w.performKeyEquivalent(with: enter)
    if !swallowed { box.keyDown(with: enter) }
    box.insertText("第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
    spin(0.5)
    check("备注框里按回车是换行，窗口不关", !swallowed && box.string == "第一行\n第二行" && AccountEditor.shared.window?.isVisible == true)
    w.makeFirstResponder(field); spin(0.5)
    _ = w.performKeyEquivalent(with: enter)
    spin(0.5)
    check("名称框里按回车保存并关窗，备注一起存下", AccountEditor.shared.window == nil && m.store.accounts[1].note == "第一行\n第二行")
    AccountEditor.shared.window?.close()
}
