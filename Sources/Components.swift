import SwiftUI
import AppKit

// 设置、编辑账号、打开终端三个窗口共用的一套样式。
// 质感跟菜单栏面板一致：毛玻璃窗口底 + 半透明圆角卡片 + 细描边。
// 规则：
//   - 窗口四周留 20，分组之间 18，卡片里每行左右 14、上下 10，行与行之间一条细线
//   - 字号只用三档：行标题 13，分组标题 12 粗，说明 11
//   - 颜色只表达状态：蓝 = 可操作 / 进行中，橙 = 风险和出错，绿 = 安全；其余一律灰阶
//   - 窗口大小打开时就定了：打开后会变的文字用 ReservedText 预留行数

enum Look {
    static let pad: CGFloat = 20             // 窗口四周
    static let groupGap: CGFloat = 18        // 分组之间
    static let rowH: CGFloat = 14            // 行内左右
    static let rowV: CGFloat = 10            // 行内上下
    static let radius: CGFloat = 12          // 卡片圆角，和面板的账号卡片一样
    static let title = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let header = Font.system(size: 12, weight: .semibold)
}

extension View {
    /// 卡片底：和面板账号卡片同一种半透明底加细描边。tint 不为空时整张卡片带一点状态色
    func card(tint: Color? = nil, radius: CGFloat = Look.radius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(tint.map { $0.opacity(0.10) } ?? Color.primary.opacity(0.045)))
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.28) } ?? Color.primary.opacity(0.08), lineWidth: 0.8))
    }
}

/// 分组标题前的小方块图标（系统设置的做法，颜色压得比较淡）
struct IconTile: View {
    let icon: String
    let tint: Color
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: icon).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// 一个分组：图标 + 标题，下面一张卡片，卡片里的行用 RowDivider 隔开
struct FormSection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconTile(icon: icon, tint: tint)
                Text(title).font(Look.header).foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }
}

/// 卡片里两行之间的细线（左边让出行内边距，和系统设置一样）
struct RowDivider: View {
    var inset: CGFloat = Look.rowH
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.8).padding(.leading, inset)
    }
}

/// 只用于 README 截图：离屏渲染时程序不在前台，系统开关画不出开着的蓝色，按系统样式画一个
private struct ShotSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule().fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: 32, height: 18)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(Color.white).frame(width: 16, height: 16).padding(1)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            }
    }
}

/// 行尾的开关
struct SwitchControl: View {
    let title: String
    let isOn: Binding<Bool>
    var body: some View {
        Group {
            if Model.demo { Toggle(title, isOn: isOn).toggleStyle(ShotSwitchStyle()) }
            else { Toggle(title, isOn: isOn).toggleStyle(.switch).controlSize(.small) }
        }
        .labelsHidden()
        .frame(height: 22)      // 系统开关进窗口前后量出来的高度不一样，固定行高，窗口大小才对得上
    }
}

/// 预留固定行数的文字：内容在窗口打开后会变（状态、出错原因），窗口不会跟着长高，
/// 所以按最多几行先把位置占好。center = 只有一行时在预留的位置里上下居中（状态条用）
struct ReservedText: View {
    let text: String
    var lines: Int = 1
    var font: Font = Look.caption
    var color: Color = .secondary
    var center = false
    var body: some View {
        if center {
            ZStack(alignment: .leading) {
                Text("占").font(font).lineLimit(lines, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                    .hidden().accessibilityHidden(true)
                Text(text).font(font).foregroundStyle(color).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text).font(font).foregroundStyle(color).lineLimit(lines, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// 行标题旁的 i：点开弹出详细说明（鼠标停住也有提示）。长解释放这里，正文只留一句
struct InfoButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("说明")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading).padding(14)
        }
    }
}

/// 卡片里的一行：左边标题（可带一句说明、一个"实验"之类的小标签、一个 i），右边控件
struct FormRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = .secondary
    var subtitleLines: Int? = nil           // 打开后会变的说明：预留几行；nil 表示固定文字，有几行占几行
    var badge: String? = nil
    var info: String? = nil
    var indent: CGFloat = 0
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(Look.title).fixedSize(horizontal: false, vertical: true)
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    if let info { InfoButton(text: info) }
                }
                if let subtitle {
                    if let n = subtitleLines { ReservedText(text: subtitle, lines: n, color: subtitleColor) }
                    else { Text(subtitle).font(Look.caption).foregroundStyle(subtitleColor).fixedSize(horizontal: false, vertical: true) }
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, Look.rowH + indent).padding(.trailing, Look.rowH)
        .padding(.vertical, Look.rowV)
        .frame(minHeight: 42)
    }
}

/// 色块提示条：图标 + 文字，用于风险提示和状态（不靠颜色也能看出意思，文字本身说清楚）
struct Callout: View {
    let icon: String
    let text: String
    let tint: Color
    var lines: Int = 1
    var weight: Font.Weight = .regular
    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
            ReservedText(text: text, lines: lines, font: .system(size: 11, weight: weight), color: tint, center: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10)))
    }
}

// MARK: - 窗口

/// 三个窗口共用的毛玻璃窗口：标题栏透明、底色延伸到标题栏下面，和菜单栏面板同一种材质。
/// 窗口大小在打开时按内容量好就固定（sizingOptions = []），打开后内容变化不会撑开窗口。
/// scrollIfTall：屏幕放不下时改成能上下滚（设置窗口用）。
@MainActor
func makeGlassWindow<V: View>(title: String, floating: Bool, scrollIfTall: Bool = false, @ViewBuilder content: () -> V) -> NSWindow {
    let view = content()
    let style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
    let bar = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled, .closable]).height    // 标题栏高度
    var host = NSHostingView(rootView: AnyView(view))
    var size = host.fittingSize
    let limit = (NSScreen.main?.visibleFrame.height ?? 900) - bar - 12
    if scrollIfTall && size.height > limit {                    // 小屏幕放不下就能上下滚
        host = NSHostingView(rootView: AnyView(ScrollView { view }.frame(width: size.width, height: limit)))
        size = NSSize(width: size.width, height: limit)
    }
    host.sizingOptions = []                  // 窗口大小固定，不让内容的布局反过来牵着窗口走
    let full = NSSize(width: size.width, height: size.height + bar)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: full), styleMask: style, backing: .buffered, defer: false)
    w.title = title
    w.titlebarAppearsTransparent = true
    // 毛玻璃底，同时当容器，避免 SwiftUI 自己改窗口大小
    let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: full))
    glass.material = .popover
    glass.blendingMode = .behindWindow
    glass.state = .active                    // 窗口没在前台时也保持毛玻璃，和菜单栏面板一致
    host.frame = NSRect(origin: .zero, size: size)          // 内容放在标题栏下面
    host.autoresizingMask = [.width, .height]
    glass.addSubview(host)
    w.contentView = glass
    w.setContentSize(full)
    w.center()
    w.isReleasedWhenClosed = false
    if floating { w.level = .floating }
    return w
}

/// 只用于 README 截图：离屏画不出真窗口的标题栏和毛玻璃，按实际样子补一个标题栏、垫一层半透明窗口底
struct ShotWindowFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                .padding(.leading, 14)
            }
            .frame(height: 32)
            content
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }
}
