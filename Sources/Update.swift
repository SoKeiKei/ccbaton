import SwiftUI
import AppKit
import CryptoKit

// 软件更新：问 GitHub Releases 有没有新版；用户点"更新"后下载、核对签名、替换自己、重新打开。
// 不需要自己的服务器。两道关：
//   1. 只安装用发布钥匙签过名的安装包（公钥写在下面，私钥只在作者电脑的钥匙串里），
//      就算 GitHub 账号被盗，传上去的假安装包也装不进来。
//   2. 新版装上后要自己"报到"，一段时间内没启动起来就换回旧版。

let updateFeedURL = URL(string: "https://api.github.com/repos/SoKeiKei/ccbaton/releases/latest")!
let releasesPageURL = URL(string: "https://github.com/SoKeiKei/ccbaton/releases/latest")!
/// 发布钥匙的公钥（tools/release-key.swift 生成；换钥匙的话，旧版本的用户只能手动更新一次）
let updatePublicKey = "BleAkCh/9liTo4AJFfKwHvDs90XAdg9jjCfxu0bf/lY="
let appBundleId = "local.ccbaton"

struct AppRelease: Codable, Equatable {
    var version: String
    var page: URL               // 这一版的说明页
    var zip: URL?               // 自动更新用的安装包和它的签名；缺任何一个就只能手动下载
    var signature: URL?
}

enum UpdatePhase: Equatable {
    case idle, checking, upToDate, downloading, installing
    case failed(String)
}

// MARK: - 版本号、版本信息

func versionNumbers(_ s: String) -> [Int]? {
    let text = s.hasPrefix("v") ? String(s.dropFirst()) : s
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { part in part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil }
    return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
}

/// a 比 b 新（1.10.0 比 1.9.0 新；1.3 和 1.3.0 一样）
func isNewer(_ a: String, than b: String) -> Bool {
    guard var x = versionNumbers(a), var y = versionNumbers(b) else { return false }
    while x.count < y.count { x.append(0) }
    while y.count < x.count { y.append(0) }
    return y.lexicographicallyPrecedes(x)
}

/// 读 GitHub "最新发布"接口的返回。草稿、预发布、版本号看不懂的都当没有
func parseRelease(_ data: Data) -> AppRelease? {
    guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          d["draft"] as? Bool != true, d["prerelease"] as? Bool != true,
          let tag = d["tag_name"] as? String, versionNumbers(tag) != nil else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    func trusted(_ text: String?) -> URL? {                 // 只认 github.com 上的 https 地址
        guard let text, let u = URL(string: text), u.scheme == "https", u.host == "github.com" else { return nil }
        return u
    }
    let assets = d["assets"] as? [[String: Any]] ?? []
    func asset(_ name: String) -> URL? { trusted(assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String) }
    let zip = "CCBaton-\(version)-macos.zip"
    return AppRelease(version: version, page: trusted(d["html_url"] as? String) ?? releasesPageURL, zip: asset(zip), signature: asset(zip + ".sig"))
}

/// 现在该不该自动检查：这次开机还没查成功过就查；之后每天最多一次。没查成（比如刚开机没网）隔 10 分钟再试
func shouldAutoCheck(enabled: Bool, boot: Date, lastSuccess: Date?, lastAttempt: Date?, now: Date = Date()) -> Bool {
    guard enabled else { return false }
    if let t = lastAttempt, now.timeIntervalSince(t) < 600 { return false }
    guard let s = lastSuccess, s >= boot, s <= now else { return true }
    return now.timeIntervalSince(s) >= 86400
}

func systemBootTime() -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return .distantPast }
    return Date(timeIntervalSince1970: Double(tv.tv_sec))
}

// MARK: - 核对安装包

