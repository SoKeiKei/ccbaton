import SwiftUI
import ServiceManagement

// 开机启动：用系统正规的登录项接口（SMAppService），在"系统设置 → 通用 → 登录项"里能看到、能关。
// 注册的是"当前运行的这份 CCBaton.app"，所以要从固定的位置（比如"应用程序"文件夹）运行它再开启；
// 放在外接盘上的话，开机时盘没挂载好就会悄悄启动失败。

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var enabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static var statusText: String {
        switch status {
        case .enabled: return "已开启"
        case .notRegistered: return "未开启"
        case .requiresApproval: return "需要在系统设置 → 通用 → 登录项 里允许"
        case .notFound: return "未开启"            // 系统对"从没注册过"的应用返回 notFound，等同于未开启
        @unknown default: return "未知状态"
        }
    }

    /// 命令行：CCBaton --login-item on | off | status
    static func runCLI(_ arg: String) -> Int32 {
        do {
            switch arg {
            case "on": try set(true)
            case "off": try set(false)
            case "status": break
            default: print("用法：--login-item on | off | status"); return 2
            }
            print("开机启动：\(statusText)（\(Bundle.main.bundlePath)）")
            return (arg == "on" && !enabled && !needsApproval) ? 1 : 0
        } catch {
            print("开机启动设置失败：\(error.localizedDescription)")
            return 1
        }
    }
}
