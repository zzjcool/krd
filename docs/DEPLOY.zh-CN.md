# 部署

[English](DEPLOY.md) | 简体中文

krd 就是一个自包含的 Mach-O 二进制。没有要安装的东西，也没有会自己启动的东西：把文件拷过去，
一次性授权两项权限，之后想在谁的终端上看桌面，就在哪条 SSH 会话里跑它。会话结束它就退出。

## 0. 一条命令

在**被观看**的那台 Mac 上（如果你要镜像的是自己这台，就在本机）：

```bash
curl -fsSL https://raw.githubusercontent.com/zzjcool/krd/main/install.sh | sh
```

它会解析最新 release、下载 `krd-vX.Y.Z-macos-universal.tar.gz`、校验 sha256、用你的
`Apple Development` 身份签名（没有就退到 ad-hoc），装到 `~/bin/krd`。
可选参数：`--prefix DIR`、`--version vX.Y.Z`、`--sign IDENTITY`、`--from-source`。
下面写的就是这个脚本干的事，外加必须手工处理的情况。

## 1. 目标 Mac 需要什么

- macOS 14 (Sonoma) 或更新。
- 打开**远程登录**：系统设置 → 通用 → 共享 → 远程登录。这一步需要图形界面（或用管理员跑
  `systemsetup`）；`deploy.sh` *不会*替你做。
- 其它什么都不用：不需要 Swift 工具链、不需要 Python、不需要 Xcode —— 二进制是整块拷过去的。
- 大约 5 MB 磁盘空间。

