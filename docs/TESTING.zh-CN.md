# 测试与标定

[English](TESTING.md) | 简体中文

`swift test` 负责机械的那一半（`Tests/krdTests`、`Tests/krdcoreTests`）：字节契约、布局数学，以及唯一可观测量就是「tty 上的字节」的那些探针。剩下的是真正有意思的部分——一个终端协议加一个截屏框架——所以下面的开关是人跑的那一半：(a) 编译一次，(b) 让一张合成画面走真实的渲染管线，(c) 在你真正在乎的那个终端里跑一遍标定流程。
下面每一个开关的存在，都是因为当时有个具体问题必须用事实回答，而不是靠猜。

```bash
swift build -c release                 # the mechanical check
.build/release/krd --selftest          # the renderer, end to end, no permissions
```

探针的字节有它们自己的进程级测试：`Tests/krdTests/ProbeBatchTests.swift` 把 `krd --wall` 放到 pty 后面，
**自己扮终端**（像真终端一样回答那些能力问题），一旦这些问题不是一次写完发出，或者读取越过了收尾的 `DA1`，
测试就失败（issue #197）。「一次写完」只有在 pty 的另一端才看得见，进程内的测试做不到。

CI（[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)）只负责机械的那一半，而且只在 PR 或手动触发时跑
（不是每次 push）；发布 tag 走 [`release.yml`](../.github/workflows/release.yml)，同样是先构建再加 `swift test`：`swift build -c release`、
只有存在 `Tests/` 目录时才跑 `swift test`（今天没有这个目录），再加一次 universal 的
`--arch arm64 --arch x86_64` 构建，确认发布路径是通的。凡是跟协议、几何或输入有关的东西，仍然必须用下面
这些开关在真实终端上验 —— CI 没有可以往里画图的 pty，也没有可以采集的屏幕。

`--selftest` 全程离线跑：不碰 ScreenCaptureKit、不碰 TCC、不折腾 window server。它假装信号源是一块
1440×2560 pt（竖屏）区域，好让等比适配那条路径被走到；pane 几何从 `TIOCGWINSZ`（或 `--cell`）拿，
然后把 40 帧合成画面推过 `handleFrame` → `TileGrid.dirty` → zlib（并行）→ `emit` → base64 → 终端，
每 250 ms 一帧。你应该看到四个纯色象限、一层暗色棋盘格，以及一条从左扫到右的亮条。看到别的东西，说明
问题在终端或协议，不在采集路径。

selftest 的几种模式都会自己结束（默认图案约 10 s，`KRD_GRID` 约 64 s，`KRD_QUADRANTS` 约 28 s）。它们
不安装任何信号处理器，所以 **Ctrl-C 会把它直接杀掉，不走清理序列**；如果之后 pane 看着不对劲，再启动
一次 krd（进入时会自愈），或者跑 `printf '\033\\\033[?2026l\033[?25h'`。

## 1. `--selftest`

| | |
|---|---|
| 验证什么 | 编码器 → 转义序列 → 瓦片 → 放置，外加布局换算和脏瓦片检测，对着的就是你眼前这个终端 |
| 需要什么 | 一个实现了 kitty 图形协议的终端；**不需要**任何权限 |
| 通过 | 四个象限铺满 pane，亮条平滑移动，没有撕裂或碎片 |
| 失败 | 什么都没出现（协议/终端问题），或者画面偏移/碎裂（几何或放置问题） |

变体（可以和后面几节的环境变量开关组合）：

```bash
krd --selftest --no-input              # --no-input is redundant here but harmless
krd --selftest --cell 17x33            # pin the cell size instead of trusting the pty
krd --selftest --tile 8x4              # more, smaller tiles: exposes per-tile overhead and seams
krd --selftest --fps 30 --tile 32x16   # fewer, bigger tiles
```

时长：40 帧 × 250 ms ≈ 10 s，然后 `endSession()`。

### TUI 层

`--dev` 用同样的办法验证 —— 标定图案走真实管线，状态栏写在它下面那一行：

