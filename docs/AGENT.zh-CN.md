# 用 agent 的方式做 krd

[English](AGENT.md) | 简体中文

这份文档写给"看不见屏幕、用不了鼠标、只看你留在磁盘上什么"的无人值守运行。完整英文版是
[AGENT.md](AGENT.md)，每个命令的参数见 [`agent/README.md`](../agent/README.md)。

## 为什么需要脚手架

krd 的 bug 都在"终端怎么处理一张图"里。`swift test` 能钉住字节，但回答不了"这张图是不是正好填满它的格子"。
而这台能回答问题的 Mac，屏幕大多数时候是锁着的。所以仓库里带了一套脚手架 `agent/`，把每个问题变成
"在一台还能测量的机器上可以被测量的东西"。

```bash
agent/bin/kagent doctor        # 先跑这个。有红项就先停下来，别开始测试。
```

`doctor` 逐项实测：VM 可达、driver 能发事件、能截屏、Accessibility 可读、窗口列表可用、解码器自检通过、
本地构建存在、Rex 可用。**`hand` 红 = 你后面每一次点击都不会发生**，在这种机器上跑测试只会得到假绿。

## 两台机器

| 位置 | 是什么 | 可以 | 绝对不要 |
|---|---|---|---|
| 当前 checkout | 代码 | 改、`swift build`、`swift test`、`kagent --target host` 读 | 在 host 上 `see`/`click`/`type` |
| `ssh krd-vm` | headless tart 虚拟机，1920×1200，权限已给 | `kagent`（默认 `--target vm`）：截图、点击、输入、读 AX | 留下跑着的 krd 或探测窗口 |
| host 上的 Rex 面板 | 唯一有 kitty graphics 的终端 | `rex capture` 读文本层、跑交互式 krd | 抢用户焦点、关用户窗口 |

`kagent` 默认走 VM 就是这个原因。`--target host` 只用于读和构建。

## 一个结论要长什么样

三句话，缺一句这活儿就没干完：

1. **看到了什么，带数字**：`stage 143x46 cells at 2431x1518 px, card 54x20 centred at 45..99`。
   不是"看起来对"。
2. **怎么看到的**：哪条命令、哪一路证据（VM 截图 / 解码后的 escape 流 / AX 树 / 真 Rex 面板）。
   截图和"解码出来的帧"是两种证据，不能互相冒充。
3. **什么情况下它会失败**：那个 check 是什么，它在**改动前**的代码上返回了什么。

## 四个动作

```bash
agent/bin/kagent see --marks --grid 200        # 看：JPEG + 坐标换算一行字 + 可点元素编号
agent/bin/kagent text -i -d 6                  # 读：AX 树按行打印，几百 token，可断言
agent/bin/kagent click --mark 4                # 动：按编号（走 AXPress，失败退到元素中心点）
agent/bin/kagent type "hello"                  #    或按坐标 / 按键 / 拖拽 / 滚轮
agent/bin/kagent wait 'element:button:Save'    # 断言：三态退出码
```

`see` 会把坐标换算写成一行：`point = (image_x * S + x0, image_y * S + y0)`。不想算就用
`click --image X Y`，它读上一帧的换算表——按比例缩放后点偏一个 scale，是这类工具最常见的静默错误。

退出码：`0` 成立 · `1` 不成立 · `2` 用法 · `3` 系统拒绝（TCC）· `4` 环境缺失 · `5` **无法判断**。
"看不了"永远不能当成"没有"。

命名快照让"屏幕有没有变"变成精确断言：

```bash
agent/bin/kagent see --as closed
agent/bin/kagent click 12 10
agent/bin/kagent wait 'diff:closed'      # 有东西画出来了
agent/bin/kagent key escape
agent/bin/kagent wait 'same:closed'      # 屏幕又回到了原样
```

`same:`/`diff:` 比的是 32×24 亮度签名 + 1% 容差，不是哈希：一个闪烁的光标每分钟能把哈希翻 60 次，
用哈希会让所有"屏幕没变"的断言变成掷硬币。

## 没有终端也能看图

这是"图是不是填满它的格子"唯一诚实的答案，也是能在锁屏机器和 CI 上跑的那条路。

```bash
agent/bin/kagent --target host render --pane 146x46 --cell 17x33 --strict-fit -- .build/release/krd --selftest
agent/bin/kagent render --target vm --pane 146x46 --cell 17x33 -- '~/bin/krd' --wall
```

看报告，不要先看图：

