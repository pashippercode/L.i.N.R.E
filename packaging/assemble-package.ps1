<#
  Irmia Agent / LiNRE —— Windows x64 便携包装配器
  ============================================================================

  它把仓库里的**已构建产物**装配成可以直接发给别人解压就用的一个目录 + 一个 zip：

      dist\             ← tsc 的编译产物（要发出去的东西，注释已由 tsconfig 的 removeComments 剥掉）
      gui\              ← flutter build windows --release 的 Release 目录整份
      runtime\node\     ← 自带的 node.exe（对方机器上有没有 node 都不影响）
      skills\           ← 框架自带的技能
      START.cmd         ← 双击入口（ASCII，控制台码页无关）
      start.ps1         ← 启动链（起后端、等端口、开界面、收尾）
      restart.ps1       ← 随包重启脚本（`src/runtime/restart-chain.ts` 的 `packaged-script` 那一条）
      gui-keepalive.ps1 ← 界面保活
      README-BETA.md    ← 内测包说明
      VERSION.txt       ← 这份包是什么、怎么装出来的（版号/运行时/打包时间/打包机）
      package.json      ← 包自己的清单（不是仓库那份：name/version 已按包装时改写）
      config.example.json
      LICENSE

  ## 为什么要这个脚本存在

  出包这件事**唯一允许的失败方式是当场失败**：装配漏一个文件，坏的是别人机器上那份安装。
  历史事故就摆在那里（`src/runtime/restart-chain.ts` 文件头）：beta.5 的内测包里没有 `tools\`、
  没有 `restart.ps1`，于是"装在别人机器上的那份重启必然失败"，而开发机上看不出来。
  所以这里的设计原则是**清单化 + 装完自检**：

    · `$PayloadFiles` 是包根脚本的**唯一清单**（不要在两处各写一份）；
    · 装配完逐个 Test-Path，缺一个就红着脸退出，绝不产出一个"看起来成功"的 zip；
    · 版号占位符 `@@VERSION@@` 必须全部被替换掉——漏一个，包里就留一行假版号。

  ## 谁调用它

    · GitHub Actions（`.github/workflows/windows-package.yml`），在 `windows-latest` 上跑：
      那台机器有 MSVC，`flutter build windows --release` 才编得出来（这是本机缺的那一环）；
    · 本机想验证装配逻辑（不需要 MSVC）：拿现成的 `dist\` + 一个假的 gui 目录即可，
      见 README 的「本机干跑装配」。

  ## 版号的单一来源

  `src/version.ts` 的 `AGENT_VERSION`。传 `-Version` 可以覆盖（CI 手工触发出一个特定版号时用），
  但**不会**回写仓库里的任何源文件：装配器只读源码、只写 `out\`。
#>
[CmdletBinding()]
param(
  # 产物版号。留空 ⇒ 读 src/version.ts 的 AGENT_VERSION（带 `-beta.N` 这种预发布标记）
  [string]$Version = '',

  # 仓库根。留空 ⇒ 本脚本所在目录的上一级
  [string]$RepoRoot = '',

  # 输出根目录。留空 ⇒ <repo>/out。里面会有装配目录 `_stage\` 与最终的 zip
  [string]$OutDir = '',

  # 含 node.exe 的目录（CI 是把 node-vX-win-x64.zip 解压到某处再传进来）
  [string]$NodeDir = '',

  # 或者直接给 node.exe 的路径（两者给一个即可；都给时以 -NodeExe 为准）
  [string]$NodeExe = '',

  # flutter 的 Release 产物目录。留空 ⇒ <repo>/gui/build/windows/x64/runner/Release
  [string]$GuiReleaseDir = '',

  # tsc 产物目录。留空 ⇒ <repo>/dist
  [string]$DistDir = '',

  # VC++ 运行库目录（`…\VC\Redist\MSVC\<ver>\x64\Microsoft.VC143.CRT`）。
  # 留空 ⇒ 用 vswhere 自动找；找不到就给黄色警告。
  # **为什么必须有它**：Flutter 的 windows install 规则只装 exe / flutter_windows.dll /
  # 插件 dll / data\，**不拷 CRT**；机器上没装 VC++ 2015-2022 运行库的人双击就是"没反应"。
  [string]$CrtDir = '',

  # latest.json 里那个 portable 产物的下载地址（CI 在打 tag 时传 GitHub Release 的资产地址）。
  # 给了才写 latest.json——站点发布管线要的就是这一份，没给就不凭空造一个地址。
  [string]$ManifestAssetUrl = '',

  # latest.json 的 notesUrl（发布说明页）。留空 ⇒ 不写这一格
  [string]$NotesUrl = '',

  # 更新通道。留空 ⇒ 版号带预发布标记就是 beta，否则 stable
  [string]$Channel = '',

  # 只装配、不打 zip（调试装配内容时用）
  [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'

# ────────────────────────────────────────────────────────────────────────────
# 包根脚本清单（**唯一一处**）
#
# restart-chain.ts 的注释里点名的就是这个变量名，改这里就够，别在别处再列一遍。
# 每一项都是 `packaging\` 里的模板，装配时做 `@@VERSION@@` 替换后落到包根。
# ────────────────────────────────────────────────────────────────────────────
$PayloadFiles = @(
  'START.cmd'
  'start.ps1'
  'restart.ps1'
  'gui-keepalive.ps1'
  'README-BETA.md'
)

# 包根**必须**存在的文件（装配完逐个检查；少一个就失败）
# 注意这是"装完之后的样子"，不是模板清单：`VERSION.txt` / `package.json` 是现生成的。
$RequiredInPackage = @(
  'runtime\node\node.exe'
  'dist\main.js'
  'dist\cli.js'
  'gui\irmia_gui.exe'
  # 界面侧的三个"少了就打不开"的东西：渲染库、ICU 数据、Flutter 资产目录。
  # 只断言 exe 是拦不住这类缺件的——exe 在、双击照样没反应。
  'gui\flutter_windows.dll'
  'gui\data\icudtl.dat'
  'config.example.json'
  'package.json'
  'VERSION.txt'
  'LICENSE'
) + $PayloadFiles

function Say([string]$Message) {
  Write-Host "[装配] $Message"
}

function Fail([string]$Message) {
  Write-Host ''
  Write-Host "[装配失败] $Message" -ForegroundColor Red
  Write-Host ''
  exit 1
}

function Resolve-FullPath([string]$Path) {
  return (Resolve-Path -LiteralPath $Path).ProviderPath
}

# 带 BOM 的文本按原样读、按原样写：包根脚本里有 `start.ps1`（带 BOM）与
# `START.cmd`（绝对不能带 BOM——cmd 会把 BOM 当命令的一部分）两种，一律照抄源文件的形态。
function Read-TextPreservingBom([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $offset = 0
  if ($hasBom) { $offset = 3 }
  $text = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
  return @{ Text = $text; HasBom = $hasBom }
}

function Write-TextPreservingBom([string]$Path, [string]$Text, [bool]$HasBom) {
  $encoding = New-Object System.Text.UTF8Encoding($HasBom)
  [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

# 找 VC++ 运行库目录（`…\x64\Microsoft.VC143.CRT`）。
# 走 vswhere 而不是猜路径：VS 装在哪、MSVC 是 14.3x 还是 14.4x 都可能变，
# 猜错的表现是"包能出、但在别人机器上打不开"——那正是这里要防的。
function Find-CrtDir {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return '' }
  $installs = @(& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null)
  foreach ($install in $installs) {
    if ([string]::IsNullOrWhiteSpace($install)) { continue }
    $redistRoot = Join-Path $install.Trim() 'VC\Redist\MSVC'
    if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) { continue }
    # 多个 MSVC 版本并存时取版本号最大的那个（字符串倒序对 14.x 够用）
    foreach ($versionDir in (@(Get-ChildItem -LiteralPath $redistRoot -Directory | Sort-Object Name -Descending))) {
      $crt = Join-Path $versionDir.FullName 'x64\Microsoft.VC143.CRT'
      if (Test-Path -LiteralPath $crt -PathType Container) { return $crt }
    }
  }
  return ''
}

# ── 0. 路径与版号 ───────────────────────────────────────────────────────────

$here = $PSScriptRoot
if ([string]::IsNullOrEmpty($here)) { Fail '拿不到脚本所在目录（$PSScriptRoot 为空）：请用 -File 方式调用本脚本。' }

if ([string]::IsNullOrEmpty($RepoRoot)) { $RepoRoot = Join-Path $here '..' }
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Fail "仓库根不存在：$RepoRoot" }
$RepoRoot = Resolve-FullPath $RepoRoot

if ([string]::IsNullOrEmpty($DistDir)) { $DistDir = Join-Path $RepoRoot 'dist' }
if (-not (Test-Path -LiteralPath $DistDir -PathType Container)) {
  Fail "找不到编译产物目录：$DistDir`n先跑一次 npm run build（CI 里是它前一步）。"
}
$DistDir = Resolve-FullPath $DistDir