```bash
make dev-mock                          # 进程内画出来的桌面：不需要权限，而且不会停
make dev-selftest                      # = krd --selftest --dev --pane 137x44 --cell 17x33
krd --wall --mock --cell 17x33         # 落地屏和它的文本层：不要授权、不要屏幕
krd --selftest --dev --dev-panel stats # 面板预先打开，方便截图或报 bug
```

看三件事：状态栏紧贴画面下方（绝不压画面）、打开面板是让画面**缩小**而不是被盖住、
`Ctrl-\\` 再 `q` 退出后终端回到原样（没留在备用屏幕里）。

## 2. `KRD_GRID=1` —— 瓦片定位

| | |
|---|---|
| 验证什么 | 第 *n* 块瓦片是不是正好落在单元格 `(tx*tileCols+1, ty*tileRows+1)` 上，占位尺寸也对 |
| 通过 | 每块瓦片都有 3 px 白边，没有缝隙、没有重叠，而且每块瓦片的边框都完整可见 |
| 失败 | 某一边的边框不见了（重叠）、变成双线（缝隙），或者最后一行/一列瓦片位置不对 |

```bash
KRD_GRID=1 krd --selftest --no-input
```

每块瓦片按自己的序号取一个与众不同的颜色（`55 + (index*37)%200`、`55 + (index*71)%200`，蓝色固定
200）加一圈白边，然后同一帧按 200 ms 间隔重发 20 次（这样一旦某次放置丢了，就会表现为某块瓦片在后续
某一趟里消失），最后再保持 60 s，让你有足够时间截图数瓦片。边缘瓦片本来就该小一些 —— 默认 16×8 分块、
137 格宽的 pane，最后一列是 9 格宽，最后一行 4 格高。

## 3. `KRD_QUADRANTS=1` —— 这个终端认哪一种发图方式？

| | |
|---|---|
| 验证什么 | 终端对「让同一张图出现在屏幕上」的四种方式各自的支持情况 |
| 通过 | 你能说清哪几个象限出现了，并且和 krd 实际用的方式（象限 2）对得上 |
| 失败 | 一个都没出现（根本没有图形协议） |

```bash
KRD_QUADRANTS=1 krd --selftest --no-input
```

四块画面间隔 400 ms 依次画出，一个象限一块（各带 6 px 黑边），每种用不同的协议形状：

| 象限 | 发图方式 | 含义 |
|---|---|---|
| 左上 | `a=T` 带 `i=` | 传输并显示，按 id 寻址 |
| 右上 | `a=T` 不带 `i=` | 传输并显示，不带 id |
| 左下 | `a=t` + `a=p`，带 `i=`/`p=`/`C=1`/`c`/`r` | **krd 生产环境用的就是这一种** |
| 右下 | `a=T` 带 `i=`，包在 `?2026` 块里 | 与左上相同，只是走同步块 |

