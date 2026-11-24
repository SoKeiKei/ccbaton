// 切换 Claude Code 登录的引擎。
// 思路和 cc-switch 的 snapshot 模块一致（MIT 许可，参考其公开源码用 Swift 重写）：
//   每个账号有自己的 CLAUDE_CONFIG_DIR（"账号槽位"）；Claude Code 默认读的 ~/.claude 是"默认槽位"。
//   切到账号 T = 把 T 的登录"移"进默认槽位，原来在默认槽位的账号 O 收回它自己的槽位。
//   登录令牌只在钥匙串里、用系统自带的 /usr/bin/security 搬动（和 Claude Code 自己的读写方式相同），
//   本程序的任何文件里都不存令牌，只存指纹。
// 安全措施：拿 Claude Code 的刷新锁；每次写入读回校验；写之前核对没被 Claude Code 改动；
//   提交前把默认槽位原来的登录备份一份到钥匙串（ClaudeAccountBar-backup）；写日志，崩溃后补完。

import Foundation
import CryptoKit

struct SwitchError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

typealias Secret = [String: Any]

/// 跟账号走的凭据键：切换时整组搬走，其余键（mcpOAuth 等，属于这台电脑）留在原处。
let accountKeys: Set<String> = [
    "claudeAiOauth", "organizationUuid", "trustedDeviceToken", "enterpriseGateway", "designOauth",
    "trustedDeviceEnrolledAfterRefusalAtMs", "cloudSessionsOauth",
]

/// 默认 .claude.json 里跟账号走的缓存，换号后由 Claude Code 重新拉。
let accountCacheKeys = [
    "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt", "additionalModelCostsCache",
    "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster", "artifactRosterDenied",
    "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots", "autoCompactWindowsCache",
    "cachedUsageUtilization", "metricsStatusCache", "metricsStatusCacheByPrincipal",
    "githubWebConnectionStatusCache", "unusedLimitResetStatusCache", "startupPrefetchedAt",
    "cachedExtraUsageDisabledReason", "penguinModeOrgEnabled",
]

// MARK: - 槽位

enum Slot {
    case defaultSlot
    case account(String)       // CLAUDE_CONFIG_DIR

    var secureDir: String {
        switch self { case .defaultSlot: return home + "/.claude"; case .account(let d): return d }
    }
    var globalConfig: String {
        switch self { case .defaultSlot: return home + "/.claude.json"; case .account(let d): return d + "/.claude.json" }
    }
    var credentialsFile: String { secureDir + "/.credentials.json" }
    var service: String {
        switch self {
        case .defaultSlot: return servicePrefix
        case .account(let d):
            let digest = SHA256.hash(data: Data(d.utf8))
            let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            return servicePrefix + "-" + suffix
        }
    }
}

func backupSlot(_ dir: String) -> Slot { .account(dir + ".prev") }

// MARK: - 钥匙串（用 /usr/bin/security，和 Claude Code 一致）

let keychainAccount: String = {
    let u = NSUserName()
    let ok = !u.isEmpty && u.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 95 || $0 == 45 }
    return ok ? u : "claude-code-user"
}()

func runSecurity(_ args: [String], stdin: Data? = nil, timeout: TimeInterval = 5) throws -> (code: Int32, out: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let inPipe = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
    do { try p.run() } catch { throw SwitchError("无法启动 security 命令") }
    if let data = stdin {
        inPipe.fileHandleForWriting.write(data)
        try? inPipe.fileHandleForWriting.close()
    }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    if p.terminationReason == .uncaughtSignal {
        throw SwitchError("访问钥匙串超时（可能在等你确认弹窗），没有切换")
    }
    return (p.terminationStatus, data)
}

func hexEncode(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func hexDecode(_ s: String) -> Data? {
    guard s.count % 2 == 0 else { return nil }
    var out = Data(); var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
        out.append(b); i = j
    }
    return out
}

