# 给 krd 加两条新通道 — headless（文本）与像素（镜像）

> 调研问题两连：①浏览器被做成 CLI 之后，LLM 不用外部工具就能操作它；krd 是远程 macOS 桌面，
> 能不能用同一原理把 Mac 的对象以**文本**交给模型？②以及它的 **headless** 形态——不要图像、
> 只要元素。
>
> 本文的实测项全部在本机跑出来（macOS 27.0.1 / M1 Pro / 2026-10-30），未验证项在 §13。
> 姊妹文档：[research-terminal-remote-desktop.md](research-terminal-remote-desktop.md)（像素链路）。

## 0. 结论（先看这段）

1. **headless 不是"另一个功能"，是 krd 的第二种运行形态。** 镜像模式回答"屏幕长什么样"，
   headless 回答"屏幕上有什么、能不能按"；两者共用同一套动作层（AX 动作 + CGEvent 兜底），
   只是观测端不同。把 headless 当主形态、镜像当兜底，整个产品的叙事就顺了：
   **同一个二进制，既能当"远程桌面"，也能当"远程 API"。**
2. **实测确认：headless 在 ssh 会话里能跑通**（这是本次最重要的新事实）。同用户 `ssh` 进去的
   进程处于 **Background** 会话（`launchctl managername`），但它 **能读到完整的 AX 树**，
   而且 `AXIsProcessTrusted()=true`、`CGPreflightPostEventAccess()=true`——**不需要任何新授权**。
   唯一的坑：**第一次 AX 调用必然失败**（`-25204 cannotComplete`，连试 3 次都一样），
   需要先碰一下 WindowServer（一次 `CGWindowListCopyWindowInfo` 即可）才通。
3. **headless 只需要 Accessibility，可以完全不要 Screen Recording。**
   `--list` 今天之所以要屏录授权，是因为 `SCShareableContent` 写在 `--list` 分支之前
   （`main.swift:267`）；而 headless 用 `CGWindowList` + AX 就够了，窗口标题从 AX
   `kAXTitleAttribute` 拿（实测可用）。这是**安装体验上的实质差别**：agent 只有读/写，
   不必把整块屏幕交出去。
4. **一个"文本屏幕"实测 ≈ 3.2k token（剪枝后）/ 8.3k（不剪枝），一张同尺寸的帧 ≈ 359 KB。**
   7 个窗口、766 个原生节点、25 KB 字符，剪枝后 134 节点、9.7 KB。单窗口大约
   **100–450 token**。这是两个数量级的差距，不是"省一点"。
5. **但 headless 有一个硬天窗：Chrome/Electron 的网页内容不在树里。**
   实测 Chrome 窗口只有 25 个节点（`AXGroup×17, AXButton×3, AXToolbar×2`），没有 `AXWebArea`；
   而业界常用的两个唤醒属性在本机**设不进去**（`AXEnhancedUserInterface` → `-25208`、
   `AXManualAccessibility` → `-25205`）。所以浏览器/Electron 类不是"多试几次"，而是
   **要有第二条腿**：CDP 或 `--force-renderer-accessibility` 启动参数。
6. **性能的方差比平均值重要**：实测每节点 0.32 ms（Finder）到 **25.6 ms**（System Settings，
   24 个节点花了 614 ms）。所以"必设超时 + 缓存 + 默认剪枝"不是优化项，是能不能用的分界线。
7. **它把 krd 的安全面换了性质**：授权门槛降低了（ssh 路径不需要授权就能读全屏文字），
   数据面却放大了（结构化全部可见文字，几 KB）。两件事必须一起处理（§11）。

## 1. 浏览器 CLI 可迁移的四条

| 浏览器侧 | 桌面侧对应物 | krd 现状 |
|---|---|---|
| DOM / `AXTree` 枚举 | `AXUIElement` 树（app → window → children…） | 无（全仓零命中） |
| `@eN` ref（snapshot 内稳定、跨 snapshot 尽量保活） | anchor（role + identifier + 同级序号）或 path | 无 |
| `click/fill/select/press` | `AXUIElementPerformAction` / `SetAttributeValue` / `CGEvent` | 只有全局 CGEvent |
| 变更后重 snapshot / 回 diff | `AXObserver` 通知 + 重 walk | 无 |
| 截图兜底 + 标注编号 | krd 本来就在画像素 → 可直接把 `[N]` 画进画面 | 无 |

`agent-browser snapshot -i` 用的 Chromium `AXTree` 与 macOS `AXUIElement` 是**同一抽象的两个实现**
（连角色名 button/textfield/heading 都同源），所以这套迁移不是打比方。

