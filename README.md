# DSH 急救 · DSH Rescue

DSH 桌面端起不来时的急救工具：先诊断，再按故障类型分档修复，全程可回滚。**只碰配置层，永远不碰你的会话数据。**

**当前版本：v1.0.0**

## 它解决什么问题

DeepSeek Harness 桌面端的 profile 目录（`~/.dsh/profiles/desktop`）里，四个文件决定"启动时装哪些插件、怎么装"：

```
package.json         依赖清单 + bundle 列表
cordis.patch.yml     插件配置覆盖层
pnpm-workspace.yaml  安装方式（hoisted）
pnpm-lock.yaml       锁定的版本树
```

这层被写坏，应用就起不来，报错还各不相同。而真正值钱的东西——会话、附件、记忆、锚点、凭据——都在**别的目录**，从头到尾没坏过。

这个脚本做的事，是把"哪种坏法、该动哪一档、怎么退回去"固化成命令。**它的价值不在修得快，而在让人不在错误的位置动手**——比如对"依赖树污染"类故障执行"清空配置"是无效的，而那一步会顺手丢掉插件配置。

## 快速开始

1. 把 `dsh-rescue.ps1` 放到 `C:\Users\<你>\.dsh\rescue\`（**故意放在 profile 外面**：profile 坏了它还得能用）。
2. 出事时先诊断，别急着动手：

```powershell
pwsh -File "$env:USERPROFILE\.dsh\rescue\dsh-rescue.ps1" diagnose
```

3. 按诊断给的分支走。诊断会明确告诉你是甲类还是乙类。

## 六个命令

| 命令 | 做什么 | 会改文件吗 |
|---|---|---|
| `status` | 依赖几个、装没装、bundles 齐不齐、safemode 状态 | 不 |
| `diagnose` | 读最新崩溃日志，抓出卡住的必需插件，判定故障类型 | 不 |
| `snapshot` | 手动打一个还原点 | 只写备份目录 |
| `minimal` | 退到最小可启动配置（bundles 只留 base + web-app，依赖清空） | 是 |
| `restore` | 还原良好依赖清单 + patch，再用 lockfile 冻结安装 | 是 |
| `rollback` | 列出所有快照（时间 / 原因 / 依赖数）让你挑，然后写回 | 是 |

## 两类故障，两条路

诊断只认两类，因为它们的**修法互斥**——用错一条不但无效，还会丢配置。

| | 甲类 | 乙类 |
|---|---|---|
| 日志特征 | `N required plugins did not activate` | `Cannot read properties of undefined (reading '...')`，栈在 `dsh-desktop-host` |
| 坏在哪 | 装载树：基础 bundle 层没被应用 | `node_modules` 依赖树 |
| 典型起因 | 插件管理操作（`set_bundle` / `install_bundle`）写到一半进程死了 | 用 `link:` 指向了自带依赖的包，hoisted 布局下把公共包名顶到了宿主用的位置 |
| 走哪条 | `minimal` → 启动确认 → `restore` | `restore -Snapshot <上一个良好快照>`，必要时先删 `node_modules` |
| `minimal` 有用吗 | 有用，先让它能起来 | **完全无效**，它只清配置不清依赖 |

```powershell
# 甲类
pwsh -File dsh-rescue.ps1 minimal
# 启动应用确认能进主界面，然后
pwsh -File dsh-rescue.ps1 restore

