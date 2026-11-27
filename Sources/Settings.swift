import SwiftUI
import AppKit

// 设置窗口：不常改的东西都放这里，菜单栏面板只留日常用的。
// 窗口大小打开时定好就不再变，所以会换内容的文字都预留行数（ReservedText）。样式见 Components.swift。

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
    @State private var loginDetail = ""        // 系统给的完整错误说明，只放进悬停提示，正文保持一行（窗口打开后不会再长高）
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

    /// 应用放在外接盘上（打开时判断一次：窗口大小要按它留出两行提示）
    private let external = !Model.demo && Bundle.main.bundlePath.hasPrefix("/Volumes/")

    private var loginNote: String {
        if !loginMessage.isEmpty { return loginMessage }
        return external ? "应用现在放在外接盘上，开机时可能启动失败，建议放进\"应用程序\"文件夹。" : "登录 Mac 时自动启动 CCBaton。"
    }

    /// 错开的算法说明（放在开关的悬停提示里）：间隔按现在能预热的账号数算
    private var staggerHelp: String {
        let usable = model.store.accounts.filter { model.states[$0.id].map { warmupEligible($0, now: Date()) } ?? false }.count
        let n = usable > 0 ? usable : model.store.accounts.count
        let example = n < 2 ? "只有 1 个号时用不上" : "现在 \(n) 个号是 \(durationText(Warmup.gap(n)))"
        return "两次激活至少隔 5 小时 ÷ 账号数（\(example)），这样各账号的重置时间不会挤在一起。"
    }

    private func setLogin(_ on: Bool) {
        guard testRoot == nil else { return }        // 沙盒测试不碰系统的登录项
        loginDetail = ""
        do { try LoginItem.set(on); loginMessage = LoginItem.needsApproval ? "需要在系统设置 → 通用 → 登录项 里允许 CCBaton。" : "" }
        catch { loginMessage = "设置失败，可到系统设置 → 登录项里手动添加。"; loginDetail = error.localizedDescription }
        loginOn = LoginItem.enabled
    }

    private var widgetSize: WidgetSize { WidgetSize(rawValue: model.store.widgetSize ?? "") ?? .medium }

    /// 开关绑定：开机启动、剩余额度……都走 Model 里原来的方法
    private func bind(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> { Binding(get: get, set: set) }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.groupGap) {
            FormSection(title: "通用", icon: "gearshape.fill", tint: .gray) {
                // 说明这一格打开后可能换成出错提示：外接盘时两行，平时一行
                FormRow(title: "开机启动", subtitle: loginNote,
                        subtitleColor: loginMessage.isEmpty && !external ? .secondary : .orange,
                        subtitleLines: external ? 2 : 1) {
                    SwitchControl(title: "开机启动", isOn: bind({ loginOn }, { setLogin($0) }))
                }
                .help(loginDetail)
                RowDivider()
                // 已用 / 剩余是二选一，不是开和关：用分段选择，两种状态都看得见（存的仍是 showRemaining，true = 剩余）
                FormRow(title: "额度显示", subtitle: "面板、小组件和菜单栏都按这里显示。") {
                    Picker("额度显示", selection: bind({ model.showRemaining }, { model.setShowRemaining($0) })) {
                        Text("已用").tag(false)
                        Text("剩余").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if model.desktopPresent {
                    RowDivider()
                    FormRow(title: "管理 Claude 桌面端账号", subtitle: "打开后才能保存和切换桌面端的账号登录；关着时不会读写桌面端的任何文件。",
                            badge: "实验") {
                        SwitchControl(title: "管理 Claude 桌面端账号", isOn: bind({ model.desktopOn }, { model.setDesktopOn($0) }))
                            .disabled(model.desktopFlow != nil)
                    }
                    FormRow(title: "同步各账号的对话列表", subtitle: "换桌面端账号时，把其他账号的 Code 对话补进来。已复制的记录，关掉开关也不会删除。",
                            indent: 16) {
                        SwitchControl(title: "同步各账号的对话列表", isOn: bind({ model.desktopSyncOn }, { model.setDesktopSyncOn($0) }))
                    }
                    .padding(.top, -6)
                    .disabled(!model.desktopOn).opacity(model.desktopOn ? 1 : 0.45)
                }
                if showImport {
                    RowDivider()
                    FormRow(title: importMessage.isEmpty ? "导入在 cc-switch 里登录的账号" : importMessage) {
                        Button("导入") { model.importCCSwitch(); importMessage = model.notice ?? "" }.controlSize(.small)
                    }
                    .lineLimit(1)
                }
            }

            if showMigration {
                let texts = model.migrationTexts(installed: ccInstalled)
                FormSection(title: texts.title, icon: "arrow.right.doc.on.clipboard", tint: .teal) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text(texts.line).font(Look.title).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("迁移到 CCBaton") { migrationResult = model.requestMigration() }
                                .controlSize(.small).disabled(model.migratable.isEmpty)
                        }
                        // 点了迁移后这里换成结果或拦下的原因，最长两行
                        ReservedText(text: migrationResult.isEmpty ? texts.note : migrationResult, lines: 2,
                                     color: migrationResult.isEmpty ? .secondary : .orange)
                    }
                    .padding(.horizontal, Look.rowH).padding(.vertical, Look.rowV)
                }
            }

            FormSection(title: "额度预热", icon: "timer", tint: .indigo) {
                FormRow(title: "自动开始 5 小时倒计时",
                        subtitle: "空闲时发一条很短的消息让倒计时先走，会消耗极少量额度。",
                        info: "账号空闲时，用最小的模型发一条很短的消息，让倒计时先走起来。会消耗极少量额度，电脑睡眠时不会激活。") {
                    SwitchControl(title: "自动开始 5 小时倒计时",
                                  isOn: bind({ model.warmupOn }, { if $0 { confirmWarmup = true } else { model.setWarmup(false) } }))
                }
                RowDivider()
                FormRow(title: "错开各账号的重置时间", info: staggerHelp) {
                    SwitchControl(title: "错开各账号的重置时间", isOn: bind({ model.staggerOn }, { model.setStagger($0) }))
                }
                .disabled(!model.warmupOn).opacity(model.warmupOn ? 1 : 0.45)
                .help(staggerHelp)
                VStack(alignment: .leading, spacing: 6) {
                    // 状态会随时变（轮到谁、几点激活），预留两行
                    Callout(icon: model.warmupOn ? "clock.arrow.circlepath" : "pause.circle", text: model.warmupStatus,
                            tint: model.warmupOn ? .accentColor : .secondary, lines: 2, weight: .medium)
                    // 风险提示始终露在外面，不收进说明里（立场见 docs/compliance.md）
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).frame(width: 14)
                        Text("Anthropic 没有明确允许这种自动操作，请自行判断。").font(Look.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                }
                .padding(.horizontal, Look.rowH).padding(.top, 2).padding(.bottom, 12)
            }

            FormSection(title: "额度提醒", icon: "bell.fill", tint: .red) {
                FormRow(title: "额度告急时弹系统通知",
                        subtitle: model.showRemaining ? "剩 10% 和用完时各提醒一次。" : "用到 90% 和用完时各提醒一次。", subtitleLines: 1) {
                    HStack(spacing: 10) {
                        Button("发送测试提醒") { model.sendTestAlert() }.controlSize(.small)
                        SwitchControl(title: "额度告急时弹系统通知", isOn: bind({ model.alertsOn }, { model.setAlerts($0) }))
                    }
                }
            }

            FormSection(title: "桌面小组件", icon: "rectangle.on.rectangle", tint: .blue) {
                // 尺寸和开关放在同一行：一个开关单独占一行太空，分两行又显得长
                FormRow(title: "显示小组件") {
                    HStack(spacing: 12) {
                        Picker("尺寸", selection: Binding(get: { widgetSize }, set: { WidgetController.shared.changeSize(model, to: $0) })) {
                            ForEach(WidgetSize.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize().help("小组件尺寸")
                        SwitchControl(title: "显示小组件", isOn: bind({ model.store.widgetVisible == true },
                                                                 { on in on ? WidgetController.shared.show(model) : WidgetController.shared.hide(model) }))
                    }
                }
            }

            UpdateSettings(model: model)

            HStack {
                Text("版本 \(appVersion)（构建 \(appBuild)）").font(Look.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                RepoLink()
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, Look.pad).padding(.top, 6).padding(.bottom, 16)
        .frame(width: 440)
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
        let w = makeGlassWindow(title: "CCBaton 设置", floating: false, scrollIfTall: true) { SettingsView(model: model) }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