if (-not (Test-Path -LiteralPath (Join-Path $DistDir 'main.js') -PathType Leaf)) {
  Fail "$DistDir 里没有 main.js：这个 dist 不是后端产物，或者编译没跑完。"
}

if ([string]::IsNullOrEmpty($GuiReleaseDir)) { $GuiReleaseDir = Join-Path $RepoRoot 'gui\build\windows\x64\runner\Release' }
if (-not (Test-Path -LiteralPath $GuiReleaseDir -PathType Container)) {
  Fail @"
找不到界面产物目录：$GuiReleaseDir

这一格要的是 `flutter build windows --release` 的输出：
    cd gui
    flutter build windows --release
它需要 MSVC（本机没有就交给 GitHub Actions 的 windows-latest，见 .github/workflows/windows-package.yml）。
"@
}
$GuiReleaseDir = Resolve-FullPath $GuiReleaseDir
if (-not (Test-Path -LiteralPath (Join-Path $GuiReleaseDir 'irmia_gui.exe') -PathType Leaf)) {
  Fail "$GuiReleaseDir 里没有 irmia_gui.exe：这不是一个 flutter windows release 产物目录。"
}

# node.exe：-NodeExe 优先，其次 -NodeDir\node.exe
if (-not [string]::IsNullOrEmpty($NodeExe)) {
  if (-not (Test-Path -LiteralPath $NodeExe -PathType Leaf)) { Fail "node.exe 不存在：$NodeExe" }
} elseif (-not [string]::IsNullOrEmpty($NodeDir)) {
  $NodeExe = Join-Path $NodeDir 'node.exe'
  if (-not (Test-Path -LiteralPath $NodeExe -PathType Leaf)) { Fail "$NodeDir 里没有 node.exe（这是 node-vX-win-x64.zip 解压出来的那个目录吗？）" }
} else {
  Fail @'
没给自带运行时。

包里的 `runtime\node\node.exe` 是这份便携包的硬要求（`start.ps1` 就按它起后端，
不依赖对方机器上装没装 node）。两条路：

  · CI：先用 actions/setup-node 之外的方式落一份官方压缩包，
        再 `-NodeDir <解压目录>`（windows-package.yml 就是这么干的）；
  · 本机干跑：`-NodeDir (Split-Path (Get-Command node).Source)`。
'@
}
$NodeExe = Resolve-FullPath $NodeExe

