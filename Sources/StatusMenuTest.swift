import SwiftUI
import AppKit

// 右键菜单栏图标的菜单测试：菜单内容、各项的动作、以及"只拦截点在自己图标上的右键"。
// 只在沙盒里跑（必须设 CAB_TEST_ROOT）；"点图标"用合成的鼠标事件，菜单本身不真的弹出（换成记录一下）。

@MainActor
func runStatusMenuTest() -> Int32 {
    guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Model.readOnly = true
    let m = Model()
    m.currentVersion = "1.5.0"
    let sm = StatusMenu.shared
    func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "—" : $0.title } }
    func item(_ menu: NSMenu, _ title: String) -> ActionMenuItem? { menu.items.first { $0.title == title } as? ActionMenuItem }

    print("— 菜单内容")
    m.store.widgetVisible = false; m.store.updateRelease = nil
    var menu = sm.makeMenu(m)
    check("顺序：版本、分隔、刷新、添加账号、小组件、设置、分隔、退出",
          titles(menu) == ["CCBaton 1.5.0", "—", "刷新额度", "添加账号…", "显示桌面小组件", "设置…", "—", "退出 CCBaton"])
    check("版本那行只是标题，点不了；其余都能点", menu.items[0].isEnabled == false && menu.items.filter { !$0.isSeparatorItem }.dropFirst().allSatisfy { $0.isEnabled })
    m.store.widgetVisible = true
    check("小组件开着时，这一项变成『隐藏』", titles(sm.makeMenu(m)).contains("隐藏桌面小组件"))
    m.store.updateRelease = AppRelease(version: "9.9.9", page: URL(string: "https://example.com")!, zip: nil, signature: nil)
    menu = sm.makeMenu(m)
    check("有新版本：版本下面多一行提示", titles(menu)[1] == "● 有新版本 9.9.9，去更新…")
    m.store.updateRelease = AppRelease(version: "1.0.0", page: URL(string: "https://example.com")!, zip: nil, signature: nil)
    check("记录里的版本不比现在新：不提示", !titles(sm.makeMenu(m)).contains { $0.contains("新版本") })
    m.store.updateRelease = nil

    print("— 桌面端子菜单")
    m.desktopAvailable = false
    check("总开关没打开：右键菜单里没有『桌面端』", !titles(sm.makeMenu(m)).contains("桌面端") && m.desktopMenuEntries().isEmpty)
    let X = Account(id: "x", label: "LK", configDir: "/x/x"), Y = Account(id: "y", label: "ZJ", configDir: "/x/y"), Z = Account(id: "z", label: "AB", configDir: "/x/z"), W = Account(id: "w", label: "WW", configDir: "/x/w")
    m.store.accounts = [X, Y, Z, W]
    for a in [X, Y, Z] { var st = AccountState(); st.loggedIn = true; m.states[a.id] = st }
    m.states["w"] = AccountState()                                  // 登录失效的账号不列出
    m.desktopAvailable = true; m.desktopOwnerState = .account(X); m.desktopSaved = ["x", "y"]
    let entries = m.desktopMenuEntries()
    check("列出登录有效的账号：在用的（不能点）、已保存的（换到）、没登录过的（登录一次）",
          entries.map { $0.title } == ["✓ LK（桌面端正在用）", "换到 ZJ", "AB：在桌面端登录一次…"] && entries.map { $0.enabled } == [false, true, true])
    let withDesktop = sm.makeMenu(m)
    let sub = withDesktop.items.first { $0.title == "桌面端" }?.submenu
    check("右键菜单里多了『桌面端』子菜单，三项和上面一致，在用的那项是灰的",
          sub?.items.map { $0.title } == entries.map { $0.title } && sub?.items.map { $0.isEnabled } == [false, true, true])
    check("『桌面端』在『添加账号』之前、『设置』之前，位置合理", { let t = titles(withDesktop); return t.firstIndex(of: "桌面端")! > t.firstIndex(of: "刷新额度")! && t.firstIndex(of: "桌面端")! < t.firstIndex(of: "设置…")! }())
    m.desktopFlow = DesktopFlow(text: "x")
    check("桌面端操作进行中：子菜单里能点的都变灰", m.desktopMenuEntries().allSatisfy { !$0.enabled })
    m.desktopFlow = nil
    m.desktopAvailable = false; m.desktopOwnerState = .none; m.desktopSaved = []; m.store.accounts = []

    print("— 各项的动作")
    var opened = 0, quits = 0
    sm.openSettings = { _ in opened += 1 }
    sm.quit = { quits += 1 }
    menu = sm.makeMenu(m)
    item(menu, "设置…")?.fire()
    check("『设置…』打开设置", opened == 1)
    m.store.updateRelease = AppRelease(version: "9.9.9", page: URL(string: "https://example.com")!, zip: nil, signature: nil)
    item(sm.makeMenu(m), "● 有新版本 9.9.9，去更新…")?.fire()
    check("『有新版本』也是去设置里更新（和面板右下角的红点一致）", opened == 2)
    m.store.updateRelease = nil
    item(menu, "退出 CCBaton")?.fire()
    check("『退出』退出程序", quits == 1)
    let before = m.store.accounts.count
    sm.askAccountName = { nil }
    item(menu, "添加账号…")?.fire()
    check("『添加账号…』点了取消：什么都不加", m.store.accounts.count == before)

    print("— 只拦截点在自己图标上的右键")
    let bar = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(bar) }
    guard let button = bar.button, let barWindow = button.window else {
        print("  跳过   这个环境里建不出菜单栏图标，没法测点击拦截")
        print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败"); return failed == 0 ? 0 : 1
    }
    button.title = "T"
    var shown: [(NSMenu, NSStatusBarButton)] = []
    sm.present = { menu, _, b in shown.append((menu, b)) }
    sm.install(m)
    func click(_ type: NSEvent.EventType, in window: NSWindow, flags: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 4, y: 4), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return }
        NSApp.sendEvent(e)
    }
    click(.rightMouseDown, in: barWindow)
    check("右键点图标：弹出菜单，菜单里有设置和退出", shown.count == 1 && shown.first.map { titles($0.0).contains("设置…") && titles($0.0).contains("退出 CCBaton") } == true && shown.first?.1 === button)
    click(.leftMouseDown, in: barWindow)
    check("普通左键点图标：不拦截（照旧弹面板）", shown.count == 1)
    click(.leftMouseDown, in: barWindow, flags: [.control])
    check("按住 Control 点图标：也弹出菜单", shown.count == 2)
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    click(.rightMouseDown, in: other)
    check("右键点别的窗口：不拦截", shown.count == 2)
    sm.install(m)
    click(.rightMouseDown, in: barWindow)
    check("重复安装不会装两份监听（一次右键只弹一次）", shown.count == 3)

    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
