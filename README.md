# DSH 急救 · DSH Rescue

DSH 桌面端起不来时用它：**先判断是哪一类故障，再走对应的那一条路**。修的是 profile 配置层，不碰会话、附件、记忆、锚点、凭据。

**当前版本：v1.4.0**

---

## 第一次用：先装一次短命令

脚本不在 PATH 上，所以**每次都要写完整路径**——这就是最容易出错的地方。装一次短命令，之后只需要敲 `dsh-rescue`：

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\rescue\dsh-rescue.ps1" install
```

然后**重开一个终端**（或先执行 `. $PROFILE`），确认能用了：

```powershell
dsh-rescue status
```

装出来的东西就是一行函数，写在 `Documents\PowerShell\Microsoft.PowerShell_profile.ps1` 里，带 `# >>> dsh-rescue >>>` 标记；重复执行只会更新、不会重复追加。

> 没装短命令也能用。下文所有命令都同时给两种写法：
> 带 `dsh-rescue` 的（已装短命令），和带完整路径的（没装）。
> **不要用 `.\dsh-rescue.ps1`**：那要求你当前目录正好是脚本所在目录，而且 PowerShell 默认不允许运行当前目录下的脚本。

---

## 出事了：跑一条命令，跟着它走

```powershell
dsh-rescue
```

不带参数就是**向导**。它自己看现状、读崩溃日志、判断类型，然后告诉你：

```
» 1/3 现状
  插件依赖    : 8 个（node_modules 里 113 个顶层包）
  patch 条目  : 7
  文件编码    : 正常（无 BOM）
  应用进程    : 未运行

» 2/3 判断
  最新崩溃：11/11/2026 16:06:04
  错误行  ：DesktopHostFatalError: Unexpected token '﻿', "﻿{
  类型    ：丁 类

» 3/3 建议
  打算做：strip-bom
  为什么：配置文件开头有 UTF-8 BOM，宿主 JSON.parse 直接失败。只减 3 字节，不动内容。
  做完看：启动应用，能进主界面就回来跑 dsh-rescue verify

现在执行 strip-bom 吗？ [Y/n]
```

- 它**问过你才动手**；你说 n，它只把该抄的命令打出来。
- 应用还在运行、而这一步必须关掉应用时，它**不会执行**，只会让你先退出——不会硬来。
- 修完重启应用，再跑 `dsh-rescue verify` 核对是不是真的好了。

**这三步就是全部**：`dsh-rescue` → 重启 → `dsh-rescue verify`。下面的内容都是这三步的展开与兜底。

## 不想走向导：直接看判断

```powershell
dsh-rescue diagnose
```

它会读**最新那份崩溃日志**，打印出 `--- error ---` 下面的那一行，然后判定故障类型。**这一行决定你走哪条路，不要跳过。**

| 日志里那一行长什么样 | 哪一类 | 该跑哪条 |
|---|---|---|
| `... required plugins did not activate` | **甲类** 装载树 | `dsh-rescue minimal` → 启动确认 → `dsh-rescue restore` |
| `Cannot read properties of undefined (reading '...')`，栈在 `dsh-desktop-host` | **乙类** 依赖树 | `dsh-rescue restore -Snapshot <上一个良好快照>` |
| `desktop welcome: Web authentication failed` | **丙类** 主进程握手 | **先看日志里有没有 `host diagnostic` 段**，见下节 |
| `Unexpected token '﻿'` / `is not valid JSON`，栈在 `readProfileManifest` | **丁类** 文件编码 | `dsh-rescue strip-bom` |
| 都不像 | 未知 | `dsh-rescue snapshot` 保底，把日志那一段发人看 |

**这四类的修法互斥。** 用错一条不但无效，还会顺手把插件配置清掉。

---

## 四类故障

### 甲类：必需插件没激活

```
DesktopHostFatalError: dsh: startup failed: 2 required plugins did not activate
```

- **坏在哪**：装载树。dsh-base 这一层 bundle 没被应用，基础插件整块 disabled，于是 `tools` / `agents` / `sessions` 没有提供者。
- **典型起因**：插件管理操作（`set_bundle` / `install_bundle`）写到一半进程死了。判据是操作日志里那条只有 `started`、**没有 `settled`**。
- **要动**：`package.json` 的 bundles、`cordis.patch.yml`。
- **命令**：

```powershell
dsh-rescue minimal        # 退到最小可启动配置
# 启动应用，能进主界面 = 活过来了
dsh-rescue restore        # 再把插件装回去
```

### 乙类：Host 启动时读字段失败