四块画完之后保持 6 s，然后 —— 只有在 `KRD_DELTEST=1` 时 —— 单独发一个
`ESC_Ga=d,i=901ESC\`，并且**不在**任何同步块里，再保持 20 s。

`KRD_DELTEST=1` 回答的是另一个问题：这个终端的 `a=d,i=<id>` 只删掉那一张图，还是把整套图集都删掉？
盯着左上那块（id 900）：它必须活着，同时 id 901 那块消失。如果全都消失了，那这个终端就是 krd 从来
不发逐块删除的原因之一（见 [PROTOCOL §6.3](PROTOCOL.zh-CN.md#63-固定-id不删除)）。

## 4. `KRD_Q=0` —— 看见协议回复

| | |
|---|---|
| 验证什么 | 你发出去的负载到底有没有被接受（`OK`），没被接受又是为什么 |
| 通过 | 任何地方都没有 `EINVAL`/`ENOENT` |
| 失败 | `EINVAL: decompression failed` → zlib 封装错了（用了裸 DEFLATE 而不是 RFC 1950） |

每个转义序列默认都带 `q=2`（所有回复都被吞掉）。`KRD_Q=0` 让它们全都上来，`KRD_Q=1` 只放错误上来。
这个值会原样写进 `q=` 字段，所以协议里定义的任何取值都能用。

回复是从 **stdin** 上来的，而 stdin 同时也是输入源，于是一条回复会被当成按键解析（先是 Alt-`G`，后面
的当文字）。所以永远配 `--no-input` 一起用：

```bash
KRD_Q=0 krd --selftest --no-input      # watch replies in the pane, nothing is typed into the desktop
```

## 5. `--bench` —— 不接终端测编码器

`krd --bench` 在合成帧上跑真实的瓦片流水线（提取 → compress → base64 → 转义序列），逐场景打印字节数和
毫秒数。它自己退出、不需要 tty，所以是横向对比两个构建的办法：

```sh
.build/release/krd --bench --pane 137x44 --cell 17x33 --log /tmp/bench.log; cat /tmp/bench.log
```

场景列表和窗格尺寸是刻意固定的；`--tile`、`--format` 决定测什么。当前数字和取舍理由见
[ENCODING.zh-CN.md](ENCODING.zh-CN.md)。

## 6. `KRD_DUMP=<path>` —— 每一个字节，离线看

| | |
|---|---|
| 验证什么 | 究竟发了什么，和屏幕上显示成什么样无关 |
| 通过 | dump 里先是会话框架，然后每帧一个 `?2026h`，每块脏瓦片是 CUP、`f=24,…,a=t,…,i=<100+n>`、4096 字符分块、`a=p` 放置，最后 `?2026l` |
| 失败 | 不适用：字节都在你手里，自己数就行 —— 这正是它的价值 |

```bash
KRD_DUMP=/tmp/krd-dump.bin krd --selftest --no-input > /dev/null
xxd /tmp/krd-dump.bin | head -40
wc -c /tmp/krd-dump.bin
```

文件在第一次使用时被截断，之后接收每一个 flush 出去的缓冲区，包括自愈序列和 `2J` 清屏，所以它是一份
忠实记录。比较两份 dump（比如 `--tile 16x8` 对 `--full-frame`）是看出协议变化最快的办法。只想要 dump
的时候把 stdout 重定向到 `/dev/null` —— 否则同样的转义序列也会打到终端上。

## 7. `--dry-run` —— 只解析输入，不产生后果

| | |
|---|---|
| 验证什么 | 一次点击或一个按键是否被解析成你期望的坐标/键码，而且是在注入任何东西之前 |
| 通过 | 日志行里的单元格/像素坐标和映射出来的屏幕点都合理 |
| 失败 | 什么都没记（stdin 不是 tty，或者开了 `--no-input`） |

```bash
krd --dry-run --debug              # trace goes to $TMPDIR/krd-<pid>.log, path printed on stderr
krd --dry-run --log /tmp/input.log # or straight to a known file
```

只用 `--dry-run` 是个坑：不给 `--debug`/`--log` 的话，轨迹会走 stderr —— 也就是直接糊在画面上，每写
一行光标就移一次，一滚屏瓦片就碎了。要看的行：

```
input: raw 6 bytes: 1b 5b 3c 30 3b 31 …
input: mouse px(437,812) -> (1204,733) type=1
input: key code=0 flags=256
```

`raw …` 证明终端确实送了东西；映射那一行证明几何是对的；如果第一行有、第二行没有，那要么事件落在了
放置区域之外（点到了画面外面），要么解析器把它丢了。

## 8. 其余开关

| 开关 | 验证什么 |
|---|---|
| `KRD_NOSYNC=1` | 在某台终端上破坏放置的，是不是每块瓦片外面那层 `?2026h/?2026l` |
| `KRD_NO_NSAPP=1` | 复现「ScreenCaptureKit 只送一帧就停」（没有 AppKit 上下文）—— 这是对照组，不是功能 |
| `--full-frame` | 非瓦片路径：一个 image id、每帧一个 `?2026` 块；用它区分「瓦片 bug」和「协议 bug」 |
| `--log <path>` | 写文件日志，但不带统计计时器和输入轨迹 |
| `--debug` | 统计计时器 + 几何 dump + 输入轨迹 + `AXIsProcessTrusted()` |
| `--list` | 屏幕录制权限，以及显示器/窗口枚举，全都在碰任何像素之前 |
| `-v`、`--version` | 手里这个二进制是不是你以为的那个：和 `VERSION` 文件、release tag 对一遍（`scripts/release.sh` 让两者保持同步） |

`stats:` 行，开 `--debug` 时每秒一行（逐字段解释见
[ARCHITECTURE §9](ARCHITECTURE.zh-CN.md#9-诊断开关的接线)）：

```
stats: 113 tiles/s  1 dirty  8 KB  3.88 MB/s  ms[zlib=1 write=0]  2329x1452 px 137x44 cells  idle=3 bad=0
```

怎么读：`tiles/s 0` 且 `dirty 0` 持续好几秒 = 什么都没变（或者什么都没来）；`idle` 一直在涨 = 采集侧
还活着，但屏幕是静止的；`bad` 一直在涨 = 采集自己在矛盾（帧声称 `complete` 却没有可用的画面），
那是真的采集/缓冲问题，不是屏幕安静；`write` 经常到几十毫秒 = 终端跟不上这个字节速率，把 `--fps`
调低，或者把瓦片调大。

## 9. 标定一台新终端

每支持一台终端，就按下面的顺序跑一遍，把答案记到 README 的兼容矩阵里
（[中文](../README.zh-CN.md#终端兼容矩阵) / [English](../README.md#terminal-compatibility)）：

1. `krd --selftest --no-input` —— 到底有没有图形协议？（象限 + 扫动的亮条）
2. `KRD_GRID=1 krd --selftest --no-input` —— 定位准不准？（白边、没有缝隙/重叠）
3. `KRD_QUADRANTS=1 krd --selftest --no-input` —— 哪几种发图方式能用？（象限表）
4. `KRD_QUADRANTS=1 KRD_DELTEST=1 krd --selftest --no-input` —— `a=d,i=` 删掉的是一张还是全部？
5. `KRD_Q=0 krd --selftest --no-input` —— 有没有 `EINVAL`/`ENOENT`？
6. `krd --list`，然后 `krd --fps 20 --debug` —— 采集通了、统计非零、画面跟着屏幕动
7. `krd --dry-run --debug` —— 鼠标上报给的是单元格还是像素？（拿已知单元格上的一次点击和日志里的点
   对比；如果出现 `px(...)`，说明这个终端认 `?1016h`）
8. `krd --fps 20 --debug` 加 `--dry-run` —— 不点击、只移动指针：远端光标跟不跟？不跟的话，说明这个
   终端忽略了 `?1003h`（任意移动上报）；点击和拖动仍然可用，悬停不行

## 10. 独立交叉验证（`probe/`）

纯 Python 脚本，只用标准库，不涉及 Swift，也不涉及 krd。要判断「这是终端的问题还是 krd 的问题」，
它们是最快的办法 —— 每个脚本都会自己把过程讲一遍：

| 脚本 | 问题 |
|---|---|
| `probe/kprobe4.py` | 单台终端的能力矩阵：`a=q`、`a=t` PNG、带 `c/r` 的 `a=p`、`x/y`、`X/Y`、`z`、`a=f`、`o=z`、裸 `f=24`、file medium、分块、删除 |
| `probe/kshow.py` | 走朴素的 `t=d` 内联路径画一张 PNG（已知可用的基线） |
| `probe/tile_test.py` | 哪一种定位方式能落在正确的地方（仅 c/r、光标锚定、`x/y`、`X/Y`） |
| `probe/tile_ab.py` | 对四种「把一块瓦片弄上屏」的可行做法做 A/B，都带白边 |
| `probe/rex_delete_probe.py` | 删图 vs 删放置的语义（`a=d,i=`、`a=d,i=,p=`） |
| `probe/kclick.py` | 用一块已知的放置矩形做命中测试，把点击反映射回图像像素 |
| `probe/kdrag.py` | `?1002h ?1006h` 下的按下/拖动/松开 + 滚轮，不重传 |
| `probe/kbench.py`、`probe/kpace.py` | 固定帧率下的管道吞吐与背压 |
| `probe/termcaps.py` | 一台终端上 UI 能假设的一切、以及问一次的代价：身份、`U=1`、`a=f`、键盘、尺寸、颜色、DECRQM、2033/2048 的即时报告、字形宽度（开/关 2027）、REP、DSR 往返、20 个查询逐个问 vs 一次写完。本地和 `ssh -t` 各跑一次对比（`--json`、`--report`） |
| `probe/placeholder_overlay.py` | 在 `U=1` 占位符格子上写文字会不会把那里的图盖掉（mirror 上的浮层），把占位符写回去能不能不重发就让图回来，OSC 22 会不会改指针形状。文字层永远显示浮层，所以要看像素：截屏，看三个区块里还有没有品红的图 |
| `probe/sck_probe.swift` | `CGPreflightScreenCaptureAccess()`、`CGPreflightPostEventAccess()`、显示器/窗口枚举（在目标 Mac 上跑，看 TCC 是不是问题所在） |
| `probe/zoom_update_probe.swift` | 运行中的 `SCStream` 能否用 `updateConfiguration` 就地改裁剪：10 次平移的延迟、稳定帧数、像素证据，以及每次裁剪内的活性检查（issue #54 就是先过这道门） |
| `probe/display_probe.swift` | 哪种显示器变化机制会触发：`now`、`list`、`set <i>`（真的改分辨率）、`watch [--appkit]` 十秒内打印 CoreGraphics 回调与 AppKit 通知 |
| `probe/scale_probe.py` | `--scale` 换来了什么（字节/秒、CPU、原始帧尺寸、从流里读回的 kitty placement 框），以及它会不会移动指针：同一个终端像素在两种缩放下各点一次，比较 TextEdit 的光标位置 |
| `probe/ax_caret_probe.swift` | 上面那个指针测试的验证器：读 `AXSelectedTextRange` 和文本区 frame，每个窗口一行、最前面的在前 |
| `probe/click_probe.py` | 在镜像窗口里点一个对照控件（`--control "New Tab"`），对每个 `--scale`、以及比窗口大和比窗口小的 pane 各点一次，打印点击前后的标签页数：`--scale` 不得改变图的 placement，点在「宽高比没占满的格子」上必须被忽略 |
| `probe/pipe_probe.py` | 把 krd 放到「吃不下的链路」后面：按固定速率（且可中途改速）读 pty，于是能看着 `--scale auto` 一格一格降下去再升回来。每秒打印 scale、`late`、fps、MB/s，以及流重启次数 |
| `probe/photo_codec.py` | issue #26 各方案（16 位量化、更少像素、不压 zlib）下彩色重内容一帧的字节数，用同一套 kitty framing，基线行与 `krd --bench` 的 `photo` 字节一致 |
| `probe/ax_probe.swift` | headless 客户端能读到什么：AX 的 warm-up 陷阱、不依赖屏录的窗口清单、逐窗口节点数与 walk 耗时、剪枝前后体积（只读） |

```bash
python3 probe/kprobe4.py > /tmp/p4.log 2>&1 ; cat /tmp/p4.log
swift probe/sck_probe.swift   # on the machine being viewed
swift probe/ax_probe.swift    # 最好在 ssh 里跑：那里第一次 AX 调用会失败到 warm-up 为止
```

### 重新生成宽度表

`Sources/krd/WidthTable.swift` 是生成的，不是手写的：`DisplayWidth` 回答的是「占几格」，而这件事唯一的权威是
终端本身，所以这张表是从 libghostty 自己的 Unicode 表里读出来的——用的就是 UI v2 方案里当参照终端的那个版本
（v1.4.0）。

```bash
git clone --depth 1 --branch v1.4.0 https://github.com/ghostty-org/ghostty /tmp/krd-spike/ghostty
cd /tmp/krd-spike/ghostty && zig build -Demit-lib-vt -Doptimize=ReleaseFast
cd - && scripts/gen-widths.sh                       # 或：scripts/gen-widths.sh <checkout>
swift test --filter WidthTableTests                 # 拿终端自己的答案验这张表
```

脚本拒绝装上一张少了任何一组集合的表（`wide` 空掉照样能编译，然后所有 CJK 都画成一格），生成文件的头里写着
它读的是哪个 tag。正常构建既不需要 Zig 也不需要那份 checkout：表是提交进仓库的。

`WidthTableTests` 里约 50 个字符串的期望宽度是 libghostty 自己算出来的，所以一次让答案变了的重新生成会表现为
一条失败的测试，而不是「文字排在了错误的列上」。最要紧的两条：`☰` 和国旗是 **2 格**，没有 VS16 的 emoji
码点（`🖥`、`⚙`）是 **1 格**。

## 11. 浸泡测试：全功能开 30 分钟

11 个 feature 是在一轮里落地的（#15 键盘协议、#16 `--ime`、#17 定向投递输入、#18 剪贴板桥、#19
显示器集合变化、#22 `--zoom`、#24 backdrop 拒绝、#25 空闲帧统计、#27/#28 `krd ax`、#31 CI 预算）。
每一个都单独 review、单独测过，所以**没人做过的正是「组合 + 时间」**——而它们每个都加了只会慢慢出问题
的东西：一个 pasteboard 轮询、一个显示器定时器、每次平移一次采集流重启、每次 dump 一个快照文件。

```bash
swift build -c release
scp .build/release/krd target:/tmp/krd-soak && scp probe/soak.py target:/tmp/
ssh target 'cd /tmp && python3 soak.py --minutes 30 --binary /tmp/krd-soak \
             --work /tmp/krd-soak --out /tmp/krd-soak/report.json'
