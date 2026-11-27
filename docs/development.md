[← 回到首页](../README.md)

# 给开发者（开发和发布）

## 目录
```
CCBaton/
├── VERSION            版本号（只在这里改）
├── build.sh           编译并打包成 build/CCBaton.app（UNIVERSAL=1 编通用版）
├── package.sh         打发布文件到 dist/：dmg（给人下载）、zip 和签名（给自动更新）、校验码
├── Resources/         应用图标 AppIcon.icns
├── tools/make-icon.swift  生成应用图标的脚本（改图标就改它）
├── tools/release-key.swift 发布钥匙：生成、签名、备份
├── docs/              使用说明（guide.md）、合规说明（compliance.md）、本文件，以及文档里的截图
├── README.md          首页（简短）
├── CHANGELOG.md       版本记录
└── Sources/
    ├── Core.swift       数据、账号列表、额度读取、模型
    ├── Switcher.swift   切换登录的引擎（钥匙串、锁、日志、恢复）
    ├── UI.swift         菜单栏面板、菜单栏图标、截图工具、命令行入口
    ├── Widget.swift     桌面小组件
    ├── Accounts.swift   账号多时的规则：紧凑布局、拖动排序、推荐、小组件放不下时显示谁
    ├── AccountsTest.swift 多账号界面和移除账号的测试
    ├── Removal.swift    移除账号：删哪些、警告框写什么
    ├── Migration.swift  把存放在 cc-switch 目录里的账号文件搬进本程序目录
    ├── MigrationTest.swift 迁移的测试
    ├── Editor.swift     编辑账号的窗口
    ├── Renewal.swift    续期提醒的日期计算
    ├── Alerts.swift     额度告警：等级、光晕、通知
    ├── Warmup.swift     额度预热：什么时候激活哪个账号、发消息、核对
    ├── WarmupTest.swift 预热的测试（含模拟和假 claude）
    ├── Settings.swift   设置窗口
    ├── Terminal.swift   打开终端：选目录和启动参数的窗口
    ├── Isolation.swift  独立终端的账号隔离
    ├── TerminalTest.swift 打开终端的测试
    ├── Driver.swift     自动驾驶测试（沙盒里模拟一通乱点）
    ├── LoginItem.swift  开机启动（系统登录项）
    ├── Update.swift     软件更新：检查、核对签名、替换自己、失败退回
    ├── Desktop.swift    Claude 桌面端账号：保存/恢复登录、退出重开、对话列表同步（实验功能，默认关）
    ├── DesktopTest.swift 桌面端切换的测试（假的数据目录和假的 Claude 进程）
    ├── StatusMenu.swift 右键菜单栏图标的简易菜单
    ├── StatusMenuTest.swift 右键菜单的测试
    ├── UpdateTest.swift 更新的测试
    ├── RobustTest.swift 账号列表损坏、找 claude 卡住、只读模式等情况的测试
    └── SelfTest.swift   切换引擎的沙盒自检
```

## 编译
```
cd CCBaton
./build.sh
```
## 发布新版
1. 改 `VERSION` 和 [CHANGELOG.md](../CHANGELOG.md)。发版前重新读一遍[合规说明](compliance.md)引用的三处 Anthropic 原文，有变化就同步改合规说明。
2. 运行 `./package.sh`。签名时系统会弹窗询问是否允许读取发布钥匙，点"允许"。
3. 在 GitHub 创建 Release，**标签必须是 `v版本号`**，把脚本列出的 5 个文件全部传上去（dmg、zip、zip.sig 和两个 sha256）。少了 zip 或 sig，软件里只能提示手动下载。

**发布钥匙**只存在发布者电脑的钥匙串里（软件里写的是对应的公钥）。请备份一份放到安全的地方：`swift tools/release-key.swift export <文件>`，换电脑用 `import` 恢复。钥匙丢了的话，已经装好的旧版没法自动更新到用新钥匙签的版本，只能手动装一次。Fork 本项目自己发版的话，要生成自己的钥匙并替换 `Sources/Update.swift` 里的公钥和下载地址。

界面改了要更新文档里的截图：
```
./build/CCBaton.app/Contents/MacOS/CCBaton --readme-shots docs/screenshots
```

## 命令行参数
以下用 `./build/CCBaton.app/Contents/MacOS/CCBaton` 运行：

| 参数 | 作用 |
|---|---|
| `--version` | 打印版本号 |
| `--dump` | 打印读到的账号状态（只读） |
| `--check` | 对每个账号做"能不能切换"的预检（只读，不写任何东西） |
| `--snapshot 目录` | 把面板、小组件、设置和终端窗口、编辑窗口、图标渲染成 PNG（只读，不需要屏幕录制权限） |
| `--readme-shots 目录` | 用虚构的演示数据渲染 README 里的截图（只读，不含任何真实信息） |
| `--login-item on｜off｜status` | 开启 / 关闭 / 查看开机启动（注册的是这次运行的那份 `.app`，请从"应用程序"里运行） |
| `--import` | 导入在 cc-switch 里登录的账号 |
| `--check-terminal-login 目录 账号` | 启动脚本内部用：核对独立终端登录的是不是这个账号 |
| `--check-update` | 问一次 GitHub 最新版本是多少（只读，不下载） |
| `--alerttest` | 告警逻辑测试（纯计算，不发通知） |
| `--selftest` / `--widgettest` / `--renametest` / `--warmuptest` / `--terminaltest` / `--multitest` / `--migratetest` / `--updatetest` / `--robusttest` / `--desktoptest` / `--statusmenutest` | 沙盒测试，**必须**设 `CAB_TEST_ROOT`（`--warmuptest`、`--terminaltest` 用假的 claude，不花额度；`--widgettest`、`--multitest` 运行时屏幕上会短暂出现小窗口） |

沙盒测试的用法（假账号、假钥匙串条目名带 `CABTEST`，完全不碰真实登录）：
```
T=$(mktemp -d)
CAB_TEST_ROOT=$T ./build/CCBaton.app/Contents/MacOS/CCBaton --selftest
rm -rf "$T"
```

`--snapshot`、`--check`、`--dump` 是只读模式：不会自动刷新额度，也绝不会写设置文件。

**自动驾驶测试**（排查布局、动画类崩溃用）：让真实运行的程序自己去点菜单栏图标、切换小组件尺寸、显示/隐藏小组件、开关设置和终端窗口、增减账号、刷新数据，跑 45 秒，崩了会返回非 0。有的系统版本（如 macOS 27）里程序点不开自己的菜单栏弹窗，所以同时开一个装着同样面板内容的替身窗口。只能在沙盒里跑：
```
T=$(mktemp -d)
CAB_TEST_ROOT=$T CAB_DRIVE=1 ./build/CCBaton.app/Contents/MacOS/CCBaton
rm -rf "$T"
```
可选环境变量：`CAB_DRIVE_SECONDS=20` 缩短时长；`CAB_DRIVE_SKIP=click,resize,toggle,data,settings,count` 关掉某类操作做"排除法"；`CAB_DRIVE_DRAG=1` 改为只测拖动排序。运行时屏幕上会有面板弹出收起、小组件变化。

---
