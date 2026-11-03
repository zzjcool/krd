# KRD · 寄居蟹

吉祥物定了：**寄居蟹**。壳 = `shell` = 你那个 SSH 会话，桌面住进终端壳里，换壳不换人。

这一页讲的是**怎么画**。造型本身只有一份：`mascot.mjs` 里的路径、渐变、裁切和分组；
下面每一个产物都是从它渲染出来的，没有第二份手抄的蟹。

```
                    docs/brand/tui/mascot.mjs        ← 唯一的源（路径 / 渐变 / 分组 / 8 拍姿态）
                              │
        ┌─────────────────────┼───────────────────────────┬──────────────────────┐
        │                     │                           │                      │
  vector.mjs::svg      vector.mjs::render          swift.mjs ──► MascotArt.swift
        │                     │                           │
  docs/media/mascot.svg   终端精灵图 / lab 页面      MascotRaster.swift（CoreGraphics）
  krd-mark / favicon      （半块 / 字符两态）            │
  krd-favicon（16px 点阵）                          krd 的加载卡（两条传输）
```

## 文件

| 文件 | 是什么 |
| --- | --- |
| `mascot.mjs` | 造型：`scene()` 一层层写出路径/填充/描边/裁切，`beat(i)` 是 8 拍姿态，`spriteView()` 是取景框 |
| `vector.mjs` | 渲染工具：路径扁平化、自己的光栅器（超采样 + 框滤波）、PNG 写出、SVG 写出、包围盒 |
| `swift.mjs` | 代码生成：把一个 lod 的场景 + 姿态表写成 Swift（`MascotArt`） |
| `logo-tui.mjs` | CLI：lab 页面、TUI、以及所有静态产物的入口 |
| `../../Sources/krd/MascotArt.swift` | **生成物**，`make mascot` 重写，不要手改 |
| `../../Sources/krd/MascotRaster.swift` | 手写：CoreGraphics 渲染 `MascotArt`，两条传输共用 |

## 三个尺寸（lod）

| lod | 用在哪 | 画什么 |
| --- | --- | --- |
| `hi` | README 的 SVG、PNG、社交图（512px 起） | 69 层：壳的厚度/内暗面/螺旋脊/高光、四条腿、钳、眼柄、腮红、天线 |
| `lo` | 终端：36 dot 的半块卡、36×45 的图片卡、`--mark` 64px、`--favicon` 16px | 22 层：壳 + 一圈螺纹 + 开口，身体 + 两只大眼 + 嘴；**腿、钳、天线在这个尺寸会糊成一团，故意不画** |

只有两个 lod，没有"小尺寸另画一份"的第三个：`lo` 就是给 36 dot 设计的，16 px 和 64 px 都用它。
`--mark` 是 64 dot 的精灵图（SVG）；`--favicon` 是 14 dot 的精灵图画在 `#080a10` 圆角 tile 上
（点阵，一 run 一个 `<rect>`、`shape-rendering="crispEdges"`）——透明底的 16 px 蟹在浅色标签栏上会散掉。

## CLI

```sh
node logo-tui.mjs                    # 全屏 TUI：8 拍动画、s 拟物/字符、空格暂停、1-8 跳拍、q 退出
node logo-tui.mjs --test             # 布局自检：8..160 列 × 4..40 行，每行严格 cols 宽
node logo-tui.mjs --frames           # 8 拍，按加载卡的画法
node logo-tui.mjs --art              # 46×23 的字符版寄居蟹
node logo-tui.mjs --dump             # 两个 lod 的半块图
node logo-tui.mjs --banner           # --help 的 5 行大写字标
node logo-tui.mjs --shot lab.html    # 一页把每一档尺寸、明暗两态都排出来
node logo-tui.mjs --plain --beat 3   # 管道里只出一张卡（字符版）；默认是半块版

node logo-tui.mjs --svg  mascot.svg  --px 680              # 只画蟹，裁到墨边，透明
node logo-tui.mjs --png  mascot.png  --px 680 [--bg #0d1117]
node logo-tui.mjs --mark krd-mark.svg --px 64
node logo-tui.mjs --favicon krd-favicon.svg --px 16
node logo-tui.mjs --beats mascot-loading.png --px 256      # 图片卡的四帧并排
node logo-tui.mjs --swift Sources/krd/MascotArt.swift      # 生成 Swift
```

零依赖，Node 18+。

## 加载卡（krd 自己画的那张）

首帧到达之前显示，两条传输，**由 `a=f` 探针决定，不猜**（#217 / 设计 §5.1）：

- **终端会播动画**：一张 36×18 的图片，四帧 `a=t`/`a=f`，帧距 220 ms，一次发完 + 一次放置，
  之后 **0 B/tick**。整卡 ~8.6 KB（3 秒窗口，含放置和两行字），预算 4 KB/s。
- **终端不会**：36×36 dot 的 `▀` 半块，110 ms 一跳，8 拍循环，~23 KB/tick——**故意保持原样**，
  这是"改之前"的对照数字，降级路径不允许顺手改画。

两拍是同一只蟹：0.05 → 0.45 → 0.8 → 1（全伸出）→ **1（眨眼）** → 1 → 0.8 → 0.45。
图片卡只发偶数拍（0/2/4/6），4 × 220 ms = 880 ms，正好是原来 8 × 110 ms 的一轮。

图片卡的像素高度由调用方量到的 cell 推出来（`36 · cellH / (2 · cellW)`，8×20 的 cell 是 45 行），
所以图片自己的长宽比等于它占的 cell 盒的长宽比——拉伸型和等比缩放型的终端看起来一样。

## 配色

自然色，不是品牌蓝：壳沙色 `#f3dfb8`、螺纹 `#c4884e` / `#8e643a`、身体珊瑚 `#f4845a`
（渐变到 `#d8603c`）、眼睛奶白 `#fffaf2`、墨 `#3b2416`、纸 `#080a10`。
品牌蓝 `#5eb8ff` 只留**瞳孔里那一点**——一眼是寄居蟹，第二眼才发现那是 krd 的蓝。

## 生成物不许漂

```sh
make mascot         # 重画：MascotArt.swift + docs/media/* + docs/brand/tui/*.svg + shot.html
make mascot-check   # 重新生成一遍比 cmp，再跑 lab 的自检；生成物过期就红
```

`MascotArt.swift` 是生成物：改造型去改 `mascot.mjs`，然后 `make mascot`。
`MascotArtTests` 守的是另一半——生成出来的东西能不能画（每条 paint 都能解析、每个 group 都能解析、
每个颜色都在调色板里、36 dot 下墨量在 25%~55%、四帧互不相同、眨眼真的闭上、纸色在角上精确）。

## 还没做

- `KRD` 大写字标和蟹并排的整体 lockup（横版/竖版、clear space）
- 抓屏动画的 GIF（TUI 里能看，`--shot` 只能出静帧）
- GitHub 社交预览图（1280×640，得把蟹放到品牌底色上）
