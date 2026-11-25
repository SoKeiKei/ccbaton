import Foundation

// 独立终端怎么做到"用量一定记在所选账号上"：
//   1. 启动前清掉终端环境里能改走别处的变量（API 密钥、接口地址、登录令牌、Bedrock 之类）。
//   2. 用 claude --settings 把设置文件里的同类项压掉（优先级高于用户设置和项目设置，不改任何文件），
//      cc-switch 换供应商、项目自带的设置都抢不走。
//   3. 启动 claude 之前核对要用的那份登录确实是所选账号，不是就不启动。
// 用哪份登录（TerminalMode，和 cc-switch 一样默认沿用现有的，不用再登录）：
//   shared    账号目录里自己的登录。切换到这个账号时登录会被搬走，这个终端随之掉线。
//   live      账号正在使用中，登录在默认位置。这个终端跟着默认登录走，切换账号时跟着换。
//   dedicated 用户选了"完全独立"：终端专用目录（terminals/<账号>/config）里单独登录一次，
//             切换功能永远不碰它。
// 只有系统级的管理设置（公司下发）优先级更高，发现里面指定了接口时直接拒绝打开。

/// 会改变"请求发到哪、用谁的身份"的环境变量
let routingKeys = [
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_UNIX_SOCKET",
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_GATEWAY",
    "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD",
    "CLAUDE_SECURESTORAGE_CONFIG_DIR",
]
/// 第三方供应商常顺带改的模型名；不压掉的话，会拿别家的模型名去请求官方
let modelKeys = [
    "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL",
]

let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"

func terminalDir(_ a: Account) -> String { "\(supportDir)/terminals/\(a.id)/config" }

/// 在 cwd 里启动 claude 时会读到的设置文件（用户的，加上这个目录及其上层目录里的）
func settingsFiles(cwd: String) -> [String] {
    var files = [home + "/.claude/settings.json"]
    var dir = (cwd as NSString).standardizingPath
    while dir.count > 1 {
        files += [dir + "/.claude/settings.json", dir + "/.claude/settings.local.json"]
        dir = (dir as NSString).deletingLastPathComponent
    }
    return files
}

/// 这些设置文件里出现过的 ANTHROPIC_* 键，以及有没有真的指向别处（给用户提示用）
func scanSettings(_ files: [String]) -> (keys: Set<String>, redirects: Bool) {
    var keys: Set<String> = [], redirects = false
    for f in files {
        guard let doc = readProfile(f) else { continue }
        if let helper = doc["apiKeyHelper"] as? String, !helper.isEmpty { redirects = true }
        for (k, v) in (doc["env"] as? [String: Any]) ?? [:] {
            if k.hasPrefix("ANTHROPIC_") { keys.insert(k) }
            if routingKeys.contains(k), !((v as? String) ?? "\(v)").isEmpty { redirects = true }
        }
    }
    return (keys, redirects)
}

