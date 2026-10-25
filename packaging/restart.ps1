# ============================================================================
# Irmia Agent —— **随包的重启脚本**（装配到包根：`<安装根>\restart.ps1`）
#
# 为什么包里必须有这一份（2026-10-07 主人报的缺陷）：
#   beta.5 的内测包**根本不含 `tools\` 目录、不含 `restart-agent.ps1`**
#   （包根只有 dist/ gui/ runtime/ skills/ config.example.json config.json package.json
#     README-BETA.md START.cmd start.ps1 VERSION.txt），
#   而界面上那颗"重启"按钮走的是**服务端**那条命令行，服务端过去写死去跑
#   `tools\restart-agent.ps1` —— 于是**装出来的那份重启必然失败**：脚本不存在。
#   开发机上看不出来，因为开发仓库里 `tools\` 一直在。
#
# 所以这一份是"**装出来的那份能自己重启**"的落点之一（路径链第 ② 条）：
#   ① 开发机：`<root>\tools\restart-agent.ps1`（仓库脚本，行为与从前一字不差）；
#   ② 装机版：**本脚本**（`<root>\restart.ps1`）；
#   ③ 两条都没有：框架自己用 `runtime\node\node.exe` 拉起一份新的自己（self-restart）。
#   三条的回执里都写明走的是哪一条（见下面 `[回执]` / `[结束]` 里的 `路径=`）。
#
# 它与 `tools\restart-agent.ps1` 的**职责相同、判据相同**，但**不许带任何开发机专用的
# 路径或参数**（那份脚本里写着出包机的私事：`-KillTag`、`-ProbeExit`、`-Repo` 的默认值……）。
# 这份只认服务端真的会传的那几条：
#
#   -Repo <安装根>        -NodeEntry <dist\main.js 的绝对路径>
#   -GuiExe <界面 exe>    -GuiOnly（只重启界面，一个后端进程都不动）
#   -TraceLog <留痕文件>  -ScriptLog <本脚本输出的落点>
#   -DelaySeconds <秒>    -Port <端口>  -ProbeHost <探测地址>  -OutLog <新实例输出的落点>
#
# 用法（人也能直接用）：pwsh -File restart.ps1            # 停旧后端 + 拉起新的
#                       pwsh -File restart.ps1 -DryRun    # 空跑：只分类参数与留痕，一个进程都不动
#
# ## Windows 上那几条实测过的坑（照抄自 `tools\restart-agent.ps1` 的文件头，一处都不改）
#
#   ① 拉起必须经 `cmd.exe /s /c ""<exe>" <args> >> <日志> 2>&1"`：
#      `Win32_Process.Create` 直接建 pwsh 时会**返回 0 而子进程立刻消失**（脚本一个字都没执行）；
#   ② **重定向必须写在内层那对引号里面**：写在外面的三种写法实测都是"返回 0、命令根本没执行"；
#   ③ 入口与 cwd 一律**绝对路径**：相对路径 + 指望工作目录 = 找不到文件、悄无声息退出；
#   ④ 拉起前后的判据是"**新出现的那个** pid"，不是"现在有一个"（这台机器上还有别的 node）；
#   ⑤ 本文件存 **UTF-8 带 BOM**：Windows PowerShell 5.1 没 BOM 会把中文读成乱码，
#      中文字节被拆坏后连字符串终结符都能吃掉（本仓实测踩过）。
#
# ## 2026-10-10：界面那一支补两处（与 `tools\restart-agent.ps1` 同一口径）
#
# 这两处都不是"顺手改改"，是对着开发机那份已经查明并落地的结论**对齐**（只读核对，没有改动它）：
#
#   (a) **界面必须带 `-WorkingDirectory <exe 所在目录>`**（本文件原来**没有**这一条）。
#       Flutter 的 Windows 产物要**就地**找 `flutter_windows.dll` 与 `data\`：工作目录不是 exe 所在
#       目录时，进程会**起来就自己退**，而 WMI/`Start-Process` 那一层**照样报成功**（留痕里
#       `[结束] ok=True`、pid 也有）——"点了重启，界面闪一下没了"就是这么来的。
#       过去这条脚本拉界面时，进程继承的是**外层 cmd 的 cwd = 安装根**（不是 exe 所在目录），
#       所以这条不是理论风险：它与开发机那份一直是 `-WorkingDirectory <exe 所在目录>` 的写法**不一致**。
#
#   (b) **拉起之后要读窗口/存活**（原来只有 `$proc.Id` 一句，什么都不看）。
#       现在用 `-PassThru` 给的 pid 认"**自己拉起的那个**"，落地与 `tools\restart-agent.ps1`
#       **逐字同口径**的四态判据（同一套状态名、同一套措辞）：
#         · `not-appeared`       没出现：任何"它跑过"的读数都拿不到；
#         · `appeared-then-exited` 出现即退：pid 在手、它已经不在了（能读到退出码就写上）；
#         · `alive-no-window`    出现但无窗口：pid 活着，窗口 top-level=0 visible=0；
#         · `alive`              出现且有窗口：pid 活着，窗口 top-level=N visible=M。
#       为什么**不许**用"同路径新进程"那种采样当判据：界面与后端不同，界面的 exe 路径是**这个安装
#       独有**的，但"采样里看到一个同路径的新进程"分不清"我拉起的"与"别人（比如主人手工）拉起的"
#       （开发机那份 2026-10-10 01:31:23 那条 `界面拉起=alive pid 27964` 就是这个疑点：拉起命令
#       01:30:38 发的，而那个进程 CreationDate 是 01:31:03，晚了 25 秒）。
#       `-PassThru` 的 pid 是**按构造**我拉起的那个，所以判据落在它身上，一个采样都不用做。
#
# 另外记住这条根因（开发机那份的 2026-10-10 结论，本份**本来就不吃**这一条）：
#   界面那一支过去还有一种"WMI 返回码 0、壳 pid 有、exe 根本没被执行"的形状，根因是
#   服务端起脚本时把**脚本自己的 stdout** 也 `>>` 到了 `data\restart-script.log`，
#   而 cmd 的 `>>` 只 FILE_SHARE_READ ⇒ 界面那一支再 `>>` 同一个文件时**打开就失败、cmd 随即退出**。
#   本份的界面支**不重定向**（`Start-Process` 默认不重定向），所以没有这一条；
#   这份的后端支重定向到 `-OutLog`（服务端给的是 `data\restart-backend.log`），与 `-ScriptLog`
#   （`data\restart-script.log`）**不是同一个文件**——两条都不踩那个坑，但**不许**把界面的
#   stdout/stderr 改成追加到 `-ScriptLog`：那正好会把上面那个根因请回来。
# ============================================================================
param(
  # 安装根（= 包根；新实例的 cwd 就是它）
  [string]$Repo = '',
  # 后端入口。默认 `<Repo>\dist\main.js`——**相对路径一律相对 Repo 解析**，不相对 cwd
  [string]$NodeEntry = '',
  # 自带 Node 运行时；默认先看 `<Repo>\runtime\node\node.exe`，再看 PATH 里的 node.exe
  [string]$NodeExe = '',
  # 界面可执行文件（可空）。给了就把它也重启——"重启前后端"那颗按钮会带它
  [string]$GuiExe = '',
  # **只重启界面**：一个后端进程都不动（后端好好的、只有界面要重开时用）
  [switch]$GuiOnly,
  # 延迟几秒再动手：让发起这次重启的 HTTP 响应先回到界面，人就不会看到"点了没反馈"
  [int]$DelaySeconds = 2,
  # 本次重启的留痕（追加写）。服务端读它判三态，**必须与服务端约定同一个路径**
  [string]$TraceLog = '',
  # 本脚本（cmd 那一层）的 stdout/stderr 落点：不给就随 WMI 进程一起消失（失败无声）
  [string]$ScriptLog = '',
  # 新实例 stdout/stderr 的落点（不给 = 丢进 `<Repo>\data\restart-backend.log`）
  [string]$OutLog = '',
  # 探哪个端口（服务端传它实际在用的那个；不给就从 config.json 的 web.port 读）
  [string]$Port = '',
  # 端口探测的目标地址。**这个名字不许叫 `$ProbeHost`**：`$ProbeHost` 是 PowerShell 的只读自动变量，
  # 参数名撞上它时**参数绑定阶段**就报 "Cannot overwrite variable Host because it is
  # read-only or constant"，脚本正文一个字都不执行——症状与"脚本没跑起来"一模一样。
  # 本机实测（2026-10-08 的隔离端到端就是这么抓到它的）：留痕一个字都没写、
  # 服务端只能说"脚本没有留下回执"。凡是与自动变量同名的参数，一个都不许留。
  [string]$ProbeHost = '127.0.0.1',
  # 等旧实例消失 / 等端口就绪的上限（秒）
  [int]$WaitSeconds = 90,
  [int]$PortWaitSeconds = 60,
  # 空跑：只走"分类参数 + 留痕 + 如实汇报"，一个进程都不停、也不拉起任何东西
  [switch]$DryRun,
  # 后端进程的 V8 老生代上限（MB）。与 `packaging\start.ps1`、`tools\restart-agent.ps1`
  # **同一个数、同一处口径**（三份各自默认 512，改的时候一起改）。
  # 0 或负数 = 不加这个参数（回到"由 V8 自己看着办"的旧行为）＝**回退就改这一格**。
  [int]$NodeMaxOldSpaceMb = 512
)

