import SwiftUI
import AppKit
import SQLite3

// 桌面端账号切换的测试：全部在沙盒里（必须设 CAB_TEST_ROOT），用假的桌面端数据目录和假的 Claude 进程，
// 不碰真实的 Claude。"用户登录"由测试直接改 config.json 和 Cookies 来模拟。

@MainActor
func runDesktopTest() -> Int32 {
    guard let root = testRoot else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    @discardableResult func waitFor(_ secs: TimeInterval = 8, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(secs)
        while !cond() && Date() < end { spin(0.02) }
        return cond()
    }
    _ = NSApplication.shared
    Model.readOnly = true
    let fm = FileManager.default
    let dd = desktopDataDir
    try? fm.createDirectory(atPath: dd, withIntermediateDirectories: true)

    // —— 造数据 ——
    func makeCookies(_ path: String, _ names: [String]) {
        try? fm.removeItem(atPath: path); try? fm.removeItem(atPath: path + "-journal")
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, "CREATE TABLE cookies (host_key TEXT, name TEXT, value BLOB)", nil, nil, nil)
        for n in names { sqlite3_exec(db, "INSERT INTO cookies VALUES ('.claude.ai', '\(n)', x'00')", nil, nil, nil) }
        sqlite3_close(db)
    }
    /// 桌面端的登录状态：uuid 为 nil 表示没登录。token 用来分辨是哪一份；legacy 是旧的 oauth:tokenCache 键
    func setDesktop(uuid: String?, token: String = "", legacy: Bool = false, cookies: [String] = ["sessionKey", "other"]) {
        var cfg: [String: Any] = ["theme": "dark", "bootSidebarPlaceholder": "side", "windowWidth": 1200]
        if let uuid { cfg["lastKnownAccountUuid"] = uuid; cfg["oauth:tokenCacheV2"] = "v2-" + token; if legacy { cfg["oauth:tokenCache"] = "v1-" + token } }
        try? JSONSerialization.data(withJSONObject: cfg).write(to: URL(fileURLWithPath: dd + "/config.json"))
        if uuid == nil { for f in desktopCookieFiles { try? fm.removeItem(atPath: dd + "/" + f) } }
        else { makeCookies(dd + "/Cookies", cookies) }
    }
    func cfg() -> [String: Any] { readProfile(dd + "/config.json") ?? [:] }
    func token() -> String? { (cfg()["oauth:tokenCacheV2"] as? String) }
    func slotCfg(_ a: Account) -> [String: Any] { readProfile(desktopSlot(a) + "/config.json") ?? [:] }
    func makeAccount(_ id: String, uuid: String, org: String = "org1") -> Account {
        let dir = root + "/accts/\(id)"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let doc: [String: Any] = ["oauthAccount": ["accountUuid": uuid, "organizationUuid": org, "emailAddress": "\(id)@example.com"]]
        try? JSONSerialization.data(withJSONObject: doc).write(to: URL(fileURLWithPath: dir + "/.claude.json"))
        return Account(id: id, label: id.uppercased(), configDir: dir)
    }
    let A = makeAccount("a", uuid: "uuid-a"), B = makeAccount("b", uuid: "uuid-b"), C = makeAccount("c", uuid: "uuid-c")

    // 假的 Claude 进程
    final class FakeApp { var running = true; var quits = 0; var launches = 0; var refuse = false; var onQuit: () -> Void = {} }
    let app = FakeApp()
    let m = Model()
    m.store.accounts = [A, B, C]
    m.desktopIsRunning = { app.running }
    m.desktopQuit = { app.quits += 1; app.onQuit(); if app.refuse { return false }; app.running = false; return true }
    m.desktopLaunch = { app.launches += 1; app.running = true }
    var told: [String] = []
    m.tellUser = { t, _ in told.append(t) }
    var confirms = 0, confirmAnswer = true
    m.confirmDesktop = { _, _ in confirms += 1; return confirmAnswer }
    m.desktopPollInterval = 0.01
    m.desktopCookieWait = 0.2
    // 每个流程结束都会重新读一遍账号状态（沙盒里没有钥匙串登录，会读成未登录），所以每次用之前重新摆好
    func setStates() { for a in [A, B, C] { m.states[a.id] = { var s = AccountState(); s.loggedIn = true; s.email = a.id + "@example.com"; return s }() } }
    setStates()
    func reset() { setStates(); app.running = true; app.quits = 0; app.launches = 0; app.refuse = false; app.onQuit = {}; told = []; confirms = 0; confirmAnswer = true; m.notice = nil }
    func ownerId() -> String? { if case .account(let o) = m.desktopOwnerState { return o.id }; return nil }
    func sameBytes(_ p: String, _ q: String) -> Bool { fm.contents(atPath: p) == fm.contents(atPath: q) && fm.contents(atPath: p) != nil }

    var done = false
    print("— 总开关")
    check("新装默认关：存档里没有这个字段，等于关", m.store.desktopEnabled == nil && m.desktopOn == false)
    setDesktop(uuid: "uuid-a", token: "off1", legacy: true)
    try? DesktopFiles.capture(from: dd, to: desktopSlot(A))
    setDesktop(uuid: "uuid-b", token: "off2"); try? DesktopFiles.capture(from: dd, to: desktopSlot(B))
    setDesktop(uuid: "uuid-a", token: "off1", legacy: true); m.reloadDesktop(); setStates()
    check("关着：装了桌面端能识别（设置里才有这个开关），但界面里不出现任何桌面端操作",
          m.desktopPresent && !m.desktopAvailable && m.desktopStatus(for: A) == .hidden && m.desktopAction(for: B) == .hidden)
    check("关着：不去读桌面端是谁在用，也不记哪些账号保存过", m.desktopOwnerState == .none && m.desktopSaved.isEmpty)
    let offBefore = (fm.contents(atPath: dd + "/config.json"), fm.contents(atPath: dd + "/Cookies")); reset(); done = false
    Task { await m.switchDesktop(to: B); await m.captureDesktop(A); await m.loginDesktop(C); done = true }; waitFor { done }
    check("关着：切换、保存、登录三个操作都直接不做（不弹窗、不退出 Claude、不改文件）",
          confirms == 0 && app.quits == 0 && app.launches == 0 && fm.contents(atPath: dd + "/config.json") == offBefore.0 && fm.contents(atPath: dd + "/Cookies") == offBefore.1)
    let alertsOff = alertsToFire(accounts: [A, B], states: ["a": { var x = AccountState(); x.loggedIn = true; x.live = true; return x }(), "b": { var x = AccountState(); x.loggedIn = true; x.fiveHour = 95; x.fiveReset = Date().addingTimeInterval(3600); return x }()], alerted: [], name: { $0.label })
    check("关着：桌面端在用的账号不单独提醒（和 1.4 一样只看终端）", alertsOff.isEmpty)
    m.desktopFlow = DesktopFlow(text: "x"); m.setDesktopOn(true)
    check("桌面端操作进行中：开关不能动", m.desktopOn == false)
    m.desktopFlow = nil
    m.setDesktopOn(true); setStates()
    check("打开：桌面端的状态和按钮出现，认得出谁在用", m.desktopAvailable && m.store.desktopEnabled == true && ownerId() == "a" && m.desktopAction(for: B) == .switchTo)
    var persisted = Store(accounts: [], workDir: "/x"); persisted.desktopEnabled = true
    let back = (try? JSONEncoder().encode(persisted)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
    check("开关存得下来、读得回来", back?.desktopEnabled == true)
    m.setDesktopOn(false)
    check("再关上：界面里的桌面端操作全部收起，已保存的档案不删", !m.desktopAvailable && m.desktopSaved.isEmpty && fm.fileExists(atPath: desktopSlot(A) + "/config.json"))
    m.setDesktopOn(true); setStates()

    print("— 谁在用桌面端")
    setDesktop(uuid: nil); m.reloadDesktop()
    check("没登录：没有归属，没有可用的按钮操作的前提", DesktopFiles.activeUuid() == nil && m.desktopOwnerState == .none && m.desktopAvailable)
    setDesktop(uuid: "uuid-a", token: "a1", legacy: true); m.reloadDesktop()
    check("登录的是 A：对应上 A", DesktopFiles.activeUuid() == "uuid-a" && ownerId() == "a")
    setDesktop(uuid: "uuid-zzz", token: "z"); m.reloadDesktop()
    check("登录的账号不在 CCBaton 里：归属未知", m.desktopOwnerState == .unknown("uuid-zzz"))
    let A2 = makeAccount("a2", uuid: "uuid-a", org: "org2")
    m.store.accounts = [A, A2, B, C]; setDesktop(uuid: "uuid-a", token: "a1"); m.reloadDesktop()
    check("同一个人有两个组织的账号：分不清，不乱猜", m.desktopOwnerState == .ambiguous("uuid-a"))
    m.store.accounts = [A, B, C]
    var half = cfg(); half.removeValue(forKey: "oauth:tokenCacheV2"); try? JSONSerialization.data(withJSONObject: half).write(to: URL(fileURLWithPath: dd + "/config.json"))
    check("只剩账号标识、没有令牌：当作没登录", DesktopFiles.activeUuid() == nil)

    print("— 保存和恢复")
    setDesktop(uuid: "uuid-a", token: "a1", legacy: true)
    try? DesktopFiles.capture(from: dd, to: desktopSlot(A))
    let sc = slotCfg(A)
    check("档案里只有三个登录键，没有主题之类的别的设置", Set(sc.keys) == Set(desktopAuthKeys))
    check("Cookies 一起存了", fm.fileExists(atPath: desktopSlot(A) + "/Cookies") && DesktopFiles.hasSessionCookie(in: desktopSlot(A)))
    let perm = { (p: String) in (try? fm.attributesOfItem(atPath: p)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    check("档案权限：目录 0700、文件 0600", perm(desktopSlot(A)) == 0o700 && perm(desktopSlot(A) + "/config.json") == 0o600 && perm(desktopSlot(A) + "/Cookies") == 0o600)
    check("存档案没有改动桌面端自己的文件", token() == "v2-a1")
    setDesktop(uuid: "uuid-b", token: "b1", legacy: false, cookies: ["sessionKey", "bOnly"])
    try? DesktopFiles.capture(from: dd, to: desktopSlot(B))
    check("没有旧令牌键的账号，档案里也没有它", slotCfg(B)["oauth:tokenCache"] == nil && slotCfg(B)["oauth:tokenCacheV2"] as? String == "v2-b1")
    // 当前是 B（没有旧令牌键），恢复 A：旧令牌键要写进来；再恢复 B：旧令牌键要删掉
    var other = cfg(); other["theme"] = "light"; try? JSONSerialization.data(withJSONObject: other).write(to: URL(fileURLWithPath: dd + "/config.json"))
    try? DesktopFiles.restore(from: desktopSlot(A), into: dd, expecting: "uuid-a")
    check("恢复 A：令牌和账号标识换成 A 的，别的设置（主题）不动", token() == "v2-a1" && cfg()["oauth:tokenCache"] as? String == "v1-a1" && cfg()["lastKnownAccountUuid"] as? String == "uuid-a" && cfg()["theme"] as? String == "light")
    try? DesktopFiles.restore(from: desktopSlot(B), into: dd, expecting: "uuid-b")
    check("恢复 B：A 遗留的旧令牌键被删掉", cfg()["oauth:tokenCache"] == nil && token() == "v2-b1" && cfg()["windowWidth"] as? Int == 1200)
    check("Cookies 也换成了 B 的", sameBytes(dd + "/Cookies", desktopSlot(B) + "/Cookies"))
    let before = (fm.contents(atPath: dd + "/config.json"), fm.contents(atPath: dd + "/Cookies"))
    var wrong: Error?
    do { try DesktopFiles.restore(from: desktopSlot(A), into: dd, expecting: "uuid-b") } catch { wrong = error }
    check("档案不属于要切的账号：拒绝，什么都没改", wrong != nil && fm.contents(atPath: dd + "/config.json") == before.0 && fm.contents(atPath: dd + "/Cookies") == before.1)
    var noSlot: Error?
    do { try DesktopFiles.restore(from: desktopSlot(C), into: dd, expecting: "uuid-c") } catch { noSlot = error }
    check("没保存过的账号：拒绝", noSlot != nil)
    makeCookies(dd + "/Cookies", ["other"])
    check("Cookies 里没有 sessionKey：查得出来", !DesktopFiles.hasSessionCookie(in: dd))
    try? fm.removeItem(atPath: dd + "/Cookies")
    check("没有 Cookies 文件：当作没有", !DesktopFiles.hasSessionCookie(in: dd))
    try? DesktopFiles.restore(from: desktopSlot(A), into: dd, expecting: "uuid-a")
    try? DesktopFiles.clearLogin(in: dd)
    check("清除登录：三个键和 Cookies 都没了，别的设置还在", DesktopFiles.activeUuid() == nil && cfg()["oauth:tokenCache"] == nil && !fm.fileExists(atPath: dd + "/Cookies") && cfg()["theme"] as? String == "light")

    print("— 切换桌面端")
    // 现在 A、B 有档案，C 没有。桌面端登录 A，令牌比档案里新（模拟用了一阵、令牌刷新了）
    setDesktop(uuid: "uuid-a", token: "a2", legacy: true); m.reloadDesktop(); reset()
    check("按钮：当前账号有档案是『已在用』，别的有档案的是『切换』，没档案的是『登录』",
          m.desktopAction(for: A) == .active && m.desktopAction(for: B) == .switchTo && m.desktopAction(for: C) == .login)
    var atQuit = ""
    app.onQuit = { atQuit = (cfg()["oauth:tokenCacheV2"] as? String) ?? "" }
    done = false
    Task { await m.switchDesktop(to: B); done = true }
    waitFor { done }
    check("切到 B：桌面端现在是 B", token() == "v2-b1" && cfg()["oauth:tokenCache"] == nil && ownerId() == "b")
    check("先退出、后改文件：退出时文件还是 A 的", atQuit == "v2-a2" && app.quits == 1)
    check("切走之前，A 最新的令牌（a2）存回了 A 的档案", slotCfg(A)["oauth:tokenCacheV2"] as? String == "v2-a2")
    check("切完重新打开了 Claude，提示条收起，备份已删", app.launches == 1 && app.running && m.desktopFlow == nil && !fm.fileExists(atPath: desktopBackupDir))
    check("问过用户（Claude 在运行）", confirms == 1)
    check("切回 A 也行，拿到的是刚存的新令牌", { reset(); done = false; Task { await m.switchDesktop(to: A); done = true }; waitFor { done }; return token() == "v2-a2" && cfg()["oauth:tokenCache"] as? String == "v1-a2" }())

    reset(); app.running = false; done = false
    Task { await m.switchDesktop(to: B); done = true }; waitFor { done }
    check("Claude 没开着：不弹确认、不退出、也不替用户打开", token() == "v2-b1" && confirms == 0 && app.quits == 0 && app.launches == 0 && !app.running)

    reset(); confirmAnswer = false; let tokBefore = token(); done = false
    Task { await m.switchDesktop(to: A); done = true }; waitFor { done }
    check("用户点了取消：什么都不做", token() == tokBefore && app.quits == 0 && m.desktopFlow == nil)

    reset(); app.refuse = true; let sbefore = (fm.contents(atPath: dd + "/config.json"), fm.contents(atPath: dd + "/Cookies")); done = false
    Task { await m.switchDesktop(to: A); done = true }; waitFor { done }
    check("Claude 退不出来：什么都不改、不强杀、不重复打开", fm.contents(atPath: dd + "/config.json") == sbefore.0 && fm.contents(atPath: dd + "/Cookies") == sbefore.1 && app.running && app.launches == 0)
    check("并且告诉用户原因", m.notice?.contains("没有退出") == true)

    reset(); setDesktop(uuid: "uuid-zzz", token: "z"); m.reloadDesktop(); let zbefore = fm.contents(atPath: dd + "/config.json"); done = false
    Task { await m.switchDesktop(to: A); done = true }; waitFor { done }
    check("桌面端登录的账号不在 CCBaton 里：不切走（否则会丢掉它）", fm.contents(atPath: dd + "/config.json") == zbefore && m.notice?.contains("不在 CCBaton 里") == true)
    check("已退出的 Claude 被重新打开，没有把用户晾在一边", app.running && app.launches == 1)

    reset(); m.store.accounts = [A, A2, B, C]; setDesktop(uuid: "uuid-a", token: "a3"); m.reloadDesktop(); done = false
    Task { await m.switchDesktop(to: B); done = true }; waitFor { done }
    check("同一个人有两个组织时不切走", token() == "v2-a3" && m.notice?.contains("分不清") == true)
    m.store.accounts = [A, B, C]

    // 回滚：让目标档案里的 Cookies-journal 读不了，写到一半失败
    reset(); setDesktop(uuid: "uuid-a", token: "a4", legacy: true); m.reloadDesktop()
    try? DesktopFiles.capture(from: dd, to: desktopSlot(A))
    try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: desktopSlot(B) + "/Cookies")     // 先换 Cookies 就会失败
    if !fm.fileExists(atPath: desktopSlot(B) + "/Cookies-journal") { fm.createFile(atPath: desktopSlot(B) + "/Cookies-journal", contents: Data("j".utf8)) }
    let rb = (fm.contents(atPath: dd + "/config.json"), fm.contents(atPath: dd + "/Cookies"))
    done = false
    Task { await m.switchDesktop(to: B); done = true }; waitFor { done }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: desktopSlot(B) + "/Cookies")
    check("写到一半失败：回滚，桌面端还是 A，文件和之前逐字节一致", token() == "v2-a4" && fm.contents(atPath: dd + "/Cookies") == rb.1 && cfg()["oauth:tokenCache"] as? String == "v1-a4")
    check("失败后备份已清理，并提示原因，Claude 重新打开", !fm.fileExists(atPath: desktopBackupDir) && m.notice?.contains("没有切换") == true && app.running)

    print("— 保存当前登录")
    reset(); setDesktop(uuid: "uuid-b", token: "b2"); m.reloadDesktop(); try? fm.removeItem(atPath: desktopSlot(B)); m.reloadDesktop()
    check("当前登录的账号没保存过：按钮是『保存』", m.desktopAction(for: B) == .capture)
    done = false; Task { await m.captureDesktop(B); done = true }; waitFor { done }
    check("保存后有档案、令牌是最新的，Claude 退出又重开", slotCfg(B)["oauth:tokenCacheV2"] as? String == "v2-b2" && app.quits == 1 && app.launches == 1 && token() == "v2-b2")
    setStates()
    check("保存后按钮变成『已在用』", m.desktopAction(for: B) == .active)

    print("— 在桌面端登录一次")
    func loginTest(_ title: String, target: Account, user: (@MainActor () -> Void)?, cancel: Bool = false, then verify: () -> Bool) {
        reset(); setDesktop(uuid: "uuid-a", token: "a5", legacy: true); m.reloadDesktop()
        for x in [B, C] { try? fm.removeItem(atPath: desktopSlot(x)) }
        m.reloadDesktop(); done = false
        Task { await m.loginDesktop(target); done = true }
        let waiting = waitFor { m.desktopFlow?.cancellable == true }
        check("\(title)：先退出、清掉登录、重新打开，进入等待", waiting && app.quits == 1 && app.launches == 1 && DesktopFiles.activeUuid() == nil)
        check("\(title)：开始之前，原来的账号（A）已保存", slotCfg(A)["oauth:tokenCacheV2"] as? String == "v2-a5")
        if cancel { m.cancelDesktopLogin() } else { user?() }
        waitFor { done }
        check(title, verify())
    }
    loginTest("登录对了（B）：存进 B 的档案、核对账号、Claude 重新打开", target: B, user: { setDesktop(uuid: "uuid-b", token: "b9") }) {
        slotCfg(B)["lastKnownAccountUuid"] as? String == "uuid-b" && slotCfg(B)["oauth:tokenCacheV2"] as? String == "v2-b9" && app.running && app.quits == 2 && m.desktopFlow == nil && told.isEmpty
    }
    loginTest("登录错了（登成了 C，C 在列表里）：问用户，同意就存到 C 名下，B 不受影响", target: B, user: { setDesktop(uuid: "uuid-c", token: "c9") }) {
        slotCfg(C)["oauth:tokenCacheV2"] as? String == "v2-c9" && !fm.fileExists(atPath: desktopSlot(B)) && confirms == 2
    }
    loginTest("登录错了，用户不同意：哪个档案都不动", target: B, user: { confirmAnswer = false; setDesktop(uuid: "uuid-c", token: "c9") }) {
        !fm.fileExists(atPath: desktopSlot(B)) && !fm.fileExists(atPath: desktopSlot(C)) && m.desktopFlow == nil
    }
    loginTest("登的账号不在 CCBaton 里：提示先添加，不保存", target: B, user: { setDesktop(uuid: "uuid-new", token: "n9") }) {
        told.contains("没有保存") && !fm.fileExists(atPath: desktopSlot(B)) && m.desktopFlow == nil
    }
    loginTest("中途取消：原来的账号（A）恢复回去，令牌和旧令牌键都是 A 的", target: B, user: nil, cancel: true) {
        token() == "v2-a5" && cfg()["oauth:tokenCache"] as? String == "v1-a5" && DesktopFiles.activeUuid() == "uuid-a" && app.running && m.desktopFlow == nil && !fm.fileExists(atPath: desktopSlot(B))
    }
    loginTest("cookie 迟迟没写出 sessionKey：等一阵后还是保存（令牌已经在了），不卡死", target: B, user: { setDesktop(uuid: "uuid-b", token: "b8", cookies: ["other"]) }) {
        slotCfg(B)["oauth:tokenCacheV2"] as? String == "v2-b8" && m.desktopFlow == nil
    }

    print("— 审核提出的边界情况")
    // 弹确认窗期间又点了一次：第二次必须被挡住，不能再开一个流程
    setDesktop(uuid: "uuid-a", token: "a6", legacy: true); m.reloadDesktop(); reset(); done = false
    try? DesktopFiles.capture(from: dd, to: desktopSlot(A)); try? DesktopFiles.capture(from: dd, to: desktopSlot(A))
    setDesktop(uuid: "uuid-b", token: "b6"); try? DesktopFiles.capture(from: dd, to: desktopSlot(B))
    setDesktop(uuid: "uuid-a", token: "a6", legacy: true); m.reloadDesktop(); setStates()
    m.confirmDesktop = { _, _ in confirms += 1; Task { await m.switchDesktop(to: B) }; spin(0.15); return true }
    Task { await m.switchDesktop(to: B); done = true }; waitFor { done }
    check("确认窗开着时又点一次：只跑一个流程（只退出一次、只弹一次）", app.quits == 1 && confirms == 1 && token() == "v2-b6")
    m.confirmDesktop = { _, _ in confirms += 1; return confirmAnswer }
    reset(); confirmAnswer = false; done = false; setStates()
    Task { await m.switchDesktop(to: A); done = true }; waitFor { done }
    check("用户点取消后「进行中」标记撤掉了，之后还能再点", m.desktopFlow == nil)

    // 准备弹窗时 Claude 没开，动手前用户把它打开了：动手前要再查一次，先退出再改
    var seenAtQuit = ""
    reset(); app.running = false; setDesktop(uuid: "uuid-a", token: "a8", legacy: true); m.reloadDesktop(); setStates(); done = false
    app.onQuit = { seenAtQuit = (cfg()["oauth:tokenCacheV2"] as? String) ?? "" }
    var checks = 0
    m.desktopIsRunning = { checks += 1; if checks == 2 { app.running = true }; return app.running }      // 第一次查（准备弹窗时）没开，第二次（动手前）开着了
    Task { await m.switchDesktop(to: B); done = true }; waitFor { done }
    m.desktopIsRunning = { app.running }
    check("准备时 Claude 没开、动手前被用户打开了：会去退出它，退出时文件还没被改", app.quits == 1 && seenAtQuit == "v2-a8" && token() == "v2-b6")
    check("并且改完重新打开了它", app.launches == 1 && app.running)

    // config.json 损坏：不改任何东西，Claude 被重新打开
    reset(); setDesktop(uuid: "uuid-a", token: "a9", legacy: true); m.reloadDesktop(); setStates()
    fm.createFile(atPath: dd + "/config.json", contents: Data("这不是 JSON".utf8))
    let bad = fm.contents(atPath: dd + "/config.json"); done = false
    Task { await m.switchDesktop(to: A); done = true }; waitFor { done }
    Task { await m.switchDesktop(to: B); done = true }; done = false; waitFor { done }
    check("config.json 损坏时切换：文件原样没动，Claude 还开着", fm.contents(atPath: dd + "/config.json") == bad && app.running)

    // 启动时清理上次被打断留下的备份
    setDesktop(uuid: "uuid-a", token: "a10", legacy: true); reset()
    try? DesktopFiles.backup(dir: dd, to: desktopBackupDir)
    setDesktop(uuid: "uuid-b", token: "half", legacy: false)         // 模拟写到一半崩溃：已经是别的账号的样子
    app.running = false; m.recoverDesktop()
    check("上次被打断、Claude 没开着：回滚到改动之前，并删掉备份、提示用户", token() == "v2-a10" && cfg()["oauth:tokenCache"] as? String == "v1-a10" && !fm.fileExists(atPath: desktopBackupDir) && m.notice?.contains("已恢复") == true)
    try? DesktopFiles.backup(dir: dd, to: desktopBackupDir)
    setDesktop(uuid: "uuid-b", token: "now", legacy: false); app.running = true; m.recoverDesktop()
    check("上次被打断、但 Claude 开着：不动文件，只删备份并提示", token() == "v2-now" && !fm.fileExists(atPath: desktopBackupDir) && m.notice?.contains("没有自动处理") == true)
    m.recoverDesktop()
    check("没有备份时什么都不做", token() == "v2-now")

    // 更新被挡住
    m.desktopFlow = DesktopFlow(text: "x")
    check("桌面端流程进行中：不能自动更新、不能移除账号", m.installBlocker?.contains("桌面端") == true && m.removalBusy?.contains("桌面端") == true)
    m.desktopFlow = nil

    print("— 对话列表同步")
    let sroot = dd + "/claude-code-sessions"
    try? fm.removeItem(atPath: sroot)
    func session(_ acct: String, _ org: String, _ id: String, at: Double, title: String = "t") {
        let d = "\(sroot)/\(acct)/\(org)"
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        let doc: [String: Any] = ["sessionId": "local_" + id, "cliSessionId": "cli-" + id, "lastActivityAt": at, "title": title]
        try? JSONSerialization.data(withJSONObject: doc).write(to: URL(fileURLWithPath: "\(d)/local_\(id).json"))
    }
    func sTitle(_ acct: String, _ org: String, _ id: String) -> String? { (readProfile("\(sroot)/\(acct)/\(org)/local_\(id).json")?["title"] as? String) }
    func has(_ acct: String, _ org: String, _ id: String) -> Bool { fm.fileExists(atPath: "\(sroot)/\(acct)/\(org)/local_\(id).json") }
    session("uuid-a", "orgA", "s1", at: 100, title: "A-s1"); session("uuid-a", "orgA", "s2", at: 200, title: "A-s2")
    try? fm.createDirectory(atPath: sroot + "/uuid-b/orgB", withIntermediateDirectories: true)
    var r1 = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("对方有 2 个对话、这边是空的：补上 2 个，内容一样", r1?.copied == 2 && r1?.refreshed == 0 && sTitle("uuid-b", "orgB", "s1") == "A-s1" && sTitle("uuid-b", "orgB", "s2") == "A-s2")
    check("来源那边原样没动", has("uuid-a", "orgA", "s1") && sTitle("uuid-a", "orgA", "s2") == "A-s2")
    r1 = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("再同步一次：没有新东西，什么都不做", r1?.copied == 0 && r1?.refreshed == 0)
    session("uuid-b", "orgB", "s1", at: 300, title: "B-new")
    r1 = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("这边的更新（活动时间更晚）不会被旧的覆盖", sTitle("uuid-b", "orgB", "s1") == "B-new" && r1?.refreshed == 0)
    session("uuid-a", "orgA", "s2", at: 500, title: "A-s2-newer")
    r1 = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("对方那份更新（活动时间更晚）会刷新过来", sTitle("uuid-b", "orgB", "s2") == "A-s2-newer" && r1?.refreshed == 1 && r1?.copied == 0)
    session("uuid-a", "orgA", "s3", at: 10, title: "A-s3"); session("uuid-c", "orgC", "s3", at: 900, title: "C-s3")
    r1 = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("几个来源有同一个对话：取最近活动的那份", sTitle("uuid-b", "orgB", "s3") == "C-s3")
    // 被删除的对话不复制回来
    session("uuid-c", "orgC", "s4", at: 50); fm.createFile(atPath: sroot + "/uuid-a/orgA/deleted_local_s4", contents: Data("x".utf8))
    session("uuid-a", "orgA", "s5", at: 60); fm.createFile(atPath: sroot + "/uuid-b/orgB/deleted_s5.json", contents: Data("{}".utf8))
    _ = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("别的账号里标了已删除的对话，不复制", !has("uuid-b", "orgB", "s4"))
    check("这个账号里标了已删除的对话，也不复制回来", !has("uuid-b", "orgB", "s5"))
    // 坏数据
    fm.createFile(atPath: sroot + "/uuid-a/orgA/local_bad.json", contents: Data("不是 JSON".utf8))
    fm.createFile(atPath: sroot + "/uuid-a/orgA/local_other.json", contents: Data("{\"x\": 1}".utf8))
    _ = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("坏文件和不是对话记录的文件不复制", !has("uuid-b", "orgB", "bad") && !has("uuid-b", "orgB", "other"))
    session("uuid-b", "orgB", "mine", at: 1)
    _ = try? DesktopFiles.syncSessions(into: "uuid-b")
    check("从不删除：这个账号自己的对话、其他账号的对话都还在", has("uuid-b", "orgB", "mine") && has("uuid-a", "orgA", "s1") && has("uuid-c", "orgC", "s3") && has("uuid-a", "orgA", "s2"))
    let rz = try? DesktopFiles.syncSessions(into: "uuid-zzz")
    check("这个账号在桌面端还没有目录（没登录过）：什么都不做、也不新建目录", rz?.copied == 0 && !fm.fileExists(atPath: sroot + "/uuid-zzz"))
    check("没有残留的临时文件", ((try? fm.contentsOfDirectory(atPath: sroot + "/uuid-b/orgB")) ?? []).allSatisfy { !$0.hasSuffix(".cab-tmp") })
    // 子开关：默认关，关着时切换不复制任何对话
    check("子开关默认关：存档里没有这个字段，等于关", m.store.desktopSyncSessions == nil && m.desktopSyncOn == false)
    try? fm.removeItem(atPath: sroot); session("uuid-a", "orgA", "n1", at: 7); session("uuid-a", "orgA", "n2", at: 8)
    try? fm.createDirectory(atPath: sroot + "/uuid-b/orgB", withIntermediateDirectories: true)
    reset(); setDesktop(uuid: "uuid-a", token: "sy0", legacy: true); m.reloadDesktop(); setStates(); done = false
    try? DesktopFiles.capture(from: dd, to: desktopSlot(A))
    Task { await m.switchDesktop(to: B); done = true }; waitFor { done }
    check("子开关关着：切到 B 时一个对话都不复制，提示里也不提同步", !has("uuid-b", "orgB", "n1") && !has("uuid-b", "orgB", "n2") && m.notice?.contains("补上") != true && token() == "v2-b6")
    var syncStore = Store(accounts: [], workDir: "/x"); syncStore.desktopSyncSessions = true
    let syncBack = (try? JSONEncoder().encode(syncStore)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
    check("子开关存得下来、读得回来", syncBack?.desktopSyncSessions == true)
    m.setDesktopSyncOn(true)
    check("打开子开关", m.desktopSyncOn && m.store.desktopSyncSessions == true)
    // 切换时顺带同步，提示里说一声
    reset(); setDesktop(uuid: "uuid-a", token: "sy1", legacy: true); m.reloadDesktop(); setStates(); done = false
    try? DesktopFiles.capture(from: dd, to: desktopSlot(A))
    Task { await m.switchDesktop(to: B); done = true }; waitFor { done }
    check("切到 B 时顺带把 A 的 2 个对话补进 B 的目录，提示里说了", has("uuid-b", "orgB", "n1") && has("uuid-b", "orgB", "n2") && m.notice?.contains("补上了其他账号的 2 个对话") == true)
    check("补完才重新打开 Claude（Claude 不会在读目录时被改）", app.running && app.launches == 1)
    m.setDesktopSyncOn(false)
    check("再关上子开关，已经复制过去的记录不会被删（从不删除）", !m.desktopSyncOn && has("uuid-b", "orgB", "n1") && has("uuid-b", "orgB", "n2"))
    try? fm.removeItem(atPath: sroot)

    print("— 提醒和账号数据")
    reset(); setDesktop(uuid: "uuid-b", token: "b1"); m.reloadDesktop()
    var sb = AccountState(); sb.loggedIn = true; sb.fiveHour = 92; sb.fiveReset = Date().addingTimeInterval(3600); sb.sevenDay = 10; sb.sevenReset = Date().addingTimeInterval(86400)
    var sa = AccountState(); sa.loggedIn = true; sa.live = true; sa.fiveHour = 10; sa.sevenDay = 10
    let none = alertsToFire(accounts: [A, B], states: ["a": sa, "b": sb], alerted: [], name: { $0.label })
    let withDesktop = alertsToFire(accounts: [A, B], states: ["a": sa, "b": sb], alerted: [], name: { $0.label }, also: ["b"])
    check("终端在用 A、桌面端在用 B：B 用到 92% 只在算上桌面端时才提醒", none.isEmpty && withDesktop.count == 1 && withDesktop[0].title.contains("B"))
    var encoded = Store(accounts: [A], workDir: "/x")
    check("账号数据结构没有新增字段（旧版文件照常读，新版文件旧版也能读）", (try? JSONEncoder().encode(encoded)).map { String(decoding: $0, as: UTF8.self).contains("desktop") == false } == true)
    encoded.showRemaining = nil

    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