func parseSecret(_ data: Data) -> Secret? {
    (try? JSONSerialization.jsonObject(with: data)) as? Secret
}
func secretData(_ s: Secret) -> Data {
    (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
}
func sha256hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
func fingerprint(_ s: Secret) -> String { sha256hex(secretData(s)) }
func accountFingerprint(_ s: Secret) -> String { fingerprint(s.filter { accountKeys.contains($0.key) }) }

struct KeychainStore {
    func read(_ slot: Slot) throws -> Secret? {
        let r = try runSecurity(["find-generic-password", "-a", keychainAccount, "-s", slot.service, "-w"])
        switch r.code {
        case 0: break
        case 44: return try readFile(slot)
        case 36: throw SwitchError("钥匙串已锁定，请解锁后再切换")
        default: throw SwitchError("读取钥匙串失败")
        }
        let text = (String(data: r.out, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if let s = parseSecret(Data(text.utf8)) { return s }
        if let d = hexDecode(text), let s = parseSecret(d) { return s }
        throw SwitchError("Claude Code 的登录信息格式无法识别，没有做任何改动")
    }

    func write(_ slot: Slot, _ secret: Secret) throws {
        let hex = hexEncode(secretData(secret))
        let line = "add-generic-password -U -a \"\(keychainAccount)\" -s \"\(slot.service)\" -X \"\(hex)\"\n"
        let r: (code: Int32, out: Data)
        if line.utf8.count <= 4032 {
            r = try runSecurity(["-i"], stdin: Data(line.utf8))
        } else {
            r = try runSecurity(["add-generic-password", "-U", "-a", keychainAccount, "-s", slot.service, "-X", hex])
        }
        switch r.code {
        case 0: deleteFile(slot)
        case 36: throw SwitchError("钥匙串已锁定，请解锁后再切换")
        default: throw SwitchError("写入钥匙串失败")
        }
    }

    func delete(_ slot: Slot) throws {
        let r = try runSecurity(["delete-generic-password", "-a", keychainAccount, "-s", slot.service])
        switch r.code {
        case 0, 44: deleteFile(slot)
        case 36: throw SwitchError("钥匙串已锁定，请解锁后再切换")
        default: throw SwitchError("删除钥匙串条目失败")
        }
    }

    /// 只查有没有这个条目，不读内容（不会触发授权弹窗）
    func exists(_ slot: Slot) -> Bool {
        if let r = try? runSecurity(["find-generic-password", "-a", keychainAccount, "-s", slot.service]), r.code == 0 { return true }
        return FileManager.default.fileExists(atPath: slot.credentialsFile)
    }

    // Claude Code 写钥匙串失败时会退回写 .credentials.json，所以钥匙串里没有就看这个文件
    private func readFile(_ slot: Slot) throws -> Secret? {
        guard let d = FileManager.default.contents(atPath: slot.credentialsFile),
              !d.allSatisfy({ $0 == 32 || $0 == 10 || $0 == 13 || $0 == 9 }) else { return nil }
        guard let s = parseSecret(d) else { throw SwitchError("Claude Code 的登录信息格式无法识别，没有做任何改动") }
        return s
    }
    private func deleteFile(_ slot: Slot) { try? FileManager.default.removeItem(atPath: slot.credentialsFile) }

    // 提交前的整份备份（只一份，每次切换覆盖）
    func writeBackup(_ secret: Secret) throws {
        let hex = hexEncode(secretData(secret))
        let svc = servicePrefix == "Claude Code-credentials" ? "ClaudeAccountBar-backup" : "CABTEST-backup"
        let line = "add-generic-password -U -a \"\(keychainAccount)\" -s \"\(svc)\" -X \"\(hex)\"\n"
        let r: (code: Int32, out: Data)
        if line.utf8.count <= 4032 { r = try runSecurity(["-i"], stdin: Data(line.utf8)) }
        else { r = try runSecurity(["add-generic-password", "-U", "-a", keychainAccount, "-s", svc, "-X", hex]) }
        if r.code != 0 { throw SwitchError("备份当前登录失败，没有切换") }
    }
    func deleteBackup() {
        let svc = servicePrefix == "Claude Code-credentials" ? "ClaudeAccountBar-backup" : "CABTEST-backup"
        _ = try? runSecurity(["delete-generic-password", "-a", keychainAccount, "-s", svc])
    }
}

// MARK: - 和 Claude Code 共用的目录锁（兼容 proper-lockfile）

final class CcLock {
    let path: String
    private var mtime: Date?
    private var released = false

    init(path: String, stale: TimeInterval, wait: TimeInterval) throws {
        self.path = path
        let start = Date()
        var parentCreated = false
        while true {
            if mkdir(path, 0o755) == 0 { mtime = CcLock.mtimeOf(path); return }
            let e = errno
            if e == EEXIST {
                if let seen = CcLock.staleMtime(path, stale), CcLock.takeOver(path, seen) { continue }
            } else if e == ENOENT {
                let parent = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                if !parentCreated { parentCreated = true; continue }
            } else {
                throw SwitchError("无法创建锁 \(path)")
            }
            if Date().timeIntervalSince(start) >= wait {
                throw SwitchError("Claude Code 正在使用登录信息（刷新或登录中），请稍后再切换")
            }
            usleep(100_000)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        if let now = CcLock.mtimeOf(path), now == mtime { rmdir(path) }
    }
    deinit { release() }

    static func mtimeOf(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }
    static func staleMtime(_ p: String, _ stale: TimeInterval) -> Date? {
        guard let m = mtimeOf(p), Date().timeIntervalSince(m) > stale else { return nil }
        return m
    }
    static func takeOver(_ p: String, _ seen: Date) -> Bool { mtimeOf(p) == seen && rmdir(p) == 0 }
}

struct RefreshLocks {
    let a: CcLock, b: CcLock
    init(_ slot: Slot) throws {
        let dir = slot.secureDir
        a = try CcLock(path: dir + "/.oauth_refresh.lock", stale: 60, wait: 10)
        let real = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        b = try CcLock(path: real + ".lock", stale: 60, wait: 10)
    }
}
func storageLock(_ slot: Slot) throws -> CcLock {
    try CcLock(path: slot.secureDir + "/.storage-write.lock", stale: 15, wait: 10)
}

// MARK: - .claude.json 里的账号资料

func readProfile(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// 在 Claude Code 的配置锁里改 .claude.json：换 oauthAccount（nil 是删掉）、删账号缓存，其余不碰。
func writeProfile(_ path: String, account: [String: Any]?) throws {
    let lock = try CcLock(path: path + ".lock", stale: 10, wait: 8)
    defer { lock.release() }
    var doc: [String: Any]
    if let d = FileManager.default.contents(atPath: path) {
        guard let parsed = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw SwitchError("\(path) 不是 JSON 对象，没有改动")
        }
        doc = parsed
    } else { doc = [:] }
    if let a = account { doc["oauthAccount"] = a } else { doc.removeValue(forKey: "oauthAccount") }
    for k in accountCacheKeys { doc.removeValue(forKey: k) }
    if doc["hasCompletedOnboarding"] == nil { doc["hasCompletedOnboarding"] = true }
    let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let tmp = path + ".cab-tmp"
    try data.write(to: URL(fileURLWithPath: tmp))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
    if rename(tmp, path) != 0 { throw SwitchError("写入 \(path) 失败") }
}

// MARK: - 身份

struct Identity { let key: String; let email: String? }

func identity(fromProfile doc: [String: Any]?) -> Identity? {
    guard let acc = doc?["oauthAccount"] as? [String: Any] else { return nil }
    func text(_ k: String) -> String? {
        let t = (acc[k] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? nil : t
    }
    guard let uuid = text("accountUuid") else { return nil }
    return Identity(key: "\(uuid):\(text("organizationUuid") ?? "")", email: text("emailAddress"))
}
func identity(ofDir dir: String) -> Identity? { identity(fromProfile: readProfile(dir + "/.claude.json")) }
func defaultOwner() -> Identity? { identity(fromProfile: readProfile(Slot.defaultSlot.globalConfig)) }

// MARK: - 凭据工具

func merge(base: Secret?, account: Secret) -> Secret {
    var m = base?.filter { !accountKeys.contains($0.key) } ?? [:]
    for k in accountKeys { if let v = account[k] { m[k] = v } }
    return m
}
func hasLogin(_ s: Secret) -> Bool {
    let t = (s["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String
    return !(t ?? "").isEmpty
}
func loginExpiry(_ s: Secret) -> Int64? {
    guard let n = (s["claudeAiOauth"] as? [String: Any])?["refreshTokenExpiresAt"] as? NSNumber else { return nil }
    let v = n.int64Value
    return v < 100_000_000_000 ? v * 1000 : v
}
func readLogin(_ store: KeychainStore, _ slot: Slot) throws -> Secret? {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    guard let s = try store.read(slot), hasLogin(s) else { return nil }
    if let e = loginExpiry(s), e <= now { return nil }
    return s
}
func stripAccountKeys(_ store: KeychainStore, _ slot: Slot, _ secret: Secret) throws {
    let rest = secret.filter { !accountKeys.contains($0.key) }
    if rest.isEmpty { try store.delete(slot) } else { try store.write(slot, rest) }
}
func writeVerified(_ store: KeychainStore, _ slot: Slot, _ secret: Secret, failed: String) throws {
    try store.write(slot, secret)
    guard let back = try store.read(slot), fingerprint(back) == fingerprint(secret) else { throw SwitchError(failed) }
}

/// 一份登录是谁：凭据加同一目录的 .claude.json。没有登录时为 nil；有登录但认不出就报错，免得收错地方。
func ownerOf(_ secret: Secret?, _ profile: [String: Any]?) throws -> Identity? {
    guard let secret, hasLogin(secret) else { return nil }
    let found = identity(fromProfile: profile)
    let profOrg = (profile?["oauthAccount"] as? [String: Any])?["organizationUuid"] as? String
    let credOrg = secret["organizationUuid"] as? String
    let agree: Bool = { if let a = credOrg, let b = profOrg { return a == b }; return true }()
    guard let found, agree else {
        throw SwitchError("认不出 Claude Code 现在登录的是哪个账号（登录资料不完整或不一致），没有切换。运行一次 claude 让它补全资料后再试")
    }
    return found
}

// MARK: - 日志（只有指纹，没有令牌）

struct Journal: Codable {
    var target: String
    var targetDir: String
    var targetAccount: String
    var step: String        // committed / done
}
let journalURL = URL(fileURLWithPath: supportDir + "/switch-journal.json")
func saveJournal(_ j: Journal?) {
    guard let j else { try? FileManager.default.removeItem(at: journalURL); return }
    try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    try? JSONEncoder().encode(j).write(to: journalURL)
}
func loadJournal() -> Journal? {
    guard let d = try? Data(contentsOf: journalURL) else { return nil }
    return try? JSONDecoder().decode(Journal.self, from: d)
}

// MARK: - 切换

enum SwitchOutcome { case alreadyLive, switched(previous: String?) }

struct Switcher {
    let store = KeychainStore()
    /// 账号 key → 它的目录（本程序管理的账号）
    let dirOf: (String) -> String?

    /// 把账号 target（目录 targetDir）的登录移进默认槽位。
    func checkOut(target: String, targetDir: String) throws -> SwitchOutcome {
        let started = Date()
        let def = Slot.defaultSlot
        let targetSlot = Slot.account(targetDir)
        // 刷新锁：挡住 Claude Code 在我们读写之间刷新令牌（两个槽位都拿）
        let l1 = try RefreshLocks(def)
        let l2 = try RefreshLocks(targetSlot)
        defer { l1.a.release(); l1.b.release(); l2.a.release(); l2.b.release() }

        // 读默认槽位和目标的登录，核对身份
        let live = try store.read(def)
        let liveProfile = readProfile(def.globalConfig)
        let liveOwner = try ownerOf(live, liveProfile)
        if liveOwner?.key == target { return .alreadyLive }

        guard let targetSecret = try readLogin(store, targetSlot) ?? readLogin(store, backupSlot(targetDir)) else {
            throw SwitchError("这个账号的登录已失效或已过期，请重新登录它再切换")
        }
        guard let targetProfile = readProfile(targetSlot.globalConfig) else {
            throw SwitchError("读不到这个账号的资料，请重新登录它")
        }
        guard let found = try ownerOf(targetSecret, targetProfile), found.key == target else {
            throw SwitchError("这个账号的目录里现在登录的不是它（可能在它的终端里登录了别的账号），没有切换")
        }

        // 备份默认槽位原来的整份登录（只留一份，出事能手动找回）
        if let live { try store.writeBackup(live) }

        // 1. 收回：原来的号 O 写回它自己的槽位
        var previous: String? = nil
        if let live, let owner = liveOwner {
            guard let parkDir = dirOf(owner.key) else {
                throw SwitchError("默认槽位里的账号还没有收录到列表，没有切换（重新打开菜单再试）")
            }
            try park(live, liveProfile, owner: owner.key, slot: .account(parkDir))
            previous = owner.key
        }

        // 2. 提交点：在 Claude Code 的写锁里先比对再写
        if Date().timeIntervalSince(started) > 30 {
            throw SwitchError("等待 Claude Code 的锁或钥匙串太久，切换已取消，请再试一次")
        }
        let planned = merge(base: live, account: targetSecret)
        do {
            let lock = try storageLock(def)
            defer { lock.release() }
            let now = try store.read(def)
            if (now.map(fingerprint)) != (live.map(fingerprint)) {
                throw SwitchError("Claude Code 刚刚改动了登录信息，切换已取消，请再试一次")
            }
            try writeVerified(store, def, planned, failed: "写入后读回不一致，请重试")
        }
        let journal = Journal(target: target, targetDir: targetDir, targetAccount: accountFingerprint(targetSecret), step: "committed")
        saveJournal(journal)

        // 3、4：默认槽位已经是 T，切换算成了。这里失败只记日志，下次启动补完
        do { try finish(journal, targetProfile: targetProfile) } catch {
            NSLog("ClaudeAccountBar: 登录已切换，收尾没做完，稍后补完: \(error)")
        }
        return .switched(previous: previous)
    }

    /// 只读预检：做和切换一样的读取和身份核对，但不加锁、不写任何东西。返回人能读的结论（不含令牌）。
    func preflight(target: String, targetDir: String) -> String {
        do {
            let def = Slot.defaultSlot
            let live = try store.read(def)
            let liveOwner = try ownerOf(live, readProfile(def.globalConfig))
            if liveOwner?.key == target { return "已在使用中（登录在默认位置）" }
            if let o = liveOwner, dirOf(o.key) == nil { return "不能切：默认位置的账号还没有收录" }
            guard let ts = try readLogin(store, .account(targetDir)) ?? readLogin(store, backupSlot(targetDir)) else {
                return "不能切：它自己的钥匙串槽位里没有可用登录（需要重新登录）"
            }
            guard let tp = readProfile(Slot.account(targetDir).globalConfig) else { return "不能切：读不到它的资料" }
            guard let f = try ownerOf(ts, tp), f.key == target else { return "不能切：目录里登录的不是这个账号" }
            let days = loginExpiry(ts).map { Int((Double($0) / 1000 - Date().timeIntervalSince1970) / 86400) }
            return "可以切（登录有效" + (days.map { "，约 \($0) 天后到期" } ?? "") + "）"
        } catch { return "不能切：\(error)" }
    }

    /// 收回：把默认槽位里 O 的账号键写回 O 的槽位
    private func park(_ live: Secret, _ liveProfile: [String: Any]?, owner: String, slot: Slot) throws {
        let l = try RefreshLocks(slot)
        defer { l.a.release(); l.b.release() }
        let dirOwner = identity(fromProfile: readProfile(slot.globalConfig))
        if dirOwner?.key != owner, let acc = liveProfile?["oauthAccount"] as? [String: Any] {
            try writeProfile(slot.globalConfig, account: acc)
        }
        let lock = try storageLock(slot)
        defer { lock.release() }
        let existing = try store.read(slot)
        if let existing, case .account(let dir) = slot, hasLogin(existing), accountFingerprint(existing) != accountFingerprint(live) {
            // 槽位里原本还有另一份登录：挪到备份槽位留一份，不直接覆盖
            try FileManager.default.createDirectory(atPath: dir + ".prev", withIntermediateDirectories: true)
            try writeVerified(store, .account(dir + ".prev"), merge(base: nil, account: existing), failed: "备份账号原有的登录失败，没有切换")
        }
        try writeVerified(store, slot, merge(base: existing, account: live), failed: "保存原来的登录失败，没有切换")
    }

    /// 提交点之后的步骤（可重复执行）
    func finish(_ j: Journal, targetProfile: [String: Any]) throws {
        var acc = (targetProfile["oauthAccount"] as? [String: Any]) ?? [:]
        if !acc.isEmpty {
            acc["profileFetchedAt"] = Int64(Date().timeIntervalSince1970 * 1000)
            try writeProfile(Slot.defaultSlot.globalConfig, account: acc)
        }
        // 用的是备份时，备份里那份现在就在默认槽位
        let bk = backupSlot(j.targetDir)
        if let s = try store.read(bk), accountFingerprint(s) == j.targetAccount { try store.delete(bk) }
        // T 自己槽位里的账号键去掉：同一个号的令牌只留一份，免得两份各自刷新、互相作废
        let ts = Slot.account(j.targetDir)
        let lock = try storageLock(ts)
        defer { lock.release() }
        if let s = try store.read(ts), accountFingerprint(s) == j.targetAccount { try stripAccountKeys(store, ts, s) }
        var done = j; done.step = "done"
        saveJournal(done)
    }

    /// 启动时补完上次没做完的切换
    func recover() {
        guard let j = loadJournal(), j.step == "committed" else { return }
        if let cur = try? store.read(.defaultSlot), accountFingerprint(cur) == j.targetAccount,
           let tp = readProfile(Slot.account(j.targetDir).globalConfig) {
            try? finish(j, targetProfile: tp)
        } else {
            saveJournal(nil)
        }
    }
}