# 乙类：指定"上一次能跑"的那份快照
pwsh -File dsh-rescue.ps1 restore -Snapshot <上一个良好快照>
```

## 它动什么、不动什么

| 动 | 不动 |
|---|---|
| `package.json`、`cordis.patch.yml`、`pnpm-workspace.yaml`、`pnpm-lock.yaml` | `~/.dsh/sessions`（会话） |
| `node_modules`（仅 `restore`） | `~/.dsh/attachments`（附件） |
| `~/.dsh/rescue/backups/`（快照） | `~/.dsh/storages`（记忆与设置） |
| | `~/.dsh/anchors`（锚点） |
| | `.credentials.yaml`、`.env`（凭据） |

这不是靠自觉，是靠代码：所有写操作都走四个固定文件名，数据目录一次都没被引用。

## 安全边界

| 机制 | 实现 |
|---|---|
| 破坏性操作前自动备份 | `minimal` / `restore` 第一步就是存快照，保留最近 12 份 |
| 应用在跑就拒绝执行 | 检测到 `DeepSeek Harness` 进程直接抛错，`-Force` 才放行 |
| 可回滚 | `rollback` 默认最近一份，`-Snapshot` 指定任意一份；会先打印列表 |
| 版本不被悄悄改掉 | `restore` 优先用快照自带的 `pnpm-lock.yaml` 做 `--frozen-lockfile` |
| 不猜路径 | pnpm / node 从 `~/.dsh/dsh-runtimes` 里现找，找不到才回落 PATH |

## 已知限制

| 限制 | 说明 | 出路 |
|---|---|---|
| 只支持 Windows | 依赖 PowerShell 7 + Windows 进程名 / 路径 | 无计划 |
| 只认 `desktop` profile | 默认路径固定，可用 `-ProfileDir` 指定别的 | 自定义 profile 传参即可 |
| 乙类故障的机理未证实 | "hoisted 布局下公共包名互相顶"是从崩溃日志、时间线和依赖清单推出来的，**没读到宿主源码那一行** | 处置方式本身有效（回退依赖树），但别拿它当定论 |
| `minimal` 不清 `node_modules` | 残留依赖一般不影响启动，但极端情况下要手工删 | 输出里会提示这一档 |
| 不修复 safemode | 只提示 `safemode.json` 处于 `armed` | 手工改 `armed: false` 或删文件 |
| 修不了磁盘 / 权限 / 端口占用 | 它只管 profile 配置层 | 看崩溃日志第一段错误 |

## 命令速查

```powershell
$r = "$env:USERPROFILE\.dsh\rescue\dsh-rescue.ps1"

pwsh -File $r status                    # 现在什么状态
pwsh -File $r diagnose                  # 先跑这个
pwsh -File $r snapshot                  # 手动留还原点
pwsh -File $r minimal                   # 甲类：先救活
pwsh -File $r restore                   # 装回最近的良好依赖
pwsh -File $r restore -Snapshot <名字>   # 指定快照
pwsh -File $r rollback                  # 回退，会列快照
pwsh -File $r help
```

参数：`-ProfileDir <路径>`（默认 `~/.dsh/profiles/desktop`）、`-Snapshot <名字>`、`-Force`。

## 文档导航

| 文档 | 面向 | 内容 |
|---|---|---|
| `README.md`（本文） | 第一次来的人 | 它是什么、怎么用、边界在哪 |
| `release-notes/` | 已装旧版的人 | 每一版改了什么；正本在 GitHub Releases |
| `--help` | 已经会用的人 | 参数与典型流程 |

## 开发

单文件 PowerShell 脚本，无外部依赖，不需要构建。

改动后至少跑一遍只读命令验证，再跑一次 `minimal` / `restore` / `rollback` 全链（**在一份复制出来的 profile 上用 `-ProfileDir` 跑，别拿正在用的那份试**）：

```powershell
# 只读自检
pwsh -NoProfile -File .\dsh-rescue.ps1 status
pwsh -NoProfile -File .\dsh-rescue.ps1 diagnose

# 全链验证：复制一份 profile 到临时目录，全部操作只指向它
$t = Join-Path $env:TEMP 'dsh-rescue-test\desktop'
New-Item -ItemType Directory -Force -Path $t | Out-Null
Copy-Item "$env:USERPROFILE\.dsh\profiles\desktop\*.yml","$env:USERPROFILE\.dsh\profiles\desktop\package.json" $t
pwsh -NoProfile -File .\dsh-rescue.ps1 minimal  -Force -ProfileDir $t
pwsh -NoProfile -File .\dsh-rescue.ps1 restore  -Force -ProfileDir $t
pwsh -NoProfile -File .\dsh-rescue.ps1 rollback -Force -ProfileDir $t
```

**为什么必须这么验**：`status` 在"依赖为空"时曾直接抛错——而那恰好是 `minimal` 之后最常见的状态，也就是急救最需要它工作的那一刻。只跑只读命令发现不了这类缺陷。

## 许可

个人工具，未附带许可证。要用于商业场景请先开 issue 说明。
