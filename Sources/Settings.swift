import SwiftUI
import AppKit

// 设置窗口：不常改的东西都放这里，菜单栏面板只留日常用的。
// 窗口大小打开时定好就不再变，所以会换内容的文字都给固定高度。

/// 一块设置：小标题加一张圆角卡片
struct SettingGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}

/// 只用于 README 截图：离屏渲染时程序不在前台，系统开关画不出开着的蓝色，按系统样式画一个
private struct ShotSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule().fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: 43, height: 20)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(Color.white).frame(width: 26, height: 16).padding(2)
            }
    }
}

/// 一行开关：左边名字，右边开关
struct SettingSwitch: View {
    let title: String
    let isOn: Binding<Bool>
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            if Model.demo { Toggle(title, isOn: isOn).toggleStyle(ShotSwitchStyle()).labelsHidden() }
            else { Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden() }
        }
        .frame(height: 22)      // 系统开关进窗口前后量出来的高度不一样，固定行高，窗口大小才对得上
    }
}

struct SettingNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

let repoURL = URL(string: "https://github.com/SoKeiKei/ccbaton")!

/// GitHub 图标，取自 GitHub 官方图标库 Octicons（MIT），见 NOTICE.md
let githubMark: NSImage = {
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>"#
    let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
    image.isTemplate = true             // 跟着文字颜色走，深浅色都看得清
    return image
}()

