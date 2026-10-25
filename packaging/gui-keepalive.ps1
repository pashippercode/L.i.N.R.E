# ============================================================================
# Irmia Agent —— 界面 + 后端 保活（看门狗）
#
# ## 为什么要有它（2026-10-11 加）
#
# 本包的正常入口 START.cmd 是"**界面管后端**"的语义：start.ps1 起后端 → 起界面 →
# 等你关掉界面，它再把后端一起停掉。于是"界面没了"有两层后果：
#   ① 看不见状态、进不去设置页（框架本来就没有网页界面，界面就是那个窗口）；
#   ② 界面那个进程若自己崩掉 / 被任务管理器结束 / 被随手关掉，**没有任何东西会把它弄回来**。
# 这台机器上的她（QQ 机器人）是 7×24 跑的，没人盯着 —— 这一份补的就是这个洞。
#
# ## 它做什么
#
# 每 `-IntervalSeconds`（出厂 10）秒看一遍：
#   · 界面 `gui\irmia_gui.exe` 在不在？不在就按 start.ps1 的口径拉起来
#     （**工作目录必须是 exe 所在目录**，Flutter 产物要就地找 flutter_windows.dll 与 data\，
#       cwd 不对它会起来就自己退，而调用方照样报成功）；
#   · 后端在不在？判据是 **config.json 的 web.port 端口通不通**（与 start.ps1 同一条判据：
#     只认"服务对外可见的行为"，不认盘上的文件名）。不通就用本包自带 node 起一个，
#     老生代上限与 start.ps1 同一个数（512）；`-NoBackend` 可关掉这一半。
#
# ## 它不做什么（边界）
#
#   · 不接管 START.cmd 那条链路：你双击 START.cmd 时它照旧工作，两边可以并存
#     （端口已通时它一个进程都不动）；
#   · 不碰 config.json、不改端口、不动 data\ 里的任何状态文件（只读 config.json 拿端口）；
#   · 不"保护"界面不被你关掉 —— 你**故意**关它，10 秒后会被拉回来。想真停：
#     建一个哨兵文件 `data\gui-keepalive.off`（内容随意）⇒ 界面不再被拉起（它自己仍在跑，
#     只是什么都不做）；删掉哨兵即恢复，**不必重启脚本**。
#
# ## 怎么停掉它（回退）
#
#   · 临时：建 `data\gui-keepalive.off`；
#   · 只停界面那半：重建开机项时加 `-NoBackend`；
#   · 彻底：删掉 HKCU\Software\Microsoft\Windows\CurrentVersion\Run 下的
#     `IrmiaGuiKeepalive` 条目，再结束命令行里带本脚本路径的那个 powershell 进程；
#   · 本脚本是**独立文件**，删掉它不影响 Irmia 本体。
#
# ## 用法
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File gui-keepalive.ps1
#     -Repo <安装根>       默认取本脚本所在目录
#     -IntervalSeconds 10  看一遍的间隔
#     -Once                只检查一遍就退出（排障用）
#     -NoBackend           只管界面，不碰后端
#     -StartGuiMinimized   拉起界面时最小化窗口（开机自启那条链用它；见下面「开机自启」）
#     -Status              只打印当前状态（界面/后端/哨兵/有没有别的实例在跑），不改动任何东西
#
# ## 开机自启（2026-10-15 加）
#
#   计划任务 `Irmia` 在**登录后**延迟 45 秒执行：
#     pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <安装根>\gui-keepalive.ps1
#       -Repo <安装根> -StartGuiMinimized
#   即"登录后，后端常驻 + 界面最小化在托盘"。
#   为什么不用 HKCU\...\Run：Run 项只记一条**写死的绝对路径**，包一搬家就静默失效
#   （2026-10-15 实测踩过：包从 Downloads 搬到 Documents 后，Run 项还指着旧路径，
#     于是每次开机都在拉一个不存在的脚本，而且不报错）。计划任务至少能在任务计划程序里看见成败。
#   为什么延迟 45 秒：让 Windows 登录后的桌面先落定再起她，避免跟开机项抢 IO；
#     看门狗首遍就会拉起界面，不必依赖 START.cmd 先跑。
#   回退：`Unregister-ScheduledTask -TaskName Irmia -Confirm:$false`，并删掉 HKCU Run 里的
#     `IrmiaGuiKeepalive` 遗留项。
#
#   ⚠ 拉起界面这件事必须由**放开文件策略**的宿主来做：受限沙盒下 Flutter 界面写不了自己的
#     配置目录，会**无输出、无错误码地立即退出**，症状就是"点了没反应"。本机 2026-10 实测过。
#
# 兼容 Windows PowerShell 5.1（不用 ?? / 三元 / Get-NetTCPConnection 这些新东西）。
# ============================================================================
param(
  [string]$Repo = '',
  [int]$IntervalSeconds = 10,
  [switch]$Once,
  [switch]$NoBackend,
  [switch]$Status,
  # 停掉正在跑的那个看门狗（按 data\gui-keepalive.pid 定位，不按命令行子串匹配）
  [switch]$Stop,
  # 后端 V8 老生代上限（MB）。与 start.ps1 / restart.ps1 同一个数、同一处口径；0 = 不加。
  [int]$NodeMaxOldSpaceMb = 512,
  # 拉起界面时用最小化窗口（开机自启用它：她照样在跑，但不抢焦点、不挡住你开机后要做的事）。
  # 想真退出界面仍然走托盘右键 → 退出；这一项只影响"怎么出现"，不影响"在不在跑"。
  [switch]$StartGuiMinimized,
  # 同一安装根最多留几个界面进程（默认 1）。多出来的按启动时间留最早的那个、其余结束。
  # 0 = 不清理（想故意开两个窗口对照看时用）。
  [int]$MaxGuiProcesses = 1
)

