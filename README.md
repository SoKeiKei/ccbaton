<p align="center"><img src="docs/icon.png" width="128" alt="CCBaton"></p>

# CCBaton

**给 Claude Code 用的多账号接力棒。** 住在 Mac 菜单栏和桌面上，一眼看到每个账号还剩多少额度，一键换号继续干活。

*English: a native macOS menu-bar app and desktop widget for people with several Claude Code subscriptions — see each account's 5-hour / 7-day quota, switch accounts in one click, open a terminal per account. Swift, no dependencies, MIT. Unofficial, not affiliated with Anthropic.*

> 当前版本 **1.5.0**　·　[下载安装包](https://github.com/SoKeiKei/ccbaton/releases/latest)　·　macOS 14 或更高
>
> **使用前请读一下**：[合规与风险说明](docs/compliance.md)——哪些做法是官方写明的，哪些是灰色地带（额度预热、桌面端切换默认关闭）。

<p align="center"><img src="docs/screenshots/hero.png" width="860" alt="CCBaton 总览：菜单栏面板带换号建议和额度告警，右边是中号和大号桌面小组件"></p>

<p align="center"><sub>图里是"快用完"时的样子：顶部建议换号，96% 红色告警、85% 橙色告警。截图里的账号、邮箱和用量都是虚构的演示数据。</sub></p>

## 能做什么

- **看额度**：每个账号的 5 小时 / 7 天额度和重置时间，可以改成显示"剩余"；[Ultra](docs/guide.md#ultra-套餐没有-5-小时限制) 没有 5 小时限制，只显示周额度。
- **一键切换**：换掉 Claude Code 登录的账号，新开的和正在运行的 `claude`，下一条消息起都用新账号。
- **额度告警**：吃紧变橙、告急变红，快用完时建议换号并弹系统通知。
- **打开终端**：给某个账号单独开终端，现选目录、可加启动参数，可选"完全独立"。
- **桌面小组件**：三种尺寸，账号前面直接有切换按钮；账号再多也放得下，顺序可拖动。
- **默认关闭的可选功能**：[额度预热](docs/guide.md#额度预热)、[Claude 桌面端账号切换](docs/guide.md#claude-桌面端)（实验功能）。
- 还有：账号管理和备注、续期提醒、[从 cc-switch 迁过来](docs/guide.md#从-cc-switch-迁过来)、签名校验的一键更新。

每一项怎么用，见 **[使用说明](docs/guide.md)**。

## 安装

要求：macOS 14 或更高（Apple 芯片和 Intel 都行），装好 Claude Code（终端里能运行 `claude`）。

1. 在 [Releases](https://github.com/SoKeiKei/ccbaton/releases/latest) 下载 `CCBaton-版本号-macos.dmg`，打开后把 `CCBaton` 拖进"应用程序"。
2. **第一次打开会被 macOS 拦住**（个人开发的免费工具，没有做 Apple 公证，不是程序有问题）：到"系统设置 → 隐私与安全性"，滚到底点"仍要打开"；或者终端运行 `xattr -dr com.apple.quarantine /Applications/CCBaton.app`。

不放心可以自己编译（要装 Xcode 命令行工具，几十秒）：

```
git clone https://github.com/SoKeiKei/ccbaton.git CCBaton && cd CCBaton
./build.sh && open build/CCBaton.app
```

校验安装包、从旧版升级等细节见[使用说明](docs/guide.md#安装和打开)。

## 先读这几条

1. **"切换"是把登录移进 Claude Code 默认读的位置**，原来的账号收回自己的位置。终端的令牌始终只在 macOS 钥匙串里，CCBaton 自己的文件里不存。官方没有专门讲过这种用法，详见[切换是怎么回事](docs/guide.md#切换是怎么回事请读一下)。
2. **没有任何工具能保证不封号。** 同时用自己名下的多个账号，Claude Code 官方文档是支持的，但"切换"、预热、桌面端切换属于灰色地带。CCBaton **不做自动轮换**，每次切换都是你主动点的。请先读[合规与风险说明](docs/compliance.md)，多个账号请都是你自己的订阅。
3. **在另一个账号下接着聊别的账号开始的对话**，Claude 会提示 "can't use thinking from another organization"：对话没丢，只是要重新思考，会慢一点、多用一点额度。这是 Claude 自己的行为，切回原账号就恢复。
4. **数据在哪里**：设置和账号列表在 `~/Library/Application Support/ClaudeAccountBar/`（目录名保留了旧名字），清单见[数据在哪里](docs/guide.md#数据在哪里)。CCBaton 自己只在检查更新时联网（访问 GitHub，只带软件名和版本号），不收集、不上传任何账号数据。
5. 出问题先看[出问题怎么办](docs/guide.md#出问题怎么办)，仍解决不了请到 [Issues](https://github.com/SoKeiKei/ccbaton/issues) 反馈。

## 文档

- [使用说明](docs/guide.md)：面板、告警、终端、预热、小组件、设置、更新、账号管理、迁移、桌面端切换……
- [合规与风险说明](docs/compliance.md)
- [给开发者](docs/development.md)：目录结构、编译、发布、命令行参数、测试
- [版本记录](CHANGELOG.md)

## 许可证与声明

- 代码以 [MIT 许可](LICENSE) 开源。
- 切换引擎和终端启动方式参考了 [cc-switch](https://github.com/farion1231/cc-switch)（MIT）的设计思路，详见 [NOTICE.md](NOTICE.md)。
- **这是个人开发的非官方工具，与 Anthropic 没有关联。** "Claude"、"Claude Code" 是 Anthropic, PBC 的商标。
- 使用风险自负：本工具会读写 Claude Code 在 macOS 钥匙串里的登录信息，请先读上面的"先读这几条"。