/// 设置页右下角：GitHub 图标 + CCBaton，点一下在浏览器里打开仓库
struct RepoLink: View {
    @State private var hover = false
    var body: some View {
        Button { NSWorkspace.shared.open(repoURL) } label: {
            HStack(spacing: 5) {
                Image(nsImage: githubMark).resizable().frame(width: 14, height: 14)
                Text("CCBaton").font(.system(size: 12, weight: .medium)).underline(hover)
            }
            .foregroundStyle(hover ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            hover = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hover { NSCursor.pop() } }
        .help("打开开源仓库：\(repoURL.absoluteString)")
        .accessibilityLabel("在 GitHub 打开 CCBaton 开源仓库")
    }
}

/// "1 小时 40 分"、"50 分钟"、"1 小时"
func durationText(_ t: TimeInterval) -> String {
    let total = Int((t / 60).rounded()), h = total / 60, m = total % 60
    return h == 0 ? "\(m) 分钟" : (m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分")
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var loginOn = false
    @State private var loginMessage = ""
    @State private var importMessage = ""
    @State private var confirmWarmup = false
    @State private var migrationResult = ""
    // 窗口大小打开时就定了，所以下面几项在打开时判断一次，出现后不中途消失
    @State private var ccInstalled: Bool
    @State private var showImport: Bool          // 装着 cc-switch 且有可导入的账号
    @State private var showMigration: Bool       // 有账号还没搬进本程序目录

    init(model: Model) {
        self.model = model
        _ccInstalled = State(initialValue: model.ccSwitchInstalled())
        _showImport = State(initialValue: model.offersImport)
        _showMigration = State(initialValue: !model.migratable.isEmpty)
    }

    private var loginNote: String {
        if !loginMessage.isEmpty { return loginMessage }
        return !Model.demo && Bundle.main.bundlePath.hasPrefix("/Volumes/")
            ? "应用现在放在外接盘上，开机时可能启动失败，建议放进\"应用程序\"文件夹。" : "登录 Mac 时自动启动 CCBaton。"
    }

    /// 错开的说明：间隔按现在能预热的账号数算
    private var warmupNote: String {
        let usable = model.store.accounts.filter { model.states[$0.id].map { warmupEligible($0, now: Date()) } ?? false }.count
        let n = usable > 0 ? usable : model.store.accounts.count
        let example = n < 2 ? "只有 1 个号时用不上" : "现在 \(n) 个号是 \(durationText(Warmup.gap(n)))"
        return "账号空闲时，用最小的模型发一条很短的消息，让倒计时先走起来。错开：两次激活至少隔 5 小时 ÷ 账号数（\(example)）。\n会消耗极少量额度；Anthropic 没有明确允许这种自动操作，请自行判断。电脑睡眠时不会激活。"
    }

    private func setLogin(_ on: Bool) {
        guard testRoot == nil else { return }        // 沙盒测试不碰系统的登录项
        do { try LoginItem.set(on); loginMessage = LoginItem.needsApproval ? "需要在系统设置 → 通用 → 登录项 里允许 CCBaton。" : "" }
        catch { loginMessage = "设置失败：\(error.localizedDescription)" }
        loginOn = LoginItem.enabled
    }

    private var widgetSize: WidgetSize { WidgetSize(rawValue: model.store.widgetSize ?? "") ?? .medium }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingGroup(title: "通用", icon: "gearshape") {
                VStack(alignment: .leading, spacing: 3) {
                    SettingSwitch(title: "开机启动", isOn: Binding(get: { loginOn }, set: { setLogin($0) }))
                    SettingNote(text: loginNote).lineLimit(2).frame(height: 28, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 3) {
                    SettingSwitch(title: "显示剩余额度", isOn: Binding(get: { model.showRemaining }, set: { model.setShowRemaining($0) }))
                    SettingNote(text: "关着时显示已用了多少；打开后各处都改成还剩多少。")
                }
                if showImport {
                    HStack(spacing: 8) {
                        Text(importMessage.isEmpty ? "导入在 cc-switch 里登录的账号" : importMessage)
                            .font(.system(size: importMessage.isEmpty ? 13 : 11)).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("导入") { model.importCCSwitch(); importMessage = model.notice ?? "" }.controlSize(.small)
                    }
                }
            }

            if showMigration {
                let texts = model.migrationTexts(installed: ccInstalled)
                SettingGroup(title: texts.title, icon: "arrow.right.doc.on.clipboard") {
                    HStack {
                        Text(texts.line).font(.system(size: 13))
                        Spacer(minLength: 8)
                        Button("迁移到 CCBaton") { migrationResult = model.requestMigration() }
                            .controlSize(.small).disabled(model.migratable.isEmpty)
                    }
                    .frame(height: 22)
                    SettingNote(text: migrationResult.isEmpty ? texts.note : migrationResult)
                        .lineLimit(2).frame(height: 28, alignment: .topLeading)
                }
            }

            SettingGroup(title: "额度预热", icon: "timer") {
                SettingSwitch(title: "自动开始 5 小时倒计时",
                              isOn: Binding(get: { model.warmupOn }, set: { if $0 { confirmWarmup = true } else { model.setWarmup(false) } }))
                SettingSwitch(title: "错开各账号的重置时间", isOn: Binding(get: { model.staggerOn }, set: { model.setStagger($0) }))
                    .disabled(!model.warmupOn).opacity(model.warmupOn ? 1 : 0.5)
                SettingNote(text: warmupNote)
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(model.warmupStatus).font(.system(size: 11, weight: .medium)).lineLimit(2)
                }
                .foregroundStyle(model.warmupOn ? Color.accentColor : Color.secondary)
                .frame(height: 28, alignment: .topLeading)
            }

            SettingGroup(title: "额度提醒", icon: "bell") {
                SettingSwitch(title: "额度告急时弹系统通知", isOn: Binding(get: { model.alertsOn }, set: { model.setAlerts($0) }))
                HStack {
                    SettingNote(text: model.showRemaining ? "剩 10% 和用完时各提醒一次。" : "用到 90% 和用完时各提醒一次。")
                    Spacer(minLength: 8)
                    Button("发送测试提醒") { model.sendTestAlert() }.controlSize(.small)
                }
            }

            SettingGroup(title: "桌面小组件", icon: "rectangle.on.rectangle") {
                SettingSwitch(title: "显示小组件", isOn: Binding(
                    get: { model.store.widgetVisible == true },
                    set: { on in on ? WidgetController.shared.show(model) : WidgetController.shared.hide(model) }))
                HStack {
                    Text("尺寸").font(.system(size: 13))
                    Spacer(minLength: 8)
                    Picker("尺寸", selection: Binding(get: { widgetSize }, set: { WidgetController.shared.changeSize(model, to: $0) })) {
                        ForEach(WidgetSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
            }

            UpdateSettings(model: model)

            HStack {
                Text("版本 \(appVersion)（构建 \(appBuild)）").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                RepoLink()
            }
            .padding(.horizontal, 2)
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { loginOn = Model.demo ? false : LoginItem.enabled }
        .alert("开启额度预热？", isPresented: $confirmWarmup) {
            Button("开启") { model.setWarmup(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("CCBaton 会在账号空闲时自动给它发一条极短的消息，让 5 小时倒计时开始走。这会消耗极少量额度。Anthropic 没有明确允许这种自动操作，属于灰色地带，账号风险由你自己承担。")
        }
    }
}

@MainActor
final class SettingsController {
    static let shared = SettingsController()
    private(set) var window: NSWindow?

    func open(_ model: Model) {
        if let w = window, w.isVisible { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        var host = NSHostingView(rootView: AnyView(SettingsView(model: model)))
        var size = host.fittingSize
        let limit = (NSScreen.main?.visibleFrame.height ?? 900) - 40       // 标题栏要占一点
        if size.height > limit {                                            // 小屏幕放不下就能上下滚
            host = NSHostingView(rootView: AnyView(ScrollView { SettingsView(model: model) }.frame(width: size.width, height: limit)))
            size = NSSize(width: size.width, height: limit)
        }
        host.sizingOptions = []                  // 窗口大小固定，不让内容的布局反过来牵着窗口走
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "CCBaton 设置"
        let container = NSView(frame: NSRect(origin: .zero, size: size))      // 同样套一层容器，避免 SwiftUI 自己改窗口大小
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        w.contentView = container
        w.setContentSize(size)
        w.center()
        w.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