$ErrorActionPreference = 'Stop'

# ── 5.1 兼容的常量（不用 `??`、不用三元、不用 `-join` 之外的新语法） ──────────
$PATH_LABEL = 'packaged-script'
$REASON_OK = 'ok'
$REASON_OLD_NOT_GONE = 'old-not-gone'
$REASON_SPAWN_FAILED = 'spawn-failed'
$REASON_PORT_NOT_READY = 'port-not-ready'
$REASON_LOCK_NOT_CHANGED = 'lock-not-changed'
$REASON_GUI_FAILED = 'gui-failed'

# ── 后端的老生代上限（2026-10-10 加） ────────────────────────────────────────
#
# **为什么是 512**：实测（`_research/probe-mem-peak.mts`，同一份 58 MB / 7.3 万条事件日志、
# 把界面各页的请求都打一遍）真实 Web 负载的堆峰值是 **217~319 MB**；**256 MB 会 OOM**
# （连真实 Web 负载都跑不完，实测 exit 134）；384 MB 能跑完但余量只剩 ~80 MB。512 给足余量。
#
# **它解决的是什么**：V8 把不再使用的堆**还给 `heapUsed`，但不还给系统** ——
# `_research/probe-v8-retention.mjs` 实测：持有 ~600 MB 再全释放 + GC ⇒ `heapUsed` 回到
# 4 MB，而 **RSS 仍是 1174 MB**。于是 RSS 只由"历史最高水位"决定，一路顶到 GB 级。
# 上限是**把那个水位钉住**（不是"让存活对象变小"）。
#
# **怎么回退**：`-NodeMaxOldSpaceMb 0`（或把默认值改成 0）＝不加这个参数，行为回到从前。
#
# ⚠ **风险如实写**：那组峰值是**Web 负载**量出来的，而活实例还要跑 agent 主循环
# （模型请求体、MCP 工具 schema、图片/base64）——本探针**没覆盖**。这台机器今天已因内存
# 不足 OOM 崩过一次 ⇒ **若再出现 OOM，第一件事是把这一格调回 0 或调大**，别去怀疑别处。
#
# **为什么不用 `NODE_OPTIONS`**：那是进程级全局环境变量，会连这台机器上**别的** node
# （SnowLuma 也是 node.exe）一起改，而这里要改的只有"我们拉起的这一个后端"。
$NodeMaxOldSpaceArg = ''
if ($NodeMaxOldSpaceMb -gt 0) { $NodeMaxOldSpaceArg = '--max-old-space-size=' + $NodeMaxOldSpaceMb }