/// 传给 claude --settings 的内容：只有空值和账号目录，不含任何密钥。
/// configDir 为 nil 表示走默认位置，这时不能指定账号目录（指定了钥匙串条目名就变了）。
func isolationSettings(configDir: String?, cwd: String) -> String {
    var env: [String: String] = [:]
    for k in routingKeys + modelKeys + Array(scanSettings(settingsFiles(cwd: cwd)).keys) { env[k] = "" }
    if let d = configDir { env["CLAUDE_CONFIG_DIR"] = d }
    let data = try? JSONSerialization.data(withJSONObject: ["apiKeyHelper": "", "env": env], options: [.sortedKeys, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

/// 启动脚本里用来指代默认位置
let defaultSlotName = "default"

/// 这个位置登录的是不是指定账号（key = accountUuid:organizationUuid），而且登录没过期
func terminalLoginMatches(dir: String, key: String) -> Bool {
    let isDefault = dir == defaultSlotName
    guard (isDefault ? defaultOwner() : identity(ofDir: dir))?.key == key else { return false }
    return ((try? readLogin(KeychainStore(), isDefault ? .defaultSlot : .account(dir))) ?? nil) != nil
}

/// 打开终端前整理它的目录：接上共享的技能、插件、对话记录等；把默认配置里的 MCP 服务器带过来。
/// 只动这个终端自己的 .claude.json，登录信息和它里面自己加的服务器保持原样。
func prepareTerminalDir(_ dir: String) throws {
    try prepareAccountDir(dir)
    let path = dir + "/.claude.json"
    let mirrorFile = (dir as NSString).deletingLastPathComponent + "/mirrored-mcp.json"
    let source = readProfile(Slot.defaultSlot.globalConfig) ?? [:]
    let lock = try CcLock(path: path + ".lock", stale: 10, wait: 8)
    defer { lock.release() }
    var doc: [String: Any] = [:]
    if let d = FileManager.default.contents(atPath: path) {
        guard let parsed = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }   // 读不懂就不动
        doc = parsed
    }
    let before = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()

    let wanted = source["mcpServers"] as? [String: Any] ?? [:]
    let old = (FileManager.default.contents(atPath: mirrorFile).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String]) ?? []
    var servers = doc["mcpServers"] as? [String: Any] ?? [:]
    for name in old where wanted[name] == nil { servers.removeValue(forKey: name) }
    for (name, v) in wanted { servers[name] = v }
    if !servers.isEmpty || doc["mcpServers"] != nil { doc["mcpServers"] = servers }
    if doc["hasCompletedOnboarding"] == nil { doc["hasCompletedOnboarding"] = true }
    if doc["theme"] == nil, let t = source["theme"] { doc["theme"] = t }

    let after = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    if after != before {
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmp = path + ".cab-tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        if rename(tmp, path) != 0 { throw SwitchError("写入 \(path) 失败") }
    }
    try JSONSerialization.data(withJSONObject: wanted.keys.sorted()).write(to: URL(fileURLWithPath: mirrorFile))
}

// MARK: - 现在开着哪些终端

/// 启动脚本在换成 claude 之前，往这里写一个以进程号命名的小文件
var runningDir: String { supportDir + "/running" }

struct RunningTerminal: Equatable {
    let mode: TerminalMode
    let accountId: String
}

func processStartTime(_ pid: pid_t) -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_stat != SZOMB else { return nil }
    let t = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
}

/// 还开着的终端。进程没了、或者进程号已经被别的程序用了（它比记录文件还新），记录顺手删掉。
func runningTerminals() -> [RunningTerminal] {
    let fm = FileManager.default
    var out: [RunningTerminal] = []
    for name in (try? fm.contentsOfDirectory(atPath: runningDir)) ?? [] {
        let path = runningDir + "/" + name
        let parts = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|") ?? []
        guard let pid = pid_t(name), parts.count == 2, let mode = TerminalMode(rawValue: parts[0]),
              let started = processStartTime(pid),
              let written = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              started <= written.addingTimeInterval(1) else { try? fm.removeItem(atPath: path); continue }
        out.append(RunningTerminal(mode: mode, accountId: parts[1]))
    }
    return out
}

/// 切换到某个账号会影响哪些开着的终端；不影响任何终端时返回 nil
func switchWarning(target: Account, name: String, terminals: [RunningTerminal]) -> String? {
    let offline = terminals.filter { $0.mode == .shared && $0.accountId == target.id }.count
    let follow = terminals.filter { $0.mode == .live }.count
    var lines: [String] = []
    if offline > 0 { lines.append("• \(offline) 个用「\(name)」开着的终端会掉线（它的登录要搬到默认位置）。") }
    if follow > 0 { lines.append("• \(follow) 个跟着默认登录的终端，下一条消息起改用「\(name)」。") }
    return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n\n完全独立的终端不受影响。"
}

// MARK: - 让终端的登录保持有效

extension Model {
    /// 没在用的登录放久了会过期：每 12 小时让 Claude 自己查一次额度（不花额度），顺便续上
    func keepTerminalLogins() async {
        guard !Model.readOnly, !refreshing, let claude = claudePath else { return }
        if testRoot != nil, !claude.hasPrefix(home + "/") { return }     // 沙盒里只用假 claude
        let kc = KeychainStore()
        let due = store.accounts.filter { a in
            if let t = store.terminalKept?[a.id], Date().timeIntervalSince(t) < 12 * 3600 { return false }
            return FileManager.default.fileExists(atPath: terminalDir(a)) && kc.exists(.account(terminalDir(a)))
        }
        guard !due.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        for a in due {
            var kept = store.terminalKept ?? [:]
            kept[a.id] = Date()
            store.terminalKept = kept
            save()
            await runUsage(claude: claude, configDir: terminalDir(a))
        }
    }
}
