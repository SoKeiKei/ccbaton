import SwiftUI
import AppKit
import CryptoKit

// 软件更新的测试。只在沙盒里跑（必须设 CAB_TEST_ROOT）：不联网，用假的版本信息和测试钥匙；
// "替换自己"用沙盒里的应用副本演练，不碰真正装着的那份。

@MainActor
func runUpdateTest() -> Int32 {
    guard testRoot != nil else { print("必须设置 CAB_TEST_ROOT"); return 2 }
    var failed = 0
    func check(_ n: String, _ ok: Bool) { print(ok ? "  通过  " : "  失败  ", n); if !ok { failed += 1 } }
    func wait(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await work(); done = true }
        let end = Date().addingTimeInterval(60)
        while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if !done { check("异步操作超时", false) }
    }
    _ = NSApplication.shared
    let fm = FileManager.default

    print("— 版本号和版本信息")
    check("比大小按数字比", isNewer("1.10.0", than: "1.9.9") && isNewer("v2.0", than: "1.9.9") && isNewer("1.3.1", than: "1.3.0"))
    check("一样的和更旧的都不算新", !isNewer("1.3", than: "1.3.0") && !isNewer("1.2.9", than: "1.3.0"))
    check("看不懂的版本号不算新", !isNewer("abc", than: "1.0") && versionNumbers("1.3.0-beta") == nil && versionNumbers("1..2") == nil && versionNumbers("") == nil)
    func feed(_ v: String, sig: Bool = true, draft: Bool = false, pre: Bool = false, host: String = "https://github.com") -> Data {
        var assets: [[String: Any]] = [["name": "CCBaton-\(v)-macos.zip", "browser_download_url": "\(host)/o/r/releases/download/v\(v)/CCBaton-\(v)-macos.zip"]]
        if sig { assets.append(["name": "CCBaton-\(v)-macos.zip.sig", "browser_download_url": "\(host)/o/r/releases/download/v\(v)/CCBaton-\(v)-macos.zip.sig"]) }
        return try! JSONSerialization.data(withJSONObject: ["tag_name": "v\(v)", "draft": draft, "prerelease": pre, "html_url": "https://github.com/o/r/releases/tag/v\(v)", "assets": assets])
    }
    let r = parseRelease(feed("1.4.0"))
    check("读出版本号、安装包和签名", r?.version == "1.4.0" && r?.zip != nil && r?.signature != nil && r?.page.path.hasSuffix("v1.4.0") == true)
    check("没带签名的版本只能手动下载", parseRelease(feed("1.4.0", sig: false))?.signature == nil)
    check("草稿和预发布不算", parseRelease(feed("1.4.0", draft: true)) == nil && parseRelease(feed("1.4.0", pre: true)) == nil)
    check("不在 github.com 或不是 https 的下载地址不认", parseRelease(feed("1.4.0", host: "https://evil.example"))?.zip == nil && parseRelease(feed("1.4.0", host: "http://github.com"))?.zip == nil)
    check("乱七八糟的返回当没有", parseRelease(Data("<html>".utf8)) == nil)

    print("— 什么时候自动检查")
    let now = Date(), boot = now.addingTimeInterval(-3 * 86400)
    func due(_ success: TimeInterval?, attempt: TimeInterval? = nil, on: Bool = true, boot b: Date? = nil) -> Bool {
        shouldAutoCheck(enabled: on, boot: b ?? boot, lastSuccess: success.map { now.addingTimeInterval($0) }, lastAttempt: attempt.map { now.addingTimeInterval($0) }, now: now)
    }
    check("关了开关就不查", !due(nil, on: false))
    check("从没查过就查", due(nil))
    check("今天查过就不再查", !due(-3600))
    check("超过一天再查", due(-86401))
    check("开机后还没查过：就算一小时前查过也查", due(-3600, boot: now.addingTimeInterval(-600)))
    check("刚试过没成功，10 分钟内不重试，之后重试", !due(nil, attempt: -300) && due(nil, attempt: -601))
    check("系统时间往回调过也照常检查", due(7200))
    check("读得到开机时间", systemBootTime() < Date() && systemBootTime() > Date().addingTimeInterval(-400 * 86400))

    print("— 检查更新")
    Model.readOnly = true
    let m = Model()
    Model.readOnly = false
    m.currentVersion = "1.3.0"
    var calls = 0, reply: Result<(Data, Int), Error> = .success((feed("1.4.0"), 200))
    m.fetchData = { _ in calls += 1; return try reply.get() }
    wait { await m.checkForUpdate(manual: true) }
    check("发现新版本", m.availableUpdate?.version == "1.4.0" && m.updatePhase == .idle)
    let disk = (try? Data(contentsOf: storeURL)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
    check("结果存盘了，重开程序红点还在", disk?.updateRelease?.version == "1.4.0" && disk?.updateCheckedAt != nil)
    reply = .failure(URLError(.notConnectedToInternet))
    wait { await m.checkForUpdate(manual: true) }
    check("手动检查失败要说清楚，已发现的新版不丢", { if case .failed(let w) = m.updatePhase { return w.contains("GitHub") && m.availableUpdate != nil }; return false }())
    wait { await m.checkForUpdate(manual: false) }
    check("自动检查失败不打扰", m.updatePhase == .idle)
    reply = .success((Data(), 403))
    wait { await m.checkForUpdate(manual: true) }
    check("被限制访问时说明原因", { if case .failed(let w) = m.updatePhase { return w.contains("限制") }; return false }())
    reply = .success((feed("1.3.0"), 200))
    wait { await m.checkForUpdate(manual: true) }
    check("已是最新：红点消失", m.updatePhase == .upToDate && m.availableUpdate == nil && m.store.updateRelease == nil)

    m.store.updateCheckedAt = nil; m.updateAttemptAt = nil; calls = 0
    m.setAutoUpdate(false)
    wait { await m.updateTick() }
    check("开关关着：不查", calls == 0)
    m.store.autoUpdateCheck = true
    wait { await m.updateTick(); await m.updateTick() }
    check("开着：查一次，马上再看不重复查", calls == 1)
    m.bootTime = { Date().addingTimeInterval(1) }; m.updateAttemptAt = nil
    wait { await m.updateTick() }
    check("重新开机后再查一次", calls == 2)
    m.bootTime = systemBootTime
    Model.readOnly = true; m.store.updateCheckedAt = nil; m.updateAttemptAt = nil
    wait { await m.updateTick() }
    check("只读模式（截图、预检）不联网", calls == 2)
    Model.readOnly = false

    print("— 核对安装包")
    let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    let payload = Data("package".utf8)
    let good = Data((try! key.signature(for: payload)).base64EncodedString().utf8)
    check("签名对得上", verifySignature(payload, signature: good + Data("\n".utf8), publicKey: pub))
    check("内容被改、换了钥匙、签名是乱码：都不认",
          !verifySignature(Data("packagf".utf8), signature: good, publicKey: pub)
          && !verifySignature(payload, signature: Data((try! other.signature(for: payload)).base64EncodedString().utf8), publicKey: pub)
          && !verifySignature(payload, signature: Data("xxx".utf8), publicKey: pub))
    check("软件里写的公钥是有效的", Data(base64Encoded: updatePublicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil)

    guard Bundle.main.bundlePath.hasSuffix(".app") else { print("请用编译出的 .app 里的程序跑这个测试"); return 2 }
    let root = home + "/update-test"
    /// 复制一份正在运行的应用，改版本号等，再重新签名
    func makeApp(_ path: String, version: String, change: (inout [String: Any]) -> Void = { _ in }) {
        try? fm.removeItem(atPath: path)
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: Bundle.main.bundlePath, toPath: path)
        var info = (NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any]) ?? [:]
        info["CFBundleShortVersionString"] = version
        change(&info)
        (info as NSDictionary).write(toFile: path + "/Contents/Info.plist", atomically: true)
        runTool("/usr/bin/codesign", ["--force", "--sign", "-", path])
    }
    func version(_ app: String) -> String { (NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "" }
    let candidate = root + "/candidate/CCBaton.app"
    makeApp(candidate, version: "1.9.9")
    check("正常的新版能装", checkBundle(candidate, expected: "1.9.9", current: "1.3.0") == nil)
    check("版本号和说好的不一样：不装", checkBundle(candidate, expected: "2.0.0", current: "1.3.0") != nil)
    check("拿旧版冒充更新：不装", checkBundle(candidate, expected: "1.9.9", current: "1.9.9") != nil && checkBundle(candidate, expected: "1.9.9", current: "2.0.0") != nil)
    makeApp(candidate, version: "1.9.9") { $0["CFBundleIdentifier"] = "com.example.other" }
    check("别的软件：不装", checkBundle(candidate, expected: "1.9.9", current: "1.3.0") != nil)
    makeApp(candidate, version: "1.9.9") { $0["LSMinimumSystemVersion"] = "99.0" }
    check("系统版本不够：不装", checkBundle(candidate, expected: "1.9.9", current: "1.3.0")?.contains("macOS") == true)
    makeApp(candidate, version: "1.9.9")
    if let h = FileHandle(forWritingAtPath: candidate + "/Contents/Resources/AppIcon.icns") { h.seekToEndOfFile(); h.write(Data("x".utf8)); h.closeFile() }
    check("签名后被改动过：不装", checkBundle(candidate, expected: "1.9.9", current: "1.3.0") != nil)

    print("— 点更新")
    let installed = root + "/Applications/CCBaton.app"
    makeApp(installed, version: "1.3.0")
    func zipped(_ v: String) -> Data {
        makeApp(candidate, version: v)
        let zip = root + "/pkg.zip"
        try? fm.removeItem(atPath: zip)
        runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", candidate, zip])
        return fm.contents(atPath: zip) ?? Data()
    }
    func sign(_ d: Data, _ k: Curve25519.Signing.PrivateKey) -> Data { Data((try! k.signature(for: d)).base64EncodedString().utf8) }
    var package = zipped("1.9.9"), signature = sign(package, key), status = 200
    var helper: [(String, [String])] = [], quits = 0, fetched: [String] = [], opened: [URL] = []
    m.fetchData = { url in fetched.append(url.lastPathComponent); return (url.pathExtension == "sig" ? signature : package, status) }
    m.startUpdateHelper = { helper.append(($0, $1)) }
    m.quitForUpdate = { quits += 1 }
    m.openLink = { opened.append($0) }
    m.updateKey = pub; m.appBundlePath = installed
    func tryInstall(sig: Bool = true) -> String {
        helper = []; quits = 0; fetched = []; m.updatePhase = .idle; m.store.updateRelease = parseRelease(feed("1.9.9", sig: sig))
        try? fm.removeItem(atPath: updateDir)
        wait { await m.installUpdate() }
        if case .failed(let w) = m.updatePhase { return w }
        return ""
    }
    func nothingHappened() -> Bool { helper.isEmpty && quits == 0 && version(installed) == "1.3.0" }
    signature = sign(package, other)
    check("签名是别人的钥匙：不安装、不解压", tryInstall().contains("签名") && nothingHappened() && !fm.fileExists(atPath: updateDir + "/staging/CCBaton.app"))
    package = zipped("1.2.0"); signature = sign(package, key)
    check("签名对、但里面是旧版：不安装", tryInstall().contains("版本号") && nothingHappened())
    package = zipped("1.9.9"); signature = sign(package, key); status = 404
    check("下载失败：不安装", tryInstall().contains("下载失败") && nothingHappened())
    status = 200
    m.refreshing = true
    check("正在读额度：先不装，连下载都不开始", tryInstall().contains("读取额度") && fetched.isEmpty && nothingHappened())
    m.refreshing = false
    m.appBundlePath = "/private/var/folders/x/AppTranslocation/y/CCBaton.app"
    check("没拖进应用程序就直接运行的：提示先拖进去", tryInstall().contains("应用程序") && fetched.isEmpty)
    m.appBundlePath = installed
    _ = tryInstall(sig: false)
    check("没带签名的版本：打开下载页面让用户手动装", opened.last?.path.hasSuffix("v1.9.9") == true && fetched.isEmpty && nothingHappened())
    check("一切正常：交给脚本替换，然后退出", tryInstall() == "" && helper.count == 1 && quits == 1 && m.updatePhase == .installing)
    let args = helper.first?.1 ?? []
    check("交给脚本的内容正确", args.count == 6 && version(args.count > 1 ? args[1] : "") == "1.9.9" && args.dropFirst(2).first == installed && fm.fileExists(atPath: updateDir + "/pending.json"))

    print("— 更新脚本：换上新版，新版起不来就退回")
    let script = root + "/install.sh"
    try? Data(updateHelperScript.utf8).write(to: URL(fileURLWithPath: script))
    func finishedPid() -> String { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try? p.run(); p.waitUntilExit(); return String(p.processIdentifier) }
    func shell(_ path: String, _ text: String) { try? Data(("#!/bin/sh\n" + text).utf8).write(to: URL(fileURLWithPath: path)); try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    // 新版"报到"靠真的运行装好的程序，让它走启动时的收尾
    let reporting = root + "/open-and-report.sh", silent = root + "/open-silent.sh"
    shell(reporting, "echo x >> \(shQuote(root + "/launches"))\nCAB_TEST_ROOT=\(shQuote(home)) \"$1/Contents/MacOS/CCBaton\" --finish-update-for-test >/dev/null 2>&1\n")
    shell(silent, "echo x >> \(shQuote(root + "/launches"))\n")
    func launches() -> Int { ((try? String(contentsOfFile: root + "/launches", encoding: .utf8)) ?? "").split(separator: "\n").count }
    func runHelper(pid: String, new: String, target: String, wait seconds: Int, launcher: String) -> Int32 {
        try? fm.removeItem(atPath: root + "/launches")
        return runTool("/bin/sh", [script, pid, new, target, updateDir, String(seconds), launcher])
    }
    func prepare() -> String {
        makeApp(installed, version: "1.3.0")
        _ = tryInstall()
        return helper.first?.1[1] ?? ""
    }
    var new = prepare()
    var code = runHelper(pid: finishedPid(), new: new, target: installed, wait: 20, launcher: reporting)
    check("换上新版，新版启动后报到", code == 0 && version(installed) == "1.9.9" && launches() == 1)
    check("旧版备份和安装包清掉了", !fm.fileExists(atPath: updateDir + "/backup.app") && !fm.fileExists(atPath: updateDir + "/staging") && !fm.fileExists(atPath: updateDir + "/download.zip"))
    check("装好的应用签名完好", runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed]) == 0)
    new = prepare()
    code = runHelper(pid: finishedPid(), new: new, target: installed, wait: 2, launcher: silent)
    check("新版没启动起来：换回旧版并重新打开它", code == 6 && version(installed) == "1.3.0" && launches() == 2)
    new = prepare()
    let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]; try? sleeper.run()
    code = runHelper(pid: String(sleeper.processIdentifier), new: new, target: installed, wait: 1, launcher: silent)
    sleeper.terminate(); sleeper.waitUntilExit()
    check("旧程序一直不退出：什么都不动", code == 3 && version(installed) == "1.3.0" && launches() == 0)
    check("找不到新版：什么都不动", runHelper(pid: finishedPid(), new: root + "/nothing.app", target: installed, wait: 1, launcher: silent) == 2 && version(installed) == "1.3.0")
    check("目标不是应用路径：拒绝执行", runHelper(pid: finishedPid(), new: installed, target: home, wait: 1, launcher: silent) == 2 && fm.fileExists(atPath: installed))

    print("— 启动时的收尾")
    func pending(_ v: String) { try? fm.createDirectory(atPath: updateDir, withIntermediateDirectories: true); try? fm.removeItem(atPath: updateDir + "/started"); try? Data("{\"version\":\"\(v)\"}".utf8).write(to: URL(fileURLWithPath: updateDir + "/pending.json")) }
    m.currentVersion = "1.9.9"; m.store.updateRelease = parseRelease(feed("1.9.9")); pending("1.9.9")
    m.finishPendingUpdate()
    check("更新成功：报到、红点消失", fm.fileExists(atPath: updateDir + "/started") && m.store.updateRelease == nil && !fm.fileExists(atPath: updateDir + "/pending.json"))
    m.currentVersion = "1.3.0"; m.updatePhase = .idle; pending("1.9.9")
    m.finishPendingUpdate()
    check("退回旧版后：说明没有成功，不报到", { if case .failed(let w) = m.updatePhase { return w.contains("没有成功") && !fm.fileExists(atPath: updateDir + "/started") }; return false }())

    print("— 界面")
    Model.readOnly = true
    applyDemo(m)
    func height(_ phase: UpdatePhase, _ release: AppRelease?) -> CGFloat {
        m.updatePhase = phase; m.store.updateRelease = release
        return NSHostingView(rootView: SettingsView(model: m)).fittingSize.height
    }
    m.currentVersion = "1.3.0"
    let newer = parseRelease(feed("1.4.0"))
    let heights = [height(.idle, nil), height(.checking, nil), height(.upToDate, nil), height(.failed("连不上 GitHub，检查网络后再试"), nil),
                   height(.idle, newer), height(.downloading, newer), height(.failed("请先把 CCBaton 拖进“应用程序”文件夹，从那里打开后再更新"), newer)]
    print("        设置窗口各状态高度:", heights.map { Int($0) })
    check("设置窗口高度不随更新状态变（窗口大小打开时就定了）", Set(heights.map { Int($0.rounded()) }).count == 1)

    print(failed == 0 ? "\n全部通过" : "\n有 \(failed) 项失败")
    return failed == 0 ? 0 : 1
}