# ── 安装根：默认取本脚本所在目录（**不是 cwd**：WMI 建出来的进程 cwd 不由我们决定） ──
if ($Repo -eq '') { $Repo = $PSScriptRoot }
try { $Repo = [System.IO.Path]::GetFullPath($Repo) } catch { }

# **相对路径一律相对 Repo 解析**：入口被解析到别的安装根上，就会拉起一个"真的别的后端"。
function Resolve-Abs([string]$Path) {
  if ($Path -eq '') { return $Path }
  try {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Repo $Path))
  } catch { return $Path }
}

$NodeEntryAbs = Resolve-Abs $NodeEntry
if ($NodeEntryAbs -eq '') { $NodeEntryAbs = Join-Path $Repo 'dist\main.js' }

# 自带运行时优先：装机版里 node 就在包内，**不指望使用者的 PATH**
if ($NodeExe -eq '') {
  $bundled = Join-Path $Repo 'runtime\node\node.exe'
  if (Test-Path -LiteralPath $bundled) { $NodeExe = $bundled }
  else { $NodeExe = 'node.exe' }
}

$dataDir = Join-Path $Repo 'data'
if ($TraceLog -eq '') { $TraceLog = Join-Path $dataDir 'restart-trace.log' }
if ($ScriptLog -eq '') { $ScriptLog = Join-Path $dataDir 'restart-script.log' }
if ($OutLog -eq '') { $OutLog = Join-Path $dataDir 'restart-backend.log' }
$OutLogAbs = Resolve-Abs $OutLog

# 端口：服务端没给就从 config.json 读（**不许猜 7788**：那是出厂值，使用者可以改）
if ($Port -eq '') {
  $portGuess = 7788
  $cfgPath = Join-Path $Repo 'config.json'
  if (Test-Path -LiteralPath $cfgPath) {
    try {
      $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $cfg.web -and $null -ne $cfg.web.port) { $portGuess = [int]$cfg.web.port }
    } catch { }
  }
  $Port = [string]$portGuess
}
$PortNum = 0
try { $PortNum = [int]$Port } catch { $PortNum = 0 }

# ── 留痕：写不进去**不算错**（重启本身比留痕重要得多，一处都不许因为日志卡住） ──
$script:TraceOk = $true
function Write-Trace([string]$Line) {
  $text = $Line
  try { Add-Content -LiteralPath $TraceLog -Value $text -Encoding UTF8 } catch { $script:TraceOk = $false }
  Write-Host $text
}

# `[结束]` 只能出现**一次**（服务端按"发起之后新增的那一段"读它）
#
# 后两个参数是**界面那一支的读数**（四态 + 一句人话），口径与 `tools\restart-agent.ps1` 的结尾行一致：
# 那边写的是 `界面拉起=<State>（<StateNote>）`，这边逐字照抄。只有"**真去拉了界面**"才有这一档
# （没给 `-GuiExe`、或路径不存在时不说——否则会凭空多出一句让人以为界面被拉过的话）。
# 位置：这一档写在**人读的话（Detail）后面**、行尾——理由有两个：① 服务端只认行首那几个
# `ok=/backendPid=/port=/guiPid=` 字段（`src\web\server.ts` 的 restart 分支），人读的话不该被它挤到后面；
# ② `界面拉起=` 是**机器可读的读数**，与开发机那份的 `界面形状=` / `失败=` 一样放行尾，便于按行尾比对。
$script:EndWritten = $false
function Write-End([string]$OkFlag, [string]$PidText, [string]$PortState, [int]$GuiPid, [string]$Reason, [string]$Detail, [string]$GuiState, [string]$GuiNote) {
  if ($script:EndWritten) { return }
  $script:EndWritten = $true
  $line = '[结束] ok=' + $OkFlag + ' backendPid=' + $PidText + ' port=' + $PortState + ' guiPid=' + $GuiPid + ' path=' + $PATH_LABEL + ' reason=' + $Reason
  if ($Detail -ne '') { $line = $line + ' · ' + $Detail }
  # 界面读数：**同一句读数只说一次**（先前把 Detail 与它拼在一起，`界面拉起=…` 会在结尾行里出现两遍）
  if ($GuiState -ne '') {
    $guiReading = '界面拉起=' + $GuiState
    if ($GuiNote -ne '') { $guiReading = $guiReading + '（' + $GuiNote + '）' }
    $line = $line + ' · ' + $guiReading
  }
  Write-Trace $line
}

# ── 判据：**分隔符无关**地找"主进程"（命令行含 `<安装根>/dist/main.js` 的 node.exe） ──
#
# 为什么按安装根 + 入口匹配（而不是按 pid、也不是按 `*dist/main.js*`）：
#   · 按 pid 要指望 lock.json 说实话，而它可能正是坏的/陈旧的；
#   · 按 `*dist/main.js*` 会**误伤**：这台机器上可能同时跑着别的安装（甚至开发仓库）；
#   · SnowLuma（协议端）也是 node.exe，它**一定不能被碰**（杀了要人重新登录 QQ）——
#     它的命令行里没有 `<安装根>/dist/main.js`，规整之后照样不含，所以判据天然不碰它。
function ConvertTo-MatchForm([string]$Text) {
  if ($null -eq $Text) { return '' }
  return $Text.Replace('\', '/').ToLowerInvariant()
}
$matchNeedle = ConvertTo-MatchForm (Join-Path $Repo 'dist\main.js')
function Get-AgentProcesses {
  $found = @()
  foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue)) {
    $line = ConvertTo-MatchForm $p.CommandLine
    if ($line -notlike ('*' + $matchNeedle + '*')) { continue }
    if ($line -like '*snowluma*') { continue }
    $found += $p
  }
  return $found
}

