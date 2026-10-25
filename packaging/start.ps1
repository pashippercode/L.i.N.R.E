# ============================================================================
# Irmia Agent v@@VERSION@@ 便携包 —— 启动链（由同目录的 START.cmd 调用）
#
# 它只干四件事，别的什么都不做：
#   ① 起后端：用**本包自带**的 Node 运行时跑 dist\main.js（你机器上有没有 node 都不影响）
#   ② 等就绪：轮询本地服务端口，通了才往下走（不靠 sleep 猜时间）
#   ③ 老实例兼容：盘上若还留着迁移期那份 data\.ui-token，顺手同步到界面读的位置；
#      新装没有这个文件，这一步自然跳过（现在进界面靠的是**你自己设的那个密码**）
#   ④ 收尾：界面关掉后停后端；加 -KeepRunning 则留着它继续无人值守地跑
#
# 为什么是 PowerShell 而不是 .bat：要等端口、要管两个进程的生死——批处理做不动。
# 为什么用 powershell.exe 而不是 pwsh：测试者机器上一定有前者，后者可能要自己装。
# 兼容 Windows PowerShell 5.1（不用 ?? / 三元 / Get-NetTCPConnection 之类的新语法与新 cmdlet）。
# ============================================================================
param(
  [switch]$KeepRunning,
  # 后端进程的 V8 老生代上限（MB）。**为什么要有它**见下面 `$NodeMaxOldSpaceArg` 那一段。
  # 0 或负数 = 不加这个参数（回到"由 V8 自己看着办"的旧行为）。
  [int]$NodeMaxOldSpaceMb = 512
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

$NodeExe    = Join-Path $Root 'runtime\node\node.exe'
$ServerJs   = Join-Path $Root 'dist\main.js'
$GuiExe     = Join-Path $Root 'gui\irmia_gui.exe'
$DataDir    = Join-Path $Root 'data'
$LogDir     = Join-Path $DataDir 'logs'
$CfgPath    = Join-Path $Root 'config.json'
$CfgExample = Join-Path $Root 'config.example.json'
$TokenPath  = Join-Path $DataDir '.ui-token'

# ── 后端的老生代上限（2026-10-10 加） ────────────────────────────────────────
#
# **为什么是 512**：实测（`_research/probe-mem-peak.mts`，同一份 58 MB / 7.3 万条事件日志、
# 把界面各页的请求都打一遍）真实 Web 负载的堆峰值是 **217~319 MB**，而连续拉 5 次
# `?limit=1000` 的大页时到 **319 MB**。**256 MB 会 OOM**（连真实 Web 负载都跑不完，
# 实测 exit 134）；384 MB 能跑完但余量只剩 ~80 MB。512 MB 给足余量。
#
# **它解决的是什么**：V8 把不再使用的堆**还给 `heapUsed`，但不还给系统** ——
# `_research/probe-v8-retention.mjs` 实测：持有 ~600 MB 再全释放 + GC ⇒ `heapUsed` 回到
# 4 MB，而 **RSS 仍是 1174 MB**。于是进程的 RSS 只由"历史最高水位"决定，一路顶到 GB 级。
# 上限是**把那个水位钉住**（不是"让存活对象变小"）。
#
# **怎么回退**：把这一格的默认值改成 `0`（或启动时传 `-NodeMaxOldSpaceMb 0`）＝不加这个
# 参数，行为回到从前。改这一个数即可，别的地方不用动。
#
# ⚠ **风险如实写**：上面那组峰值是**Web 负载**量出来的，而活实例还要跑 agent 主循环
# （模型请求体、MCP 工具 schema、图片/base64）——那部分本探针**没覆盖**。这台机器今天
# 已因内存不足 OOM 崩过一次 ⇒ **若再出现 OOM，第一件事是把这一格调大或调回 0**，
# 别去怀疑别处。（`--max-old-space-size` 是 V8 的**软上限**：到了会拼命 GC，
# 真到极限仍是 `FATAL ERROR: … JavaScript heap out of memory`。）
#
# **为什么不用 `NODE_OPTIONS`**：那是进程级全局环境变量，会连同这台机器上**别的** node
# 一起改（SnowLuma 也是 node.exe），而这里要改的只有"我们拉起的这一个后端"。
$NodeMaxOldSpaceArg = ''
if ($NodeMaxOldSpaceMb -gt 0) { $NodeMaxOldSpaceArg = '--max-old-space-size=' + $NodeMaxOldSpaceMb }

function Say([string]$Message) {
  Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Fail([string]$Message) {
  Write-Host ''
  Write-Host "[启动失败] $Message" -ForegroundColor Red
  Write-Host ''
  exit 1
}

# 端口探活：连得上就是"在监听"。比 netstat 解析稳，也不用管理员权限。
function Test-PortOpen([int]$Port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne(400)) { return $false }
    $client.EndConnect($async)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

# 本包自己的后端进程：命令行里带本包的 dist\main.js 绝对路径。
# 为什么不按进程名找 node.exe：你机器上可能还有别的 node（别的项目、别的 agent），杀错就是事故。
function Get-OurBackends {
  try {
    $all = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop)
  } catch {
    return @()
  }
  return @($all | Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$ServerJs*") })
}

Write-Host ''
Write-Host '  Irmia Agent v@@VERSION@@  ·  win-x64 便携包' -ForegroundColor Cyan
Write-Host '  （内测版：功能面到"能装能用"，但还会改接口与数据结构）' -ForegroundColor DarkGray
Write-Host ''

# ── 0. 自检：包是不是完整的 ────────────────────────────────────────────────
foreach ($required in @($NodeExe, $ServerJs, $GuiExe)) {
  if (-not (Test-Path $required)) {
    Fail "包里缺文件：$required`n这个包可能没解压完整，或者被杀毒软件删了文件。请重新解压一份完整包。"
  }
}

# ── 1. 配置：没有 config.json 就从示例复制一份（改端口/改模型都在这里） ──────
if (-not (Test-Path $CfgPath)) {
  if (Test-Path $CfgExample) {
    Copy-Item -Path $CfgExample -Destination $CfgPath
    Say 'config.json 不存在，已从 config.example.json 复制一份（首启等价于出厂设置）'
  }
}

$Port = 7788
if (Test-Path $CfgPath) {
  try {
    $cfg = Get-Content -Path $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.web -and $cfg.web.port) { $Port = [int]$cfg.web.port }
  } catch {
    Fail "config.json 不是合法 JSON：$($_.Exception.Message)`n用记事本打开它检查一下（或删掉它，让启动器从 config.example.json 重新复制一份）。"
  }
}

Write-Host "  包目录  ：$Root"
Write-Host "  数据目录：$DataDir"
Write-Host "  本地服务：http://127.0.0.1:$Port（框架不提供网页界面，界面就是那个窗口）"
Write-Host ''

# ── 2. 后端：已在跑就复用，端口被别人占了就讲清楚怎么办 ────────────────────
$backend = $null
# `@(...)` 不是装饰：Windows PowerShell 5.1 下，函数只回一个 CimInstance 时会被拆成标量，
# 而标量的 `.Count` 在 5.1 里是 $null（pwsh 7 才补成 1）——于是"明明找到了自己的后端"却判成
# "端口被别人占了"。实测踩过这个坑，包一层数组把语义钉死。
$ourBackends = @(Get-OurBackends)

if (Test-PortOpen $Port) {
  if ($ourBackends.Count -gt 0) {
    $backend = Get-Process -Id $ourBackends[0].ProcessId
    Say "后端已在运行（pid $($backend.Id)）——复用它，不重复启动"
  } else {
    Fail @"
端口 $Port 已经被**别的程序**占用了（不是本包的后端）。
两条路，任选一条：
  1) 把 config.json 里的 "port": $Port 改成别的值（例如 7801），保存后重新双击 START.cmd；
  2) 找出占用端口的程序并关掉它（PowerShell 里跑：Get-NetTCPConnection -LocalPort $Port | Select-Object OwningProcess）。
"@
  }
} else {
  # data\ 与 data\logs\ 只在真要起后端时才建：启动前的检查失败（端口被占等）不该在包里留痕
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $outLog = Join-Path $LogDir ("backend-$stamp.out.log")
  $errLog = Join-Path $LogDir ("backend-$stamp.err.log")

  # 环境只设本包自己的：数据目录钉在包内，PATH 前置自带 Node 目录——
  # 于是"你机器上装没装 node、PATH 里有没有 node"都不影响这条启动链。
  $env:IRMIA_DATA_DIR = $DataDir
  $env:IRMIA_WEB_PORT = "$Port"
  $env:PATH = (Join-Path $Root 'runtime\node') + ';' + $env:PATH

  Say '正在启动后端（自带 Node 运行时）…'
  # -NoNewWindow 而不是 -WindowStyle Hidden：让后端跟启动器共用同一个控制台，于是
  #   · Ctrl+C 会同时送到两边 —— 后端收到 SIGINT 走它自己的优雅退出（结算 session/end、落缓存、放锁）
  #   · 万一有人直接叉掉这个黑窗口，后端也一起走，不会留个没人管的孤儿进程
  # 输出仍然全部重定向到文件，控制台不会被她的话刷屏。
  #
  # 参数顺序：**Node 的选项必须在入口之前**（`node <opts> <entry>`），所以
  # `$NodeMaxOldSpaceArg` 拼在 `"$ServerJs"` 前面；为空时不留多余空格。
  $backendArgs = ('"' + $ServerJs + '"')
  if ($NodeMaxOldSpaceArg -ne '') { $backendArgs = $NodeMaxOldSpaceArg + ' ' + $backendArgs }
  $backend = Start-Process -FilePath $NodeExe `
    -ArgumentList $backendArgs `
    -WorkingDirectory $Root -NoNewWindow `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
  Say "后端进程 pid $($backend.Id)，日志：data\logs\$(Split-Path -Leaf $outLog)"
  if ($NodeMaxOldSpaceArg -ne '') {
    Say "（后端老生代上限 $NodeMaxOldSpaceMb MB：$NodeMaxOldSpaceArg —— 见脚本头部那段注释，回退就把它调成 0）"
  }
}

# ── 3. 等就绪：本地服务端口通了就继续 ──────────────────────────────────────
# **就绪判据是"端口通"，不是"某个文件出现了"。**
#   文件是某一版认证的产物；端口才是"服务真的在听"。把两者绑在一起，等于让启动链
#   偷偷依赖一个内部实现细节——实现一换，包就起不来，而装配与闸门**都会给它开绿灯**。
#   这一版正好踩到：判据原来是「端口通 **且** data\.ui-token 出现」，而 .ui-token 是
#   上一版的旧凭据，现在只读兼容、**不再生成**（见 src\web\auth.ts）——新装的包永远
#   不会出现它，于是 60 秒后报"后端没就绪"并退出，**使用者双击之后什么都起不来**。
#   以后要加判据：只加"服务对外可见的行为"（能连、能应答），不要加盘上的文件名。
$deadline = (Get-Date).AddSeconds(60)
$ready = $false
while ((Get-Date) -lt $deadline) {
  if ($backend -and $backend.HasExited) { break }
  if (Test-PortOpen $Port) { $ready = $true; break }
  Start-Sleep -Milliseconds 500
}

if (-not $ready) {
  $tail = ''
  $latest = Get-ChildItem -Path $LogDir -Filter 'backend-*.out.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) {
    $tail = (Get-Content -Path $latest.FullName -Tail 20 -Encoding UTF8) -join "`n"
  }
  Fail @"