## 2. Headless：不要图像的那一半（本次实测）

### 2.1 三个不同的"headless"，别混

| 说法 | 含义 | krd 今天 | 说明 |
|---|---|---|---|
| **无采集** | 不抓帧、不出图，只回元素/文本 | ❌ | 本文的主线，架构上最便宜 |
| **无 tty** | `ssh host krd ax tree \| jq`，stdout 是管道 | ⚠️ `--list` 已支持 | 渲染模式必须有 tty（要 `TIOCGWINSZ`），headless 不需要 |
| **无显示器** | Mac mini 不接屏、合盖 | ⚠️ 屏录可能失败，AX 不受影响 | 这正是 headless 比镜像更该做主的场景 |

注意 headless ≠ 没有屏幕。屏幕还在、应用还在跑，只是**我们不采集**，所以带宽、CPU、token
都降到零头。

### 2.2 实测：ssh 会话里 AX 到底能不能用

三组对照，全部同机同用户（`ssh localhost`，BatchMode）：

| 场景 | `launchctl managername` | `AXIsProcessTrusted` | `CGPreflightPostEventAccess` | AX 调用 |
|---|---|---|---|---|
| 本机 GUI 终端（Aqua） | `Aqua` | **false** | false | `-25204 cannotComplete` |
| `ssh`（Background） | **`Background`** | **true** | **true** | 冷启动 `-25204` ×3 → 碰一次 WindowServer 后 **ok** |
| `ssh + launchctl asuser $UID` | — | — | — | `Operation not permitted`（非 root 不可用） |

**关键的两条**：

1. **Background 会话能读 AX，但需要 warm-up。** 冷启动第一次
   `AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute)` 稳定返回
   `cannotComplete`；先调一次 `CGWindowListCopyWindowInfo` 建立 WindowServer 连接后，
   同一调用立刻成功，之后整棵树都能读。
   → 实现上必须写"**先 warm、失败重试一次**"，否则 `krd ax tree` 会稳定地第一条命令就报错，
   而且错误信息看起来很像是权限问题（实际不是）。
2. **`AXIsProcessTrusted()` 在 Background 会话里返回 true，不是因为拿到了授权**，
   而是因为 TCC 不把该进程归给任何被授权的 app。所以**别用它做能力判断**——
   真正的判断是"能不能取到 `AXWindows`"。同时这也是一个事实：**同用户的 ssh 进程目前可以
   不经授权读全屏文字**（这既是 adoption 的优势，也是 §11 的安全问题）。

> 这条与 `docs/DEPLOY.md:96-100` 的说法不冲突但需要补一句：那里说的是**授权弹窗**不能在 ssh 里
> 点（弹窗归属不到 sshd 起的进程），而不是"ssh 里 AX 不可用"。实测证明后者是可用的。

### 2.3 实测：一个"文本屏幕"有多大

7 个 on-screen（layer 0）应用窗口，深度 ≤6 全量行走：

| 应用 | 窗口 | 原生节点 | 原生字符 | 剪枝后节点 | 剪枝后字符 |
|---|---|---:|---:|---:|---:|
| Finder | Downloads | 308 | 7,378 | 30 | 821 |
| Rex Beta（终端） | krd-chrome2 … | 64 | 7,597 | 31 | 6,801 |
| Xcode | Kraal — … | 236 | 5,552 | 43 | 1,248 |
| System Settings | Screen & … | 75 | 2,028 | 12 | 326 |
| Tailscale | — | 46 | 1,187 | 11 | 269 |
| Chrome | magpie | **25** | 684 | 7 | 246 |
| Finder | （第二窗） | 12 | 596 | 0 | 0 |
| **合计** | 7 窗 | **766** | **25,022** | **134** | **9,711** |

- 换算（`chars / 3`，中英混排的保守估计）：**原生 ≈ 8.3k token，剪枝后 ≈ 3.2k token**。
  （另一次运行：752 节点 / 24,123 字符 → 剪枝 133 / 9,434。差异来自窗口内容变化，量级稳定。）
- 剪枝规则 = 只留"可交互 + 有名字"的节点，丢掉 `AXGroup/AXRow/AXCell/AXImage/AXSplitter/AXMenu*`
  （与 `agent-browser` 的 `-i` 同思路）。**一行规则就把体积砍掉 61%。**
