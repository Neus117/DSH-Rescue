# DSH 急救 · DSH Rescue

DSH 桌面端起不来时用：先判类型，再走对应的一条路。只动配置层，不碰会话、附件、记忆、锚点、凭据。

**当前版本：v1.5.3** · 只支持 Windows + PowerShell 7

---

## 三步

```powershell
# 1) 装一次短命令（已装过就跳过）
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\rescue\dsh-rescue.ps1" install

# 2) 出事时
dsh-rescue

# 3) 按它说的做 → 重启 DSH → 核对
dsh-rescue verify
```

`dsh-rescue` 不带参数就是向导：看现状 → 判类型 → 说清"打算做什么 / 为什么 / 做完看什么" → 问你一句才动手。你说 n，它只把该抄的命令打出来。

---

## 30 秒定类型

看崩溃日志里 `--- error ---` 后面那一行，对照下表。不知道**哪份日志**就先 `dsh-rescue diagnose`，它替你读。

| 那一行长什么样 | 类型 | 怎么办 |
|---|---|---|
| `... required plugins did not activate` | 甲 装载树 | `dsh-rescue minimal` → 重启 → `dsh-rescue restore` |
| `Cannot read properties of undefined`，栈在 `dsh-desktop-host` | 乙 依赖树 | `dsh-rescue restore` |
| `desktop welcome: Web authentication failed` | 丙 握手 | 先看日志里有没有 `host diagnostic` 段，见下 |
| `Unexpected token '﻿'` / `is not valid JSON` | 丁 编码 | `dsh-rescue strip-bom` |
| `only the launching environment may set` | 戊 `.env` 越权 | `dsh-rescue fix-env` |
| 都不像 | ? | `dsh-rescue` 会生成报告并建议回退快照 |

---

## 五类故障

### 甲 · 必需插件没激活

- **现象**：启动立刻失败，`N required plugins did not activate`。
- **原因**：dsh-base 那层 bundle 没被应用（常因插件管理操作写到一半进程没了）。
- **修**：`minimal` 先让它能起来 → 重启确认 → `restore` 装回插件。

### 乙 · Host 启动时读字段失败

- **现象**：栈在 `dsh-desktop-host` 的 `main()`，插件层还没轮到。
- **原因**：`node_modules` 依赖树被改坏（`link:` 或手工覆盖文件）。
- **修**：`restore`；还不行就删 `node_modules` 再 `restore`。
- **注意**：这条机理是推断，未读到宿主源码那一行；但"回退依赖树"这个处置验过。

### 丙 · 主进程握手失败

- **现象**：`Web authentication failed`，两个原因症状一模一样。
- **判据**：日志里**有没有** `host diagnostic (as reported by the Host process)` 段。

| 有这个段 | 含义 | 动作 |
|---|---|---|
| 有 | 宿主跑起来了 → 问题在登录态 | `dsh-rescue reset-cookies` |
| 没有 | 宿主根本没起来，main 把"连不上宿主"包装成登录失败 | 先 `restore`，最后才 `reset-cookies` |

### 丁 · 配置文件带 BOM

- **现象**：`Unexpected token '﻿', "﻿{`，栈在 `readProfileManifest`。
- **原因**：PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM，`JSON.parse` 不认。
- **修**：`dsh-rescue strip-bom`（只减 3 字节）。`restore` 装回时也会自动剥。
- **根治**：改这些文件用 `pwsh`，或显式 `-Encoding utf8NoBOM`。

### 戊 · `.env` 里写了越权的键

- **现象**：`... sets "X", which only the launching environment may set ...; export X instead of putting it in a .env file`。
- **原因**：`~/.dsh/.env` 有白名单，有些键只允许启动环境设置。
- **修**：`dsh-rescue fix-env`（删日志点名那一行，先备份）。
- **要这个开关**：启动前 `$env:X = '1'`，同一窗口启动应用。**不要写进 `.env`。**

---

## 命令