等 60 秒后端还没就绪（本地服务端口 $Port 一直没有应答）。
最近的启动日志（$($latest.Name)）末尾几行：
$tail
常见原因：端口被占、data 目录没有写权限、杀毒软件拦了 node.exe。
"@
}

Say '后端已就绪'

# 老实例兼容：盘上还留着迁移期那份 data\.ui-token 时，把它放到界面读的那个位置
# （%APPDATA%\Irmia\gui-token）。**新装没有这个文件**——进界面靠你自己设的密码，这一步跳过。
if ((Test-Path $TokenPath) -and $env:APPDATA) {
  $token = (Get-Content -Path $TokenPath -Raw -Encoding UTF8).Trim()
  $guiToken = Join-Path $env:APPDATA 'Irmia\gui-token'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $guiToken) | Out-Null
  Set-Content -Path $guiToken -Value $token -NoNewline -Encoding ASCII
  Say '检测到旧凭据（data\.ui-token），已同步到界面读的那个位置'
}

# ── 4. 界面 + 收尾 ────────────────────────────────────────────────────────
Say '正在打开界面…'
$gui = Start-Process -FilePath $GuiExe -WorkingDirectory (Split-Path -Parent $GuiExe) -PassThru

Write-Host ''
Write-Host "  界面已开。本地服务：http://127.0.0.1:$Port（框架不提供网页界面，界面就是那个窗口）" -ForegroundColor Green
Write-Host '  第一次打开它**会让你设一个密码**——设完就是登录态，以后用它进。'
if ($KeepRunning) {
  Write-Host '  -KeepRunning 已开：关掉界面后，后端会继续在后台跑（无人值守）。' -ForegroundColor Yellow
  Write-Host "  要停它：Stop-Process -Id $($backend.Id)（或任务管理器里结束那个 node.exe）"
} else {
  Write-Host '  点界面的「叉」= 退出界面（她照常在后台跑）；想改成"关窗就收进托盘"，在设置页里打开那个开关。' -ForegroundColor Yellow
  Write-Host '  也可以在这个黑窗口里按 Ctrl+C 直接收工；别直接叉掉黑窗口（那样后端可能留在后台跑）。' -ForegroundColor DarkGray
}
Write-Host ''