$ErrorActionPreference = 'Continue'

# 控制台/重定向输出的编码：pwsh 非真终端时按系统 ANSI（本机 GBK）写重定向文件，中文会成乱码
# （2026-10-11 实测：data\gui-keepalive.out.log 里全是乱码方块）。这里钉成 UTF-8。
try {
  [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
  $OutputEncoding = New-Object Text.UTF8Encoding($false)
} catch { }

if ([string]::IsNullOrEmpty($Repo)) { $Repo = $PSScriptRoot }

$NodeExe  = Join-Path $Repo 'runtime\node\node.exe'
$ServerJs = Join-Path $Repo 'dist\main.js'
$GuiExe   = Join-Path $Repo 'gui\irmia_gui.exe'
$GuiDir   = Split-Path -Parent $GuiExe
$DataDir  = Join-Path $Repo 'data'
$LogDir   = Join-Path $DataDir 'logs'
$CfgPath  = Join-Path $Repo 'config.json'
$LogPath  = Join-Path $DataDir 'gui-keepalive.log'
$Sentinel = Join-Path $DataDir 'gui-keepalive.off'
$SendOut  = Join-Path $DataDir 'gui-keepalive.out.log'
$PidPath   = Join-Path $DataDir 'gui-keepalive.pid'

function Write-Log([string]$Message) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  try {
    if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1048576)) {
      Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.1') -Force
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch { }
  Write-Host $line
}

# 端口探活：连得上就是"在监听"。与 start.ps1 同一口径（不用 netstat 解析，不要管理员）。
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
    try { $client.Close() } catch { }
  }
}

function Get-WebPort {
  $port = 7788
  try {
    if (Test-Path -LiteralPath $CfgPath) {
      $cfg = Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($cfg.web -and $cfg.web.port) { $port = [int]$cfg.web.port }
    }
  } catch { }
  return $port
}

# 界面在不在。判据是"进程名 + 可读时路径要对上本包的 exe"——
# 只按名字算会在"这台机器上装了第二份 Irmia"时误判成"已活着"。
function Test-GuiAlive {
  $procs = @(Get-Process -Name 'irmia_gui' -ErrorAction SilentlyContinue)
  foreach ($p in $procs) {
    $path = $null
    try { $path = $p.Path } catch { $path = $null }
    if ([string]::IsNullOrEmpty($path)) { return $true }
    if ($path.Equals($GuiExe, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-BackendProcesses {
  # 只认"命令行里带本包 dist\main.js"的 node（这台机器上还有别的 node：SnowLuma 等）。
  $found = @()
  try {
    $found = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains(($ServerJs).ToLower()) })
  } catch { $found = @() }
  return $found
}

# 同一个安装根只该有一个界面进程。
# 为什么会有多的：别的启动器（START.cmd）、看门狗的第二份实例、或用户手动双击 —— 只要在
# 本看门狗"发现界面不在"的那一瞬间各起一个，就会攒出两个窗口，而且谁也不收尸（2026-10-15 实测过）。
# 处置：按启动时间留最早的那个，其余结束掉 —— 界面是无状态的前端，杀掉多余的不丢任何东西。
# -MaxGuiProcesses 0 可关掉这项（比如你要故意开两个窗口对照看）。
function Remove-DuplicateGui {
  if ($MaxGuiProcesses -le 0) { return 0 }
  $procs = @()
  try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='irmia_gui.exe'" -ErrorAction Stop |
      Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($GuiExe, [System.StringComparison]::OrdinalIgnoreCase) } |
      Sort-Object CreationDate)
  } catch { return 0 }
  if ($procs.Count -le $MaxGuiProcesses) { return 0 }
  $extra = $procs | Select-Object -Skip $MaxGuiProcesses
  $killed = 0
  foreach ($p in $extra) {
    try {
      Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
      $killed++
      Write-Log ('发现重复界面：pid={0}（保留最早的 pid={1}），已结束重复的那个' -f $p.ProcessId, $procs[0].ProcessId)
    } catch {
      Write-Log ('结束重复界面 pid={0} 失败：{1}' -f $p.ProcessId, $_.Exception.Message)
    }
  }
  return $killed
}

