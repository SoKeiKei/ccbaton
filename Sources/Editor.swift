import SwiftUI
import AppKit

// 编辑账号的窗口：上面是这个账号真实登录的 Claude 信息（只读），下面填显示名称、每月续期日和备注。
// 改的只是本程序里记的东西，不会改 Claude 的登录。

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
    @State private var renewalDay: Int          // 0 = 不提醒
    @State private var note: String
    @FocusState private var focus: Field?
    private enum Field { case name, note }

    init(model: Model, account: Account, close: @escaping () -> Void) {
        self.model = model; self.account = account; self.close = close
        _name = State(initialValue: account.label)
        _renewalDay = State(initialValue: account.renewalDay ?? 0)
        _note = State(initialValue: account.note ?? "")
    }

    private var renewalHint: String {
        guard let date = nextRenewal(day: renewalDay), let left = renewalDaysLeft(day: renewalDay) else { return "选了日期后，到期前两天起在面板和小组件上提醒。" }
        let when = left == 0 ? "就是今天" : "还有 \(left) 天"
        return "下次 \(monthDayText(date))（\(when)），提前两天提醒。" + (renewalDay > 28 ? "没有这一天的月份按月底算。" : "")
    }

    var st: AccountState { model.states[account.id] ?? AccountState() }
    var current: Account { model.store.accounts.first { $0.id == account.id } ?? account }

    func save() {
        model.rename(account, to: name)
        model.setDetails(account, renewalDay: renewalDay, note: note)
        close()
    }

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
                    .focused($focus, equals: .name)
                    .onSubmit(save)
                Text("只改本程序里显示的名字，不会改动 Claude 登录。留空就显示邮箱。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("每月续期日").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("每月续期日", selection: $renewalDay) {
                        Text("不提醒").tag(0)
                        ForEach(1...31, id: \.self) { Text("\($0) 号").tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                }
                Text(renewalHint).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).frame(height: 14, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("备注").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.system(size: 13))
                    .focused($focus, equals: .note)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 76)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(focus == .note ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: 1))
                    .accessibilityLabel("备注")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { model.requestRemoval(current) } label: {
                        Text("移除账号…").foregroundStyle(model.removalBlocker(current) == nil ? Color.red : Color.secondary)
                    }
                    .disabled(model.removalBlocker(current) != nil)
                    if !current.label.isEmpty {
                        Button("恢复默认名称") { name = "" ; save() }
                    }
                    Spacer()
                    Button("取消") { close() }.keyboardShortcut(.cancelAction)
                    // 在备注框里按回车是换行，不是保存
                    Button("保存") { save() }.keyboardShortcut(focus == .note ? nil : .defaultAction)
                }
                // 这一行始终占着位置：窗口大小打开时就定了
                Text(model.removalBlocker(current).map { $0 + "。" } ?? " ").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focus = .name }
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
        w.title = "编辑账号"
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