- 单个普通窗口 **≈ 80–420 token**；终端窗口例外（它是"一整屏文字"，必须按行截断）。
- 对照像素：同尺寸整帧 PNG **452 KB**、zlib 瓦片 359 KB
  （`research-terminal-remote-desktop.md` §2.2）。**量级差 2 个数量级。**

### 2.4 实测：headless 需要哪些授权

| 能力 | 需要 | 实测 |
|---|---|---|
| 窗口清单（pid/层/位置） | 无 | `CGWindowListCopyWindowInfo` 在 ssh 下正常（27 个窗口） |
| 窗口标题 | 无（走 AX） | `kAXTitleAttribute` 正常，不依赖屏录的 `kCGWindowName` |
| 元素树 / 属性 | Accessibility（Background 会话下不校验） | ✅ 读已实测；写/动作未测（§13 #3） |
| 像素 / OCR | **Screen Recording** | headless 不用 |
| 键盘鼠标注入 | Accessibility（`CGEventPost`） | `CGPreflightPostEventAccess()=true`（ssh 下） |

结论：**headless 的最小权限集 = 空**。这不是漏洞而是现状：能 ssh 进同一用户的人，本来就能
用 `screencapture`/AX 拿走屏幕内容。真正的安全边界一直是"这个账号"，不是 TCC。

### 2.5 headless 独有的乘积效应：并行

镜像模式是**单占用**资源：一块屏、一个 pane、一次人机共享。headless 天然可分片：
`krd ax tree --app Slack` 和 `krd ax tree --app Xcode` 是两个进程，互不打扰。
配合 AX 动作（`AXPress` 不需要前台、不需要鼠标），**多个 agent 可以同时操作不同 app**——
这是镜像模式做不到的，也是"远程 Mac 当 CI 机/agent 宿主"这个场景真正的价值。

## 3. 一个窗口上到底能拿到什么

### 3.1 窗口层（不需要 AX）

| 来源 | 给什么 | 权限 | 现状 |
|---|---|---|---|
| `SCShareableContent.windows` | windowID / frame / owningApplication / title / layer / isOnScreen | 屏幕录制 | ✅ 已用（`main.swift:267`），只打印 4 个字段（`:275-277`） |
| `CGWindowListCopyWindowInfo` | 同上，同步、无需异步 | 无 | 未用（headless 的更好起点） |
| `NSWorkspace.runningApplications` | pid / bundleID / 是否前台 | 无 | 未用 |
| AX `kAXWindowsAttribute` | AX 窗口对象（能继续往下走） | 见 §2.2 | 未用 |

### 3.2 元素层（AX）

每个元素有三样东西：**属性、动作、通知**。

**属性**：`AXRole`/`AXSubrole`、`AXTitle`/`AXDescription`/`AXHelp`、`AXValue`/`AXSelectedText`、
`AXIdentifier`（SwiftUI/Catalyst 几乎只有这个）、`AXPosition`/`AXSize`/`AXFrame`
（**全局 points、原点主屏左上——与 krd 的 `Viewport`、`CGDisplayBounds`、`CGEvent.location`
同一坐标系，可直接互换**）、`AXEnabled`/`AXFocused`/`AXSelected`/`AXExpanded`/`AXModal`、
`AXChildren`/`AXContents`/`AXRows`/`AXColumns`。

**动作**（`AXUIElementCopyActionNames`，实测可见）：`AXPress`、`AXShowMenu`、`AXConfirm`、
`AXCancel`、`AXIncrement`/`AXDecrement`、`AXScrollToVisible`、`AXPick`。
这是文本通道真正的价值点：**不需要鼠标坐标、不需要窗口在前台、不会被别的窗口挡住**
（"press, don't click"）。对比现状——注入是全局 `.cghidEventTap`，窗口不在最前就点错地方
（`docs/TROUBLESHOOTING.md:189-193`）。

**可写属性**：`AXValue`（填空）、`AXFocused`、`AXSelectedText`、`AXPosition`/`AXSize`。
实测：终端里的 `AXTextArea` 的 `AXValue` **不可写**（`IsAttributeSettable=false`）——
每类控件都要先查 `IsAttributeSettable` 再写，别假设。

**通知**（`AXObserver`）：`AXFocusedUIElementChanged`、`AXValueChanged`、`AXWindowCreated`、
`AXUIElementDestroyed`、`AXTitleChanged`、`AXSelectedChildrenChanged`。「增量」与
`krd ax wait` 的全部基础。

### 3.3 一次 dump 长什么样（示意）