```
DesktopHostFatalError: Cannot read properties of undefined (reading 'authenticatedUrl')
    at main (... dsh-desktop-host/lib/index.js:605)
```

- **坏在哪**：`node_modules` 依赖树。**不是**配置问题。
- **典型起因**：用 `link:` 指向了自带依赖的本地包，hoisted 布局下把 `openai` / `zod` 这类公共包名顶到了宿主用的位置。
- **⚠ 这条机理是推断，未证实**（没读到宿主源码那一行）；但"回退依赖树"这个处置是验过的。
- **要动**：依赖树，**不要动配置**。
- **命令**：

```powershell
dsh-rescue restore -Snapshot <上一个良好快照>
# 还不行：删 node_modules 再来一次
Remove-Item -Recurse -Force "$env:USERPROFILE\.dsh\profiles\desktop\node_modules"
dsh-rescue restore -Snapshot <上一个良好快照>
```

### 丙类：主进程在 welcome / 登录握手阶段失败

```
Error: desktop welcome: Web authentication failed
    at connectDesktopWelcome (... app.asar/lib/main.js:16856)
```

这一类**有两个完全不同的原因**，而且症状一模一样。判据只有一条：**日志里有没有 `host diagnostic (as reported by the Host process)` 这一段。**

| 有没有 host diagnostic | 说明 | 该怎么办 |
|---|---|---|
| **有** | 宿主子进程跑起来了并报了错 → 问题在登录态 | `dsh-rescue reset-cookies`，重启后重新登录 |
| **没有** | 宿主根本没报告 → main 进程把"连不上宿主"包装成了登录失败，真凶在插件/依赖树 | **先别删 Cookies**，按 1→3 试 |

"没有 host diagnostic"时的顺序（代价从小到大）：

```powershell
# 1. 回退到上一个良好快照
dsh-rescue restore -Snapshot <上一个良好快照>
# 2. 若你手工改过 node_modules（覆盖文件 / link / 手装包），删掉再来一次
Remove-Item -Recurse -Force "$env:USERPROFILE\.dsh\profiles\desktop\node_modules"
dsh-rescue restore -Snapshot <上一个良好快照>
# 3. 前两步都无效，才动 Cookies
dsh-rescue reset-cookies
```

> **v1.1.0 曾把这里写成"一定是 Cookies 坏了"，那是错的。** 2026-11-11 那次事故里，崩溃前 4 分钟有人把 73 个 fork 文件覆盖进了 `node_modules/dsh-pet`，而日志里没有 host diagnostic——更可能是宿主启动即死。当时删 Cookies 只是**恰好**也一并解决了问题（因为同时删了 `node_modules`、把配置退成了最小）。判据只看 `host diagnostic` 在不在，不看"删了之后好了"。

Cookies 的真实位置：`%APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies`（Chromium 的新布局），不在顶层。工具是**递归**找的，顶层和 `Partitions\*` 里的也会一起处理。

`reset-cookies` 只是**改名**成 `.bak-时间戳`，不是删除；要退回把名字改回来。

### 丁类：配置文件带 BOM

```
DesktopHostFatalError: Unexpected token '﻿', "﻿{ "n"... is not valid JSON
    at readProfileManifest (... dsh-app-boot/lib/index.js:1692)
```

- **坏在哪**：profile 的 `package.json` 开头多了一个 UTF-8 BOM（`EF BB BF`）。Node 的 `JSON.parse` **不认 BOM**，第一个字符就炸。宿主在读清单时崩，插件一层都还没轮到。
- **典型起因**：用 **PowerShell 5.1** 写了这个文件。`Set-Content -Encoding UTF8`、`Out-File`、`ConvertTo-Json | Set-Content` 在 5.1 里**都会写 BOM**（7 的 `utf8` 才不带）。
- **判据**：报错里的 `"﻿{` 那个方块就是 BOM；或者 `status` 直接报"文件编码 … 带 BOM"。
- **命令**（应用要完全退出）：

```powershell
dsh-rescue strip-bom
```

它逐个扫 profile 根目录的 `*.json` / `*.yml` / `*.yaml`，把 BOM 去掉（只减 3 字节，内容不动）。

> **`restore` 会自动去 BOM**：快照本身可能就是坏的（带 BOM 的 package.json 被存进去过），所以装回去时会剥掉，不会把崩溃原样搬回来。这条是 v1.3.0 修的——v1.2.0 之前，`restore` 会**忠实复现**这个崩溃。

**根治**：改这几个文件用 `pwsh`，或者显式指定 `-Encoding utf8NoBOM`。

---

## 命令

