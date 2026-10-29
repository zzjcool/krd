# 终端里的 macOS 远程桌面 — 技术调研

日期：2026-10-29 ｜ 机器：macOS 27.0 (arm64, Retina @2x) ｜ 终端：Herdr 0.9.5
目标：把远程桌面的「客户端」换成 SSH 会话里的一块终端 pane（kitty graphics 协议渲染），
支持桌面级与窗口级两种视图，并要求鼠标/键盘能反向操作远端。

---

## 0. 结论（先看这段）

**可行，而且这台机器上最难的前置条件已经满足。**

| 前置条件 | 实测状态 |
|---|---|
| 终端能画图（kitty graphics） | ✅ Herdr 支持，`a=q` → `Gi=1;OK` |
| 终端能批量刷帧（吞吐） | ✅ 实测接收侧 ~100 MB/s，960×540 帧 123 fps 无阻塞 |
| 终端能收到鼠标/键盘事件 | ✅ SGR 1006 点击/拖动/滚轮已实测；kitty 键盘协议可查询可启用 |
| macOS 屏幕采集权限 | ✅ `CGPreflightScreenCaptureAccess() == true` |
| macOS 键鼠注入权限 | ✅ `CGPreflightPostEventAccess() == true` |
| 窗口级采集 API | ✅ ScreenCaptureKit 可用（枚举到 3 显示器 / 55 窗口，可单独取窗口） |

**唯一被堵死的捷径**：开源终端 VNC 客户端 **desktui 明确不支持 Apple Screen Sharing（ARD）认证**，
所以「desktui 直连 macOS 内置屏幕共享」这条最省事的路走不通（详见 §4 路线 A）。

**推荐路线**：单二进制 agent（路线 C）——`ssh mac ./krd`，agent 自己把画面编码成 kitty
graphics 转义序列写到 stdout，同时从 stdin 读鼠标/键盘事件并用 CGEvent 注入。
不需要写客户端，因为「客户端」就是终端本身。

---

## 1. 目标拆解（五段链路）

| 段 | 职责 | 候选实现 | 本机状态 |
|---|---|---|---|
| ① 采集 | 显示器/窗口像素 | ScreenCaptureKit（display / window filter）、CGDisplayStream（废弃）、`screencapture`（太慢） | SCK 可用 |
| ② 编码 | 降带宽 | 瓦片 zlib（`o=z`）、整帧 PNG、VideoToolbox HEVC/H.264 | zlib/PNG 已验证 |
| ③ 传输 | 过网络 | SSH pty（base64 内联）、另开 TCP、ssh -L 端口转发 | pty 100MB/s；SSH 58MB/s ↓ |
| ④ 渲染 | 画到终端 | kitty graphics：每瓦片一个 image id，脏瓦片重传即原子替换 | Herdr 支持（含动画帧） |
| ⑤ 输入 | 反向操作 | SGR 1006/1016 鼠标 + kitty 键盘协议 → CGEvent → 远端应用 | 两种权限均已授予 |

---

## 2. 实测数据（全部在本机/本链路跑出来的，不是估算）

### 2.1 终端管道吞吐（Herdr pane，raw 模式）

```
纯文本      20 MB  / 0.20 s  =  99.7 MB/s
图像 320×180  60 帧 / 10.56 MB / 0.11 s = 96.6 MB/s = 549 fps
图像 960×540  20 帧 / 10.84 MB / 0.16 s = 67.0 MB/s = 124 fps
```

> 口径说明：这测的是「Herdr 接收并消化转义流的速率」（写满 pty 缓冲就会反压），
> 不等于屏幕真正重绘的帧率。结论是**管道不是瓶颈**，真正的成本在帧大小与解码。

### 2.2 帧有多大（真实桌面截图，不是合成图）

主屏 1728×1117（逻辑）= 3456×2234 设备像素；终端 pane 可视区只有 **1128×1080 设备像素**。