# 版号：留空就读源码里的唯一真相源
if ([string]::IsNullOrEmpty($Version)) {
  $versionFile = Join-Path $RepoRoot 'src\version.ts'
  if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    Fail "找不到 $versionFile：版号没处读，要么修好它，要么显式传 -Version。"
  }
  $versionText = (Read-TextPreservingBom $versionFile).Text
  $match = [regex]::Match($versionText, "AGENT_VERSION\s*=\s*'([0-9A-Za-z.\-+]+)'")
  if (-not $match.Success) { Fail "$versionFile 里没找到 AGENT_VERSION = '…' 这一行。" }
  $Version = $match.Groups[1].Value
}

if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') {
  Fail "版号形状不对：'$Version'（要 x.y.z 或 x.y.z-预发布；它会进目录名与 zip 名，所以不许有空格/中文/斜杠）"
}

if ([string]::IsNullOrEmpty($Channel)) {
  if ($Version -match '-') {
    $Channel = 'beta'
  } else {
    $Channel = 'stable'
    # 这条警告不是客套：出厂配置的 update.channel 是 beta，客户端按"清单通道必须等于
    # 请求通道"判 channel-mismatch（src/update/check.ts）⇒ 稳定版清单发出去，
    # 所有装在默认配置上的旧客户端都读不到它。要发稳定线，先确认站点与客户端都切过去。
    Write-Host '[装配] 注意：版号没有预发布标记 ⇒ latest.json 的 channel 写的是 stable；' -ForegroundColor Yellow
    Write-Host '        默认配置（update.channel=beta）的已装客户端会把它判成 channel-mismatch 而看不到。' -ForegroundColor Yellow
  }
}