```
# window 8421  app=Safari  "Apple Developer Documentation"  [0,25 1440x900]  focused
@e1  window     "Apple Developer Documentation"                  [0,25 1440x900]
@e2  button     "Back"          id=back                          [12,52 24x24]   press
@e3  textfield  "Address"       value="developer.apple.com"      [200,52 600x28] press set
@e4  webarea    ""                                               [0,90 1440x835]
@e5    heading  "Documentation"                                  [80,120 400x40]
@e6    link     "Technologies"  url=/technologies                [80,180 120x20] press
@e7    textbox  "Search"        value=""                         [900,120 300x24] press set
```

`ref · role · name · (id/value/url) · frame · 可用动作`。空容器、纯装饰、菜单栏默认不出。

## 4. 除 AX 之外的六条路

| # | 通道 | 粒度 | 额外权限 | 覆盖 | 免焦点 | 适合 |
|---|---|---|---|---|---|---|
| A | **AX 树** | 控件 | Accessibility（headless 下不校验） | AppKit/SwiftUI 好；浏览器内容差；canvas 无 | ✅ | 主力 |
| B | AppleScript / `System Events` | 应用语义 | **Automation**（逐 app 弹窗） | 有脚本字典的 app | ⚠️ | 已有字典的 app |
| C | App 自有协议 | 原生对象 | 视 app | Chromium/Electron（CDP）、Safari（WebDriver）、`shortcuts run`、URL scheme | ✅ | 浏览器/Electron 的**必需品** |
| D | Vision OCR | 文本块 | Screen Recording | 一切可见文字 | — | canvas、游戏、无树 app |
| E | `CGWindowList` | 窗口 | 无 | 全部 | ✅ | 只要窗口级时最便宜 |
| F | 代码注入 / swizzle | 任意 | 关 SIP | 全部 | ✅ | 不做 |

**B 为什么不能用**：实测 `osascript -e 'tell application "System Events" to …'` 6 秒不返回、
无输出无错误（与 TCC 弹窗挂起一致，无人应答环境无法闭环）。它要的是 **Automation** 票，
krd 的 Accessibility 授权**不能复用**，且逐 app 弹窗。

**C 为什么是必需品**：见 §5.3 的实测——Chrome 的网页内容压根不在树里。

## 5. 三条硬约束

### 5.1 权限：一张票，但"能读"和"有票"是两回事

- AX 读写、CGEvent 注入、`AXUIElementCopyElementAtPosition` 全部只要 **Accessibility**。
- 但 §2.2 实测：**Background 会话下 `AXIsProcessTrusted()` 恒 true 且确实能读**，
  而 GUI 终端里反而是 false。**所以不要用 `AXIsProcessTrusted()` 判断可用性**，
  用"能不能取到 `AXWindows`，取不到再报权限错误"。
- 授权记在代码签名上，krd 已用固定标识 `com.kkrt.macdesk` 解决（`install.sh:10-12`、
  `docs/DEPLOY.md:127-133`）——这一层对**镜像模式**仍然必要（屏录 + 本地终端注入）。

### 5.2 性能：同步 IPC，方差极大

- 每次 `AXUIElementCopyAttributeValue` 是一次跨进程 Mach 调用，**默认超时 ~6 秒**
  （AXSwift 文档与多份实测一致）。目标卡住时 CLI 就卡 6 秒。
- 实测每节点耗时：Finder **0.32 ms**、Xcode **0.51 ms**、Chrome 1.51 ms、
  **System Settings 25.6 ms**（24 个节点 614 ms）。7 个 app 串起来 1.3 s。
- 必须做：`AXUIElementSetMessagingTimeout(app, 0.5~2.0)`（**这个值是"发送时读取"的进程级全局，
  只在元素上单独设才免疫**，见 §14 的事故复盘）、深度/节点上限、默认剪枝、**永不遍历菜单栏
  除非显式要**（Ventriloquist 的实测里菜单栏是 walk 的大头）、`AXObserver` 增量。
- 批量手段：`AXUIElementCopyMultipleAttributeValues`、`AXUIElementCopyAttributeValues`（带 range）。

### 5.3 应用分四类（实测过前两类）

| 类别 | 例子 | 实测/已知 | 处理 |
|---|---|---|---|
| AppKit 原生 | Finder、Notes、Xcode | 实测 236–308 节点，0.3–0.5 ms/节点 | 直接用 |
| Chromium / Electron | Chrome、Slack、VS Code | **实测只有 25 节点、无 `AXWebArea`**；`AXEnhancedUserInterface`→`-25208`、`AXManualAccessibility`→`-25205`（**设不进去**） | CDP / `--force-renderer-accessibility`；否则只能读壳（按钮/工具栏），页面内容读不到 |
| Catalyst / SwiftUI | 大量新 app | 有树，靠 `AXIdentifier` 不靠 label | anchor 优先 identifier |
| 无树 | 游戏、自绘 canvas、部分 Java/Qt | 几乎空 | 退 OCR / CDP / 坐标点击 |