function Test-PortListening([string]$TargetHost, [int]$TargetPort) {
  if ($TargetPort -le 0) { return $false }
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(500, $false) -and $client.Connected) { return $true }
    return $false
  } catch {
    return $false
  } finally {
    try { $client.Close() } catch { }
  }
}

function Get-LockPid {
  $lockPath = Join-Path $dataDir 'lock.json'
  if (-not (Test-Path -LiteralPath $lockPath)) { return 0 }
  try {
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [int]$lock.pid
  } catch { return 0 }
}

# 拉起一个**分离**进程（本脚本会退出，它必须活着）。三条实测纪律见文件头 ①②③。
function Invoke-Detached([string]$Exe, [string]$ArgLine, [string]$WorkDir, [string]$LogPath) {
  $inner = '""' + $Exe + '"'
  if ($ArgLine -ne '') { $inner = $inner + ' ' + $ArgLine }
  if ($LogPath -ne '') { $inner = $inner + ' >> "' + $LogPath + '" 2>&1' }
  $inner = $inner + '"'
  $cmd = 'cmd.exe /s /c ' + $inner
  $si = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
  $si.ShowWindow = 0
  $created = $null
  try { $created = ([wmiclass]'Win32_Process').Create($cmd, $WorkDir, $si) } catch { return $null }
  if ($null -eq $created) { return $null }
  if ($created.ReturnValue -ne 0) {
    Write-Trace ('拉起失败：WMI 返回码 ' + $created.ReturnValue + ' · 命令行 ' + $cmd)
    return $null
  }
  Write-Trace ('拉起读数：' + $cmd + ' => WMI 返回码 ' + $created.ReturnValue + ' · 壳 pid ' + $created.ProcessId)
  return $created
}

function Stop-Processes($Processes) {
  $stopped = @()
  foreach ($p in $Processes) {
    try {
      Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
      $stopped += $p.ProcessId
    } catch { }
  }
  return $stopped
}

# ── 窗口读数（"出现但无窗口"这一态的唯一证据） ─────────────────────────────
#
# 与 `tools\restart-agent.ps1` 的 `Get-WindowNote` **同一口径、同一份 C#**（逐字抄的那一处）。
# 为什么用 `[Win32]::` 这个简短别名 + 一行 C#，而不是 `Add-Type -MemberDefinition`：
# 那个开关是 PowerShell 6.0 才有的，而这份脚本要在 **5.1** 上跑（见文件头 ⑤）。
# 整段包在 try 里、并先问一句类型在不在：拿不到窗口数只是"这一次少一条证据"，
# **绝不许**它把重启本身弄挂（窗口读数是附加证据，不是重启的前置条件）。
if (-not ('Win32' -as [type])) {
try {
Add-Type -TypeDefinition ('using System;using System.Runtime.InteropServices;using System.Text;' + 'public static class Win32 {' + 'delegate bool EnumProc(IntPtr h, IntPtr l);' + '[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);' + '[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);' + '[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);' + 'public static string Count(int target) {' + 'int c = 0; int v = 0;' + 'EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid); if (pid == (uint)target) { c++; if (IsWindowVisible(h)) v++; } return true; }, IntPtr.Zero);' + 'return "top-level=" + c + " visible=" + v; }' + '}') -ErrorAction Stop
} catch { }
}
function Get-WindowNote([int]$TargetPid) {
  if ($TargetPid -le 0) { return '' }
  try { if ('Win32' -as [type]) { return ([Win32]::Count($TargetPid)) } } catch { }
  return ''
}