# `v` 前缀只用在"给人看"的地方（目录名/文件名），版号本体进 manifest 时不带 v
$displayVersion = "v$Version"
$packageName = "irmia-agent-$displayVersion-win-x64"

if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $RepoRoot 'out' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = Resolve-FullPath $OutDir

$stageRoot = Join-Path $OutDir '_stage'
$packageDir = Join-Path $stageRoot $packageName

Say "版号      ：$Version（通道 $Channel）"
Say "仓库根    ：$RepoRoot"
Say "后端产物  ：$DistDir"
Say "界面产物  ：$GuiReleaseDir"
Say "自带运行时：$NodeExe"
Say "输出      ：$OutDir"

# ── 1. 干净重来 ─────────────────────────────────────────────────────────────
# 装配目录整个删掉重建：上一次的残留文件混进这一次的包，是那种"本机看着没问题、
# 别人机器上多一个旧文件"的错误，而且只在很久以后才发作。
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

# ── 2. 后端产物 dist\ ───────────────────────────────────────────────────────
Say '复制 dist\ …'
# 先建目标目录再拷内容：`Copy-Item 源\* -Destination 不存在的目录` 会把第一个子项
# 当文件名（Container cannot be copied onto existing leaf item），是这条命令的老坑。
New-Item -ItemType Directory -Force -Path (Join-Path $packageDir 'dist') | Out-Null
Copy-Item -Path (Join-Path $DistDir '*') -Destination (Join-Path $packageDir 'dist') -Recurse -Force
$distFiles = @(Get-ChildItem -LiteralPath (Join-Path $packageDir 'dist') -Recurse -File)
$distJs = @($distFiles | Where-Object { $_.Extension -eq '.js' })
Say "  $($distFiles.Count) 个文件（其中 $($distJs.Count) 个 .js）"

# ── 3. 界面产物 gui\ ────────────────────────────────────────────────────────
# 整份 Release 目录照搬：flutter_windows.dll、插件 dll、msvcp140/vcruntime140* 都在里面，
# 少一个界面就起不来（而缺 dll 的表现是"双击没反应"，最难排查的那种）。
Say '复制 gui\ …'
New-Item -ItemType Directory -Force -Path (Join-Path $packageDir 'gui') | Out-Null
Copy-Item -Path (Join-Path $GuiReleaseDir '*') -Destination (Join-Path $packageDir 'gui') -Recurse -Force

# ── 3b. VC++ 运行库（Flutter 不拷，我们补） ─────────────────────────────────
# 这一段治的是"双击没反应"里最常见的一类：`irmia_gui.exe` 依赖 msvcp140 / vcruntime140*，
# 而 flutter 的 install 规则一条 CRT 都不装。装过 VC++ 2015-2022 运行库的机器看不出问题，
# 干净的测试机 / 重装过的系统就会静默起不来（连错误框都不一定弹）。
if ([string]::IsNullOrEmpty($CrtDir)) { $CrtDir = Find-CrtDir }
if (-not [string]::IsNullOrEmpty($CrtDir)) {
  if (-not (Test-Path -LiteralPath $CrtDir -PathType Container)) { Fail "VC++ 运行库目录不存在：$CrtDir" }
  $crtFiles = @(Get-ChildItem -LiteralPath $CrtDir -File -Filter '*.dll')
  if ($crtFiles.Count -eq 0) { Fail "VC++ 运行库目录里没有 dll：$CrtDir" }
  Say "复制 VC++ 运行库（$($crtFiles.Count) 个 dll）…"
  foreach ($dll in $crtFiles) {
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $packageDir 'gui') -Force
    Say "  $($dll.Name)"
  }
} else {
  Write-Host '[装配] 警告：找不到 VC++ 运行库目录（vswhere 没报出带 C++ 工作负载的 VS）。' -ForegroundColor Yellow
  Write-Host '        这份包在"没装过 VC++ 2015-2022 运行库"的机器上，界面可能双击没反应。' -ForegroundColor Yellow
  Write-Host '        修法：装 VS 生成工具时勾上 C++ 工作负载，或用 -CrtDir <…\x64\Microsoft.VC143.CRT> 显式指定。' -ForegroundColor Yellow
}