> 更正：网上流传的"设 `AXManualAccessibility` 就能点亮 Electron"在**本机 macOS 27 的 Chrome 上
> 不成立**。可见这条不是普适偏方，必须按 app 实测；同时说明"读得动、点不动"的风险是真的——
> 对 Electron 类**动作后必须回读校验**。

### 5.4 headless 的观测盲区

headless 看不到：图形/图表/布局/颜色/图片内容/视频/自定义绘制/字体渲染结果。
这些不是"再读深一点"能解决的，只能回像素。所以产品上必须是**两种形态**，不是二选一（§9）。

## 6. 与 krd 现有架构的接缝（事实）

- **`--list` 已经是"文本模式"的先例**：`main.swift:269-281` 写 stdout 后 `exit(0)`，
  发生在 `beginSession()` 之前，不进 alt screen。
- **铁律：会话内绝不往 tty 写文本**（`CONTRIBUTING.md:72-74`、`docs/ARCHITECTURE.md:163-166`、
  `Log.swift:3-6`）。文本通道只有三个合法落点：**子命令**（会话外 stdout，首选）、
  **文件旁路**（`--stats-json`/`KRD_DUMP` 风格）、**stderr**（`--bench-wire` 风格）。
- **无 subcommand 机制**：`parseArguments()` 是扁平 `--flag` 扫描，无 positional，未知参数静默忽略
  （`main.swift:87-167`）。加 `ax` 子命令 = 第一次引入 positional，是**小而真实的架构变更**
  （usage、双语文档、`--no-input` 兼容都要跟着改）。
- **无守护、无 socket**（`CONTRIBUTING.md:11-13`）。ref 必须能从磁盘重建（§8）。
- **`ApplicationServices` 已 import**（`main.swift:2`），AX 不新增链接目标，不违反"不加依赖"
  （`CONTRIBUTING.md:14-20`）。
- **已有 `--dry-run`**（`InputReader(dryRun:)`）——写操作可复用同一语义。
- **headless 是"第五个早退路径"**：现有 `--selftest`/`--bench`/`--replay`/`--list` 都是
  `Desk.run()` 里的早退分支（`main.swift:220-281`），headless 挂在同一个位置，**不碰采集、
  不碰渲染、不碰输入**，风险最小。

## 7. 三种集成形态

| | A. 无状态子命令 | B. 常驻 + 事件流 | C. 会话内旁路 |
|---|---|---|---|
| 形态 | `ssh host krd ax tree -w 8421` | `krd ax watch --out events.ndjson` | 渲染会话里 `--ax-events <path>` |
| 状态 | 无（ref 落盘） | 进程内（AXObserver/缓存） | 与画面同生命周期 |
| 延迟 | 每次重 walk（20 ms–1.3 s） | 首帧后增量（ms） | 不阻塞画面 |
| 违反 out-of-scope？ | 否 | **是**（长驻） | 否 |
| 适配 agent 习惯 | ✅ 最好 | ⚠️ 要管生命周期 | ✅ 人类可见 |
| 建议 | **v0 就做这个（headless 的主形态）** | 之后再说，只做 `--follow` 前台模式 | 与 A 并行，用于示教/调试 |

**为什么不做 MCP server**：MCP 要宿主进程来接，而 krd 的前提是"你已有的那个 ssh 会话就是客户端"
（`README.md:19-20`）。做成子命令，任何能执行命令的模型都能用，也不引入常驻进程和端口；
需要 MCP 的人在外面套薄适配器即可。

## 8. 引用（ref）设计 —— 没有 daemon 怎么让 `@e4` 还能点

三个候选：

1. **纯 path**（`@w8421/0/2/1`）：实现最简，但树一变（弹 sheet）序号全偏，**会点错**。
2. **纯 anchor**（`AXButton|Save|第2个同名`）：抗重排，但每次都要走树找，歧义时只能失败。
3. **snapshot + 落盘 ref 表**（推荐）：`krd ax tree` 生成 snapshot 时把
   `{ref → anchor 链, generation, windowID, 时间戳}` 写到 `$TMPDIR/krd-ax/<windowID>.json`；
   `krd ax press @e4` 读表、按 anchor 链重新解析，**解析不到或有歧义就 fail-closed**。

