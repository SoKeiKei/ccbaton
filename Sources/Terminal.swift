import SwiftUI
import AppKit

// 打开终端：点账号上的"终端"先弹一个小窗口，选目录、勾启动选项、填附加参数，再用这个账号开终端。
// 每个账号记住自己上次的目录和参数；"最近用过"的目录各账号共用。

struct TerminalPrefs: Codable, Equatable {
    var dir: String
    var skipPermissions: Bool
    var args: String
}

/// 终端用哪份登录，含义见 Isolation.swift
enum TerminalMode: String { case shared, live, dedicated }

let recentDirLimit = 10

/// 最近用过的目录：新的排前面，不重复，最多留 recentDirLimit 个
func addRecent(_ dir: String, to list: [String]) -> [String] {
    Array(([dir] + list.filter { $0 != dir }).prefix(recentDirLimit))
}

func isDirectory(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
}

/// 把"附加参数"按空格拆开，支持引号和反斜杠；引号没配对返回 nil。
/// 输入法和系统的"智能引号 / 智能破折号"会把 " 变成 “”、把 -- 变成 —，这里按原意认回来。
func splitArguments(_ text: String) -> [String]? {
    var out: [String] = [], current = "", started = false
    var closing: Character?                 // 现在在引号里的话，等哪个字符收尾
    var rest = text.makeIterator()
    while let c = rest.next() {
        if let q = closing {
            if c == q || (c == "\"" && q == "”") || (c == "'" && q == "’") { closing = nil }
            else if c == "\\", q == "\"", let n = rest.next() {
                if n != "\"" && n != "\\" { current.append(c) }
                current.append(n)
            } else { current.append(c) }
        } else if c.isWhitespace {
            if started { out.append(current); current = ""; started = false }
        } else {
            switch c {
            case "\"", "'": closing = c
            case "“": closing = "”"
            case "‘": closing = "’"
            case "\\": if let n = rest.next() { current.append(n) }
            case "—", "–": current += started ? String(c) : "--"
            default: current.append(c)
            }
            started = true
        }
    }
    if closing != nil { return nil }
    if started { out.append(current) }
    return out
}

// MARK: - 启动

extension Model {
    /// 窗口打开时填什么：这个账号上次用的；没有就用最近的目录
    func terminalPrefs(_ a: Account) -> TerminalPrefs {
        store.terminalPrefs?[a.id] ?? TerminalPrefs(dir: store.recentDirs?.first ?? store.workDir, skipPermissions: false, args: "")
    }

    var recentDirs: [String] { store.recentDirs ?? (store.workDir == home ? [] : [store.workDir]) }

    func removeRecent(_ dir: String) {
        store.recentDirs = recentDirs.filter { $0 != dir }
        save()
    }

    /// 现在给这个账号开终端会用哪份登录（和 cc-switch 一样：账号目录里有登录就用它，
    /// 登录在默认位置就走默认）。用户做过"完全独立"登录的优先。nil 表示没有可用的登录。
    func terminalMode(_ a: Account) -> TerminalMode? {
        guard let key = identity(ofDir: a.configDir)?.key else { return nil }
        if terminalLoginMatches(dir: terminalDir(a), key: key) { return .dedicated }
        if terminalLoginMatches(dir: a.configDir, key: key) { return .shared }
        if terminalLoginMatches(dir: defaultSlotName, key: key) { return .live }
        return nil
    }

    /// 终端的启动脚本（怎么保证用量记在所选账号上见 Isolation.swift）。
    /// 附加参数一个个单独加引号，不会被终端当成别的命令执行。
    /// 脚本里用 builtin / whence -p，绕开用户终端配置里同名的别名和函数。
    func terminalScript(_ a: Account, _ p: TerminalPrefs, _ mode: TerminalMode) -> String {
        let dir: String? = mode == .live ? nil : (mode == .dedicated ? terminalDir(a) : a.configDir)
        let key = identity(ofDir: a.configDir)?.key ?? ""
        let email = states[a.id]?.email ?? ""
        let name = shortDisplayName(a)
        let who = email.isEmpty ? "「\(name)」" : "「\(name)」（\(email)）"
        let app = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let unset = (routingKeys + modelKeys).filter { !$0.hasPrefix("ANTHROPIC_") } + ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]
        // --settings 放在附加参数前面：附加参数里就算有 -- 也盖不掉它
        var run = "exec \"$bin\" --settings " + shQuote(isolationSettings(configDir: dir, cwd: p.dir))
        if p.skipPermissions { run += " --dangerously-skip-permissions" }
        for arg in splitArguments(p.args) ?? [] { run += " " + shQuote(arg) }

