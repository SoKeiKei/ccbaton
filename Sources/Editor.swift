import SwiftUI
import AppKit

// 编辑账号的窗口：上面是这个账号真实登录的 Claude 信息（只读），下面填显示名称、每月续期日和备注。样式见 Components.swift。
// 改的只是本程序里记的东西，不会改 Claude 的登录。

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

    /// 状态小标签：短字放标签里，完整说明放悬停提示
    private var status: (text: String, full: String, tint: Color) {
        if st.live { return ("使用中", "使用中（Claude Code 现在登录的就是它）", .green) }
        if st.loggedIn { return ("已登录，未在使用", "已登录，未在使用", .secondary) }
        return ("登录已失效", "登录已失效，需要重新登录", .orange)
    }

    private var showOrg: Bool { !st.orgName.isEmpty && st.orgName != st.email && !st.orgName.hasPrefix(st.email) }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.groupGap) {
            // 真实登录的 Claude 账号（只读）
            VStack(alignment: .leading, spacing: 8) {
                Text("真实登录的 Claude 账号").font(Look.header).foregroundStyle(.secondary).padding(.leading, 2)
                HStack(spacing: 12) {
                    Avatar(model: model, account: current, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(st.email.isEmpty ? "—" : st.email).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(st.email)
                        HStack(spacing: 6) {
                            Text(st.plan.isEmpty ? "套餐 —" : st.plan).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.primary.opacity(0.09)))
                            if showOrg {
                                Text("组织：\(st.orgName)").font(Look.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail).help(st.orgName).textSelection(.enabled)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    let s = status
                    HStack(spacing: 4) {
                        Circle().fill(s.tint == .secondary ? Color.secondary : s.tint).frame(width: 6, height: 6)
                        Text(s.text).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(s.tint == .secondary ? Color.secondary : s.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((s.tint == .secondary ? Color.primary : s.tint).opacity(0.10)))
                    .fixedSize()
                    .help(s.full)
                    .accessibilityLabel("状态：\(s.full)")
                }
                .padding(Look.rowH)
                .card()
            }

            // 本程序里记的东西：名称、续期日、备注
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("显示名称").font(Look.title)
                    TextField("想显示的名称，比如：工作、个人", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                        .onSubmit(save)
                    Text("只改本程序里显示的名字，不会改动 Claude 登录。留空就显示邮箱。")
                        .font(Look.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Look.rowH).padding(.vertical, 12)
                RowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("每月续期日").font(Look.title)
                        Spacer(minLength: 8)
                        Picker("每月续期日", selection: $renewalDay) {
                            Text("不提醒").tag(0)
                            ForEach(1...31, id: \.self) { Text("\($0) 号").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    // 随选的日期变，最长两行（窗口大小打开时就定了）
                    ReservedText(text: renewalHint, lines: 2)
                }
                .padding(.horizontal, Look.rowH).padding(.vertical, 12)
                RowDivider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("备注").font(Look.title)
                    TextEditor(text: $note)
                        .font(.system(size: 13))
                        .focused($focus, equals: .note)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(focus == .note ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: 1))
                        .accessibilityLabel("备注")
                }
                .padding(.horizontal, Look.rowH).padding(.top, 12).padding(.bottom, Look.rowH)
            }
            .card()

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
                    Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(focus == .note ? nil : .defaultAction)
                }
                // 这一行始终占着位置：窗口大小打开时就定了
                ReservedText(text: model.removalBlocker(current).map { $0 + "。" } ?? "", color: .secondary)
            }
        }
        .padding(.horizontal, Look.pad).padding(.top, 6).padding(.bottom, 14)
        .frame(width: 440)
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
        let w = makeGlassWindow(title: "编辑账号", floating: true) { view }
        NSApp.activate(ignoringOtherApps: true)    // 菜单栏程序没有 Dock 图标，要主动抢到前台才能打字
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