/// 签名文件里是 base64 文字
func verifySignature(_ data: Data, signature: Data, publicKey: String) -> Bool {
    guard let key = Data(base64Encoded: publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
          let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return key.isValidSignature(sig, for: data)
}

@discardableResult
func runTool(_ path: String, _ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// 解出来的应用能不能装；能装返回 nil。版本必须就是说好的那一版、而且比现在新（不让用旧包冒充新版）
func checkBundle(_ path: String, expected: String, current: String) -> String? {
    guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] else { return "安装包里没有应用" }
    guard info["CFBundleIdentifier"] as? String == appBundleId else { return "安装包里不是 CCBaton" }
    guard let v = info["CFBundleShortVersionString"] as? String, v == expected, isNewer(v, than: current) else { return "安装包的版本号对不上" }
    if let need = (info["LSMinimumSystemVersion"] as? String).flatMap(versionNumbers) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if [os.majorVersion, os.minorVersion, os.patchVersion].lexicographicallyPrecedes(need) { return "新版需要更高版本的 macOS" }
    }
    guard let exe = info["CFBundleExecutable"] as? String, FileManager.default.isExecutableFile(atPath: path + "/Contents/MacOS/" + exe),
          runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", path]) == 0 else { return "安装包不完整或被改动过" }
    return nil
}