契约三条：**ref 只在同一 generation 内有效**；**歧义 ≠ 猜**（agent-browser 也是这个规则）；
**动作后回读**（返回焦点/值/标题的最小 diff，而不是 "ok"）。

副作用：新增一个临时状态目录（含屏幕文本，属敏感），要写进 `SECURITY.md`。

### 8.1 已实现（issue #28）

方案 3，落在 `Sources/krd/AXRefs.swift`（纯逻辑 + 文件 IO）与 `AXCommand.swift`（AX 那一侧）：

```
$TMPDIR/krd-ax/index.json               ref → 是哪次 dump 打印的（+ 每个窗口的计数器）
$TMPDIR/krd-ax/snapshots/<generation>.json   那次 dump 的每个 ref 及其 anchor 链
KRD_AX_STATE                           把上面整个目录搬到别处（测试/只读 TMPDIR）
```

anchor 链的每一步是 `{index, role, identifier, title}`：`index` 是父节点 `AXChildren` 里的位置，
后三个是当时那个 child 的样子。解析时逐级往下：**先看记录的那个 index**（树很少动，命中只读一个
child），对不上才把整层读出来找唯一匹配。匹配规则：两边都有 `AXIdentifier` 就只比它（按钮标题从
"Start" 变 "Stop" 还是同一个按钮）；否则比 role+title（标题改了就当它没了）。

四条由此得到的性质，都是实测过的：

1. **编号按窗口单调递增，不重用**。这条是实测逼出来的：实测时先 dump（@e19 是 bold 复选框），
   中间又 dump 了一次（重新从 @e1 编号），再 `press @e19` —— 工具点到了 `ruler` 上。现在每次 dump
   从上次的最后一个号往后编（`AXIndex.counters`），旧 ref 永远指向打印它的那次 dump，配合 anchor
   校验，只可能"成功"或"明确失败"，不会改指。该窗口的 snapshot 全被淘汰后计数器才归零。
2. **失效就 fail-closed，并说清下一步**。窗口没了 / 应用重启（pid 复用也算）/ 节点改名 / 一层里
   出现两个一样的兄弟，都是非零退出 + "重新 dump"，不会回退到"按 index 硬点"。
3. **`find` 与 `tree` 用同一套 walk 参数**，同一个界面状态下编号一致；`--all` 会搜到更多节点，
   也就必然换号（文档写明了）。
4. **`--menubar` 的链从 menu bar 起**，snapshot 每个节点记 `root`，解析时选对起点（实测
   `press` 一个菜单项：`AXPress` 返回 0 ms，但目标窗口没有焦点时菜单项是 disabled，回读直接把
   `enabled=false` 打出来，而不是假装成功）。

写路径的默认值是关的：`press`/`set` 是显式子命令，`--dry-run` 只打印不发送，写入后一定回读；
`set` 回读到的值不等于请求值就按 `6` 退出（应用接受了写入却规范化/裁掉了内容时，这是唯一诚实的
答案）。

## 9. 两种形态的职责划分（产品视角）

| 任务 | headless（AX） | mirror（像素） |
|---|---|---|
| 列窗口 / 找控件 / 填表 / 点按钮 / 读表格 | ✅ 首选 | 慢且贵 |
| 看布局、图表、图片、颜色、渲染结果 | ❌ | ✅ |
| 无树应用（游戏、canvas、部分 Qt） | ⚠️ 只能读壳 | ✅（+ OCR） |
| 浏览器里的网页 | ⚠️ 只有壳（§5.3） | ✅ 或 CDP |
| 多 agent 并行 | ✅ 天然可并行 | ❌ 单占用 |
| 人类旁观 / 随时接管 | ❌ | ✅ |

命令面草案（headless）：

```
krd ax screen                       # 全屏文本快照（窗口 + 焦点，可选剪贴板）
krd ax windows                      # 窗口清单（不需要屏录授权）
krd ax tree -w 8421 -d 4 -i         # 单窗口树，只出可交互
krd ax find --role AXButton --title Save
krd ax press @e4                    # AXPress，免焦点
krd ax set @e7 --text "hello"       # 先查 IsAttributeSettable
krd ax focus @e5
krd ax wait --until "value:@e7=/done/" --timeout 10
krd ax at 300,420                   # 屏幕点 → 元素（示教）
krd ax watch --out events.ndjson    # AXObserver 事件流
```