try {
  $windowSeen = $false
  $trayHinted = $false
  while (-not $gui.HasExited) {
    Start-Sleep -Milliseconds 800
    if ($backend -and $backend.HasExited) {
      Write-Host ''
      Write-Host "[!] 后端进程先退了（退出码 $($backend.ExitCode)）——界面这会儿连不上本地服务。看看 data\logs 里最新的日志。" -ForegroundColor Red
      break
    }
    if (-not $trayHinted) {
      # 窗口出现过、后来又没了 = 被收进托盘了。提示一次就够，之后她要再显示出来也别刷屏。
      $gui.Refresh()
      if ($gui.MainWindowHandle -ne [IntPtr]::Zero) {
        $windowSeen = $true
      } elseif ($windowSeen) {
        $trayHinted = $true
        Write-Host '[提示] 界面已收进托盘（进程还在，后端也还在跑）。要真退出：右键托盘图标 → 退出。' -ForegroundColor DarkGray
      }
    }
  }
} finally {
  if ($backend -and -not $backend.HasExited) {
    if ($KeepRunning) {
      Say "界面已关；后端（pid $($backend.Id)）按 -KeepRunning 继续跑"
    } else {
      Say '界面已关，正在停后端…'
      Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue
      # 被强杀不影响数据：事件日志是唯一真相源，启动时 recover 会把没结算的那一步补上。
      Say '后端已停（事件日志设计上崩溃可恢复：下次启动会自动恢复未结算的那一步）'
    }
  }
}
Say '再见。'