| 命令 | 做什么 | 会改文件 |
|---|---|---|
| `dsh-rescue` | **不带参数：向导**（看现状 → 判类型 → 问过你再修） | 视情况 |
| `dsh-rescue verify` | 修完重启后核对：真的好了还是又崩了 | 否 |
| `dsh-rescue diagnose` | 只看判断（读最新崩溃日志 + 定类型） | 否 |
| `dsh-rescue snapshot` | 手动留一个还原点 | 只写备份目录 |
| `dsh-rescue minimal` | 甲类用：退到最小可启动配置 | 是 |
| `dsh-rescue restore` | 装回良好依赖 + patch（有 lockfile 则冻结版本） | 是 |
| `dsh-rescue rollback` | 列出所有快照，挑一份写回 | 是 |
| `dsh-rescue reset-cookies` | 丙类用：把 Cookies 改名（可回退） | 是 |
| `dsh-rescue strip-bom` | 丁类用：去掉配置文件开头的 BOM | 是（只减 3 字节） |
| `dsh-rescue install` | 把短命令写进 PowerShell profile | 是（只改 profile） |
| `dsh-rescue help` | 用法 | 否 |

参数：`-Snapshot <名字>`（restore / rollback 选哪份快照）、`-ProfileDir <路径>`（默认 `~/.dsh/profiles/desktop`）、`-Force`（应用在跑也继续，不推荐）。

---

## 别做这五件事

这五条都是**真实踩过**的，代价写在后面。

| ❌ 不要 | 后果 |
|---|---|
| 用 `minimal` 去修**不是甲类**的崩溃 | 它只清配置，对乙/丙/丁类无效；而且会把 `cordis.patch.yml` 清空，插件配置丢一遍 |
| 手工删 `node_modules` / `pnpm-lock.yaml` / 把 patch 写成 `[]` | 和上一条一样：自伤，而且删了 lockfile 后 `^0.3.8` 可能解析出没验证过的新版本 |
| 用 `link:` 把本地包接进 profile，或**手工覆盖 `node_modules` 里的文件** | 乙类故障的典型起因；要改本地包用 `pnpm patch`，或只在独立测试 profile 里试 |
| 用 PowerShell 5.1 的 `Set-Content -Encoding UTF8` 改 profile 配置 | 会写 BOM，宿主 `JSON.parse` 直接失败（丁类）；改用 `pwsh` 或 `-Encoding utf8NoBOM` |
| 让任何脚本去改 profile 的 `package.json`（加 `patchedDependencies`、改 bundles、改依赖） | 2026-11-11 那次就是这么崩的：脚本用 PS 5.1 写回 `package.json` → 带 BOM → 启动即死。**profile 的清单只允许 `dsh-rescue` 改，或人工在 `pwsh` 里改** |
| 把"pnpm 说 Done / 依赖都在位"当成"应用能用" | 安装成功 ≠ 启动成功。**只有重启进得去主界面才算验证** |

**判断口诀**：`diagnose` 说甲类才碰配置；说乙类只碰依赖；说丙类先看 `host diagnostic`；说丁类只碰文件编码；说不认识就只做 `snapshot`。

---

## 它动什么、不动什么

| 动 | 不动 |
|---|---|
| `package.json`、`cordis.patch.yml`、`pnpm-workspace.yaml`、`pnpm-lock.yaml` | `~/.dsh/sessions` 会话 |
| `node_modules`（仅 `restore`） | `~/.dsh/attachments` 附件 |
| `~/.dsh/rescue/backups/` 快照目录 | `~/.dsh/storages` 记忆与设置 |
| `%APPDATA%\@deepseek-ai\dsh-desktop\Cookies*`（仅 `reset-cookies`） | `~/.dsh/anchors` 锚点 |
| PowerShell profile（仅 `install`） | `.credentials.yaml`、`.env` 凭据 |

三次事故里，**上面"不动"那一列一次都没坏过**。看到"东西丢了"，先怀疑配置层，不要怀疑数据。

## 安全边界

- 破坏性操作（`minimal` / `restore`）第一步自动存快照，保留最近 12 份。
- 应用在跑就直接拒绝执行，`-Force` 才放行。
- `rollback` 会先列出所有快照（时间 / 原因 / 依赖数）供你挑，不是只能退回上一步。
- 快照里带 `pnpm-lock.yaml` 时按它冻结安装。
- pnpm / node 从 `~/.dsh/dsh-runtimes` 现找，不写死路径。

## 健壮性（v1.2.0 加固）