| 画面 | 整帧 PNG | 瓦片 zlib 合计 | 单瓦片中位数 | p90 |
|---|---|---|---|---|
| 1128×729（终端可视区） | 452 KB | 359 KB（64px 瓦片） | **1.2 KB** | 4.5 KB |
| 1128×729 | — | 351 KB（128px） | 5.1 KB | 14.1 KB |
| 1728×1117（逻辑全屏） | 821 KB | 646 KB（64px） | 0.9 KB | 3.5 KB |
| 1728×1117 | — | 627 KB（128px） | 4.2 KB | 12.4 KB |

关键推论：**一次普通 UI 变化（打一个字、光标移动、按钮高亮）= 1~2 个瓦片 = 1~5 KB**。
全屏变化（滚动网页、播放视频）才是 350~650 KB 级别。

### 2.3 换算成帧率（分母是链路带宽）

链路实测（devcloud，同城云）：上行 28.7 MB/s，下行 **57.7 MB/s**，RTT 33.8 ms。

| 可用带宽 | 全帧 452KB | 典型 UI 变化 3KB |
|---|---|---|
| 5 MB/s（家庭 40 Mbps） | 11 fps | 理论 1600 fps（实际受采集/编码限制） |
| 20 MB/s | 44 fps | 同上 |
| 58 MB/s（实测链路） | **128 fps** | 同上 |

结论：**瓦片脏更新策略下，普通操作在 5 MB/s 的家庭带宽都绰绰有余**；只有全屏动态场景需要编解码器或降分辨率。

### 2.4 终端几何 / 显示环境

```
pane: rows=54 cols=141 xpixel=1128 ypixel=1080 → cell = 8.0 × 20.0 px（非方形！）
TIOCGWINSZ 会返回像素尺寸（很多终端返回 0，这台不会）
显示器 3 块：1728×1117（主，@2x）、1440×2560、1920×1080
可枚举窗口 55 个（含 企业微信 1292×1084 这类窗口级样本）
backingScaleFactor = 2.0 → HiDPI 陷阱：逻辑像素和设备像素差 2 倍
```

### 2.5 采集路径耗时（决定用哪条）

```
screencapture 整屏 PNG   : 261 ms/帧  → 只有 ~4 fps，演示可以，实用不行
screencapture 小区域     : 160 ms/帧
ScreenCaptureKit 连续流  : 按帧回调节奏推送，目标 30~60 fps（本项目要走这条）
```

---

## 3. 协议与 SDK 事实（决定架构的硬约束）

### 3.1 kitty graphics 在 Herdr 上的实测能力矩阵

探测脚本 `probe/kprobe4.py`，日志 `docs/herdr-graphics-probe.log`：

| 能力 | 探测 | 结果 |
|---|---|---|
| 支持查询 | `a=q` | ✅ `Gi=1;OK` |
| 传输 PNG | `a=t,f=100` | ✅ OK |
| 放置 / 缩放 | `a=p,c=8,r=4` | ✅ OK |
| 偏移 `x,y` | `a=p,x=3,y=2` | ✅ 接受 |
| 偏移 `X,Y` | `a=p,X=7,Y=9` | ✅ 接受 |
| 层叠 `z` | `a=p,z=5` | ✅ 接受 |
| **动画帧 + 帧间隔** | `a=f,z=200` | ✅ `Gi=50,r=2;OK` |
| **zlib 压缩** | `o=z` | ✅ OK |
| 原始 RGB | `f=24,s=8,v=4` | ✅ OK |
| 文件介质 `t=f` / `t=t` | — | ⚠️ 无回复（本路径不需要） |

要点：
- **`a=f` 动画帧可用**：可以让终端自己按 `z=<ms>` 节奏播帧，客户端不必自己卡时间。
- **`o=z` 可用**：瓦片走 deflate 比 PNG 更省 CPU（不用做 PNG 编码）。
- **image id 复用 = 原子替换**：同一 `i=` 重传即替换原图与放置，脏瓦片更新无需 delete，不闪。
  （desktui 的 README 把这条当作「无闪烁部分更新」的基础，实测 Herdr `a=p` 语义一致。）