function Start-Gui {
  try {
    # -StartGuiMinimized：开机自启那条链用最小化窗口起界面（她照常在跑，只是不抢焦点）。
    # 界面本身"点叉只退出界面、进程留托盘"是它的既有行为（ui-state.json 的 close-to-tray），
    # 与本参数无关 —— 这里只决定"出现时是什么窗口状态"。
    $spArgs = @{ FilePath = $GuiExe; WorkingDirectory = $GuiDir; PassThru = $true }
    if ($StartGuiMinimized) { $spArgs['WindowStyle'] = 'Minimized' }
    $p = Start-Process @spArgs
    Write-Log ('界面不在，已拉起：pid={0}（工作目录 {1}，窗口={2}）' -f `
      $p.Id, $GuiDir, $(if ($StartGuiMinimized) { '最小化' } else { '正常' }))
    return $p.Id
  } catch {
    Write-Log ('拉起界面失败：{0}' -f $_.Exception.Message)
    return $null
  }
}

function Start-Backend([int]$Port) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $out = Join-Path $LogDir ('backend-{0}.out.log' -f $stamp)
  $err = Join-Path $LogDir ('backend-{0}.err.log' -f $stamp)
  $argList = @()
  if ($NodeMaxOldSpaceMb -gt 0) { $argList += ('--max-old-space-size=' + $NodeMaxOldSpaceMb) }
  $argList += $ServerJs
  try {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $p = Start-Process -FilePath $NodeExe -ArgumentList $argList -WorkingDirectory $Repo `
      -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    Write-Log ('后端端口 {0} 不通，已拉起后端：pid={1}（日志 data\logs\{2}）' -f $Port, $p.Id, (Split-Path -Leaf $out))
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
      if ($p.HasExited) { Write-Log ('后端起来就退了（exit {0}），看 data\logs\{1}' -f $p.ExitCode, (Split-Path -Leaf $err)); return $false }
      if (Test-PortOpen $Port) { Write-Log ('后端已就绪：127.0.0.1:{0}' -f $Port); return $true }
      Start-Sleep -Milliseconds 500
    }
    Write-Log ('等 60 秒后端仍未就绪（端口 {0} 无应答）' -f $Port)
    return $false
  } catch {
    Write-Log ('拉起后端失败：{0}' -f $_.Exception.Message)
    return $false
  }
}

