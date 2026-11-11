#Requires -Version 7.0
<#
.SYNOPSIS
  DSH 桌面端急救工具。用于 profile 根配置被写坏、启动报
  "N required plugins did not activate" 这类起不来的情况。

.DESCRIPTION
  只碰 profile 根目录的配置文件（package.json / cordis.patch.yml /
  pnpm-workspace.yaml / lockfile）。永远不碰数据：
  sessions、attachments、storages、anchors、.credentials.yaml。

  命令：
    status     看一眼现状（只读）
    diagnose   读最新崩溃日志 + 校验配置，给出判断（只读）
    snapshot   备份当前 profile 根配置
    minimal    退到最小可启动配置（bundles 只留 base+web-app，依赖清空）
    restore    还原最近一次良好依赖清单 + patch，再 pnpm install
    rollback   把最近一次快照写回

.EXAMPLE
  pwsh -File dsh-rescue.ps1 diagnose
.EXAMPLE
  pwsh -File dsh-rescue.ps1 minimal
.EXAMPLE
  pwsh -File dsh-rescue.ps1 restore
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'diagnose', 'snapshot', 'minimal', 'restore', 'rollback',
               'reset-cookies', 'install', 'help')]
  [string]$Command = '',

  [string]$ProfileDir = '',

  [string]$Snapshot = '',

  # 仅用于测试：把“应用数据目录”指到别处，避免动到真实 Cookies
  [string]$AppDataDir = '',

  [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------- 基础路径 ----------------
$HomeDir = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
  $ProfileDir = Join-Path $HomeDir '.dsh\profiles\desktop'
}
$ProfileDir = [System.IO.Path]::GetFullPath($ProfileDir)
if (-not (Test-Path $ProfileDir)) { throw "找不到 profile 目录：$ProfileDir" }

$RescueRoot = Join-Path $HomeDir '.dsh\rescue'
$BackupRoot = Join-Path $RescueRoot 'backups'
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

$ConfigFiles = @('package.json', 'cordis.patch.yml', 'pnpm-workspace.yaml', 'pnpm-lock.yaml')
$MaxBackups = 12

# 应用数据目录：登录态（Cookies）在这里，与 profile 是两回事
$AppDataRoot = if ([string]::IsNullOrWhiteSpace($AppDataDir)) {
  Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop'
} else { [System.IO.Path]::GetFullPath($AppDataDir) }

function Get-CookieFiles {
  if (-not (Test-Path $AppDataRoot)) { return @() }
  # 现代 Chromium 把登录取在 Network\Cookies，不在顶层；递归找，别只扫根目录
  @(Get-ChildItem $AppDataRoot -Recurse -File -Filter 'Cookies*' -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('Cookies', 'Cookies-journal') })
}