- **over SSH 只能用 `t=d`（base64 内联）**：`t=f/t/t/s` 要求终端能访问同一文件系统。
  desktui 宣传的 `t=s` 共享内存 15× 加速，**在 SSH 场景完全用不上**。
- 分块上限 4096 字符/块，最后一块 `m=0`。

### 3.2 macOS 侧

| 能力 | API | 权限 | 备注 |
|---|---|---|---|
| 整屏采集 | `SCContentFilter(display:excludingWindows:)` | 屏幕录制 | 对应你说的「桌面级」 |
| **单窗口采集** | `SCContentFilter(desktopIndependentWindow:)` | 屏幕录制 | 对应「窗口级」，可只镜像某个 App |
| 连续帧 | `SCStream` + `SCStreamOutput` | 同上 | 支持 `showsCursor`、`queueDepth`、丢旧帧 |
| 键鼠注入 | `CGEvent.post(tap:.cghidEventTap)` | 辅助功能 | 键盘带 flags（Cmd/Ctrl/Alt），鼠标含滚轮/拖动 |
| 剪贴板 | `NSPasteboard` / OSC 52 | — | 双向可选 |
| 内置屏幕共享服务端 | RFB 3.889 + Apple 专有认证类型 30/33/35/36 | 管理员开启 | 见 §4 路线 A |

权限实测：`CGPreflightScreenCaptureAccess() == true`、`CGPreflightPostEventAccess() == true`。
**但注意**：这是在 GUI 应用（Herdr）派生的 shell 里测的。经 `sshd` 启动的进程归属 `sshd`
（responsible process），TCC 大概率不继承这两个授权 → 需要以 LaunchAgent 形式跑在用户
GUI session 里（`launchctl asuser`），详见 §6 风险 1。本机未开启免密登录，未能就地验证。

---

## 4. 四条候选路线

### 路线 A：desktui（现成终端 VNC 客户端）+ macOS 内置屏幕共享

- desktui：Rust 写的终端 VNC 客户端，瓦片 128×128、每瓦片一个 image id、脏瓦片重传、
  `Ctrl+A` 前缀、双向剪贴板、`--fps/--quality/--compression`、`SetDesktopSize` 让远端
  改成终端的像素尺寸（零重采样）。
- **堵点**：其 README 明确写 *Not supported: macOS Screen Sharing (Apple Remote Desktop auth)*。
  desktui 只支持 `None` 和 VNC password；macOS 内置服务端用的是类型 30（Apple-DH）/
  33/35/36（ARD），生态里 libvncclient、noVNC-ARD、Remmina 有部分实现，TigerVNC 也不完整。
- 附加代价：macOS 内置屏幕共享默认关闭，要用 GUI 或 `kickstart`（需管理员）开启；
  Apple 的服务端单线程、无 HEVC，弱网体验差。
- 结论：**不能作为首选**。可作为「改一行 auth 就能跑起来」的备选（要自己补 ARD 认证）。

### 路线 B：自写 macOS RFB 服务端 + 复用 desktui 当客户端

- 只实现 RFB 服务端（`ServerInit`、`SetPixelFormat`、`SetEncodings`、`FramebufferUpdateRequest`、
  `KeyEvent/PointerEvent`、`SetDesktopSize`），画面源换成 SCK，输入落到 CGEvent。
- 好处：白拿 desktui 的成熟渲染（同步输出模式 2026 防撕裂、1016 像素鼠标、键盘协议、
  剪贴板、1:1 像素、帧率/码率旋钮）。
- 代价：多一层协议实现（约 1.5~2.5k 行），且 SSH 上要再开一个端口转发（`ssh -L 5901:…`）。
- 结论：**中期最佳**，但不是最快见效。

### 路线 C：单二进制 agent 直接把画面渲染进 pty（推荐先做）