# ── 单实例：同一时间只允许一个看门狗（多个会互相打架，尤其是在"拉起"那一侧） ──
# 为什么还要一道 pid 文件仲裁：mutex 只在**自己启动那一刻**判一次，而 pid 文件的写入是原子的
# （先写临时文件再 Move-Item）。两份实例如果在同一瞬间起来，mutex 那边可能双双通过，
# 各自的"发现界面不在"又各拉一个界面 —— 2026-10-15 实测攒出 2 个看门狗 + 2 个界面窗口。
# 规则：pid 文件里那个活着就让它当唯一的，本实例自己退；pid 文件没有/已死就自己写进去接管。
function Get-LiveKeepalivePid {
  $targetPid = 0
  try { $targetPid = [int]((Get-Content -LiteralPath $PidPath -Raw -Encoding UTF8).Trim()) } catch { return 0 }
  if ($targetPid -le 0 -or $targetPid -eq $PID) { return 0 }
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
  if (-not $proc) { return 0 }
  # 只认"命令行里带本脚本"的 powershell：光看 pid 存活会误判（pid 会被回收给别人）
  if (-not ($proc.CommandLine -and ($proc.CommandLine -like '*gui-keepalive.ps1*'))) { return 0 }
  return $targetPid
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\IrmiaGuiKeepalive')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
$another = -not $owned
$livePid = Get-LiveKeepalivePid
if ($livePid -gt 0) { $another = $true }

# ── -Status：只读汇报，一个进程都不动 ──
if ($Stop) {
  $targetPid = 0
  try { $targetPid = [int]((Get-Content -LiteralPath $PidPath -Raw -Encoding UTF8).Trim()) } catch { $targetPid = 0 }
  if ($targetPid -le 0) { Write-Host '没有 pid 文件：看门狗大概没在跑'; exit 0 }
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
  if (-not $p) {
    Write-Host ('pid {0} 已经不在了：清掉过期 pid 文件' -f $targetPid)
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    exit 0
  }
  if (-not ($p.CommandLine -and ($p.CommandLine -like '*gui-keepalive.ps1*'))) {
    Write-Host ('pid {0} 不是看门狗（命令行对不上），不动它' -f $targetPid)
    exit 1
  }
  Stop-Process -Id $targetPid -Force
  Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
  Write-Host ('已停看门狗 pid {0}（开机项仍在：下次登录它会自己回来；现在不想让它回来就先删 HKCU Run 里那条）' -f $targetPid)
  exit 0
}
if ($Status) {
  $port = Get-WebPort
  Write-Host ''
  Write-Host '=== Irmia 保活状态 ==='
  Write-Host ('  安装根      : {0}' -f $Repo)
  Write-Host ('  界面        : {0}' -f ($(if (Test-GuiAlive) { '在跑' } else { '**不在**' })))
  Write-Host ('  后端端口    : {0} -> {1}' -f $port, ($(if (Test-PortOpen $port) { '通' } else { '**不通**' })))
  Write-Host ('  哨兵文件    : {0}' -f ($(if (Test-Path -LiteralPath $Sentinel) { '存在（不拉界面）' } else { '不存在' })))
  Write-Host ('  看门狗实例  : {0}' -f ($(if ($another) { '已有别的实例在跑' } else { '当前没有别的实例在跑' })))
  Write-Host ('  日志        : {0}' -f $LogPath)
  Write-Host ''
  if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
  exit 0
}

if ($another) {
  Write-Log ('已有一个保活实例在跑（pid {0}），本实例退出' -f $(if ($livePid -gt 0) { $livePid } else { '未知' }))
  exit 0
}

# pid 文件原子写：先写临时文件再 Move-Item（同卷上是替换语义）。
# 两份实例同瞬间写同一路径时，这样至少不会出现"半个 pid"被对方读成别的数字。
try {
  $tmpPid = Join-Path $DataDir ('gui-keepalive.pid.{0}.tmp' -f $PID)
  Set-Content -LiteralPath $tmpPid -Value $PID -Encoding UTF8
  Move-Item -LiteralPath $tmpPid -Destination $PidPath -Force
} catch { }

if (-not (Test-Path -LiteralPath $GuiExe) -and -not (Test-Path -LiteralPath $NodeExe)) {
  Write-Log ('安装根不像 Irmia 的包根（既没有 {0} 也没有 {1}），退出' -f $GuiExe, $NodeExe)
  try { $mutex.ReleaseMutex() } catch { }
  exit 1
}

$port = Get-WebPort
Write-Log ('保活启动：根={0} · 端口={1} · 间隔={2}s · 后端={3} · 日志={4}' -f `
  $Repo, $port, $IntervalSeconds, ($(if ($NoBackend) { '不管' } else { '兼顾' })), $LogPath)

$pausedLogged = $false
$pass = 0
while ($true) {
  $pass++

  if (Test-Path -LiteralPath $Sentinel) {
    if (-not $pausedLogged) {
      Write-Log ('发现哨兵 {0}：不再拉起界面（删掉它即恢复）' -f $Sentinel)
      $pausedLogged = $true
    }
    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSeconds
    continue
  }
  if ($pausedLogged) {
    Write-Log '哨兵已删除：恢复保活'
    $pausedLogged = $false
  }

  if (-not $NoBackend) {
    if (-not (Test-PortOpen $port)) { Start-Backend $port | Out-Null }
  }

  if (Test-GuiAlive) {
    if ($pass -eq 1) { Write-Log '界面在跑，本次不做任何动作' }
  } else {
    Start-Gui | Out-Null
  }

  # 收掉重复的界面窗口（见 Remove-DuplicateGui 的注释；默认只留 1 个）
  Remove-DuplicateGui | Out-Null

  # 每 60 遍（10s 间隔下 = 10 分钟）写一行心跳，便于事后确认"它一直在看"
  if ($pass % 60 -eq 0) {
    Write-Log ('心跳：第 {0} 遍 · 界面={1} · 后端={2}' -f $pass, ($(if (Test-GuiAlive) { '在' } else { '不在' })), ($(if (Test-PortOpen $port) { '在' } else { '不在' })))
  }

  if ($Once) { break }
  Start-Sleep -Seconds $IntervalSeconds
}

try { $mutex.ReleaseMutex() } catch { }
exit 0