镜像模式加三个开关：`--ax-events <path>`（事件 NDJSON，不碰 tty）、`--marks`（把 `@eN`
的编号画进画面）、`--headless`（完全不开采集，等价于 `krd ax screen` 的持续版）。

## 10. krd 独有的三个结合点（别人做不了）

1. **像素 ↔ 文本双向**：krd 已经在画像素，可以把 `@eN` 编号**直接画进终端画面**——
   人看到的 `[3]` 和模型看到的 `@e3` 是同一个东西。纯 MCP server 做不到，它们没有画面。
2. **示教**：人在终端里点一下（krd 本来就能收 SGR 鼠标坐标），krd 用
   `AXUIElementCopyElementAtPosition`（**实测 ssh 下可用**）反查出控件并输出 `@e7 button "Save"`。
3. **免焦点操作**：`AXPress`/`AXValue` 不需要窗口在前台、不需要动鼠标，直接解掉
   `TROUBLESHOOTING.md:189-193` 的"窗口不在最前就点错"，也让 agent 能操作看不见的窗口。

## 11. 风险（按严重度）

1. **安全面换性质**：现在泄露的是像素（有损、按帧、几百 KB）；headless 泄露的是**结构化全屏文字**
   （近无损、几 KB）。写侧从"模拟鼠标"升级成"直接设任意字段、按任意按钮"。而且 §2.2 的实测说明
   **ssh 路径连授权都不需要**。必须在同一批改动里定：默认只读？写要不要二次确认？审计日志？
   （`SECURITY.md:36` 的"授权才是真正的资产"在本通道下更成立。）
2. **AX 调用会把 CLI 挂 6 秒**（默认超时），目标卡住时**不可中断**。必须全局
   `AXUIElementSetMessagingTimeout` + 命令级硬超时。
3. **Chromium/Electron 内容不在树里**（实测），且唤醒属性设不进去。别承诺"能操作网页"，
   否则第一周就会被现实打脸。
4. **元素失效**（`kAXErrorInvalidUIElement`）：app 重启、窗口关闭、页面跳转后 ref 全废。
   fail-closed + 明确错误码。
5. **跨 Space / 最小化**：`AXWindows` 只列当前 Space 的窗口，别的要用 `AXMainWindow`/
   `AXFocusedWindow` 兜底并标注。
6. **控制字符注入**：`--list` 已有此问题（`SECURITY.md:52-58`：窗口标题里的转义序列会被终端解释）。
   新通道输出的是**任意应用提供的字符串**，必须一律 sanitize——CJK 标题 + 恶意文档名是现实攻击面。
7. **安全输入**（密码框）读不到——这是对的，别绕过；但要显式说明，否则模型会一直重试。
8. **`AXIsProcessTrusted()` 会骗人**（§2.2）。任何"先查 trust 再干活"的写法都会在 ssh 路径下
   误判为"已授权"。

## 12. 落地顺序

| 阶段 | 内容 | 验收（用实测口径） |
|---|---|---|
| **P0（已完成）** | [`probe/ax_probe.swift`](../probe/ax_probe.swift)：warm-up 陷阱、窗口清单、逐窗口节点数/walk 耗时、剪枝前后体积（只读） | 本文 §2 的数字，可复现 |
| **P1（已落地）** | `krd ax doctor` / `windows` / `tree --app <q> [--pid] [--window] [-d] [-i] [--all] [--menubar] [--max] [--json]` / `screen`；失败给出可执行提示 | 单窗口 < 450 token、< 300 ms；慢 app 不超时 |
| **P2（1~2 天）** | ref + `find` / `press` / `set`（带 `IsAttributeSettable` 预检）+ `--dry-run` + 动作后回读 | Finder/Notes/Xcode 各跑通"找→按→校验" |
| **P3（1 天）** | `wait`、`at`、`--menubar`、跨 Space 兜底、慢 app 超时降级 | 端到端不确定场景（等保存完成）能过 |
| **P4** | `watch`（AXObserver → NDJSON）、`--marks`、`--headless` 常驻、CDP 通道（Chrome） | 事件流不阻塞渲染；画面编号与 ref 一致 |

P0 已完成且**不动主链路一行代码**——这也是为什么它应该第一个做。

> **更正（#103）**：P1 落地时是「预检在最前面」——每个动词都先花 ~50 ms 查授权/窗口清单/
> systemwide 往返，然后除 `doctor` 外把结果丢掉。这条结论后来被推翻：**预检改在动词有东西要报时
> 才跑**（成功路径 0 次；失败或空结果 1 次，且整进程至多 1 次）。见 §2.2 的实测与 issue #103。