```
本地:  herdr pane / 任意终端
远端:  ssh mac ./krd --fps 30 --tile 16x8
        └─ SCK 抓帧 → 降采样到终端像素尺寸 → 瓦片 diff → zlib → \e_G…\e\ 写 stdout
        └─ 读 stdin 的 SGR 鼠标/kitty 键盘 → CGEvent 注入
```

- 零客户端代码：终端就是客户端；没有 VNC、没有 codec、没有额外端口。
- 天然支持「桌面级 / 窗口级」：`--window <id|title>` 切换 SCK filter。
- 天然共享 SSH 认证、加密、跳板机。
- 风险集中在一处：agent 必须跑在 GUI session 里拿 TCC 授权（LaunchAgent）。

### 路线 D：VideoToolbox 硬编 + 本地 `mpv --vo=kitty` / `ffmpeg` 解码

- 带宽最优（HEVC 1080p 30fps 常用 2~5 Mbps），动态场景最流畅；
  kitty 官方文档就把 mpv（`--vo=kitty`）列为使用者，可行性有背书。
- 但：输入要另开通道（mpv 不能把点击送回远端），且终端侧解码延迟、`ffmpeg → 终端帧`
  的管道抖动都更重。**只适合「看」，不适合「控」**。
- 结论：作为路线 C 的动态场景增强分支（静态 UI 走瓦片，动态走 HEVC），别一开始就上。

### 对比表

| 维度 | A desktui+Apple | B 自写RFB+desktui | C 单二进制agent | D HEVC+mpv |
|---|---|---|---|---|
| 首次可见效果 | 快（但要补 ARD 认证，否则 0） | 中 | **快** | 中 |
| 总工作量 | 小~中（阻塞） | 大 | **小** | 中 |
| 静态 UI 带宽 | 优 | 优 | **优** | 中 |
| 动态画面 | 差（Apple 服务端弱） | 中 | 中（可加 D） | **优** |
| 输入保真 | 取决于服务端 | 优 | 优（自己做） | **差（做不了）** |
| 额外端口/认证 | 需开 5900 | 需 ssh -L | **无** | 无 |
| 依赖 | Apple 服务端 | desktui | 无 | ffmpeg/mpv |

---

## 5. 推荐实施计划

**P0（半天~1 天，验收「能看见 + 能点」）**
1. `krd`（Swift）：SCK 抓主屏 → 降到终端像素尺寸（1128×1080 或按 `TIOCGWINSZ` 动态算）
2. 瓦片 64×64、zlib（`o=z`, `f=24`）或 PNG，脏瓦片 `a=T,i=<tileIdx>` 原子替换
3. SGR 1006 鼠标点击 → 反算远端坐标 → `CGEvent` 左键
4. 验收指标：终端里能看到桌面；点终端里的按钮，远端 App 有反应；单次点击端到端 < 150 ms

**P1（2~3 天，验收「能用」）**
5. `--window` 窗口级采集；多显示器枚举与切换
6. kitty 键盘协议（`\e[>9u`）→ 全量按键（含 Ctrl+C 透传、裸修饰键、key release）
7. 滚轮 64/65、拖动（`?1002h`）、双击、修饰键（shift/alt/ctrl 在 `b` 里）
8. 剪贴板双向（OSC 52）
9. 丢帧策略：采集侧 `queueDepth=1`，忙时丢旧帧；编码侧只在脏瓦片 > 70% 时降分辨率
10. `stty -onlcr` 或全程 base64，避免远端 pty 的换行转换污染二进制

**P2（可选）**
11. 动态场景切 VideoToolbox HEVC（路线 D 作为分支）
12. 或转为路线 B：把这套采集/输入封装成 RFB 服务端，白拿 desktui 的成熟交互

---

## 6. 风险与坑（按严重度排序）

1. **TCC 归属（最大风险）**：SCK/辅助功能授权属于「责任进程」。经 `sshd` 起的进程很可能
   两个 preflight 都是 false，且无法弹窗授权。对策：打成 `.app`，用 LaunchAgent 跑在用户
   GUI session（`launchctl asuser $UID …`），首次在屏幕上点「允许」。**必须最先验证**。