```

退出码 0 即通过。改脚本时用短跑冒烟（`--minutes 2 --interval 10`）。脚本还会给 pty 设一个窗口尺寸
（`TIOCSWINSZ`，60x24 格、每格 17x33 px）：不设的话 krd 从终端读到 0x0，回退成 1x1 格的 pane，镜像出来的
画面是 136x132 px 的「什么也没有」。下面的表格是在这行代码之前测的——内存、fds、线程不受影响，
tile 数与 `delivered` 是小 pane 的数字，和真实会话不可比。它每 30 秒采一次 RSS
（`ps -o rss=`）、fds（`lsof`）、threads（`ps -M`）和 `krd ax` 状态目录大小，同时开着
`--stats-json`，并且一直戳那些「只在长时间里漏」的路径：

| 压力 | 频率 | 压的是什么 |
|---|---|---|
| `pbcopy`，16 B … 8 KB 随机文本 | 60 秒 | pasteboard `changeCount` 轮询 → OSC 52 编码 → 写出去（#18） |
| `krd ax tree --app Finder` | 60 秒 | 每次 dump 一个快照文件，每窗口保留 16 个（#28） |
| 指针扫动（SGR mouse 报文写进 pty），从左下到右上 | 60–120 秒 | 指针跟随与 `--zoom-follow`，即每次平移一次采集流重启（#22） |
| （被动） | 2 Hz | #19 的显示器集合指纹轮询 |

### 它发现了什么

在 `kraal-agent`（macOS 26.6.2，M1 Pro 虚拟机）上跑了三次，参数相同（`--zoom 2 --zoom-follow
--clipboard=in --pane 60x24 --cell 17x33`）：

| 轮次 | 构建 | 内存 / fds / threads | 画面 |
|---|---|---|---|
| A，30 分钟 | `cadf25e` | 全平：RSS 31.3 → 31.6 MB，fds 25–26，threads 13→14，`krd ax` 72 KB（16 个快照，已修剪），stats 间隙 1.0 秒 | **第 10 分钟起冻住**，之后 19 分钟一直冻着 |
| B，30 分钟 | A + `didStopWithError` 后重启 | 全平：RSS 31.2 → 31.5 MB，fds 25–27，threads 13→15，`krd ax` 72 KB | 恢复过一次，然后又冻了 19 分钟 |
| C，12 分钟 | B + 给 `stopCapture()` 加上限 + 帧看门狗 | 全平：RSS 31.3 → 31.6 MB，fds 19–25，threads ≤15，`krd ax` 52 KB | 第 10 分钟被重启救回来了，第 11 分钟整个主队列卡死 |

**没有任何东西泄漏。** 四次运行（两次是完整的 30 分钟），每轮 12–30 次 pasteboard 写入、同样次数的
`krd ax` 快照 dump、12–15 次采集流重启：RSS 只动 0.3–0.4 MB，fds 动一两个，threads 每次重启后都会回落，
快照目录恰好停在 16 个文件。这就是 issue #44 那个问题的答案。

坏掉的是「投递」，在有重启的运行里大约第 10 分钟：

```
krd: capture stopped: Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3805
     "Failed during stream due to application connection being interrupted"
