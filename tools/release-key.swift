// 发布钥匙：给安装包签名。软件里写着公钥，只安装签名对得上的更新。
// 私钥只存在这台电脑的钥匙串里（读取时系统会弹窗让你确认），绝不放进项目、不上传。
//   swift tools/release-key.swift create           生成钥匙（只做一次）
//   swift tools/release-key.swift public           打印公钥
//   swift tools/release-key.swift sign <安装包>     生成 <安装包>.sig
//   swift tools/release-key.swift export <文件>     把私钥备份到文件（放到安全的地方，别放进项目）
//   swift tools/release-key.swift import <文件>     换电脑后从备份恢复
import Foundation
import CryptoKit

let service = "CCBaton-update-signing-key", account = "ccbaton"

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

@discardableResult
func security(_ arguments: [String], input: String? = nil) -> (code: Int32, out: String) {
    let p = Process(), out = Pipe(), inPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = arguments
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    do { try p.run() } catch { fail("无法运行 security") }
    if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)); try? inPipe.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func exists() -> Bool { security(["find-generic-password", "-a", account, "-s", service]).code == 0 }

func store(_ base64: String) {
    // 通过标准输入传，不让私钥出现在进程参数里；-T "" 表示任何程序读它都要弹窗问你
    security(["-i"], input: "add-generic-password -a \"\(account)\" -s \"\(service)\" -T \"\" -w \"\(base64)\"\n")
    if !exists() { fail("写入钥匙串失败") }
}

func load() -> Curve25519.Signing.PrivateKey {
    guard exists() else { fail("钥匙串里没有发布钥匙。新电脑请用 import 从备份恢复。") }
    FileHandle.standardError.write(Data("系统可能弹窗询问是否允许读取钥匙，请点“允许”。\n".utf8))
    let r = security(["find-generic-password", "-a", account, "-s", service, "-w"])
    guard r.code == 0, let raw = Data(base64Encoded: r.out), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("读不到发布钥匙") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "create":
    if exists() { fail("已经有发布钥匙了，不会覆盖") }
    let key = Curve25519.Signing.PrivateKey()
    store(key.rawRepresentation.base64EncodedString())
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(load().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]) else { fail("用法：sign <安装包>") }
    let key = load()
    let source = (try? String(contentsOfFile: "Sources/Update.swift", encoding: .utf8)) ?? ""
    if !source.contains("let updatePublicKey = \"\(key.publicKey.rawRepresentation.base64EncodedString())\"") {
        fail("这把钥匙和软件里写的公钥对不上，签了也装不上。请在项目根目录运行，并确认用的是同一把钥匙。")
    }
    guard let signature = try? key.signature(for: data), key.publicKey.isValidSignature(signature, for: data) else { fail("签名失败") }
    do { try (signature.base64EncodedString() + "\n").write(toFile: args[1] + ".sig", atomically: true, encoding: .utf8) } catch { fail("写签名文件失败") }
    print("已签名：\(args[1]).sig")
case "export":
    guard args.count == 2 else { fail("用法：export <文件>") }
    if FileManager.default.fileExists(atPath: args[1]) { fail("文件已存在，不会覆盖") }
    let text = load().rawRepresentation.base64EncodedString() + "\n"
    guard FileManager.default.createFile(atPath: args[1], contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { fail("写文件失败") }
    print("已备份到 \(args[1])。拿到这个文件的人能给你的软件发假更新，请放到安全的地方。")
case "import":
    guard args.count == 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("用法：import <文件>") }
    let base64 = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: base64), (try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)) != nil else { fail("这个文件不是发布钥匙") }
    if exists() { fail("已经有发布钥匙了，不会覆盖") }
    store(base64)
    print("已恢复")
default:
    fail("用法：create | public | sign <安装包> | export <文件> | import <文件>")
}