*看*的那台机器需要一个实现了 kitty 图形协议的终端（见 [README 的兼容矩阵](../README.zh-CN.md#终端兼容矩阵)）
和一个 `ssh` 客户端。

## 2. 部署

在一份本仓库的检出里，于一台装了 Xcode command line tools 的 Mac 上：

```bash
./deploy.sh user@host                    # → 目标机的 ~/bin/krd
./deploy.sh user@host /usr/local/bin/krd # 指定目标路径
```

脚本做了什么：

1. `swift build -c release --arch arm64 --arch x86_64` —— 一个 universal 二进制，目标机是什么架构都行。
2. 用 `install.sh` 用的同一个身份签名（`security find-identity -v -p codesigning` 里第一个
   `Apple Development: …`；可用 `KRD_SIGN_IDENTITY=…` 覆盖），并强制 identifier 为 `com.kkrt.macdesk`。
3. 打印架构和体积，然后用 `cat | ssh "cat > …"` 把签名过的文件流式拷过去，签名逐字节保留
   （有些服务器的 `scp`/`sftp` 是关的）。
4. 打印安装后的字节数，以及从 `codesign -dv` 里取出的 identifier。

远端目录必须事先存在 —— `cat > ~/bin/krd` 不会顺手创建 `~/bin`：

```bash
ssh user@host 'mkdir -p ~/bin'
./deploy.sh user@host
```

想走手工路线（同架构，不编 universal）也可以：

```bash
scripts/install-from-source.sh      # 本机编译、签名、装到 ~/bin/krd
scp ~/bin/krd user@host:~/bin/krd   # 或者：cat ~/bin/krd | ssh user@host 'cat > ~/bin/krd'
ssh user@host 'codesign -dv ~/bin/krd 2>&1 | head -3'
```

复制一个*已签名*的文件没问题；但在目标机上重新签名不行（见 §4）。

### 本机没有工具链：用 Release 里的 tarball

每次发版（`v*` tag 触发 `.github/workflows/release.yml`）都会在 Releases 页面上传
`krd-vX.Y.Z-macos-universal.tar.gz` 和对应的 `.sha256`。那个二进制是 CI 编的，**没有**用任何本地身份
签名，所以第一次跑之前自己签一下 —— TCC 授权挂在签名上，未签名/ad-hoc 的二进制每重编一次都要重新授权：

```bash
curl -LO https://github.com/zzjcool/krd/releases/download/vX.Y.Z/krd-vX.Y.Z-macos-universal.tar.gz
shasum -a 256 -c krd-vX.Y.Z-macos-universal.tar.gz.sha256    # 或者自己跟一眼
tar xzf krd-vX.Y.Z-macos-universal.tar.gz && cd krd-vX.Y.Z-macos-universal
codesign --force --sign "Apple Development: …" --identifier com.kkrt.macdesk krd
cat krd | ssh user@host 'cat > ~/bin/krd && chmod +x ~/bin/krd'
ssh user@host '~/bin/krd --version'      # 应该是 X.Y.Z
```

## 3. 第一次运行：两项 TCC 授权

屏幕录制和辅助功能是两项独立授权，而且都是「每台机器一份」：

| 授权 | 用来做什么 | 没有它会怎样 |
|---|---|---|
| 屏幕录制 | ScreenCaptureKit 采集，以及 `--list` | 采集报 `-3801 user declined`，或者 pane 一直是黑的 |
| 辅助功能 | `CGEvent` 注入（鼠标、键盘） | 画面正常，但任何操作都没反应 |

这一步请**在目标 Mac 上、用它自己的图形界面终端**（Terminal.app 之类）做一次，不要从 SSH 会话里做 ——
macOS 不会给一个由 `sshd` 拉起的进程弹授权框，而你看不见的弹框等于没法点「允许」：

```bash
~/bin/krd --list        # 触发「屏幕录制」弹框 → 允许
~/bin/krd --fps 20      # 触发「辅助功能」弹框 → 允许（画面会立刻出来）
# Ctrl-\ 退出
```

### macOS 26+：授权发给「负责的进程」，永远不会发给 krd

TCC 不问调用 ScreenCaptureKit 的那个进程，而是问它的**负责进程**（responsible process）—— 用户实际启动的
那个 App，或者这个会话登录所在的进程 —— 一份授权覆盖这个会话里跑的所有东西。本仓库实测（issue #219，证据在
PR 里）：

| krd 是从哪里启动的 | 需要被授权的是谁 | 在那里 krd 的表现 |
|---|---|---|
| 图形界面终端（Terminal、WezTerm、iTerm、Ghostty、Rex） | **那个终端 App** | 第一次弹一次框；之后这个终端里的每个 krd、每次重编都能采集 |
| SSH 会话 | **`/usr/libexec/sshd-keygen-wrapper`** —— `sshd` 跑会话的那个进程 | 不会弹框（没有图形会话）；这个会话里任何二进制都能采集，签名什么都无所谓 |
| `launchd` 任务、没有图形会话的 CI 步骤 | **二进制自己** | 只有这一种情况下「给二进制签名」才有意义 |

所以走 SSH 时，授权不是 krd 自己能拿到的，重签多少次都改不了这个答案。改去授权那个 wrapper —— 每台机器一次，
之后所有 SSH 里的 krd 都能用：

```
系统设置 → 隐私与安全性 → 屏幕录制 → +
  → Cmd-Shift-G → /usr/libexec/sshd-keygen-wrapper → 打开 → 勾上
  → 重连 SSH（`sshd` 每个会话重新读一次授权），再跑 `ssh host ~/bin/krd --list`
```

被拒时 krd 现在就说上表里的那个名字 —— 不再是「this binary」，那是永远给不出去的答案：

```
krd: grant Screen Recording to rex in System Settings > Privacy & Security > Screen Recording, then re-run
krd: grant Screen Recording to /usr/libexec/sshd-keygen-wrapper (the process an SSH session runs under)
     in System Settings > Privacy & Security > Screen Recording, then reconnect and re-run
```

墙的页脚用一行说同一件事（`no picture - grant Screen Recording to …`）；`--mirror` 起不来时会说
`Screen Recording is off for this SSH session - grant it to …`，而不是一声不响地退出。

**`tccutil reset ScreenCapture com.kkrt.macdesk` 不是检查手段。** 它回 `-10814 No such bundle identifier`，
是因为它只经 LaunchServices 解析 **bundle** identifier，而裸可执行文件的 identifier 根本不在那一类里 ——
同时授权（`/usr/libexec/sshd-keygen-wrapper` 这种按路径记的 client）好端端地就在那里。issue #219 的报告者
把这句话读成了「krd 没有 TCC 记录」，这句话本身对，但和能不能采集无关：下文两台机器都没有 krd 的记录，两台都能采集。

**在终端里、以及在 SSH 下，`+` 加 `~/bin/krd` 没有用** —— macOS 在那儿根本不问 krd。只有表里第三行
（完全没有图形祖先）才值得这么做。

**tmux 那个偏方（从有授权的图形终端里起一个 tmux server，然后 `ssh -t host 'tmux attach'`）本车道没能验证。**
它和规则是一致的 —— 子进程继承「启动整条链的那个 App」，而从终端里起的 tmux server 就是那个终端的子进程 ——
但没法端到端跑：宿主机的 sshd 没开，测试 VM 的 SSH 会话已经由 wrapper 授权（要撤销就得写 TCC 数据库）。
已验证的解法是授权 wrapper；tmux 请当作未测。

如果 **辅助功能** 压根不弹框，就手动加：系统设置 → 隐私与安全性 → **辅助功能** → `+` → 选中 `~/bin/krd`
（按 `Cmd-Shift-G` 可以直接输路径）→ 打开开关。过期条目用 `−` 删掉。

授权卡住时，也可以用命令行把记录清掉重来：

```bash
tccutil reset ScreenCapture com.kkrt.macdesk
tccutil reset Accessibility com.kkrt.macdesk
```

（`tccutil` 不需要 sudo；这里的 identifier 就是 `install.sh`/`deploy.sh` 冻住的那个。它只能碰到记在
**bundle** identifier 上的授权，所以在 macOS 26 上它通常只会告诉你「没东西可重置」—— 见上。）

`--debug` 会在日志里记 `krd: accessibility trusted=true|false`，采集失败也会把具体错误写进日志 ——
先看日志，别猜。

## 4. 签名稳定性（它管什么、不管什么）

上文的授权属于**负责进程**（§3），所以在 macOS 26 上「签名稳定」并不决定一个会话能不能采集：一个刚编出来的
`Signature=adhoc` 二进制，从已授权的终端 App 里能采集，从已授权 wrapper 的 SSH 里也能采集（两项都实测过）。
签名仍然决定的是：

- **记在二进制自己身上的授权**（用 `+` 加的那种，或表里 `launchd` 那一行）是按代码要求（csreq）匹配的，
  ad-hoc 签名会让它失效：每次编译都是新 cdhash，记录对不上。所以 `install.sh`/`deploy.sh` 在有身份时
  仍然用你的身份签，退到 ad-hoc 时会警告。
- **identifier**（`com.kkrt.macdesk`）就是这种记录的键；改掉它 —— 哪怕只是改成「更好看的名字」——
  macOS 就会把它当成一个新 App 重新要授权。
- **安装路径**同样要稳：同一份二进制的第二个副本就是第二条记录，而第一条从此指向空气。
- **绝对不要在目标机上 `strip`、重签或 `xattr` 这个二进制。** 本地重编、本地重签、再拷一次。
- 所以升级流程是：停掉 krd → `./deploy.sh user@host` → 再运行。终端与 SSH 两种情况不用重新授权，
  按二进制记的那种也不用 —— 因为身份和 identifier 都没变。

确认装上去的到底是什么：

```bash
ssh user@host 'codesign -dv ~/bin/krd 2>&1 | head -5; file ~/bin/krd; ls -l ~/bin/krd; ~/bin/krd --version'
```

期望看到：`Identifier=com.kkrt.macdesk`、用你自己的身份签的名（不是 `Signature=adhoc`）、
`Mach-O universal binary with 2 architectures`、和 `deploy.sh` 打印一致的字节数，以及 `VERSION` /
`Sources/krd/Version.swift` 里的那个版本号。

## 5. 日常使用

```bash
ssh -t user@host ~/bin/krd --fps 20 --debug --log ~/krd.log
```

- **`-t` 是必须的。** stdin 没有 tty 时 krd 会禁用输入并退回 80×24 格。
- `--log ~/krd.log` 把日志固定在一个你能读的位置（另一个会话里 `ssh user@host tail -f ~/krd.log`）。
  不给的话，`--debug` 会写到目标机的 `$TMPDIR/krd-<pid>.log`，并在 stderr 上把这个路径打一次。
- `--fps 20` 是默认值；局域网可以调高，慢链路调低。瓦片让字节率只和真正变化的面积有关，所以 `--fps`
  主要买的是手感，不是带宽。
- 网络断了 pty 就死，krd 跟着结束（它处理 `SIGHUP`/`SIGTERM` 并恢复终端）。在不可靠链路上跑长会话时
  加 `-o ServerAliveInterval=30 -o ServerAliveCountMax=3`，让会话早点干净地断开，而不是挂着不动。

之后就当本地桌面用：点击、拖动、滚轮、打字。Ctrl-\\ 退出，终端状态是干净的。

## 6. 运维注意

- **你不启动，它就不存在。** krd 就是你 SSH 会话里的一个前台进程；你走了它也就没了。没有其他东西要安装、
  要启用、要保活。
- **目标机不开任何端口。** 一切都走 SSH 会话，所以不需要防火墙规则，也不存在「谁能连上这个服务」的问题 ——
  连 SSH 都进不来的人本来也碰不到它。
- **睡眠会中断画面。** krd 不会阻止 Mac 睡眠；会话睡眠或锁屏之后 macOS 就不再给屏幕内容了（黑帧）。
- **一个会话一个进程。** 每条 SSH 会话启动自己的 krd、自己的一条采集流 —— 两三个观看者没问题，再多就浪费了。
- **卸载**就是 `rm ~/bin/krd`，再去隐私与安全性里删掉那两条记录。没有收据、没有 plist、没有缓存要清。

## 7. 部署到多台 Mac

```bash
for host in mac-mini@10.0.0.11 macbook@10.0.0.12; do
  ssh "$host" 'mkdir -p ~/bin'
  ./deploy.sh "$host"
done
```

每台仍然要各自做一次授权（§3）—— 授权是按机器记的，不能转移 —— 但注意被授权的是**谁**：
如果你在那台机器上也会从窗口里跑 krd，就是那个终端 App；如果你只在 SSH 里跑，就是
`/usr/libexec/sshd-keygen-wrapper`。