## 13. 待验证清单

0. **`ssh -t`（带 pty）是否改变会话类型**：未测；预期仍是 Background，但部署脚本常用 `ssh -t`，值得确认。
1. **warm-up 的稳定性**：重复起进程 100 次，是否每次都只需一次 `CGWindowList` 预热？
   是否可以用更轻的 `CGMainDisplayID`/`CGDisplayBounds` 替代（避免枚举 27 个窗口）。
2. **授权的真实归属**：这台机器上 ssh 路径不需要授权，是因为"没被归属"还是因为某处已有授权？
   换一台干净机器（无任何 TCC 记录）重测，决定 `docs/DEPLOY.md` 要不要改。
3. **动作侧实测**：`AXPress`/`AXValue` 在 ssh（Background）下能否生效（本次只测了读，
   没敢在用户屏幕上按按钮）。
4. **锁屏 / 无显示器**：锁屏时能否读、无外接屏的 Mac mini 上 `CGWindowList` 与 `AXWindows` 是否完整。
5. **Chromium 的第二条腿**：`--force-renderer-accessibility` 启动后 Chrome 树有多大；
   CDP 与 AX 的混合决策规则（哪个窗口用哪条腿）。
6. **`AXObserver` 在一次性进程里的可用性**：能不能只订阅 200 ms 就拿增量，而不是全量重 walk。
7. **剪枝规则的普适性**：在 Slack/Outlook/邮件这类列表密集应用上，剪枝后是否还够模型理解。
8. **混合 DPI**：AX frame 与 krd `Viewport` 在 Retina + 外接屏下的坐标一致性。
9. **Vision 在新 macOS 上的延迟**（新旧两套 API），决定 OCR 兜底值不值得做。

## 14. 附录

### A. 本机实测记录（macOS 27.0.1 / M1 Pro / 2026-10-30）

```
launchctl managername        local=Aqua            ssh=Background
AXIsProcessTrusted           local=false           ssh=true
CGPreflightPostEventAccess   local=false           ssh=true
AX 冷启动                     cannotComplete ×3     → warm-up 后 ok
launchctl asuser $UID        Operation not permitted（非 root）
--------------------------------------------------------------
屏幕窗口（layer 0）            7 个 app / 7 个窗口
walk 深度 ≤6                  766 节点 / 25,022 字符
剪枝后                        134 节点 / 9,711 字符
每节点耗时                    Finder 0.32ms · Xcode 0.51ms · Chrome 1.51ms · System Settings 25.6ms
Chrome 树                     25 节点，无 AXWebArea；两个唤醒属性设不进去(-25208/-25205)
element-at-position           ok（返回 AXGroup）
focusedElement                AXTextArea，valueLen=2400，IsAttributeSettable(AXValue)=false
```

复现：`swift probe/ax_probe.swift`（**最好在 ssh 会话里跑**——本地 GUI 终端里反而读不到）。
数字会随窗口内容浮动，量级稳定。

### B. 生态速查（读过源码/文档，按可用性排序）

| 项目 | 是什么 | 价值 |
|---|---|---|
| [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser) | 浏览器 CLI，`snapshot -i/-c/-d` + `@eN` ref | **剪枝与 ref 形态的直接范本** |
| [mediar-ai/mcp-server-macos-use](https://github.com/mediar-ai/mcp-server-macos-use) | Swift MCP，AX 树 + CGEvent，"tree diff after each action" | 最接近的实现 |
| [sitharaj88/macctl](https://github.com/sitharaj88/macctl) | Accessibility-first MCP，权限分级 + 审计日志 | 权限分级 / handle 失效即失败 |
| [ShaanGS/ventriloquist](https://github.com/ShaanGS/ventriloquist) | 把 AX 操作"编译"成确定性工具包 | 应用分类、anchor、token/时间数据 |
| [AXSwift](https://github.com/tmandry/AXSwift) | Swift AX 封装 | 错误分类与超时语义（不引入，抄语义） |
| [mediar-ai/ui-events](https://github.com/mediar-ai/ui-events) | AXObserver → websocket 事件流 | `ax watch` 形态参考 |
| [fynpdf-ax 作者总结](https://maheepk.net/posts/accessibility) | "Press, don't click"、不设焦点、不模拟输入 | 免焦点操作与安全边界论证 |
| [Agent-friendly CLI](https://agentsurface.dev/docs/cli-design) / [CLI Spec](https://clispec.dev/) | 结构化输出、可发现性、非交互 | 子命令面清单（`--json`/退出码/`--dry-run`） |