| 命令 | 做什么 | 改文件 |
|---|---|---|
| `dsh-rescue` | 向导（默认） | 视情况 |
| `dsh-rescue verify` | 修完重启后核对：真好了还是又崩了 | 否 |
| `dsh-rescue diagnose` | 只看类型判断 | 否 |
| `dsh-rescue status` | 依赖 / 补丁 / 编码 / 登录态一览 | 否 |
| `dsh-rescue snapshots` | 列快照（依赖数 / 补丁 / 为什么拍的 / 是否带 BOM） | 否 |
| `dsh-rescue report` | 把崩溃原文 + 配置 + 快照清单写成 txt | 只写报告目录 |
| `dsh-rescue snapshot` | 手动留还原点 | 只写备份 |
| `dsh-rescue minimal` | 甲类：退到最小可启动配置 | 是 |
| `dsh-rescue restore` | 装回良好依赖 + patch | 是 |
| `dsh-rescue rollback` | 挑一份快照写回 | 是 |
| `dsh-rescue reset-cookies` | 丙类：Cookies 改名（不删） | 是 |
| `dsh-rescue strip-bom` | 丁类：去掉 BOM | 是 |
| `dsh-rescue fix-env` | 戊类：从 `.env` 删掉越权键 | 是 |
| `dsh-rescue install` | 装短命令 | 只改 profile |
| `dsh-rescue help` | 用法 | 否 |

参数：`-Snapshot <名字>`（也可直接写 `restore <名字>`）、`-ProfileDir <路径>`、`-Force`。

> `-Snapshot` 后面必须带名字；不知道名字先 `dsh-rescue snapshots`。

---

## 别做这六件事

| 不要 | 后果 |
|---|---|
| 用 `minimal` 修非甲类崩溃 | 无效，且会清空 `cordis.patch.yml`，插件配置丢一遍 |
| 手删 `node_modules` / `pnpm-lock.yaml` / 把 patch 写成 `[]` | 自伤；删了 lockfile 后 `^0.3.8` 可能装出没验证过的版本 |
| 用 `link:` 接本地包，或手工覆盖 `node_modules` 里的文件 | 乙类的典型起因；要改本地包用 `pnpm patch` |
| 用 PS 5.1 的 `Set-Content -Encoding UTF8` 改 profile 配置 | 写 BOM → 下次启动即死（丁类） |
| 把开关写进 `~/.dsh/.env` | 宿主白名单拒绝，启动即死（戊类） |
| 把 "pnpm Done / 依赖在位" 当成能用 | 只有重启后进得去主界面才算 |

---

## 边界

**动**：`package.json`、`cordis.patch.yml`、`pnpm-workspace.yaml`、`pnpm-lock.yaml`、`patches/`、`node_modules`（仅 restore）、`Cookies*`（仅 reset-cookies）、PowerShell profile（仅 install）。

**不动**：`sessions`、`attachments`、`storages`、`anchors`、`.credentials.yaml`、`.env`（只读，fix-env 除外）。

**每次都先备份**：破坏性操作自动存快照（含 `patches/`），保留最近 12 份；应用在跑直接拒绝执行。

**已知限制**

| 限制 | 出路 |
|---|---|
| 每份快照含 17MB 补丁，12 份约 200MB | 嫌大就少留几份 |
| 乙类机理未证实 | 处置有效，别拿它当定论改别处 |
| 只验过 Windows + PS 7 | 无计划扩平台 |
| 修不了磁盘 / 权限 / 端口占用 | 看日志第一段错误 |

---

## 开发

单文件 PowerShell，无依赖，无构建。

**必须用副本验证**（`-ProfileDir` 指过去），别拿正在用的那份试：

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

为什么要这么验：`status` 曾在"依赖为空"时崩——而那正是 `minimal` 之后的状态，也是急救最需要它工作的那一刻。只跑只读命令发现不了。

发版：`release-notes/vX.Y.Z.md` 走 patch 递增，`git tag -a` 后 `gh release create --notes-file`。