# ══════════ 拉起界面：**Start-Process 形状**（`-PassThru` + `-WorkingDirectory`） ══════════
#
# 分工写清楚：**后端仍走 `Invoke-Detached`（`cmd /s /c`，一字未动）**；界面走这一个。
# 返回的 `$info` 与 `Invoke-Detached` 的调用者需要的字段**同形**（State / StateNote / Ok /
# ExePid / Cmd …），所以两处调用点与 `Write-End` 不用各自再写一套判定。
#
# 与"手工那条每次都成"的形状**一字不差**：`Start-Process -FilePath <exe 绝对路径>
# -WorkingDirectory <exe 所在目录> -PassThru`（默认**不重定向**——重定向目标正是开发机那份
# 2026-10-10 查明的那条根因所在，见文件头；这份不重定向，也就没有那个变量）。
#
# 四态判据（与 `tools\restart-agent.ps1` 逐字同口径，一个都没改名）：
#   ① `not-appeared`          没出现：任何"它跑过"的读数都拿不到；
#   ② `appeared-then-exited`  出现即退：`-PassThru` 的 pid 在手，而它已经不在了；
#   ③ `alive-no-window`       出现但无窗口：pid 活着，窗口 top-level=0 visible=0；
#   ④ `alive`                 出现且有窗口。
# 每一态的证据都比"只有一个 pid"硬：`-PassThru` 的 pid **就是界面自己**（这条形状没有 cmd 壳），
# 建不起来**当场抛异常**（异常原文进留痕），退出码读得到（⇒"出现即退"能带上原因）。
# **不许**改成"拉起前后采样同路径进程"那种判据：它分不清"我拉起的"与"别人拉起的"（见文件头）。
function Invoke-DetachedStartProcess([string]$Exe, [string]$ArgLine, [string]$WorkDir, [string]$LogPath) {
  # `ReturnValue` 恒为 -1：这条形状里**没有** WMI 返回码这个概念（留这一栏只为与 `Invoke-Detached` 同形）。
  $info = @{
    Shape = 'Start-Process'; Cmd = ''; Redirect = 'none'
    ReturnValue = -1; CmdPid = 0; ExePid = 0; Ok = $false; Note = ''
    State = 'not-appeared'; StateNote = ''
    WindowTop = 0; WindowVisible = 0; ExitCode = ''; ElapsedSec = 0
  }
  # 这一份**不允许**给界面重定向（理由见文件头最后那一段：界面一旦把 stdout/stderr 追到
  # `-ScriptLog` 上，cmd 的 `>>` 那一族坑就回来了）。参数留着只为与开发机那份同形，
  # 而"实际有没有重定向"要**写在留痕里**——留痕必须能回答"这次用的是哪条形状"。
  if ($LogPath -ne '') {
    $info.Redirect = '忽略：本份（随包）的界面支**不重定向**（' + $LogPath + '）——界面写进 -ScriptLog 会把"目标被外层持有"那条根因请回来'
  }
  # 工作目录：**exe 所在目录**（Flutter 产物要就地找 DLL 与 `data\`，见文件头 (a)）。
  # 调用方已经算好并传进来；这里再兜一次底（空 = 用 exe 的目录，绝不用 cwd）。
  if ($WorkDir -eq '') { $WorkDir = Resolve-Abs (Split-Path -Parent $Exe) }
  # 命令行原文：这一行要能**照着复现**（出问题时人是照着它手打一遍的）
  $shape = 'Start-Process -FilePath "' + $Exe + '"'
  if ($ArgLine -ne '') { $shape = $shape + ' -ArgumentList ' + $ArgLine }
  $shape = $shape + ' -WorkingDirectory "' + $WorkDir + '" -PassThru'
  $info.Cmd = $shape
  $exeName = [System.IO.Path]::GetFileNameWithoutExtension($Exe)
  Write-Trace ('拉起界面：形状=' + $info.Shape + ' · 工作目录=' + $WorkDir + '（exe 所在目录——Flutter 要就地找 DLL 与 data；工作目录不是它，界面会起来就自己退）· 重定向=' + $info.Redirect)
  $proc = $null
  $createError = ''
  try {
    # splatting：`-ArgumentList` 不是每回都有，拼两条分支不如一张表。`-ErrorAction Stop` 是必须的：
    # 默认它只写一条非终止错误，`$proc` 会是 $null，于是"没建起来"会被当成"建起来了但没读数"。
    $sp = @{ FilePath = $Exe; WorkingDirectory = $WorkDir; PassThru = $true; ErrorAction = 'Stop' }
    if ($ArgLine -ne '') { $sp['ArgumentList'] = @($ArgLine) }
    $proc = Start-Process @sp
  } catch {
    $createError = $_.Exception.GetType().FullName + ' :: ' + $_.Exception.Message
  }
  if ($createError -ne '') {
    Write-Trace ('拉起读数（形状=' + $info.Shape + '）：' + $shape + ' => 抛异常 ' + $createError)
    $info.State = 'not-appeared'
    $info.StateNote = '没出现：Start-Process 抛异常，进程**没有被建起来**（' + $createError + '）'
    $info.Note = 'Start-Process 抛异常：' + $createError
    return $info
  }
  $passPid = 0
  if ($null -ne $proc) { try { $passPid = [int]$proc.Id } catch { $passPid = 0 } }
  Write-Trace ('拉起读数（形状=' + $info.Shape + ' · 重定向=' + $info.Redirect + '）：' + $shape + ' => -PassThru pid ' + $passPid + ' · 工作目录 ' + $WorkDir)
  if ($passPid -le 0) {
    $info.State = 'not-appeared'
    $info.StateNote = '没出现：Start-Process 没有给出 pid（进程没建起来）'
    $info.Note = 'Start-Process 没给出 pid（进程没建起来）'
    Write-Trace ('拉起失败：' + $Exe + ' · Start-Process 没给出 pid · 命令行 ' + $shape)
    return $info
  }
  # `-PassThru` 的 pid **就是界面自己**（这条形状没有 cmd 壳）⇒ 后面所有判据都落在它身上，
  # 一次"同路径进程采样"都不做：**按构造**它就是我拉起的那个，不会认错人。
  $info.CmdPid = $passPid
  $info.ExePid = $passPid
  # **活过观察窗**才叫拉起成功（与开发机那份同名的那条判据同一分寸）：复看两次（3 秒，再 2.5 秒），
  # **连续两次都不在**才算"起来又退"。只复看一次会把"撞上它正在初始化的那一刻"误报成失败。
  # 计时只为把**实测**秒数写进留痕（不是判据）。
  $attemptAt = Get-Date
  $aliveNow = ($null -ne (Get-Process -Id $passPid -ErrorAction SilentlyContinue))
  $exitText = ''
  if (-not $aliveNow) {
    try { if ($proc.HasExited) { $info.ExitCode = [string]$proc.ExitCode; $exitText = '（退出码 ' + $info.ExitCode + '）' } } catch { }
  }
  if (-not $aliveNow) {
    $info.ElapsedSec = [int]((Get-Date) - $attemptAt).TotalSeconds
    # ① 没出现 —— 这条形状下的确切含义是"**任何读数都拿不到**"（既不在跑、也没有退出读数）：
    #    建不起来会抛异常（上面那条分支）、起来就退读得到退出码（下面②），所以这一态只剩这一种可能。
    if ($exitText -eq '') {
      $info.State = 'not-appeared'
      $info.StateNote = '没出现：Start-Process 给的 pid ' + $passPid + ' 既不在跑、也没有退出读数（含"建起来了但比我们看它更快就退"这种可能）'
      $info.Note = 'Start-Process 给出的 pid ' + $passPid + ' 查不到任何读数'
      Write-Trace ('拉起失败：' + $info.Note + ' · 命令行 ' + $shape)
      return $info
    }
    # ② 出现即退：**建起来了**（pid 在手）但它已经不在了，退出码也读得到（旧形状拿不到这个读数）
    $info.State = 'appeared-then-exited'
    $info.StateNote = '出现即退：Start-Process 建起来的 pid ' + $passPid + ' 活不到 ' + $info.ElapsedSec + ' 秒' + $exitText + '（缺依赖 / 缺 data / 参数不认 / 被单实例判据挡回，都是这一态）'
    $info.Note = '拉起的 ' + $exeName + ' pid ' + $passPid + ' 活不到 ' + $info.ElapsedSec + ' 秒' + $exitText
    Write-Trace ('拉起失败：' + $info.Note + ' · 命令行 ' + $shape)
    return $info
  }
  for ($i = 0; $i -lt 2; $i++) {
    Start-Sleep -Seconds 3
    if ($null -ne (Get-Process -Id $passPid -ErrorAction SilentlyContinue)) { break }
    if ($i -eq 0) { Start-Sleep -Milliseconds 2500 }
    if ($null -ne (Get-Process -Id $passPid -ErrorAction SilentlyContinue)) { break }
    $exitText2 = ''
    try { if ($proc.HasExited) { $info.ExitCode = [string]$proc.ExitCode; $exitText2 = '（退出码 ' + $info.ExitCode + '）' } } catch { }
    $info.State = 'appeared-then-exited'
    $info.StateNote = '出现即退：Start-Process 建起来的 pid ' + $passPid + ' 在 3 秒复看时已经不在' + $exitText2
    $info.Note = '拉起的 ' + $exeName + ' pid ' + $passPid + ' 在 3 秒内就退出了（缺依赖 / 参数不认 / 自己崩了）'
    Write-Trace ('拉起失败：' + $info.Note + ' · 命令行 ' + $shape)
    return $info
  }
  # 窗口读数（"出现但无窗口"这一态的唯一证据）。趁它还活着读——死了就没有窗口可言了。
  $winNote = Get-WindowNote $passPid
  $winTop = 0
  $winVisible = 0
  if ($winNote -match 'top-level=(\d+) visible=(\d+)') { $winTop = [int]$Matches[1]; $winVisible = [int]$Matches[2] }
  $info.WindowTop = $winTop
  $info.WindowVisible = $winVisible
  $info.Ok = $true
  if ($winNote -ne '') { Write-Trace ('窗口读数：pid ' + $passPid + ' ' + $winNote) }
  if ($winNote -ne '' -and $winVisible -eq 0) {
    # ③ 出现但无窗口：进程活着、但没有可见的顶层窗口（对人来说等于"看不见"）。如实标出来，但**不**判失败
    #    （判失败会误报：后端那一支本来就没有窗口；界面这一支"活着"也确实算拉起来了，只是要说清）。
    $info.State = 'alive-no-window'
    $info.StateNote = '出现但无窗口：pid ' + $passPid + ' 活着，窗口 ' + $winNote
  } else {
    # ④ 出现且有窗口。`$winNote` 为空（读不到窗口数）时也落这一态：那只说明**这一次少一条证据**，
    #    而"进程活着且活过复看"这两件直接观测到的事实仍然成立——措辞只说看得到的，不替人下结论。
    $info.State = 'alive'
    if ($winNote -ne '') { $info.StateNote = '出现且有窗口：pid ' + $passPid + ' 活着，窗口 ' + $winNote }
  }
  $info.Note = 'Start-Process pid ' + $passPid + '（复看两次都还在跑）'
  Write-Trace ('拉起成功（形状=' + $info.Shape + ' · 重定向=' + $info.Redirect + '）：' + $info.Note + ' · 命令行 ' + $shape)
  return $info
}