# ── 4. 自带运行时 runtime\node\ ─────────────────────────────────────────────
Say '复制 runtime\node\ …'
$runtimeNodeDir = Join-Path $packageDir 'runtime\node'
New-Item -ItemType Directory -Force -Path $runtimeNodeDir | Out-Null
Copy-Item -LiteralPath $NodeExe -Destination (Join-Path $runtimeNodeDir 'node.exe') -Force
# 官方包里的 LICENSE 一起带上（Node 是 MIT，分发要带许可文本）
$nodeLicense = Join-Path (Split-Path -Parent $NodeExe) 'LICENSE'
if (Test-Path -LiteralPath $nodeLicense -PathType Leaf) {
  Copy-Item -LiteralPath $nodeLicense -Destination (Join-Path $runtimeNodeDir 'LICENSE') -Force
} else {
  Write-Host '[装配] 注意：node.exe 旁边没有 LICENSE（自带的运行时许可文本缺失，建议补上）' -ForegroundColor Yellow
}

# ── 5. 包根脚本（模板 + 版号替换） ──────────────────────────────────────────
Say '复制包根脚本（替换 @@VERSION@@）…'
foreach ($name in $PayloadFiles) {
  $template = Join-Path $here $name
  if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { Fail "模板缺失：$template" }
  $source = Read-TextPreservingBom $template
  if ($source.Text.Contains('@@VERSION@@')) {
    $source.Text = $source.Text.Replace('@@VERSION@@', $Version)
  }
  Write-TextPreservingBom (Join-Path $packageDir $name) $source.Text $source.HasBom
  Say "  $name"
}

# ── 6. skills\ ──────────────────────────────────────────────────────────────
$skillsSrc = Join-Path $RepoRoot 'skills'
if (Test-Path -LiteralPath $skillsSrc -PathType Container) {
  Say '复制 skills\ …'
  New-Item -ItemType Directory -Force -Path (Join-Path $packageDir 'skills') | Out-Null
  Copy-Item -Path (Join-Path $skillsSrc '*') -Destination (Join-Path $packageDir 'skills') -Recurse -Force
} else {
  Write-Host '[装配] 注意：仓库里没有 skills\，这份包不带技能。' -ForegroundColor Yellow
}

# ── 7. 配置与许可 ───────────────────────────────────────────────────────────
# 只发 `config.example.json`：真正的 config.json 里有 owner 名、联系人表与本机路径，
# 那是**装机之后**才该出现的东西（start.ps1 首启会从示例复制一份）。
$cfgExample = Join-Path $RepoRoot 'config.example.json'
if (-not (Test-Path -LiteralPath $cfgExample -PathType Leaf)) { Fail "缺少 config.example.json：$cfgExample" }
Copy-Item -LiteralPath $cfgExample -Destination (Join-Path $packageDir 'config.example.json') -Force

$licenseSrc = Join-Path $RepoRoot 'LICENSE'
if (Test-Path -LiteralPath $licenseSrc -PathType Leaf) {
  Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $packageDir 'LICENSE') -Force
} else {
  Write-Host '[装配] 注意：仓库根没有 LICENSE，包里也就没有。' -ForegroundColor Yellow
}