```

以前 krd 写完这一行就继续跑：`callbacks` 再也不动，`delivered` 冻住，`bad` 一直是 0，RSS/fds/threads
全平，stats 定时器照常写。**从外面看——以及从这个脚本当初要盯的每一个数字看——一切正常。** 所以 A 轮最初
的判定是 PASS，而画面其实已经冻了 19 分钟；下面那条 `frames` 规则就是为它加的。

### 因此改了什么

- `didStopWithError` 现在会重启采集流，最多五次、退避 1-2-4-8-8 秒，每次尝试都写日志
  （`krd: capture stopped (SCStream -3805: …); restarting in 1s (attempt 1/5)`）。
- `Capturer.stop()` 最多等 2 秒。在已经死掉的流上调 `stopCapture()` 在这个系统上不会回调，而
  `restartCapture` 要等它返回才清掉「有重启在飞」的标志——一次卡住的 stop 就把之后所有重启都堵死，
  包括那个能把画面救回来的。C 轮之所以还会冻，是因为**下一个**问题：
- **仍然未解决：** 那次恢复之后整个主队列卡死（看门狗自己的 5 秒 tick 不再出现在日志里，线程掉到 8，
  画面冻住），而进程还活着。下一步是 `probe/soak.py` 现在会自动抓的栈采样：`callbacks` 静止满一分钟时
  写一份 `<work>/sample.txt`，它会告诉我们卡在 `SCStream` 调用里，还是卡在采集队列的 `write(2)` 后面。

### 判定规则，以及为什么是这些形状

| 规则 | 阈值 | 理由 |
|---|---|---|
| RSS | 峰值 − 基线 < 10 MB | issue 里给的数字；30 分钟漏不到 10 MB 的漏不是我们要防的那种 |
| fds | 后半程不得比前半程最大值再高出 2 | **最大值在上升**才是泄漏特征；`lsof` 抓到瞬时描述符不算 |
| threads | 同上 | SCK 工作线程随采集流重启来去，数字上下波动是正常的 |
| `krd ax` 状态目录 | < 64 MB | 设计就是每窗口 16 个快照；实测停在 72 KB、文件数恰好 16 |
| stats 节奏 | 无 > 5 秒间隙 | 写阻塞或回调卡住会先在这里露头 |
| **有回音** | 每次压力动作都必须在 20 秒内换到一帧（`ANSWER_SECONDS`） | 真正要防的是「问它要东西、它什么也没回」，而不是沉默：静止桌面本来一帧都不发（实测 1 秒窗口 0 帧、指针扫动之间 56 秒空档） |
| 帧（只报告，不判失败） | `callbacks` 最长静止窗口 | 保留这个数字，因为死掉的流**也**长这样；它自己不能当判据——这正是当初「冻结 30 分钟即失败」那条规则学到的教训 |

最后一行是这次练习的教训，也是脚本要在内存数字旁边一并报 `saw N OSC 52` / `N transmits` 的原因：只测
「增长」的浸泡测试，分不清「稳定」和「已经不动了」。

### 不覆盖什么

- `--window` 模式（#17）采单窗口而不是显示器，定向投递输入在本轮是闲着的；`--ime` 同样（没有打字）。
- 内容基本是静止的虚拟机桌面，编码器几乎没被压到。要压编码把 `--extra` 指到会动的画面。
- 单显示器虚拟机测不了 #19 的拔线路径（那条有自己的测试和 probe）。
- 30 分钟不是一天；而且这台虚拟机的 ScreenCaptureKit 明显比真机脆：重启十次后出 `-3805` 可能只是 VM 的
  问题。看门狗和重启的意义正是让这个差别不再致命。