2. **锁屏/登录窗**：锁屏后 SCK 只给黑帧；睡眠会断流。对策 `caffeinate -d`、检测黑帧后暂停。
3. **HiDPI**：逻辑 1728×1117 vs 设备 3456×2234，且 cell 是 8×20 非方形。缩放要用整数倍或
   最近邻，否则文字糊；`TIOCGWINSZ` 的像素值必须校验（本机给了 1128×1080，可信）。
4. **鼠标精度**：SGR 1006 只到单元格；`?1016h`（SGR-Pixels）在 Herdr 上**未验证**。
   要做像素级定位必须先探测；否则最差会有一个 cell（8×20 px）的误差。
5. **无相对位移/无绝对锁定**：终端只给绝对坐标，FPS 类应用、精细拖拽体验差；这是终端形态
   的天花板，不是实现问题。
6. **键盘**：kitty 键盘协议可查询到（`\e[?u` → `\e[?0u`，当前 flags=0），可启用；但 Cmd 系
   统级快捷键（Cmd+Tab）能否稳定注入取决于进程权限（辅助功能 vs 输入监控）。
7. **滚轮是离散按键**（64/65），没有像素级 delta/惯性。
8. **二进制污染**：远端 pty 的 `ONLCR` 会把 `\n` 变成 `\r\n`；全程 base64 即可规避（代价 +33%）。
9. **剪贴板/拖拽文件/输入法候选窗**：终端形态下不可用或需要额外协议（OSC 52 只搬文本）。
10. **Apple 内置屏幕共享**：需管理员开启，且其 RFB 认证是专有实现，第三方客户端支持零散。

---

## 7. 待验证清单（下一步就做这几件）

- [ ] 经 SSH 启动时 `CGPreflightScreenCaptureAccess` / `CGPreflightPostEventAccess` 的真实值
      （本机未开免密登录，需在目标 Mac 上跑 `probe/sck_probe.swift`）
- [ ] LaunchAgent + `launchctl asuser` 方案能否稳定拿到两项授权
- [ ] Herdr 是否支持 `?1016h`（SGR-Pixels）：开模式后看坐标是否超过列数
- [ ] SCK 连续流在本机的实际帧率与 CPU（1080p，`queueDepth=1`）
- [ ] 瓦片 zlib（`f=24,o=z`）与 PNG（`f=100`）在 Herdr 侧的渲染开销差异（谁更省 CPU）
- [ ] 端到端延迟分解：采集 → 编码 → pty → 渲染 → 人工感知

---

## 附录 A：复现命令

```bash
# 终端能力探测（在 pane 里跑，日志写文件）
python3 probe/kprobe4.py > /tmp/p4.log 2>&1; cat /tmp/p4.log

# 管道吞吐
python3 probe/kbench.py 320 180 60      # 小帧
python3 probe/kbench.py 960 540 20      # 大帧
python3 probe/kpace.py 960 540 90 30    # 30fps 节流，看是否反压

# 交互（点击 / 拖动 / 滚轮 / 缩放）
python3 probe/kdrag.py                  # q 退出

# macOS 权限与 SCK 能力
swift probe/sck_probe.swift
```

## 附录 B：生态速查

- **desktui** — 终端 VNC 客户端（Rust），瓦片 + image id 原子替换 + 同步输出 + 剪贴板；
  不支持 Apple ARD 认证。本项目的交互设计可以直接照抄它。
- **terminal-browser** — 在 kitty 里跑 Chromium，鼠标键盘全通；证明「终端里的完整交互」可行。
- **mpv `--vo=kitty`** / **timg** / **tiv** / **chafa** — 终端视频/图片播放的现成参考。
- **notcurses** — 终端图形库，有视频播放路径。
- **LibVNCClient / noVNC-ARD / Remmina** — Apple ARD 认证（类型 30/33/35/36）的零散实现，
  若走路线 A 需要移植这部分。