| 加固 | 为什么 |
|---|---|
| 配置**原子写**（写临时文件再改名） | 之前的事故里有两次是"操作写到一半进程没了"。"写到一半"的配置文件是最难救的状态，原子写让它不可能出现 |
| `pnpm install` **硬超时 180 秒 + 超时杀进程树** | 卡住的安装会让人干等；`taskkill /F /T` 才杀得干净（只杀父进程会留下孤儿占着 node_modules） |
| Cookies 判定**递归**、坏一份就报 | Chromium 把登录取在 `Network\Cookies`，只扫顶层会漏；`Partitions\*` 下也可能有 |
| Cookies **被占用不算坏** | 应用在运行时独占锁 SQLite 是正常状态，之前会误报成"打不开" |
| `diagnose` 不再靠关键词白名单 | 改成直接取 `--- error ---` 后面第一行——白名单每遇到新故障就漏一次（v1.0 和 v1.1 各漏一次） |
| `diagnose` 先看 `host diagnostic` 在不在 | 丙类的两个原因症状完全一样，这是唯一能区分的结构信号 |
| **`restore` 装回去时自动去 BOM** | 快照可能本身就存着带 BOM 的 `package.json`；原样拷回等于复现崩溃 |
| **去 BOM 走"读源→写目标"而不是"拷完再改"** | v1.2.0 那种写法在文件被占用时会**静默失败**，却照样报成功 |
| **向导先判类型再动手，且必须你确认** | 前面几次事故的代价都来自"看错类型就动手"；向导把"做什么/为什么/做完看什么"一次讲清 |
| **向导检测到应用在跑就不执行** | 在运行中改 profile 是前两次事故的共同前提 |

## 已知限制

| 限制 | 说明 | 出路 |
|---|---|---|
| 只支持 Windows | 依赖 PowerShell 7 与 Windows 路径/进程名 | 无计划 |
| 只认 `desktop` profile | 其他 profile 要传 `-ProfileDir` | 传参即可 |
| 乙类机理未证实 | 处置有效，但"为什么"是推断 | 别把它当定论去改别的 |
| 修不了磁盘/权限/端口 | 只管 profile 配置层 + Cookies | 看日志第一段错误 |
| `reset-cookies` 要重新登录 | 登录态本来就在这两个文件里 | 无 |

## 全部命令（可逐条粘贴，无变量、不依赖当前目录）

```powershell
# 装一次短命令（只有第一次需要）
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\rescue\dsh-rescue.ps1" install

# 之后
dsh-rescue                 # 看现状
dsh-rescue diagnose        # 判定故障类型 —— 永远先做这个
dsh-rescue snapshot        # 留还原点
dsh-rescue minimal         # 甲类
dsh-rescue restore         # 装回依赖
dsh-rescue rollback        # 回退（会列快照）
dsh-rescue reset-cookies   # 丙类
dsh-rescue strip-bom       # 丁类
```

没装短命令时，把 `dsh-rescue xxx` 换成：

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\rescue\dsh-rescue.ps1" xxx
```

## 开发者

单文件 PowerShell，无外部依赖，无构建。

**验证必须用复制出来的 profile 副本**（`-ProfileDir` 指过去），不要拿正在用的那份试；`reset-cookies` 用 `-AppDataDir` 指到假目录测：

```powershell
$t = Join-Path $env:TEMP 'dsh-rescue-test'
New-Item -ItemType Directory -Force -Path $t | Out-Null
Copy-Item "$env:USERPROFILE\.dsh\profiles\desktop\*.yml","$env:USERPROFILE\.dsh\profiles\desktop\package.json" $t
pwsh -NoProfile -File .\dsh-rescue.ps1 snapshot      -Force -ProfileDir $t
pwsh -NoProfile -File .\dsh-rescue.ps1 minimal       -Force -ProfileDir $t
pwsh -NoProfile -File .\dsh-rescue.ps1 restore       -Force -ProfileDir $t
pwsh -NoProfile -File .\dsh-rescue.ps1 rollback      -Force -ProfileDir $t
pwsh -NoProfile -File .\dsh-rescue.ps1 reset-cookies -Force -AppDataDir $t
```

**为什么要这么验**：`status` 曾经在"依赖为空"时直接崩——而那正好是 `minimal` 之后的状态，也就是急救最需要它工作的那一刻。只跑只读命令发现不了。

## 文档导航

| 文档 | 面向 | 内容 |
|---|---|---|
| `README.md` | 第一次来的人 | 分诊、三类故障、命令、禁忌 |
| `release-notes/` | 已装旧版的人 | 每版改了什么；正本在 GitHub Releases |
| `dsh-rescue help` | 已经会用的人 | 参数与流程 |

## 许可

个人工具，未附带许可证。商业使用请先开 issue 说明。