```
cells=[29, 2, 87, 28] native=[1479, 924] fit=exact
```

- `misfits: 0` —— 每张图的像素正好等于它的格子盒。非 0 就是**接缝 bug**（1:1 终端会漏黑线，
  这个仓库为此付过两次学费）。
- `placeholder_rects` —— 卡片的格子几何，也就是布局层面该断言的东西。
- `frames` —— 什么都没画出来的渲染器，也不会画错。

`--terminal rex`（默认）会像 Rex 一样回答 krd 的 `U=1` / DSR / 字格尺寸探测。不回答它，krd 会走
另一条回退传输，你测的就不是用户在用的那条路。

## 场景与证明

```bash
agent/bin/kagent run agent/scenarios/screen-changes-and-restores.json
agent/bin/kagent prove --check agent/checks/<复现脚本>.sh --baseline HEAD
```

场景是 JSON：每一步要么是一条命令（和 CLI 完全同一套字符串，所以不可能漂移），要么是一条期望。
失败即停，产物写进 `artifacts/<scenario>-<时间戳>/`：`report.json`、`report.md`、每一帧、transcript。

`prove` 在一个一次性 git worktree 里构建 baseline，拿同一个 check 分别跑两个二进制：

| 结论 | 含义 | 该怎么办 |
|---|---|---|
| `fixed` | 改前失败、改后通过 | 完成 |
| `not-a-bug` | 改前就通过 | 你的 check 没复现任何东西 |
| `not-fixed` | 改后还失败 | 补丁没解决它 |
| `regressed` | 改前通过、改后失败 | 补丁把它弄坏了 |

只有 `fixed` 算数。证据在 `artifacts/<name>/{before.txt,after.txt,state.json}`，直接贴进 PR。

## 修完还要证明没弄坏别的

```bash
swift build -c release && swift test
agent/bin/kagent selftest
agent/bin/kagent run agent/scenarios/screen-changes-and-restores.json
python3 bench/bench.py --quick
```

改测试、改 golden fixture 让测试变绿，是唯一一件永远不能悄悄做的事。

## 无人值守的硬规矩

每条都已经被违反过一次：

1. **不要碰用户的桌面**：host 上禁止 `see`/`click`/`type`，禁止 `screencapture` 整屏"就确认一下"。
2. **同一个目标一次只跑一个场景**：一个指针，一个焦点。
3. **收尾**：删探测窗口；自己起的 krd 卡死了就 `ssh krd-vm 'pkill -9 -x krd'`。
4. **不要留后台进程**在 VM 上：卡住的 krd 会永久占住 ScreenCaptureKit，后面每次运行都像产品 bug。
5. **状态写文件**：`artifacts/<run>/transcript.jsonl` 免费提供，finding 再写一份 `state.json`。
6. **给循环封顶**：每个 finding 最多 3 次尝试，然后记 `inconclusive` 收手。
7. **看不了就说看不了**（退出码 5）。权限问题绝不能变成产品 bug。
8. **不要在写代码的同一个上下文里给自己评分**：回读证据（transcript、before/after 退出码），
   不要读自己的总结。

## 已知的坑

| 坑 | 现象 | 处理 |
|---|---|---|
| 显示休眠会卡死 ScreenCaptureKit | krd 在 `wall cell` 之后不再打印，进程 `Ss+`，`kill` 无效 | `pkill -9 -x krd`，然后 `caffeinate -u -t 10` |
| driver 过期 | 报 "unknown verb" / "no such file" | `kagent doctor --fix`（按源码哈希重建） |
| Chrome/Electron 内容不在 AX 树里 | `kagent text --app Chrome` 几乎空 | 用 `see`，或走 CDP；别下结论说界面是空的 |
| AX 是点、截图是像素 | 点击偏一个 backing scale | 用 `see` 打印的换算；或 `click --image` / `--mark` |
| 菜单栏时钟 | `same:` 每分钟失败一次 | 裁掉时钟（`--rect 0,30,...`）或用命名快照 |
| 菜单项在 AX 树里永远存在 | 菜单没打开也能"找到 About This Mac" | 菜单项在关闭时是 0×0 帧；用像素（`diff:`/`same:`）断言 |

## 数字写在哪

- [`agent/README.md`](../agent/README.md) —— 每个命令和参数。
- [`TESTING.md`](TESTING.md) —— 产品自己的标定开关。
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) —— 这个项目已经付过学费的失败。
- `artifacts/<run>/transcript.jsonl` —— 这次运行到底做了什么。