# 判定 Cookies 是否可读：0 字节、非 SQLite 头、残留非空 journal 都算坏
# 注意：Chromium 可能有多份（顶层 + Network + Partitions/*），逐份判，坏一份就报
function Get-CookieReport {
  $files = @(Get-CookieFiles)
  if ($files.Count -eq 0) {
    return [pscustomobject]@{ Exists = $false; Bad = $false; Detail = '没有 Cookies 文件（下次启动会重新登录）' }
  }
  $rel = { param($p) $p.FullName.Substring($AppDataRoot.Length).TrimStart('\') }
  $bad = $false
  $whys = @()
  $notes = @()

  foreach ($f in $files) {
    $name = & $rel $f
    if ($f.Name -eq 'Cookies') {
      if ($f.Length -eq 0) { $bad = $true; $whys += "$name 是 0 字节" ; continue }
      try {
        $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
        try {
          $buf = New-Object byte[] 15
          [void]$fs.Read($buf, 0, 15)
          if ([System.Text.Encoding]::ASCII.GetString($buf) -ne 'SQLite format 3') {
            $bad = $true; $whys += "$name 不是 SQLite 文件头"
          }
        } finally { $fs.Dispose() }
      } catch {
        # 应用在运行时独占锁这个库，打不开属正常，不能据此判坏
        $notes += "$name 读取被占用（应用在运行，正常）"
      }
    }
    elseif ($f.Name -eq 'Cookies-journal' -and $f.Length -gt 0) {
      $bad = $true; $whys += "$name 残留 $($f.Length)B（上次写到一半）"
    }
  }

  $detail = (@($files | ForEach-Object { "$(& $rel $_)=$($_.Length)B" }) -join '  ')
  if ($whys.Count -gt 0) { $detail = "$detail   ← " + ($whys -join '；') }
  elseif ($notes.Count -gt 0) { $detail = "$detail   （$($notes -join '；')）" }
  [pscustomobject]@{ Exists = $true; Bad = $bad; Detail = $detail }
}


# ---------------- 输出 ----------------
function Say($m)  { Write-Host $m }
function Step($m) { Write-Host "» $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  ✔ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  ✘ $m" -ForegroundColor Red }

# ---------------- 工具链 ----------------
function Find-Runtime {
  $pnpm = Get-ChildItem (Join-Path $HomeDir '.dsh\dsh-runtimes') -Recurse -File -Filter 'pnpm.cjs' -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match 'pnpm[\\/]bin[\\/]pnpm\.cjs$' } |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $node = Get-ChildItem (Join-Path $HomeDir '.dsh\dsh-runtimes') -Recurse -File -Filter 'node.exe' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1

  $pnpmPath = if ($pnpm) { $pnpm.FullName } else { $null }
  $nodePath = if ($node) { $node.FullName } else {
    $onPath = Get-Command node -ErrorAction SilentlyContinue
    if ($onPath) { $onPath.Source } else { $null }
  }
  [pscustomobject]@{ Pnpm = $pnpmPath; Node = $nodePath }
}

function Get-CrashLogs {
  $roots = @(
    (Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'),
    (Join-Path $env:APPDATA '@deepseek-ai')
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($r in $roots) {
    $logs = Get-ChildItem $r -Recurse -File -Filter 'crash-*-host.log' -ErrorAction SilentlyContinue
    if ($logs) { return ($logs | Sort-Object LastWriteTime -Descending) }
  }
  return @()
}

function Assert-AppClosed {
  $p = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue
  if ($p -and -not $Force) {
    throw 'DeepSeek Harness 正在运行。请先完全退出应用（托盘也要退），或加 -Force 强行继续（不推荐）。'
  }
}

function Read-ProfileJson {
  $p = Join-Path $ProfileDir 'package.json'
  if (-not (Test-Path $p)) { return $null }
  try { Get-Content $p -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-DepNames {
  param($Json)
  if (-not $Json) { return @() }
  if (-not $Json.PSObject.Properties['dependencies']) { return @() }
  # 注意：dependencies 为空对象时，PSObject.Properties.Name 在 StrictMode 下会抛错
  @($Json.dependencies.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-Bundles {
  param($Json)
  if (-not $Json) { return @() }
  if (-not $Json.PSObject.Properties['dsh']) { return @() }
  if (-not $Json.dsh.PSObject.Properties['profile']) { return @() }
  if (-not $Json.dsh.profile.PSObject.Properties['bundles']) { return @() }
  @($Json.dsh.profile.bundles)
}

function Get-PatchIds {
  $p = Join-Path $ProfileDir 'cordis.patch.yml'
  if (-not (Test-Path $p)) { return @() }
  Select-String -Path $p -Pattern '^\s*-\s*id:\s*(\S+)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value.Trim('"', "'") }
}

function Get-Snapshots {
  Get-ChildItem $BackupRoot -Directory -Filter 'auto-*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending
}

# 短命令是否已装进 PowerShell profile
function Test-ShortInstalled {
  try {
    $t = Get-Content $PROFILE -Raw -ErrorAction Stop
    return [bool]($t -and $t.Contains('# >>> dsh-rescue >>>'))
  } catch { return $false }
}

function New-Snapshot {
  param([string]$Reason = 'manual')
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dir = Join-Path $BackupRoot "auto-$stamp"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $n = 0
  foreach ($f in $ConfigFiles) {
    $src = Join-Path $ProfileDir $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $dir $f) -Force; $n++ }
  }
  @{ reason = $Reason; at = (Get-Date).ToString('o'); files = $n } |
    ConvertTo-Json | Set-Content (Join-Path $dir 'meta.json') -Encoding utf8NoBOM

  # 只留最近 N 份
  $all = @(Get-Snapshots)
  if ($all.Count -gt $MaxBackups) {
    $all | Select-Object -Skip $MaxBackups | ForEach-Object {
      Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  return $dir
}

# ---------------- 原子写（先写临时文件再改名，避免"写一半进程没了"） ----------------
function Write-TextAtomic {
  param([string]$Path, [string]$Text)
  $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  Set-Content -Path $tmp -Value $Text -Encoding utf8NoBOM -NoNewline
  Move-Item -Path $tmp -Destination $Path -Force
}

function Copy-FileAtomic {
  param([string]$From, [string]$To)
  $tmp = "$To.tmp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  Copy-Item -Path $From -Destination $tmp -Force
  Move-Item -Path $tmp -Destination $To -Force
}

# ---------------- pnpm：硬超时 + 超时杀进程树 ----------------
function Invoke-Pnpm {
  param([string]$Node, [string]$Pnpm, [string]$Dir, [string[]]$PnpmArgs, [int]$TimeoutSec = 180)
  $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $out = Join-Path $env:TEMP "dsh-rescue-pnpm-$tag.log"
  $err = "$out.err"
  $all = @($Pnpm) + $PnpmArgs + @('--reporter=append-only')

  $proc = Start-Process -FilePath $Node -ArgumentList $all -WorkingDirectory $Dir `
    -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err

  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    & taskkill /F /T /PID $proc.Id 2>$null | Out-Null
    return [pscustomobject]@{ Code = 124; Log = $out; TimedOut = $true }
  }
  $proc.Refresh()
  return [pscustomobject]@{ Code = $proc.ExitCode; Log = $out; TimedOut = $false }
}

# ---------------- status ----------------
function Show-Status {
  $json = Read-ProfileJson
  $deps = @(Get-DepNames $json)
  $bundles = @(Get-Bundles $json)
  $patchIds = @(Get-PatchIds)

  Say ""
  Say "profile : $ProfileDir"
  Say ("package.json  : " + $(if ($json) { "可解析，依赖 $($deps.Count) 个，bundles $($bundles.Count) 个" } else { "缺失或 JSON 损坏" }))
  Say ("cordis.patch  : " + $(if ($patchIds.Count -gt 0) { "$($patchIds.Count) 个条目" } else { "空 / 无条目" }))

  $nm = Join-Path $ProfileDir 'node_modules'
  if (Test-Path $nm) {
    $installed = @(Get-ChildItem $nm -Force -Directory | Where-Object { $_.Name -notlike '.*' })
    Say "node_modules  : 存在，$($installed.Count) 个顶层包"
    if ($deps.Count -gt 0) {
      $missing = @($deps | Where-Object { -not (Test-Path (Join-Path $nm $_)) })
      if ($missing.Count -gt 0) { Bad ("清单里有但没装：" + ($missing -join ', ')) }
      else { Ok '清单里的依赖都在 node_modules' }
    }
  } else {
    Warn 'node_modules 不存在（依赖未安装）'
  }

  if ($bundles.Count -gt 0) {
    $hasBase = $bundles -contains '@deepseek-ai/dsh-base'
    $hasWeb = $bundles -contains '@deepseek-ai/dsh-web-app'
    if ($hasBase -and $hasWeb) { Ok 'bundles 含 dsh-base + dsh-web-app' }
    else { Bad "bundles 缺基础层：base=$hasBase web=$hasWeb" }
  }

  $sm = Join-Path $ProfileDir '.rescue\safemode.json'
  if (Test-Path $sm) {
    try {
      $s = Get-Content $sm -Raw | ConvertFrom-Json
      if ($s.armed) { Warn "safemode 处于 armed 状态（applied=$($s.applied)）——若启动后插件全不生效，先处理它" }
    } catch { Warn 'safemode.json 读不了' }
  }

  $snaps = @(Get-Snapshots)
  Say ("最近快照      : " + $(if ($snaps.Count -gt 0) { $snaps[0].Name } else { '无' }))
  $logs = @(Get-CrashLogs)
  Say ("最近崩溃日志  : " + $(if ($logs.Count -gt 0) { "$($logs[0].Name) @ $($logs[0].LastWriteTime)" } else { '无' }))
  $ck = Get-CookieReport
  if ($ck.Bad) { Bad "登录态        : $($ck.Detail)" }
  else { Say "登录态        : $($ck.Detail)" }

  Say ''
  Say '下一步（按情况挑一条，直接粘）：'
  if (Test-ShortInstalled) {
    Say '  看不清问题   : dsh-rescue diagnose'
    Say '  要留还原点   : dsh-rescue snapshot'
    Say '  不知道怎么办 : dsh-rescue help'
  } else {
    Say "  看不清问题   : pwsh -File `"$PSCommandPath`" diagnose"
    Say "  要留还原点   : pwsh -File `"$PSCommandPath`" snapshot"
    Say "  嫌命令太长   : pwsh -File `"$PSCommandPath`" install   （装一次，之后敲 dsh-rescue）"
  }
  Say ''
}

# ---------------- diagnose ----------------
function Show-Diagnose {
  Say ""
  Step '配置校验'
  $json = Read-ProfileJson
  if (-not $json) { Bad 'package.json 缺失或 JSON 损坏 —— 这本身就能让启动失败' }
  else {
    $bundles = @(Get-Bundles $json)
    if (-not ($bundles -contains '@deepseek-ai/dsh-base')) {
      Bad 'bundles 里没有 @deepseek-ai/dsh-base —— 基础层不应用，会报 required plugins did not activate'
    } else { Ok 'bundles 含 dsh-base' }
    if (-not ($bundles -contains '@deepseek-ai/dsh-web-app')) { Bad 'bundles 里没有 @deepseek-ai/dsh-web-app' }
  }

  $patchPath = Join-Path $ProfileDir 'cordis.patch.yml'
  if (-not (Test-Path $patchPath)) { Warn 'cordis.patch.yml 不存在（会用纯 bundle 默认配置启动）' }
  else {
    $ids = @(Get-PatchIds)
    $bytes = (Get-Item $patchPath).Length
    if ($ids.Count -eq 0) { Warn "cordis.patch.yml 里没有条目（$bytes 字节）——插件配置丢了，但一般不至于起不来" }
    else { Ok "cordis.patch.yml 有 $($ids.Count) 个条目" }
  }

  Say ""
  Step '崩溃日志'
  $logs = @(Get-CrashLogs)
  if ($logs.Count -eq 0) { Warn '没有 crash 日志，可能不是启动崩溃'; return }

  $latest = $logs[0]
  Say "  最新：$($latest.Name)  ($($latest.LastWriteTime))"

  # 配置比日志新 → 这份日志是旧账
  $cfgLatest = @(
    (Join-Path $ProfileDir 'package.json'),
    (Join-Path $ProfileDir 'cordis.patch.yml')
  ) | Where-Object { Test-Path $_ } | ForEach-Object { (Get-Item $_).LastWriteTime } |
    Sort-Object -Descending | Select-Object -First 1
  if ($cfgLatest -and $cfgLatest -gt $latest.LastWriteTime) {
    Warn "配置在上次崩溃之后被改过（配置 $cfgLatest / 日志 $($latest.LastWriteTime)）"
    Warn '这份日志是旧账。若应用现在能起来，说明已经修过；真正的当前问题看下一次崩溃。'
  }

  $head = @(Get-Content $latest.FullName -TotalCount 400)
  $hasHostDiag = [bool](Select-String -Path $latest.FullName -Pattern 'host diagnostic' -Quiet -ErrorAction SilentlyContinue)

  # 取 --- error --- 后面第一行非空内容：这是唯一能用来分型的依据
  $errLine = ''
  $mark = -1
  for ($i = 0; $i -lt $head.Count; $i++) { if ($head[$i].Trim() -eq '--- error ---') { $mark = $i; break } }
  if ($mark -ge 0) {
    for ($i = $mark + 1; $i -lt $head.Count; $i++) {
      if ($head[$i].Trim()) { $errLine = $head[$i].Trim(); break }
    }
  }
  if ($errLine) { Bad $errLine } else { Warn '这份日志里没有 --- error --- 段' }

  $missing = @($head | Select-String -Pattern '^\s{2}\S+\s+\(required\)' |
    ForEach-Object { $_.Line.Trim() } | Select-Object -Unique)
  if ($missing.Count -gt 0) { Say '  卡住的必需插件：'; $missing | ForEach-Object { Say "    - $_" } }

  $other = $head | Select-String -Pattern 'Cannot find (module|package)|ERR_MODULE_NOT_FOUND|EACCES|ENOENT|EADDRINUSE' | Select-Object -First 3
  if ($other) { Say '  其它线索：'; $other | ForEach-Object { Say "    - $($_.Line.Trim())" } }

  Say ""
  Step '判断'
  $bundles = @(Get-Bundles $json)
  $errText = $errLine

  if ($errText -match 'did not activate') {
    # 甲类：装载树没起来（基础 bundle 层未应用）
    if ($bundles -contains '@deepseek-ai/dsh-base') {
      Say '  甲类故障：必需插件没激活，通常是因为 dsh-base 的 bundle 层没被应用。'
      Say '  多半由某次没跑完的插件管理操作（set_bundle / install_bundle）留下残局。'
      Say '  建议：snapshot → minimal（先救活）→ 启动确认 → restore（装回插件）'
    } else {
      Say '  甲类故障，且 bundles 里缺 dsh-base —— 直接 minimal 重建最小配置。'
    }
  }
  elseif ($errText -match 'authenticatedUrl' -or $errText -match 'dsh-desktop-host') {
    # 乙类：Host 启动期读服务对象失败 —— 依赖树被污染，不是配置问题
    Say '  乙类故障：Host 在启动阶段读某个对象的字段失败（不是插件没激活）。'
    Say '  这类问题出在 node_modules 依赖树，不在 package.json / patch 那层配置上。'
    Say '  常见起因：用 link: 指向了自带依赖的包，hoisted 布局下把 openai / zod 这类'
    Say '  公共名字顶到宿主自己用的位置，宿主拿到的对象形状就不对了。'
    Say ''
    Say '  警告：minimal 对这类故障无效（它只清配置，不清 node_modules）。'
    Say '  正确做法：'
    Say '    1) snapshot'
    Say '    2) 回退到上一个良好快照的依赖树（restore -Snapshot <名字>，它会用 lockfile 冻结版本）'
    Say '    3) 若仍失败：手动删 node_modules，再按良好 lockfile 重装'
    Say '    4) 在问题查清前，别往 profile 里再装 link: 依赖'
  }
  elseif ($errText -match 'Web authentication failed' -or $errText -match 'connectDesktopWelcome') {
    # 丙类：主进程在登录取证阶段失败。两种可能，先证后修。
    Say '  丙类故障：主进程在 welcome / 登录握手阶段失败（Web authentication failed）。'
    Say ''
    $ck = Get-CookieReport
    Say ("  Cookies：$($ck.Detail)")
    if ($hasHostDiag) {
      Say '  日志里有 host diagnostic 段 → 宿主跑起来了，问题在登录态。'
      Say '  处置：让应用完全退出，然后 pwsh -File dsh-rescue.ps1 reset-cookies；重启后重新登录。'
    } else {
      Say '  日志里**没有** host diagnostic 段 → 宿主子进程根本没报告。'
      Say '  这种情况下 main 进程会把"连不上宿主"包装成登录失败，真凶更可能是插件/依赖树，'
      Say '  而不是 Cookies。**先别删 Cookies**，按下面顺序试：'
      Say '    1) pwsh -File dsh-rescue.ps1 restore -Snapshot <上一个良好快照>'
      Say '    2) 若你手工改过 node_modules（覆盖文件 / link / 手装包），先删 node_modules 再来一次'
      Say '    3) 前两步都无效，才考虑 reset-cookies'
    }
  }
  else {
    Say '  错误类型没有命中已知模式。先 snapshot 保底，再人工看日志里第一段 --- error ---。'
  }
  Say ""
}
# ---------------- minimal ----------------
function Invoke-Minimal {
  Assert-AppClosed
  $snap = New-Snapshot -Reason 'before-minimal'
  Ok "已备份当前配置：$snap"

  $minimal = [ordered]@{
    name           = 'dsh-profile-desktop'
    private        = $true
    dependencies   = @{}
    dsh            = @{ profile = @{ bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app') } }
  }
  $json = $minimal | ConvertTo-Json -Depth 6
  Write-TextAtomic -Path (Join-Path $ProfileDir 'package.json') -Text $json

  # patch 层退回纯注释的空数组，避免引用没装的插件
  $patch = @'
# 急救：minimal 模式下 patch 层被清空。
# 原配置已备份到 ~/.dsh/rescue/backups/，用 restore 或 rollback 取回。
[]
'@
  Write-TextAtomic -Path (Join-Path $ProfileDir 'cordis.patch.yml') -Text $patch

  Ok '已写入最小配置（bundles 只留 base + web-app，依赖清空，patch 清空）'
  Warn 'node_modules 没删——它不参与 bundle 层决议，留着不影响启动'
  Say ""
  Say '下一步：启动 DeepSeek Harness。能进主界面就说明救回来了，再跑：' -ForegroundColor Yellow
  Say '  pwsh -File dsh-rescue.ps1 restore' -ForegroundColor Yellow
  Say '起不来就跑 diagnose，把输出发我。'
  Say ''
  Warn '最后手段：若 minimal 还是起不来，再手动删掉 profile 的 node_modules（这次事故最终就是这么救活的）。'
  Warn '删之前先 snapshot 一次，删完重跑 restore。'
}

# ---------------- restore ----------------
function Invoke-Restore {
  Assert-AppClosed

  # 1) 找来源：指定了 -Snapshot 就用那一份，否则挑最新一份"含依赖"的
  if (-not [string]::IsNullOrWhiteSpace($Snapshot)) {
    $dir = Join-Path $BackupRoot $Snapshot
    if (-not (Test-Path (Join-Path $dir 'package.json'))) {
      throw "快照 '$Snapshot' 不存在或没有 package.json。先跑 rollback（不带参数）看可用列表。"
    }
    $depSource = Get-Item (Join-Path $dir 'package.json')
  } else {
    $cands = @()
    foreach ($dir in @($BackupRoot, (Join-Path $ProfileDir '.rescue\snapshots'))) {
      if (-not (Test-Path $dir)) { continue }
      $cands += Get-ChildItem $dir -Recurse -File -Filter 'package.json' -ErrorAction SilentlyContinue
    }
    $depSource = $cands |
      Where-Object {
        try {
          $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
          @($j.dependencies.PSObject.Properties | ForEach-Object { $_.Name }).Count -gt 0
        } catch { $false }
      } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }

  if (-not $depSource) { throw '找不到含依赖的 package.json 备份。先用 minimal 救起来，再在应用内重新装插件。' }
  $srcDir = Split-Path $depSource.FullName

  # 2) 找 patch 来源：指定快照时用同目录副本；否则用 profile 里最新的、真有条目的 .bak
  $patchSource = $null
  if (-not [string]::IsNullOrWhiteSpace($Snapshot)) {
    $p = Join-Path $srcDir 'cordis.patch.yml'
    if (Test-Path $p) { $patchSource = Get-Item $p }
  } else {
    $patchSource = Get-ChildItem $ProfileDir -File -Filter 'cordis.patch.yml.bak-*' -ErrorAction SilentlyContinue |
      Where-Object { $_.Length -gt 300 } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $patchSource) {
      $sibling = Join-Path $srcDir 'cordis.patch.yml'
      if ((Test-Path $sibling) -and (Select-String -Path $sibling -Pattern '^\s*-\s*id:' -Quiet)) {
        $patchSource = Get-Item $sibling
      }
    }
  }

  $snap = New-Snapshot -Reason 'before-restore'
  Ok "已备份当前配置：$snap"

  Step "还原依赖清单：$($depSource.FullName)"
  Copy-FileAtomic -From $depSource.FullName -To (Join-Path $ProfileDir 'package.json')
  $ws = Join-Path $srcDir 'pnpm-workspace.yaml'
  if (Test-Path $ws) { Copy-FileAtomic -From $ws -To (Join-Path $ProfileDir 'pnpm-workspace.yaml') }
  Ok 'package.json 已还原'

  # 有 lockfile 就一起还原：锁定成当时能跑的那棵树，避免 ^ 解析出更新的版本
  $frozen = $false
  $lf = Join-Path $srcDir 'pnpm-lock.yaml'
  if (Test-Path $lf) {
    Copy-FileAtomic -From $lf -To (Join-Path $ProfileDir 'pnpm-lock.yaml')
    $frozen = $true
    Ok 'pnpm-lock.yaml 已还原（将按它冻结安装）'
  } else {
    Warn '该快照没有 lockfile，将按 package.json 重新解析版本'
  }

  if ($patchSource) {
    Step "还原 patch：$($patchSource.Name)"
    Copy-FileAtomic -From $patchSource.FullName -To (Join-Path $ProfileDir 'cordis.patch.yml')
    Ok 'cordis.patch.yml 已还原'
  } else {
    Warn '没有可用的 patch 备份，保留当前 patch'
  }

  $rt = Find-Runtime
  if (-not $rt.Pnpm -or -not $rt.Node) { throw "找不到内嵌 pnpm/node（pnpm=$($rt.Pnpm) node=$($rt.Node)）" }

  Step '安装依赖（硬超时 180 秒，超时杀进程树）'
  $pnpmArgs = if ($frozen) { @('install', '--frozen-lockfile') } else { @('install') }
  $run = Invoke-Pnpm -Node $rt.Node -Pnpm $rt.Pnpm -Dir $ProfileDir -PnpmArgs $pnpmArgs
  if ($run.TimedOut) { throw "pnpm install 超过 180 秒，已杀进程树。日志：$($run.Log)" }
  if ($run.Code -ne 0) { throw "pnpm install 失败（退出码 $($run.Code)）。日志：$($run.Log)" }
  Ok '依赖安装完成'

  $json = Read-ProfileJson
  $deps = @(Get-DepNames $json)
  $nm = Join-Path $ProfileDir 'node_modules'
  $missing = @($deps | Where-Object { -not (Test-Path (Join-Path $nm $_)) })
  if ($missing.Count -gt 0) { Warn ('没装上的依赖：' + ($missing -join ', ')) }
  else { Ok "$($deps.Count) 个依赖全部就位" }

  Say ""
  Say '下一步：启动 DeepSeek Harness 验证。起不来就先 diagnose，再 rollback。' -ForegroundColor Yellow
}

# ---------------- rollback ----------------
function Invoke-Rollback {
  Assert-AppClosed
  $snaps = @(Get-Snapshots)
  if ($snaps.Count -eq 0) { throw '没有 auto-* 快照可回滚。' }

  Say ''
  Step '可用快照（新 → 旧）'
  foreach ($s in $snaps) {
    $reason = '?'
    $meta = Join-Path $s.FullName 'meta.json'
    if (Test-Path $meta) { try { $reason = (Get-Content $meta -Raw | ConvertFrom-Json).reason } catch { } }
    $depsN = 0
    $pj = Join-Path $s.FullName 'package.json'
    if (Test-Path $pj) {
      try { $depsN = @((Get-Content $pj -Raw | ConvertFrom-Json).dependencies.PSObject.Properties | ForEach-Object { $_.Name }).Count } catch { }
    }
    $mark = if ($s.Name -eq $Snapshot) { ' ←' } else { '' }
    Say ("  {0}  {1,-14} 依赖 {2}{3}" -f $s.Name, $reason, $depsN, $mark)
  }

  $target = if ([string]::IsNullOrWhiteSpace($Snapshot)) { $snaps[0] }
            else { $snaps | Where-Object { $_.Name -eq $Snapshot } | Select-Object -First 1 }
  if (-not $target) { throw "没有名为 '$Snapshot' 的快照。用上面的名字，或 -Snapshot 指定。" }

  Say ''
  Step "回滚自：$($target.Name)"
  foreach ($f in $ConfigFiles) {
    $from = Join-Path $target.FullName $f
    if (Test-Path $from) {
      Copy-Item $from (Join-Path $ProfileDir $f) -Force
      Ok "已还原 $f"
    } else {
      $dest = Join-Path $ProfileDir $f
      if ((Test-Path $dest) -and $f -eq 'pnpm-lock.yaml') { Remove-Item $dest -Force; Ok "已删除 $f（快照里没有）" }
    }
  }
  Warn '配置文件已回滚；node_modules 未变动。若依赖也需要对齐，跑 restore 或重新 install。'
}

# ---------------- reset-cookies ----------------
function Invoke-ResetCookies {
  Assert-AppClosed
  $files = @(Get-CookieFiles)
  if ($files.Count -eq 0) {
    Warn "在 $AppDataRoot 里没找到 Cookies 文件，无需处理（下次启动会重新登录）"
    return
  }
  $ck = Get-CookieReport
  Step "应用数据目录：$AppDataRoot"
  Say "  当前：$($ck.Detail)"

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach ($f in $files) {
    $dest = "$($f.FullName).bak-$stamp"
    Move-Item $f.FullName $dest -Force
    Ok "已改名：$($f.Name) → $(Split-Path $dest -Leaf)"
  }

  Say ''
  Say '下一步：启动 DeepSeek Harness，会要求重新登录一次。' -ForegroundColor Yellow
  Say "要退回：把上面那些 .bak-$stamp 改回原名即可（没有删除任何东西）。" -ForegroundColor Yellow
}

# ---------------- install（把短命令写进 PowerShell profile） ----------------
function Invoke-Install {
  $scriptPath = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path $scriptPath)) {
    throw '拿不到脚本自身路径，无法安装短命令。'
  }
  $prof = $PROFILE
  $dir = Split-Path $prof -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $begin = '# >>> dsh-rescue >>>'
  $end = '# <<< dsh-rescue <<<'
  $block = "$begin`r`nfunction dsh-rescue { & '$scriptPath' @args }`r`n$end"

  $existing = if (Test-Path $prof) { Get-Content $prof -Raw } else { '' }
  if ($existing -and $existing.Contains($begin)) {
    $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    $updated = [regex]::Replace($existing, $pattern, $block)
    Set-Content -Path $prof -Value $updated -NoNewline -Encoding utf8NoBOM
    Ok "已更新 $prof 里的 dsh-rescue"
  } else {
    Add-Content -Path $prof -Value "`r`n$block" -Encoding utf8NoBOM
    Ok "已把 dsh-rescue 写进 $prof"
  }

  Say ''
  Say '重开一个终端（或先执行 . $PROFILE），之后就可以直接用：' -ForegroundColor Yellow
  Say '  dsh-rescue diagnose' -ForegroundColor Yellow
  Say '  dsh-rescue snapshot' -ForegroundColor Yellow
}

# ---------------- 分发 ----------------
if ([string]::IsNullOrWhiteSpace($Command)) { $Command = 'status' }

if ($Command -eq 'help') {
  Say @'
DSH 急救 · dsh-rescue

  status         看现状（只读）
  diagnose       看最新崩溃日志、判定故障类型（只读，先跑这个）
  snapshot       手动留一个还原点
  minimal        甲类用：退到最小可启动配置
  restore        装回良好依赖 + patch（有 lockfile 则冻结安装）
  rollback       把快照写回（默认最近一份，会列出所有快照）
  reset-cookies  丙类用：登录态坏了，把 Cookies 改名（不删除，可回退）
  install        把短命令 dsh-rescue 写进 PowerShell profile

参数：
  -ProfileDir <路径>   默认 ~/.dsh/profiles/desktop
  -Snapshot <名字>     restore / rollback 时指定用哪份快照
  -AppDataDir <路径>   默认 %APPDATA%\@deepseek-ai\dsh-desktop
  -Force               应用在运行中也继续（不推荐）

三步：
  1. dsh-rescue diagnose          ← 永远先做这个
  2. 按它说的抄一条命令
  3. 重启应用；起不来就 dsh-rescue rollback
'@
  return
}

switch ($Command) {
  'status'        { Show-Status }
  'diagnose'      { Show-Diagnose }
  'snapshot'      { $d = New-Snapshot -Reason 'manual'; Ok "已备份：$d" }
  'minimal'       { Invoke-Minimal }
  'restore'       { Invoke-Restore }
  'rollback'      { Invoke-Rollback }
  'reset-cookies' { Invoke-ResetCookies }
  'install'       { Invoke-Install }
}
