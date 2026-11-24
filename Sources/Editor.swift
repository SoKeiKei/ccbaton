import SwiftUI
import AppKit

// 修改账号显示名称的窗口：上面是这个账号真实登录的 Claude 信息（只读），下面填想显示的名字。
// 改的只是本程序里的显示名，不会改 Claude 的登录。

struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value.isEmpty ? "—" : value).font(.system(size: 13)).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct EditView: View {
    @ObservedObject var model: Model
    let account: Account
    let close: () -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(model: Model, account: Account, close: @escaping () -> Void) {
        self.model = model; self.account = account; self.close = close
        _name = State(initialValue: account.label)
    }

    var st: AccountState { model.states[account.id] ?? AccountState() }
    var current: Account { model.store.accounts.first { $0.id == account.id } ?? account }

    func save() { model.rename(account, to: name); close() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("真实登录的 Claude 账号", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    InfoRow(title: "邮箱", value: st.email)
                    InfoRow(title: "套餐", value: st.plan)
                    if !st.orgName.isEmpty && st.orgName != st.email && !st.orgName.hasPrefix(st.email) {
                        InfoRow(title: "组织", value: st.orgName)
                    }
                    InfoRow(title: "状态", value: st.live ? "使用中（Claude Code 现在登录的就是它）" : (st.loggedIn ? "已登录，未在使用" : "登录已失效，需要重新登录"))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("显示名称").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("想显示的名称，比如：工作、个人", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                Text("只改本程序里显示的名字，不会改动 Claude 登录。留空就显示邮箱。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            HStack {
                if !current.label.isEmpty {
                    Button("恢复默认") { name = "" ; save() }
                }
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focused = true }
    }
}

@MainActor
final class AccountEditor {
    static let shared = AccountEditor()
    private(set) var window: NSWindow?

    func open(_ model: Model, account: Account) {
        window?.close()
        let view = EditView(model: model, account: account, close: { [weak self] in
            self?.window?.close()
            self?.window = nil
        })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.sizingOptions = []                  // 窗口大小固定，不让内容的布局反过来牵着窗口走
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "修改账号名称"
        let container = NSView(frame: NSRect(origin: .zero, size: size))      // 同样套一层容器，避免 SwiftUI 自己改窗口大小
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        w.contentView = container
        w.setContentSize(size)
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating
        NSApp.activate(ignoringOtherApps: true)    // 菜单栏程序没有 Dock 图标，要主动抢到前台才能打字
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