# ── 停界面（按 exe 全路径匹配：不能因为"名字一样"就去杀另一个安装的界面） ──────
function Get-GuiProcesses([string]$GuiPath) {
  if ($GuiPath -eq '') { return @() }
  $full = ''
  try { $full = [System.IO.Path]::GetFullPath($GuiPath) } catch { return @() }
  $name = [System.IO.Path]::GetFileName($full)
  $found = @()
  foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = '$name'" -ErrorAction SilentlyContinue)) {
    $path = $p.ExecutablePath
    if (-not $path) { continue }
    try { if ([System.IO.Path]::GetFullPath($path) -ieq $full) { $found += $p } } catch { }
  }
  return $found
}

# ════════════════════════════════ 正文 ════════════════════════════════

# 第一行就是**回执行**：服务端起完进程就回读它（读得到 = 这份随包脚本真的跑起来了）。
Write-Trace ('[回执] 路径=' + $PATH_LABEL + ' · 随包脚本已启动 · Repo=' + $Repo + ' · NodeEntry=' + $NodeEntryAbs + ' · NodeExe=' + $NodeExe + ' · Port=' + $Port + ' · GuiExe=' + $GuiExe + ' · GuiOnly=' + [string]$GuiOnly + ' · DryRun=' + [string]$DryRun)
Write-Trace ('参数原文：Repo=' + $Repo + ' NodeEntry=' + $NodeEntryAbs + ' TraceLog=' + $TraceLog + ' ScriptLog=' + $ScriptLog + ' OutLog=' + $OutLogAbs + ' DelaySeconds=' + $DelaySeconds + ' WaitSeconds=' + $WaitSeconds + ' PortWaitSeconds=' + $PortWaitSeconds + ' NodeMaxOldSpaceMb=' + $NodeMaxOldSpaceMb)

