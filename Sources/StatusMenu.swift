import AppKit
import SwiftUI

// 右键（或按住 Control 点）菜单栏图标：弹出一个简易菜单，放面板底部那几样常用的操作，不用先点开面板。
// 菜单栏图标是 SwiftUI 的 MenuBarExtra（左键弹面板），它自己不响应右键，所以这里监听鼠标事件：
// 只拦截"点在本程序自己的菜单栏图标上"的右键，其余事件原样放行。

@MainActor
final class StatusMenu {
    static let shared = StatusMenu()
    private var monitor: Any?
    private weak var model: Model?

    // 下面这些动作在测试里换掉
    var present: (NSMenu, NSEvent, NSStatusBarButton) -> Void = { menu, event, button in
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }
    var openSettings: (Model) -> Void = { SettingsController.shared.open($0) }
    var quit: () -> Void = { NSApp.terminate(nil) }
    /// 问新账号叫什么名字；返回 nil 表示取消（可以是空字符串：不起名）
    var askAccountName: () -> String? = {
        let alert = NSAlert()
        alert.messageText = "添加 Claude 账号"
        alert.informativeText = "会打开终端，用 Claude 官方的登录流程，在浏览器里授权。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "名字（可不填，如：工作）"
        alert.accessoryView = field
        alert.addButton(withTitle: "在终端里登录")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }

    func install(_ model: Model) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let model = self.model, let button = self.statusButton(in: event) else { return event }
            // 左键只有按着 Control 才算右键；普通左键照旧弹面板
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return event }
            self.present(self.makeMenu(model), event, button)
            return nil
        }
    }

    /// 这个鼠标事件是不是点在本程序的菜单栏图标上
    func statusButton(in event: NSEvent) -> NSStatusBarButton? {
        func find(_ v: NSView) -> NSStatusBarButton? {
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        return event.window?.contentView.flatMap(find)
    }

    func makeMenu(_ model: Model) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: "CCBaton \(model.currentVersion)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if let r = model.availableUpdate {
            menu.addItem(ActionMenuItem("● 有新版本 \(r.version)，去更新…") { [weak self] in self?.openSettings(model) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("刷新额度") { Task { @MainActor in model.reloadStates(); await model.refreshAll(force: true) } })
        let desktop = model.desktopMenuEntries()
        if !desktop.isEmpty {                       // 桌面端总开关打开后才有
            let sub = NSMenu()
            sub.autoenablesItems = false
            for e in desktop {
                let item = ActionMenuItem(e.title) { model.desktopButton(e.account) }
                item.isEnabled = e.enabled
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "桌面端", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(ActionMenuItem("添加账号…") { [weak self] in
            guard let name = self?.askAccountName() else { return }
            model.addAccount(label: name)
        })
        let shown = model.store.widgetVisible == true
        menu.addItem(ActionMenuItem(shown ? "隐藏桌面小组件" : "显示桌面小组件") {
            if shown { WidgetController.shared.hide(model) } else { WidgetController.shared.show(model) }
        })
        menu.addItem(ActionMenuItem("设置…") { [weak self] in self?.openSettings(model) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("退出 CCBaton") { [weak self] in self?.quit() })
        return menu
    }
}