        var lines = [
            // 目录进不去就停在终端里，绝不换个地方启动 claude（尤其是跳过权限确认的时候）
            "builtin cd -- \(shQuote(p.dir)) || { print -r -- \(shQuote("打不开这个目录：" + p.dir)); exec zsh -il; }",
            "builtin unset -m 'ANTHROPIC_*'",
            "builtin unset " + unset.joined(separator: " "),
            dir.map { "export CLAUDE_CONFIG_DIR=\(shQuote($0))" } ?? "builtin unset CLAUDE_CONFIG_DIR",
            "bin=$(builtin whence -p claude) || { print -r -- '找不到 claude 命令'; exec zsh -il; }",
            "signed_in() { \(shQuote(app)) --check-terminal-login \(shQuote(dir ?? defaultSlotName)) \(shQuote(key)) }",
        ]
        if mode == .dedicated {
            var login = "\"$bin\" auth login --claudeai"
            if !email.isEmpty { login += " --email " + shQuote(email) }
            lines += [
                "if ! signed_in; then",
                "  print -r -- \(shQuote("=== 给 \(who) 做一次完全独立的登录。浏览器里请确认授权的是这个账号 ==="))",
                "  " + login,
                "  if ! signed_in; then",
                "    print -r -- \(shQuote("没有启动 claude：这次没登录成功，或者浏览器里授权的不是 \(who)。先在浏览器里退出别的 Claude 账号，再试一次。"))",
                "    exec zsh -il",
                "  fi",
                "fi",
            ]
        } else {
            lines.append("signed_in || { print -r -- \(shQuote("没有启动 claude：\(who) 的登录刚刚变了（比如切换过账号）。回到 CCBaton 重新点「终端」。")); exec zsh -il; }")
        }
        lines += [
            // exec 之后进程号不变，记下来，切换账号前好提醒哪些终端会受影响
            "mkdir -p \(shQuote(runningDir)) && print -r -- \(shQuote("\(mode.rawValue)|\(a.id)")) > \(shQuote(runningDir))/$$",
            run,
        ]
        return lines.joined(separator: "\n")
    }

    /// 打开终端。independent 表示用户要"完全独立"。成功返回 nil，否则返回给用户看的原因。
    func openTerminal(_ a: Account, _ p: TerminalPrefs, independent: Bool = false) -> String? {
        reloadStates()          // 开窗口到点按钮之间可能切过账号
        guard identity(ofDir: a.configDir) != nil else { return "这个账号还没有登录过，先在面板里点「重新登录」" }
        guard isDirectory(p.dir) else { return "找不到这个目录，换一个试试" }
        guard let args = splitArguments(p.args) else { return "附加参数里的引号没有配对" }
        if args.contains(where: { $0 == "--settings" || $0.hasPrefix("--settings=") }) { return "附加参数里不能带 --settings，它会破坏账号隔离" }
        if scanSettings([managedSettingsPath]).redirects { return "系统管理设置里指定了别的接口，无法保证用量记在这个账号上" }
        guard let mode = independent ? .dedicated : terminalMode(a) else { return "这个账号现在没有可用的登录，先在面板里点「重新登录」" }
        do {
            // 只整理本程序自己建的目录；从 cc-switch 导入的账号目录归它管，不动
            if mode == .dedicated { try prepareTerminalDir(terminalDir(a)) }
            else if mode == .shared, a.configDir.hasPrefix(supportDir + "/") { try prepareTerminalDir(a.configDir) }
        } catch { return "准备账号目录失败：\(error)" }
        // 每次用不同的脚本文件（执行时自己删掉），连着开几个终端不会互相覆盖
        let file = "open-\(a.id)-\(newLocalId().prefix(8))"
        guard launchTerminal(name: file, body: "rm -f -- \"$0\"\n" + terminalScript(a, p, mode)) else { return "写启动脚本失败" }
        var all = store.terminalPrefs ?? [:]
        all[a.id] = p
        store.terminalPrefs = all
        store.recentDirs = addRecent(p.dir, to: recentDirs)
        store.workDir = p.dir
        save()
        return nil
    }
}