$guiGiven = $GuiExe -ne ''
$guiExists = $false
if ($guiGiven) { $guiExists = Test-Path -LiteralPath $GuiExe }
$guiPath = ''
if ($guiGiven -and $guiExists) { try { $guiPath = [System.IO.Path]::GetFullPath($GuiExe) } catch { $guiPath = $GuiExe } }

# 空跑：把"会怎么走"逐条写出来（用的就是真跑那套判据，不是另写一份）
if ($DryRun) {
  $dryTargets = @()
  if (-not $GuiOnly) { $dryTargets = @(Get-AgentProcesses) }
  Write-Trace ('空跑：判据 = 命令行含 ' + $matchNeedle + '（分隔符无关）此刻命中 ' + $dryTargets.Count + ' 个 node.exe')
  if ($dryTargets.Count -gt 0) { Write-Trace ('空跑：真跑时会停 pid=[' + (($dryTargets | ForEach-Object { $_.ProcessId }) -join ',') + ']') }
  Write-Trace ('空跑：界面 GuiExe 收到=' + [string]$guiGiven + ' 盘上存在=' + [string]$guiExists + '；端口探测目标 ' + $ProbeHost + ':' + $Port)
  Write-Trace ('空跑：不延迟、不停任何进程、不拉起任何东西；此刻端口有人听=' + [string](Test-PortListening $ProbeHost $PortNum))
  Write-End 'False' '0' 'unknown' 0 'dry-run' '空跑：什么都没做（这不是失败，是 -DryRun 的定义）'
  exit 0
}

# 延迟：让这次请求的 HTTP 回执先回到界面（否则人看到的是"点了没反馈"）
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

$oldPid = Get-LockPid
$guiPid = 0
$portState = 'unknown'
$backendPid = 0
# 界面那一支的**四态读数**：只有"真去拉了界面"才会被填上（空 ⇒ `Write-End` 不说这一档）。
# 取值域与 `tools\restart-agent.ps1` 一致：not-appeared / appeared-then-exited / alive-no-window / alive。
$guiLaunchState = ''
$guiLaunchNote = ''