# ── 8. package.json（包自己的清单，不是仓库那份） ───────────────────────────
# 包根的 package.json 只做两件事：让人一眼看到"这是 Irmia Agent 的哪一版"，
# 以及让 `node dist/main.js` 在包内仍然成立（"type": "module" 必须留着，否则 .js 会被当 CJS）。
$repoPkgPath = Join-Path $RepoRoot 'package.json'
$repoPkg = $null
if (Test-Path -LiteralPath $repoPkgPath -PathType Leaf) {
  $repoPkg = (Read-TextPreservingBom $repoPkgPath).Text | ConvertFrom-Json
}
$pkg = [ordered]@{
  name = 'irmia-agent'
  version = $Version
  description = '本地持久化无人值守 Agent — 事件日志唯一真相源，崩溃可恢复，有人格，极小资源，只有桌面 GUI'
  type = 'module'
  private = $true
  engines = [ordered]@{ node = '>=22' }
  scripts = [ordered]@{
    build = 'tsc -p tsconfig.json'
    start = 'node dist/main.js'
    cli = 'node dist/cli.js'
  }
}
# 仓库那份的 devDependencies 照抄（包里不含 node_modules，留着它只是让包内 npm 语义说得通）
if ($repoPkg -and $repoPkg.devDependencies) { $pkg.devDependencies = $repoPkg.devDependencies }
$pkgJsonPath = Join-Path $packageDir 'package.json'
Write-TextPreservingBom $pkgJsonPath ($pkg | ConvertTo-Json -Depth 6) $false

# ── 9. VERSION.txt ──────────────────────────────────────────────────────────
# 它的价值全在"事后":用户报"我装的那份重启不了"时，这几行能立刻说清
# 这是哪一版、自带哪个 node、哪台机器什么时候装出来的。
$nodeVersionText = ''
try { $nodeVersionText = (& $NodeExe -v 2>$null | Select-Object -First 1) } catch { $nodeVersionText = '' }
if ([string]::IsNullOrEmpty($nodeVersionText)) { $nodeVersionText = '（读不到 node.exe 版本）' }

$builder = '本地装配'
if (-not [string]::IsNullOrEmpty($env:GITHUB_ACTIONS)) {
  # 只留 run id：包是要发出去的文本，机器名（COMPUTERNAME / RUNNER_NAME）没有排障价值却有暴露价值
  $builder = "GitHub Actions · run $env:GITHUB_RUN_ID"
}

$versionLines = @(
  "Irmia Agent $Version （Windows x64 便携包）"
  ''
  '版本口径：'
  "  产品版号（界面/日志）：$displayVersion"
  "  package.json version        ：$Version"
  "  自带的 node 运行时          ：$nodeVersionText（runtime\node\node.exe，MIT，LICENSE 同目录）"
  "  后端产物                    ：dist\（$($distFiles.Count) 个文件，由 tsc -p tsconfig.json 编译）"
  '  本地服务                    ：http://127.0.0.1:7788（端口在 config.json 的 web.port；框架不提供网页界面）'
  ''
  "更新通道：$Channel"
  "打包时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  "打包机  ：$builder"
)
Write-TextPreservingBom (Join-Path $packageDir 'VERSION.txt') (($versionLines -join "`r`n") + "`r`n") $false

# ── 10. 自检：少一个文件就不许出包 ──────────────────────────────────────────
Say '自检包里该有的东西 …'
$missing = @()
foreach ($rel in $RequiredInPackage) {
  if (-not (Test-Path -LiteralPath (Join-Path $packageDir $rel))) { $missing += $rel }
}
if ($missing.Count -gt 0) {
  Fail ("包里缺这些文件，拒绝出包：`n  - " + ($missing -join "`n  - "))
}

# 占位符漏替换 = 包里留一行假版号。**按内容判断是不是文本**（有 NUL 字节的当二进制跳过），
# 不按扩展名白名单：模板将来换成别的后缀、或加一个无扩展名的文件，白名单就会静默漏检。
$leftover = @()
foreach ($file in (Get-ChildItem -LiteralPath $packageDir -Recurse -File)) {
  if ($file.Length -gt 8MB) { continue }
  $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
  if ($bytes -contains 0) { continue }
  if ([System.Text.Encoding]::UTF8.GetString($bytes).Contains('@@VERSION@@')) {
    $leftover += $file.FullName.Substring($packageDir.Length + 1)
  }
}
if ($leftover.Count -gt 0) {
  Fail ("版号占位符没替换干净，拒绝出包：`n  - " + ($leftover -join "`n  - "))
}