// MARK: - 窗口

struct TerminalLaunchView: View {
    @ObservedObject var model: Model
    let account: Account
    let close: () -> Void
    /// 弹系统的选目录窗口，选好后回调
    let pickDirectory: (String, @escaping (String) -> Void) -> Void

    @State private var prefs: TerminalPrefs
    @State private var error = ""
    @State private var mode: TerminalMode?
    @State private var independent = false      // 勾了"完全独立"（还没做过独立登录时）

    init(model: Model, account: Account, close: @escaping () -> Void,
         pickDirectory: @escaping (String, @escaping (String) -> Void) -> Void = { _, _ in }) {
        self.model = model; self.account = account; self.close = close; self.pickDirectory = pickDirectory
        _prefs = State(initialValue: model.terminalPrefs(account))
        _mode = State(initialValue: Model.demo ? .shared : model.terminalMode(account))
    }

    /// 系统管理设置指定了别的接口：它优先级最高，隔离做不到
    private var managed: Bool { !Model.demo && scanSettings([managedSettingsPath]).redirects }
    private var redirected: Bool { !Model.demo && scanSettings(settingsFiles(cwd: prefs.dir)).redirects }
    private var needsLogin: Bool { independent && mode != .dedicated }

    /// 顶部说明框：图标、颜色、标题、正文
    private func explanation(_ name: String) -> (String, Color, String, String) {
        if managed { return ("exclamationmark.triangle", .orange, "无法保证隔离", "系统管理设置里指定了别的接口，它的优先级最高，所以不打开。") }
        if needsLogin {
            return ("person.badge.key", .accentColor, "完全独立：打开时登录一次",
                    "浏览器授权时请确认是 \(model.states[account.id]?.email ?? "这个账号")。以后直接打开，切换账号完全不影响它。")
        }
        let skip = redirected ? "已忽略设置里的第三方接口。" : ""
        switch mode {
        case .dedicated: return ("lock.shield.fill", .green, "完全独立：固定用「\(name)」", skip + "切换账号、换第三方供应商都不影响它。")
        case .shared: return ("lock.shield", .green, "独立终端：固定用「\(name)」", skip + "用量记在这个账号上。只有切换到「\(name)」时它会掉线。")
        case .live: return ("arrow.triangle.swap", .orange, "跟着默认登录走", skip + "「\(name)」正在使用中。之后切换账号，这个终端也会换号。")
        case nil: return ("exclamationmark.circle", .orange, "这个账号没有可用的登录", "先在面板里点「重新登录」。")
        }
    }
    private var badArgs: Bool { splitArguments(prefs.args) == nil }
    private var missing: Bool { !Model.demo && !isDirectory(prefs.dir) }

    private func open() {
        if let e = model.openTerminal(account, prefs, independent: needsLogin) { error = e } else { close() }
    }