/// 命令行 --check-update：问一次 GitHub，打印最新版本和能不能自动更新
func runUpdateCheckCLI() -> Int32 {
    let done = DispatchSemaphore(value: 0)
    var request = URLRequest(url: updateFeedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
    request.setValue("CCBaton/\(appVersion)", forHTTPHeaderField: "User-Agent")
    var code: Int32 = 1
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { done.signal() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let data, status == 200, let r = parseRelease(data) else { print("没查到版本信息（\(error?.localizedDescription ?? "HTTP \(status)")）"); return }
        print("现在 \(appVersion)，GitHub 最新 \(r.version)：\(isNewer(r.version, than: appVersion) ? "有新版本" : "已是最新")")
        print(r.zip != nil && r.signature != nil ? "这一版带签名，可以自动更新" : "这一版没带签名，只能手动下载")
        code = 0
    }.resume()
    _ = done.wait(timeout: .now() + 40)
    return code
}

// MARK: - 替换自己

var updateDir: String { supportDir + "/update" }

/// 在程序退出后接手的脚本。参数：旧进程号、新版应用、要替换的位置、工作目录、最多等几秒、打开方式（空 = 用系统打开）
let updateHelperScript = #"""
#!/bin/sh
# CCBaton 更新脚本：等旧程序退出 → 换上新版 → 打开；新版没有报到就换回旧版
pid="$1"; new="$2"; target="$3"; work="$4"; wait_s="$5"; launcher="$6"
backup="$work/backup.app"; ok="$work/started"; log="$work/install.log"
say() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$log"; }
case "$target" in /*.app) ;; *) say "路径不对：$target"; exit 2 ;; esac
[ -d "$new" ] || { say "找不到新版"; exit 2; }
launch() { if [ -n "$launcher" ]; then "$launcher" "$target"; else /usr/bin/open -n "$target"; fi; }
n=0
while kill -0 "$pid" 2>/dev/null; do
  n=$((n+1)); [ $n -gt $((wait_s*5)) ] && { say "旧程序没有退出，放弃"; exit 3; }; sleep 0.2
done
rm -rf "$backup" "$ok"
mv "$target" "$backup" 2>>"$log" || { say "旧版挪不走"; launch; exit 4; }
if ! /usr/bin/ditto "$new" "$target" 2>>"$log"; then
  say "新版放不进去，换回旧版"; rm -rf "$target"; mv "$backup" "$target"; launch; exit 5
fi
launch
n=0
while [ ! -e "$ok" ]; do
  n=$((n+1))
  if [ $n -gt $((wait_s*5)) ]; then
    say "新版没有启动起来，换回旧版"
    /usr/bin/pkill -f "^$target/Contents/MacOS/"; sleep 1
    rm -rf "$target"; mv "$backup" "$target"; launch; exit 6
  fi
  sleep 0.2
done
say "更新完成"
rm -rf "$backup" "$work/staging" "$work/download.zip"
"""#

private struct PendingUpdate: Codable { var version: String }

extension Model {
    var autoUpdateOn: Bool { store.autoUpdateCheck ?? true }

    func setAutoUpdate(_ on: Bool) {
        store.autoUpdateCheck = on
        updateAttemptAt = nil
        save()
        if on { Task { await updateTick() } }
    }

    /// 已经发现、而且比现在新的版本
    var availableUpdate: AppRelease? {
        guard let r = store.updateRelease, isNewer(r.version, than: currentVersion) else { return nil }
        return r
    }

    private var updateInProgress: Bool { updatePhase == .checking || updatePhase == .downloading || updatePhase == .installing }

    func checkForUpdate(manual: Bool) async {
        guard !updateInProgress else { return }
        updatePhase = .checking
        updateAttemptAt = Date()
        do {
            let (data, status) = try await fetchData(updateFeedURL)
            if status == 403 || status == 429 { throw SwitchError("GitHub 暂时限制了访问，过一会儿再试") }
            guard status == 200, let r = parseRelease(data) else { throw SwitchError("没有拿到版本信息") }
            store.updateCheckedAt = Date()
            let newer = isNewer(r.version, than: currentVersion)
            store.updateRelease = newer ? r : nil
            updatePhase = newer ? .idle : .upToDate
            save()
        } catch let e as SwitchError {
            updatePhase = manual ? .failed("\(e)") : .idle
        } catch {
            updatePhase = manual ? .failed("连不上 GitHub，检查网络后再试") : .idle
        }
    }

    /// 每分钟看一眼要不要自动检查
    func updateTick() async {
        guard !Model.readOnly, shouldAutoCheck(enabled: autoUpdateOn, boot: bootTime(), lastSuccess: store.updateCheckedAt, lastAttempt: updateAttemptAt) else { return }
        await checkForUpdate(manual: false)
    }

    /// 现在为什么不能自动安装；能装返回 nil
    var installBlocker: String? {
        let path = appBundlePath, parent = (path as NSString).deletingLastPathComponent
        let move = "请先把 CCBaton 拖进“应用程序”文件夹，从那里打开后再更新"
        if !path.hasSuffix(".app") { return "现在不是以应用方式运行的，没法自己更新" }
        if path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: parent) { return move }
        if switching { return "正在切换账号，几秒后再点" }
        if warming != nil { return "正在预热账号，几秒后再点" }
        if refreshing { return "正在读取额度，几秒后再点" }
        return nil
    }

    /// 下载、核对、交给脚本替换。成功的话程序会退出
    func installUpdate() async {
        guard !updateInProgress, let r = availableUpdate else { return }
        guard let zipURL = r.zip, let sigURL = r.signature else { openLink(r.page); return }      // 这一版没带签名：手动下载
        if let why = installBlocker { updatePhase = .failed(why); return }
        updatePhase = .downloading
        let fm = FileManager.default, work = updateDir
        do {
            try? fm.removeItem(atPath: work)
            try fm.createDirectory(atPath: work + "/staging", withIntermediateDirectories: true)
            let (zip, s1) = try await fetchData(zipURL)
            let (sig, s2) = try await fetchData(sigURL)
            guard s1 == 200, s2 == 200 else { throw SwitchError("下载失败，稍后再试") }
            guard verifySignature(zip, signature: sig, publicKey: updateKey) else { throw SwitchError("安装包的签名对不上，没有安装") }
            let zipPath = work + "/download.zip"
            try zip.write(to: URL(fileURLWithPath: zipPath))
            guard runTool("/usr/bin/ditto", ["-x", "-k", zipPath, work + "/staging"]) == 0 else { throw SwitchError("安装包解不开") }
            let new = work + "/staging/CCBaton.app"
            if let why = checkBundle(new, expected: r.version, current: currentVersion) { throw SwitchError(why + "，没有安装") }
            if let why = installBlocker { throw SwitchError(why) }         // 下载期间情况可能变了
            try JSONEncoder().encode(PendingUpdate(version: r.version)).write(to: URL(fileURLWithPath: work + "/pending.json"))
            let script = work + "/install.sh"
            try Data(updateHelperScript.utf8).write(to: URL(fileURLWithPath: script))
            updatePhase = .installing
            try startUpdateHelper(script, [String(getpid()), new, appBundlePath, work, "60", ""])
            quitForUpdate()
        } catch let e as SwitchError {
            updatePhase = .failed("\(e)")
        } catch {
            updatePhase = .failed("下载或安装没成功：\(error.localizedDescription)")
        }
    }

    /// 启动时：如果刚做过更新，向脚本报到，或者说明没成功
    func finishPendingUpdate() {
        let pending = updateDir + "/pending.json"
        guard let data = FileManager.default.contents(atPath: pending),
              let p = try? JSONDecoder().decode(PendingUpdate.self, from: data) else { return }
        try? FileManager.default.removeItem(atPath: pending)
        if p.version == currentVersion {
            FileManager.default.createFile(atPath: updateDir + "/started", contents: nil)     // 向脚本报到
            store.updateRelease = nil
            showToast("已更新到 \(currentVersion)")
            Alerter.post(title: "CCBaton 已更新", body: "现在是 \(currentVersion) 版。")
            save()
        } else {
            let text = "更新到 \(p.version) 没有成功，现在还是 \(currentVersion)"
            updatePhase = .failed(text)
            Alerter.post(title: "CCBaton 没有更新", body: text + "。")
        }
    }
}

// MARK: - 设置里的"软件更新"

/// "今天 09:30"、"昨天 21:05"、"11 月 3 日"
func pastText(_ d: Date, now: Date = Date()) -> String {
    let cal = Calendar.current, f = DateFormatter()
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
    f.dateFormat = days <= 1 ? "HH:mm" : "M 月 d 日"
    return (days <= 0 ? "今天 " : (days == 1 ? "昨天 " : "")) + f.string(from: d)
}

/// 面板右下角的版本号；有新版时前面一个红点，点一下打开设置里的更新
struct VersionTag: View {
    @ObservedObject var model: Model
    var body: some View {
        let label = Text("v\(model.currentVersion)").font(.caption2).foregroundStyle(.tertiary)
        if let r = model.availableUpdate {
            Button { SettingsController.shared.open(model) } label: {
                HStack(spacing: 4) { Circle().fill(Color.red).frame(width: 7, height: 7); label }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("有新版本 \(r.version)，点一下去更新")
            .accessibilityLabel("有新版本 \(r.version)")
        } else {
            label.help("CCBaton \(model.currentVersion)（构建 \(appBuild)）")
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var model: Model

    private var status: String {
        switch model.updatePhase {
        case .checking: return "正在检查…"
        case .downloading: return "正在下载 \(model.availableUpdate?.version ?? "")…"
        case .installing: return "正在安装，马上会重新打开…"
        case .failed(let why): return why
        case .upToDate: return "已是最新版本（\(model.currentVersion)）"
        case .idle:
            if let r = model.availableUpdate { return "发现新版本 \(r.version)" }
            guard let t = model.store.updateCheckedAt else { return "还没有检查过" }
            return "上次检查：\(pastText(t))"
        }
    }

    private var busy: Bool { [.checking, .downloading, .installing].contains(model.updatePhase) }

    var body: some View {
        let release = model.availableUpdate
        var failed = false
        if case .failed = model.updatePhase { failed = true }
        return SettingGroup(title: "软件更新", icon: "arrow.down.circle") {
            SettingSwitch(title: "自动检查更新", isOn: Binding(get: { model.autoUpdateOn }, set: { model.setAutoUpdate($0) }))
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(status).font(.system(size: 11, weight: release != nil || failed ? .medium : .regular))
                        .foregroundStyle(failed ? Color.orange : (release != nil ? Color.accentColor : Color.secondary))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let r = release, !failed {
                        Button("查看更新内容") { model.openLink(r.page) }.buttonStyle(.link).font(.system(size: 11))
                    } else if failed {
                        Button("打开下载页面") { model.openLink(releasesPageURL) }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
                Spacer(minLength: 8)
                if let r = release {
                    Button(r.zip != nil && r.signature != nil ? "更新到 \(r.version)" : "去下载 \(r.version)") { Task { await model.installUpdate() } }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy)
                } else {
                    Button("检查更新") { Task { await model.checkForUpdate(manual: true) } }.controlSize(.small).disabled(busy)
                }
            }
            .frame(height: 46, alignment: .top)      // 固定高度：设置窗口大小打开时就定了
        }
    }
}