# 本机绝对路径不该出现在要发出去的文本里（`dist\` 曾因源码注释把本机例子带出门过，
# 见 tsconfig.json 里 removeComments 那段）：命中不拦，但必须**说出来**，不许静默。
# 扫全包（不只 dist）：`skills\` 里也可能带着打包者自己的路径。
# `C:\Users\<用户名>` 这种是**占位符**，不算泄漏，所以要求反斜杠后紧跟的是一个真字符。
$leakHits = @()
foreach ($file in (Get-ChildItem -LiteralPath $packageDir -Recurse -File)) {
  if ($file.Length -gt 8MB) { continue }
  $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
  if ($bytes -contains 0) { continue }
  if ([System.Text.Encoding]::UTF8.GetString($bytes) -match 'C:\\Users\\[^<\\]') {
    $leakHits += $file.FullName.Substring($packageDir.Length + 1)
  }
}
if ($leakHits.Count -gt 0) {
  Write-Host ("[装配] 警告：dist 里有 $($leakHits.Count) 个文件带本机绝对路径（发出去会暴露打包者目录）：") -ForegroundColor Yellow
  foreach ($hit in $leakHits) { Write-Host "        $hit" -ForegroundColor Yellow }
}

$packageBytes = (Get-ChildItem -LiteralPath $packageDir -Recurse -File | Measure-Object Length -Sum).Sum
Say ("自检通过：{0:N1} MB · {1} 个文件" -f ($packageBytes / 1MB), (Get-ChildItem -LiteralPath $packageDir -Recurse -File).Count)

# ── 11. zip + 校验和 ────────────────────────────────────────────────────────
$zipPath = Join-Path $OutDir "$packageName.zip"
$hashPath = "$zipPath.sha256"
$hash = ''

if ($SkipZip) {
  Say "-SkipZip 已给：只装配，不打 zip。装配目录：$packageDir"
} else {
  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  Say '打 zip …'
  # 以 `_stage` 为根归档：解压出来就是 `irmia-agent-vX-win-x64\` 一层目录，
  # 而不是把一堆文件摊在别人选的那个文件夹里（散装解压过一次就知道了）。
  Compress-Archive -Path $packageDir -DestinationPath $zipPath -CompressionLevel Optimal -Force
  $zipBytes = (Get-Item -LiteralPath $zipPath).Length
  Say ("zip：{0}（{1:N1} MB）" -f $zipPath, ($zipBytes / 1MB))

  $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  # 校验和文件写成 `<hash>  <文件名>` 两空格：`sha256sum -c` / `Get-FileHash` 对照都认这个形态
  Write-TextPreservingBom $hashPath "$hash  $packageName.zip`n" $false
  Say "sha256：$hash"
}

# ── 12. latest.json（站点发布管线要的那份） ─────────────────────────────────
# 形状对齐 `src/update/check.ts` 的 parseManifest：version/channel/platforms 必须有；
# `platforms[]` 的 os 写 `win32`（那是 `process.platform` 的原话，客户端按它匹配）。
if (-not $SkipZip -and -not [string]::IsNullOrEmpty($ManifestAssetUrl)) {
  $manifest = [ordered]@{
    channel = $Channel
    version = $Version
    platforms = @(
      [ordered]@{
        os = 'win32'
        arch = 'x64'
        kind = 'portable'
        url = $ManifestAssetUrl
        size = (Get-Item -LiteralPath $zipPath).Length
        sha256 = $hash
      }
    )
    # 网盘分流：用户定下的结构，没开放就是一条 pending（界面显示「即将开放」而不是空白）
    mirrors = @([ordered]@{ provider = 'pending' })
    publishedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  if (-not [string]::IsNullOrEmpty($NotesUrl)) { $manifest.notesUrl = $NotesUrl }
  $manifestPath = Join-Path $OutDir 'latest.json'
  Write-TextPreservingBom $manifestPath (($manifest | ConvertTo-Json -Depth 6) + "`n") $false
  Say "latest.json：$manifestPath"
}

Write-Host ''
Write-Host "  装配完成：$displayVersion" -ForegroundColor Green
Write-Host "  目录：$packageDir"
if (-not $SkipZip) { Write-Host "  产物：$zipPath" }
Write-Host ''

# 显式退出码：上面调过 node.exe（原生命令），它的退出码会留在 $LASTEXITCODE 里，
# 不写这一行的话"装配成功"会被调用方读成 1（CI 里就是一条假红灯）。
exit 0