try {
  # ── ① 先停界面：旧后端要死了，界面留着只会对着一个断掉的连接狂重连 ──
  $guiStopped = 0
  if ($guiGiven) {
    if (-not $guiExists) {
      # 与仓库脚本同一条纪律：路径不存在时**不动界面**，并在结尾如实说出来
      Write-Trace ('界面：-GuiExe=' + $GuiExe + ' 在盘上不存在 ⇒ 本次不动界面')
    } else {
      $guiProcs = @(Get-GuiProcesses $guiPath)
      $guiStopped = @(Stop-Processes $guiProcs).Count
      Write-Trace ('界面：停了 ' + $guiStopped + ' 个进程（' + $guiPath + '）')
    }
  }

  # ── ② 停旧后端：按安装根 + 入口匹配（**不碰 SnowLuma**） ──
  $targets = @()
  if (-not $GuiOnly) {
    $targets = @(Get-AgentProcesses)
    Write-Trace ('判据命中 ' + $targets.Count + ' 个主进程（命令行含 ' + $matchNeedle + '；SnowLuma 一律不匹配）')
    $stoppedPids = @(Stop-Processes $targets)
    Write-Trace ('已停主进程 pid=[' + ($stoppedPids -join ',') + ']')
    # 等它们**真的消失**再拉新的：不等就会撞锁 / 抢端口（新实例会以 LockHeldError 或
    # EADDRINUSE 退出，而症状又是"点了重启没反应"）
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
      $alive = @($targets | Where-Object { $null -ne (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue) })
      if ($alive.Count -eq 0) { break }
      Start-Sleep -Milliseconds 300
    }
    $stillAlive = @($targets | Where-Object { $null -ne (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue) })
    if ($stillAlive.Count -gt 0) {
      $aliveText = ($stillAlive | ForEach-Object { $_.ProcessId }) -join ','
      Write-End 'False' ([string](Get-LockPid)) 'unknown' 0 $REASON_OLD_NOT_GONE ('旧实例 pid=[' + $aliveText + '] 在 ' + $WaitSeconds + ' 秒里没有退出；没有拉起新实例——撞锁/抢端口只会让两个实例互相打架')
      exit 1
    }
  } elseif ($guiGiven -and $guiExists) {
    # 只重启界面：一个后端进程都不动，端口那一档由现役后端回答
    #
    # 这是界面被拉起的**两处之一**（另一处是第 ⑤ 步）。两处都走同一处判定
    # （`Invoke-DetachedStartProcess`：`-WorkingDirectory <exe 所在目录>` + `-PassThru` + 四态），
    # 免得"同一件事写两处、迟早坏一半"（开发机那份 2026-10-08 的界面误杀事故就是这个形状）。
    $guiDir = Resolve-Abs (Split-Path -Parent $guiPath)
    $guiLaunch = Invoke-DetachedStartProcess $guiPath '' $guiDir ''
    $guiLaunchState = $guiLaunch.State
    $guiLaunchNote = $guiLaunch.StateNote
    $up = 0
    if ($guiLaunch.Ok) { $up = $guiLaunch.ExePid }
    $guiPid = $up
    $portState = 'timeout'
    if (Test-PortListening $ProbeHost $PortNum) { $portState = 'ready' }
    $reason = $REASON_GUI_FAILED
    if ($up -gt 0) {
      $reason = $REASON_OK
      # "活着但没有可见窗口"也算拉起来了（进程真的在跑），但界面这一支的用途就是给人看：
      # 那就**必须**在留痕里说出来——否则人看到的还是一句"起来了"（与开发机那份同一分寸）。
      if ($guiLaunchState -eq 'alive-no-window') { Write-Trace ('界面读数（alive-no-window）：' + $guiLaunchNote) }
    }
    Write-End ([string]($up -gt 0)) ([string](Get-LockPid)) $portState $guiPid $reason '只重启了界面（-GuiOnly：一个后端进程都没动）' $guiLaunchState $guiLaunchNote
    if ($up -gt 0) { exit 0 }
    exit 1
  }

  # ── ③ 拉起新的自己：入口与 cwd 都是绝对路径，stdout/stderr 落它自己的日志 ──
  if (-not (Test-Path -LiteralPath $NodeEntryAbs)) {
    Write-End 'False' '0' 'unknown' 0 $REASON_SPAWN_FAILED ('没有这个入口：' + $NodeEntryAbs)
    exit 1
  }
  # 每个参数各自加引号（路径带空格时也必须是一个参数）
  #
  # Node 的选项**必须排在入口之前**（`node <opts> <entry>`），所以上限拼在入口前面；
  # 为空时不留多余空格（`Invoke-Detached` 把整串塞进 `cmd /s /c`，多一个空格就多一处拼错的机会）。
  $entryArg = '"' + $NodeEntryAbs + '"'
  if ($NodeMaxOldSpaceArg -ne '') { $entryArg = $NodeMaxOldSpaceArg + ' ' + $entryArg }
  $created = Invoke-Detached $NodeExe $entryArg $Repo $OutLogAbs
  if ($null -eq $created) {
    Write-End 'False' '0' 'unknown' 0 $REASON_SPAWN_FAILED ('拉起失败：WMI 那一层没把进程建起来（命令行见留痕）')
    exit 1
  }

  # ── ④ 两条硬凭据：**她换了个人**（lock.json 的新 pid）+ **端口能应答** ──
  $newPid = 0
  $portReady = $false
  $deadline = (Get-Date).AddSeconds($PortWaitSeconds)
  while ((Get-Date) -lt $deadline) {
    $lockPid = Get-LockPid
    if ($lockPid -gt 0 -and $lockPid -ne $oldPid) { $newPid = $lockPid }
    $portReady = Test-PortListening $ProbeHost $PortNum
    if ($portReady -and $newPid -gt 0) { break }
    Start-Sleep -Milliseconds 500
  }
  if ($portReady) { $portState = 'ready' } else { $portState = 'timeout' }
  $backendPid = $newPid

  if ($newPid -le 0) {
    Write-End 'False' ([string](Get-LockPid)) $portState 0 $REASON_LOCK_NOT_CHANGED ('端口那一档=' + $portState + '，而 lock.json 里的 pid 还是旧的（=' + $oldPid + '）——"换了个人"这条凭据不成立')
    exit 1
  }
  if (-not $portReady) {
    Write-End 'False' ([string]$newPid) $portState 0 $REASON_PORT_NOT_READY ('新的 pid=' + $newPid + ' 已经写进 lock.json，但端口 ' + $ProbeHost + ':' + $Port + ' 在 ' + $PortWaitSeconds + ' 秒里没有应答')
    exit 1
  }
  Write-Trace ('[实例] 后端已接管 pid=' + $newPid + ' source=lock.json path=' + $PATH_LABEL)

  # ── ⑤ 界面：端口能应答之后再拉起来 ──
  $guiNote = '本次只重启了后端（没有收到 -GuiExe：界面不在本次动作范围内，它只是重连回来）'
  if ($guiGiven) {
    if (-not $guiExists) {
      $guiNote = '本次只重启了后端（-GuiExe 指向的 ' + $GuiExe + ' 在盘上不存在，界面一个进程都没动）'
    } else {
      # **工作目录 = exe 所在目录**，显式算好再传（见文件头 (a)：Flutter 的产物要就地找 DLL 与 `data\`；
      # 工作目录给成安装根，界面会起来就自己退，而"拉起"这一层照样报成功）。
      $guiDir = Resolve-Abs (Split-Path -Parent $guiPath)
      $guiLaunch = Invoke-DetachedStartProcess $guiPath '' $guiDir ''
      $guiLaunchState = $guiLaunch.State
      $guiLaunchNote = $guiLaunch.StateNote
      if ($guiLaunch.Ok) { $guiPid = $guiLaunch.ExePid }
      if ($guiPid -gt 0) {
        $guiNote = '界面也重启了（pid=' + $guiPid + '）'
        # "活着但没有可见窗口"：拉起来了，但人看不见——必须在留痕里点出来（与开发机那份同一分寸）
        if ($guiLaunchState -eq 'alive-no-window') { Write-Trace ('界面读数（alive-no-window）：' + $guiLaunchNote) }
      } else {
        Write-End 'False' ([string]$newPid) $portState 0 $REASON_GUI_FAILED ('后端已就绪（pid=' + $newPid + '），但界面没拉起来（' + $guiLaunchState + '）：' + $guiPath) $guiLaunchState $guiLaunchNote
        exit 1
      }
    }
  }

  Write-End 'True' ([string]$newPid) $portState $guiPid $REASON_OK ('新实例 pid=' + $newPid + '；' + $guiNote) $guiLaunchState $guiLaunchNote
  exit 0
} catch {
  # 中途任何异常都要留下 `[结束] ok=False` 与原因：服务端绝不该"等不到结尾"就只能猜
  Write-End 'False' ([string]$backendPid) $portState 0 'exception' ('脚本中途抛异常：' + $_.Exception.Message)
  exit 1
}
