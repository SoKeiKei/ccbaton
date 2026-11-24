import SwiftUI
import AppKit

// 自动驾驶测试：让真实运行的程序自己去点菜单栏图标、切换小组件尺寸、显示/隐藏小组件、刷新数据，
// 用来复现"点着点着就崩"这类只有真实窗口和动画一起跑才会出现的问题。
// 只在沙盒里跑：必须同时设置 CAB_TEST_ROOT 和 CAB_DRIVE=1。

@MainActor
enum Driver {
    static var enabled: Bool { testRoot != nil && ProcessInfo.processInfo.environment["CAB_DRIVE"] == "1" }

    /// 找到菜单栏上的状态栏按钮（点它就能弹出/收起面板）
    static func statusButton() -> NSStatusBarButton? {
        func find(_ v: NSView) -> NSStatusBarButton? {
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        for w in NSApp.windows { if let root = w.contentView, let b = find(root) { return b } }
        return nil
    }

    static func start(_ model: Model, seconds: Double) {
        applyDemo(model)
        // 对照实验：CAB_DRIVE_SAFEPOS=1 时把小组件放在主屏幕中间（左上角 x=300），不会伸出屏幕边缘
        if ProcessInfo.processInfo.environment["CAB_DRIVE_SAFEPOS"] == "1" {
            model.store.widgetOrigin = [300, Double((NSScreen.screens.first?.frame.height ?? 1500) - 400)]
        }
        // 崩溃时把当前所有窗口的情况打印出来，看是哪个窗口的布局出了问题
        NSSetUncaughtExceptionHandler { _ in
            print("=== 崩溃时的窗口列表")
            for w in NSApp.windows {
                let cls = String(describing: type(of: w))
                var host = ""
                if let cv = w.contentView { host = String(describing: type(of: cv)) }
                print("  \(cls) | 内容视图 \(host) | 可见 \(w.isVisible) | frame \(w.frame) | level \(w.level.rawValue) | 标题 \"\(w.title)\"")
            }
            fflush(stdout)
        }
        let sizes: [WidgetSize] = [.large, .small, .medium, .large, .medium, .small]
        var step = 0
        var clicks = 0, resizes = 0, toggles = 0
        // 排除法：CAB_DRIVE_SKIP=click,resize,toggle,data 可以关掉某类操作，看哪一类是崩溃的必要条件
        let skip = Set((ProcessInfo.processInfo.environment["CAB_DRIVE_SKIP"] ?? "").split(separator: ",").map(String.init))
        let secs = Double(ProcessInfo.processInfo.environment["CAB_DRIVE_SECONDS"] ?? "") ?? seconds
        // 每 0.4 秒做一件事，几种操作轮流来，节奏有快有慢
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                step += 1
                if !skip.contains("data") {
                    model.states["d1"]?.fiveHour = Double((step * 7) % 100)
                    model.states["d2"]?.sevenDay = Double((step * 13) % 100)
                }
                @MainActor func log(_ t: String) {
                    let f = WidgetController.shared.panel?.frame
                    let d = WidgetController.shared.desiredSize(model)
                    print("[\(step)] \(t)    ← 窗口 \(f.map { "\(Int($0.width))×\(Int($0.height))" } ?? "无")，设置 \(model.store.widgetSize ?? "默认")，内容量出来 \(Int(d.width))×\(Int(d.height))"); fflush(stdout)
                }
                switch step % 9 {
                case 0, 4: if !skip.contains("click") { log("点菜单栏图标（弹出/收起面板）"); statusButton()?.performClick(nil); clicks += 1 }
                case 1, 5, 7: if !skip.contains("resize") { let t = sizes[step % sizes.count]; log("小组件换尺寸 → \(t.title)"); WidgetController.shared.changeSize(model, to: t); resizes += 1 }
                case 3: if !skip.contains("toggle") { log("显示/隐藏小组件（现在\(WidgetController.shared.isVisible ? "可见" : "隐藏")）"); WidgetController.shared.toggle(model); toggles += 1 }
                case 6: if !skip.contains("toggle"), !WidgetController.shared.isVisible { log("补开小组件"); WidgetController.shared.show(model) }
                default: break
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            print("自动驾驶测试完成：点图标 \(clicks) 次，换尺寸 \(resizes) 次，显示/隐藏小组件 \(toggles) 次，没有崩溃")
            fflush(stdout)
            exit(0)
        }
    }
}