    private func folderName(_ p: String) -> String { (p as NSString).lastPathComponent }
    private func parentName(_ p: String) -> String { ((p as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        let name = model.shortDisplayName(account)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Avatar(model: model, account: account, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("在哪个目录打开终端？").font(.system(size: 15, weight: .bold))
                    Text("用「\(name)」的登录启动 Claude Code。一般选你的项目文件夹。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }

            // 隔离说明：颜色跟着状态走（绿 = 固定在这个账号，橙 = 会跟着换号或打不开）
            let (icon, tint, title, detail) = explanation(name)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 26, height: 26).background(Circle().fill(tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    ReservedText(text: detail, lines: 2)
                    Toggle(isOn: $independent) { Text("要完全独立（这个账号多登录一次）").font(Look.caption) }
                        .toggleStyle(.checkbox).frame(height: 16)
                        .opacity(mode == .dedicated || managed ? 0 : 1).disabled(mode == .dedicated || managed)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .card(tint: tint)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: missing ? "folder.badge.questionmark" : "folder.fill").font(.system(size: 16))
                            .foregroundStyle(missing ? Color.orange : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folderName(prefs.dir)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(missing ? "找不到这个目录（外接盘没插上？）" : parentName(prefs.dir))
                                .font(Look.caption).foregroundStyle(missing ? Color.orange : Color.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .card(tint: missing ? .orange : .accentColor, radius: 10)
                    .help(prefs.dir)
                    Button("更换…") { pickDirectory(prefs.dir) { prefs.dir = $0; error = "" } }
                }

                Text("最近用过").font(Look.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2).padding(.top, 2)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.recentDirs, id: \.self) { d in
                            RecentRow(path: d, name: folderName(d), parent: parentName(d), selected: d == prefs.dir,
                                      pick: { prefs.dir = d; error = "" }, remove: { model.removeRecent(d) })
                        }
                        if model.recentDirs.isEmpty {
                            Text("还没有记录，开过一次终端就会出现在这里。").font(Look.caption).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).padding(.horizontal, 8)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 148)
                .card(radius: 10)
            }

            // 启动选项：和设置窗口同一种卡片
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("跳过权限确认").font(Look.title)
                            Text("--dangerously-skip-permissions").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        SwitchControl(title: "跳过权限确认", isOn: $prefs.skipPermissions)
                    }
                    // 打开开关后才出现的提醒：始终占一行
                    ReservedText(text: prefs.skipPermissions ? "Claude 改文件、执行命令都不会再问你，只在信得过的目录里用。" : "", color: .orange)
                }
                .padding(.horizontal, Look.rowH).padding(.top, Look.rowV).padding(.bottom, 6)
                RowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("附加参数（可选）").font(Look.title)
                    TextField("例如 --continue 或 --model opus", text: $prefs.args)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .frame(height: 22)
                        .autocorrectionDisabled()
                        .onChange(of: prefs.args) { error = "" }
                    ReservedText(text: badArgs ? "引号没有配对，补上才能打开。" : "接在启动命令后面。用空格分隔，含空格的值用引号括起来。",
                                 color: badArgs ? .orange : .secondary)
                }
                .padding(.horizontal, Look.rowH).padding(.vertical, Look.rowV)
            }
            .card()

            HStack {
                ReservedText(text: error, lines: 2, color: .orange)
                Spacer(minLength: 8)
                Button("取消") { close() }.keyboardShortcut(.cancelAction)
                Button(needsLogin ? "登录并打开" : "打开终端") { open() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(badArgs || missing || managed || (mode == nil && !independent))
            }
        }
        .padding(.horizontal, Look.pad).padding(.top, 4).padding(.bottom, 16)
        .frame(width: 460)
    }
}

/// "最近用过"里的一行：点一下选中，鼠标移上去可以删掉
struct RecentRow: View {
    let path: String
    let name: String
    let parent: String
    let selected: Bool
    let pick: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: pick) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(parent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor) }
            if hover {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("从最近用过里去掉（不会删文件夹）")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hover ? 0.07 : 0)))
        .onHover { hover = $0 }
        .help(path)
    }
}

@MainActor
final class TerminalController {
    static let shared = TerminalController()
    private(set) var window: NSWindow?

    func open(_ model: Model, account: Account) {
        window?.close()
        let view = TerminalLaunchView(model: model, account: account, close: { [weak self] in
            self?.window?.close()
            self?.window = nil
        }, pickDirectory: { [weak self] current, done in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = URL(fileURLWithPath: current)
            panel.prompt = "选这个目录"
            guard let w = self?.window else { return }
            panel.beginSheetModal(for: w) { r in if r == .OK, let u = panel.url { done(u.path) } }
        })
        let w = makeGlassWindow(title: "打开终端", floating: true) { view }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
