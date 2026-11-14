# 上游 beta13 → beta16 前端（Flutter GUI）差异评估

> 审查范围：`gui/` 全部（lib / test / pubspec / tool）。后端由另一路审。
> 基线：`5e9748a`（v0.1.0-beta.13） → `upstream/main`（`8fdddf1`，v0.1.0-beta.16）。
> 本地对照：`HEAD = 4024e47`（分支 `feat/builtin-plugins`）。
> 本文只读审查，未修改 `gui/` 下任何文件；唯一写入是本报告。

---

## 概览

一句话：**beta14–16 的上游前端是"三个新页面 + 一次全仓 dart format 重排 + 一套后端新能力的前端开口"，其中真正能脱离后端单独搬走的只有 api/instances/nav 那一层；三个新页面在本地后端上全部跑不起来。**

数字（`git diff 5e9748a upstream/main -- gui`）：

| 项 | 数值 |
|---|---|
| 文件 | 50（lib 25 / test 22 / 其他 3：`pubspec.yaml`、`pubspec.lock`、`tool/spawn_probe.dart`） |
| 行数 | lib `+21741 / −4498`，test `+5282 / −252`，合计 `+27062 / −4750` |
| 新增文件（lib） | 7：`mood_page.dart`(4872)、`subagents_page.dart`(3718)、`stickers_panel.dart`(1096)、`plugins_panel.dart`(414)、`mood_kit.dart`(232)、`win_spawn.dart`(197)、`backend_stop_marker.dart`(59) |
| 新增测试文件 | 9：`intimacy_tab_test`(1032)、`subagents_page_test`(1024)、`mood_page_test`(610)、`stickers_panel_test`(515)、`subagents_page_preview_test`(455)、`api_instance_context_test`(352)、`mood_page_preview_test`(337)、`logs_event_summary_test`(131)、`instance_config_test`(37) |
| 本地同区间改动 | 13 文件 `+3085 / −38`（只动 app / tray / theme / i18n / extensions / plugins_panel / 两个本地页 + 测试） |
| 两侧改到的文件交集 | 11 个 |
| i18n | `app_strings.dart` 9751→12980 行；无参 getter 962→1243；去重新增 key **373** 个；两侧共有的 962 个 getter 里**文案真改的只有 5 个** |

三个必须先摆清楚的判断：

1. **`plugins_panel.dart` 不是本地自研，是两侧同源。** 上游 `c8d7903`（插件平台：后端管理器 + 界面「扩展」页插件面板）与本地的 `4130cbf` 是**同一份改动**（diffstat 逐行一致：i18n +183/+95、extensions +88、plugins_panel +357、测试 +280）。`git diff c8d7903 HEAD -- gui/lib/pages/plugins_panel.dart` 为空、`extensions_page.dart` 也为空。所以本地"插件面板"的基线就是上游 beta14 那一版，之后上游往前走了（+57 行净增），本地往前走的是别的方向。
2. **本地 `gui/lib/pages/mood_page.dart`(449) 与 `stickers_page.dart`(316) 是死代码。** `git grep -n "mood_page|stickers_page" -- gui` 零命中：`app.dart` 里「情绪」「表情包」两个入口都指向 `PluginViewPage`（插件自描述渲染器），这两个文件既不 import 也没测试引用。本地"情绪页/表情包页"的真实实现在 `plugin_view.dart` + 运行时插件包 `data/plugins/packages/linre-affect|linre-stickers`，不在仓库源码里。
3. **上游 `channels_page.dart` 的 +1110 行里，功能性新增只占约 250–350 行**（Ingress 来源卡 + 少量字段/展开控件），其余是 dart format 重排。同一现象吃掉了 i18n 两个文件 diff 的绝大部分（见 §7）。

---

## 按模块逐节

### A. 平台层：`win_spawn.dart`（新，197 行）+ `backend_stop_marker.dart`（新，59 行）+ `instances.dart`

**变了什么**

- `win_spawn.dart`：用 `dart:ffi` 直接调 `kernel32!CreateProcessW`，带 `CREATE_NO_WINDOW`(0x08000000) + `DETACHED_PROCESS`(0x8)，外加自己实现 Windows 命令行 quoting。理由写在注释里且很具体：`Process.start` 给不了这个标志位 → node.exe 是控制台子系统程序 → 会多一个黑窗口；而 2026-10-27 用 `conhost --headless` 包一层被火绒判成 `ADV:Ransom/Genalocker.A` **并删了 node.exe**。`pubspec.yaml` 因此加了 `ffi: ^2.1.2`。
- `backend_stop_marker.dart`：在实例数据目录写/删 `backend-stopped.marker`（含 ts/pid/reason）。解决的问题是**看护脚本分不清"崩了"和"人主动停的"**：人点「退出实例/退出登录」后一分钟内看护按"后端不在"把它又拉起来，拉起后触发了那次报毒。标记只由人主动停写，人再叫她起来时删。
- `instances.dart`：
  - `backendNodeArgs()` 新增 `--config <实例配置>`，`instanceConfigPathFor()` 按"是否默认实例"选 `<安装根>/config.json` 或 `<dataDir>/config.json`；
  - `launchBackend()` 在 Windows 上**优先走 `launcher.mjs --spawn-instance <dataDir> <port>`**，失败再退 FFI 直起 node，最后退 `Process.start`。注释给的现场是：FFI 直起 node 时子进程拿不到有效 stdout/stderr，后端写第一行日志就崩，界面只看到"一直没就绪"；
  - **新建实例端口不再从 7788 起**，改 `kFirstSpawnedInstancePort = 7789`，并跳过登记表里已占用的端口（现场：默认实例停着时 7788 在探测里是空的，新实例被分到 7788，两台抢同一端口 → "创建卡半天"）；
  - `canDelete` 从 `!running && !entry.isDefault` 放开成 `!running`（默认实例只是"默认选谁"，不该不可删）；
  - 新增 `defaultInstanceDataDirOf()` / `_normalizedPath()` 与后端 `defaultDataDirOf` 对齐。

**用户可见影响**：以后台方式起后端不再闪黑窗；人主动退出后不会被看护半小时内又拉起来（连带少一次杀软误报）；新建实例不再撞端口；被挪走数据目录的"幽灵条目"能删了。

**建议：`仅参考`（分层看）**

- `backend_stop_marker` 的思路 **值得摘**，但**必须同时改 `linre-keepalive.ps1`**（本地看护脚本里没有 marker 判据，`marker|stopped` 零命中）——这是 gui/ 之外的联动，单摘前端等于写了个没人读的文件。
- `win_spawn` + `launchBackend` 的 launcher 分支 **不要摘**：本地**没有 `packaging/launcher.mjs`**（仓库里 `launcher.mjs` 不存在，也没有 `--spawn-instance`），摘了只会在缺少 launcher 时落到 FFI 直起 node → 命中上游注释里那个"后端一写日志就崩"。用例 `instance_config_test.dart`(37) 也只测 `backendNodeArgs` 的拼装，不保护这条路。
- `instances.dart` 的**三处独立小修值得摘**：端口从 7789 起 + 跳过已登记端口、`canDelete` 放开、`backendNodeArgs` 里加 `--config`（本地后端 `src/main.ts` 确实实现了 `--config`，`parseMainArgs` 认它）。这三处后端无关、可单测。

---

### B. `api.dart`：请求代际 + 旧响应作废（`ApiStaleRequest`）

**变了什么**：`baseUrl` / `token` / `instance` 三个字段从 public final 改成私有 + setter，每次 set 递增 `_generation`；每个请求进来先 `_captureContext()` 拍一张（generation/baseUrl/token/instance），`_roundTrip` 与 `events()` 在**每个 await 之后**核对代际，对不上就抛 `ApiStaleRequest`（`events()` 里则把错误换成它）。401 自愈路径特意允许"本请求在同一地址上换票重试一次"，但**不**把新实例的票送到旧地址；`_authErrorOf` 也改成用 context 里的 instance 而不是成员变量，避免并发请求互相覆盖。新增 `patch()` / `delete()`。

**用户可见影响**：切实例/重新登录的那一刻，在途的旧请求不会再把旧实例的数据写成新实例的状态，也不会用旧票打新地址。是纯正确性修复，无 UI 变化。

**建议：`值得摘`**。理由：①本地 `api.dart` 与 beta13 完全一致（本地 13 个改动文件里没有它），零冲突；②后端无关，纯前端状态机；③自带 352 行单测 `api_instance_context_test.dart`，是这次 50 个文件里**最干净的一颗**。摘的时候连测试一起拿。

---

### C. 启动流程与导航：`app.dart` / `home.dart`

**变了什么**

- 一级导航从 6 项变 7 项：`overview, chat, schedule, mood, persona, extensions, channels`；「情绪」上移一级，「人格配置」改名「人格」，「消息适配器」挪到「扩展」之后。
- 二级「更多」变成 `subagents, memory, logs, settings`（4 项）；本地是 `mood, stickers, plugin-views, memory, logs, settings`（6 项）。
- `_navLabel()`：新入口 `subagents` 走 `strings.navSubagents`，其余旧入口**故意不做全局重命名**（理由写在注释里：会把既有页面的中文测试断言一起带偏）。`home.dart` 里给「更多」的每一项补了 `ValueKey('nav-${page.id}')`，测试才能按 id 定位。
- `AppState` 新增：子代理角标（`subagentsEnabled` / `subagentActiveCount` / `refreshSubagentBadge()`，并发合并成一次、失败静默、404 不挡门）、`affectRevision`（情绪页只在事件变化时重读 `/api/affect`，不新增轮询）、启动时"多实例先选"（`_startupInstanceResolved` + 用 `FLUTTER_TEST` 环境变量排除测试进程）、创建实例的 `deadSeconds` 判死（端口既无实例应答也无健康应答连续 15 秒就直接报错，不再让人干等 180 秒）、登出/退出实例时写 `backend_stopped.marker`、`refreshInstances` 里清幽灵条目、`_loadDashboard` 捕获 `ApiStaleRequest`。

**用户可见影响**：装了多台实例时开机先进选择页（原来直接进"最早那台"）；实例列表不再出现自己没建过的幽灵条目；新实例创建失败会 15 秒内明说而不是等三分钟；侧栏"子代理"有活跃角标。

**建议：`仅参考`（按块拆）**

- `仅参考`：导航重排（与本地入口设计直接冲突，见 §4）+ 子代理角标（本地无 `/api/subagents`，`refreshSubagentBadge` 会每进壳 404 一次并静默，属于白烧一次请求）。
- `值得摘`：`deadSeconds` 判死（一个小循环变量，本地"创建卡半天"同样存在）、幽灵条目清理（`refreshInstances` 里那段，本地多实例场景同样中招）、`_loadDashboard` 捕获 `ApiStaleRequest`（配合 §B 一起）。
- `值得摘`：`home.dart` 的 `ValueKey('nav-${page.id}')`（纯测试可达性，零风险）。

---

### D. `onboarding.dart`：引导标志按实例作用域

**变了什么**：`kOnboardingDoneFlag` 这个"问过了"的标志原来一台机器一份，于是**新建实例直接继承老实例的"已经引导过"，第一次打开什么都不问、落在空白运行情况页**。改成 `onboardingFlagKeyOf(state)` → `'$kOnboardingDoneFlag@$dataDir'`，读和写都必须走同一个函数；另给测试留 `onboardingFlagScopeOverride`。同时 `guiVersion` 从 `v0.1.0-beta.13` 改成 `v0.1.0-beta.16`（`settings_page.dart` 一行）。

**用户可见影响**：新建的实例第一次打开会正常走四步引导。

**建议：`值得摘`**。后端无关、~20 行、修的是真 bug；本地 fork 也在做多实例（`feat/builtin-plugins` 有 `InstanceBook` 相关改动），这个坑本地一样有。

---

### E. 情绪页：`mood_page.dart`(4872) + `mood_kit.dart`(232) + `theme.dart` 的 `MoodPalette`

**变了什么**

- `mood_page.dart` 按 2026-10-31 设计稿重做，**一页三 tab**：`0=情绪 / 1=表情包 / 2=亲密`。
  - 情绪 tab：hero（状态词 + 一句人话 + 两个 stat pill + 同心轨道与渐变球 `_OrbSpace/_OrbPainter`）→ 情绪构成（六行色点 + 轨道 + 百分比）→ 心境轨迹（今天/近 7 天自绘折线：虚线网格、渐变面积、平滑曲线、末端圆点，还有"相邻两拍合并"的纯函数 `_mergeNearby` 防"竖刺"）→ 最近 5 条影响（点开右侧 `_DetailSheet` 浮层）→ 页脚一行"情绪不改变工具授权与任务要求"。
  - 亲密 tab：左侧 phase 卡 + 右侧 2×2 读数卡 + 最近变化 + 四色潮汐；四条硬规矩写在文件头（只有点进 tab 才读 `/api/intimacy`、关闭态只留开关、走势图 <2 点不画、`labels/estrus/afterglow/phase` 全按后端字段渲染不二次推导）。
  - 数据只走 `GET /api/affect`（`history` 也由后端折好）、`GET /api/intimacy`、`PUT /api/stickers?pageSize=200`；开关走 `POST /api/commands/config-update`（`affect.enabled` + `affect.evaluatorEnabled` 成对写，`intimacy.enabled` / `intimacy.maxLevel`）。
- `mood_kit.dart`：从 mood_page 抽出的**共用版式件**（`MoodPanelSkin.of(context)` / `MoodPanelTop` / `MoodSectionBadge`），给情绪页与子代理页共用同一套 surface/圆角/描边/发丝影，避免"情绪页暖、子代理页冷"。
- `theme.dart`：新增 `abstract final class MoodPalette`（19px 圆角、发丝边框、六维情绪色 `concern/warmth/shyness/joy/distress/irritation`、四套球体径向渐变、折线图色、六种 tone 色、`emotionColor(key)` 未知回主色）。

**用户可见影响**：情绪页从"一列卡片"变成设计稿版式，多出折线轨迹、影响详情浮层、亲密读数；表情包被收进同一页第二个 tab。

**建议：`不要摘`（代码）／`值得参考`（思路）**

理由三条，都是硬的：

1. **后端全缺**：本地 `src/` 里 `/api/affect`、`/api/intimacy`、`affect/appraised` 事件全部 0 命中。本地的情绪是**插件**给的（`linre-affect`，`plugin.json` 的 `contributions.events.namespace = "linre-affect"`，界面走 `/api/plugin/linre-affect/ui/mood`）。摘上游页面 = 摘一张永久空态/报错的页。
2. **类名正面相撞**：本地 `theme.dart` 已经有 `MoodPalette`，但形态是**实例类**（`MoodPalette.light` / `.dark` / `static MoodPalette of(context)`），被 `plugin_view.dart`（12 处）和 `stickers_page.dart` 使用；上游的 `MoodPalette` 是 `abstract final class` + 全静态 const，`mood_kit.dart` 里写的是 `MoodPalette.shell` / `MoodPalette.cardShadow`。**同一个文件里的同名类，两种互不兼容的 API** —— 摘 `theme.dart` 那个 hunk 会直接编译不过（而且不报"命名冲突"，是"成员不存在"的迷惑错误）。
3. **产品语义重复**：本地把情绪/表情包做成插件页（插件自描述 + 通用渲染器 `plugin_view.dart`，16 种 block kind），上游把它们做成一级页面。这是架构路线二选一，不是"补个功能"。

可以做的是**抄版式语言**：把 `mood_kit.dart` 那套 `MoodPanelSkin`（亮/暗两套底 + 22 个 token）搬成 `plugin_view.dart` 的一层 skin，让插件渲染出来的页面也长这样 —— 这不涉及任何后端端点。

---

### F. 表情包：`stickers_panel.dart`(1096)

**变了什么**：完整的表情包管理工作台 —— 列表 + 标签 + 计数 + 设置，上传走 `pickStickerFile()`（Windows 上 `powershell.exe -STA` 起 `System.Windows.Forms.OpenFileDialog` 取路径，不引第三方 picker 包），另有 `sticker-harvest`（"收图"）与 `/api/stickers/events` 实时流。端点：`GET /api/stickers`、`GET /api/stickers/:id`、`GET /api/stickers/events`、`POST /api/commands/sticker-harvest`、`POST /api/commands/config-update`。

**用户可见影响**：表情包有了独立管理面板（上传/打标/删除/收图），并从独立页面变成情绪页的第二个 tab。

**建议：`不要摘`（代码）／`仅参考`（交互）**。本地 `/api/stickers` 全族 0 命中，表情包由 `linre-stickers` 插件提供（视图走 `/api/plugin/linre-stickers/ui/stickers`），端点与数据模型都不一样。唯一值得抄的是 `pickStickerFile()` 这个"不引包拿本地文件"的手法和"上传前先验 mime"的校验顺序。

---

### G. 插件面板：`plugins_panel.dart` 的本地→上游 delta（约 +120 行）

**变了什么**（`git diff HEAD upstream/main -- gui/lib/pages/plugins_panel.dart`）：

1. 审核弹窗从"一段说明"扩成**可滚动的事实清单**：正文 + `permissions` + `net.allow` + `hooks`（取 `manifest.hooks[].point`）+ `runtime`（type/state/pid）；
2. 卡片上多一行 `net.allow: … · runtime: …`，hooks 非空时多一行；
3. 新增 **`plugin-uninstall`**（按钮 + 确认弹窗 + 红色前景 + `extPluginUninstallTitle/Body/Uninstall` 三个新 key）；
4. `extensions_page.dart` 同步多一个 `plugin-uninstall` 的 toast 分支；
5. 文案上，`extPluginRestartBody` 与 `extSectionPluginsBlurb` 改成"代码插件即时起停 / 声明式包重启后生效"。

**用户可见影响**：审核时能看见一个插件到底要什么权限、要不要联网、挂了哪些 hook、跑的是哪种 runtime；插件能卸载了。

**建议：`值得摘`（分两步）**

- **第一步（纯前端，无后端改动）值得摘**：审核弹窗与卡片上的 `permissions / net / hooks / runtime` 展示。`_stringList` / `_hookPoints` / `_runtimeSummary` 三个纯函数 + 6 处 `Text`，后端字段本地已有（`/api/plugins` 在 `src/web/server.ts` 里存在）。
- **第二步（uninstall）需后端**：本地 `server.ts` 里 `plugin-uninstall` **0 命中**（`plugin-install` / `plugin-confirm` / `plugin-enable` 都在），摘了按钮会 404。要么先补后端命令，要么这次只摘展示、按钮延后。
- ⚠ 文案**不能连带上游的**：本地 `extPluginRestartBody` 是"人工启停只写入下一份生效状态，重启主进程后才接管"，上游是"代码插件即时启停"。上游的说法在本地是**假话**（本地只支持声明式包），照抄会让界面骗人。

---

### H. 子代理页：`subagents_page.dart`(3718)

**变了什么**：`更多 → 子代理` 下的管理页 —— 左栏角色包（Profile）+ 右栏会话列表/详情，宽窗左右、窄窗单列；详情里 `canResume` 才出现恢复、`canCancel` 才出现取消；SSE 按 `agentId` 过滤只往当前详情追加，断线每 12 秒轮询兜底；明确"摘要面"边界（不显示完整 transcript / 工具输出 / 请求体 / workspace 绝对路径）。端点：`/api/subagents`、`/api/subagents/:id`、`/api/subagents/profiles`、`commands/subagent-message|cancel|resume|install|verify`。版式复用 `mood_kit`。

**用户可见影响**：能看见并管理她派出去的子代理（排队/运行/中断/完成/归档），侧栏有活跃数角标。

**建议：`不要摘`**。本地 `/api/subagents` 0 命中（`src/subagent.ts` 有实现，但 web 层没开这条端点），整页 3718 行 + 测试 1479 行在本地是纯死重。而且它 `import '../pages/mood_kit.dart'` —— 摘它必然连带 §E 的 `MoodPalette` 冲突。**如果**将来上子代理页，最省的路径是"先让后端开 `/api/subagents`，再整页照搬"，而不是现在拆着摘。

---

### I. 消息适配器：`channels_page.dart`（+1110 / −290）

**变了什么**（去噪后）：

1. **新增「Ingress 来源」卡**（约 250 行）：`GET /api/ingress-sources` 列表 + `commands/ingress-source-create|rotate|toggle|delete`；每行 = 名字 + `id · wake 策略` + 开关 + 轮换 + 删除；创建弹窗填名字与 wake 策略（`always` / `critical` / `never`）；token **只在创建/轮换的响应里出现一次**，用 `_showIngressToken` 单独展示；卡底一行说明"老的 config 那套还在，这是外部脚本那条路"。
2. 「Webhook 与文件监听」改名为「事件与告警」（`chanHookTitle` / `chanHookBlurb` 两条文案），配置卡标题对 hook 项也换成 `chanHookConfigTitle`。
3. 少量交互打磨：群成员块可整组展开/收起（`_expandedGroups` + `chanMembersExpand/Collapse`）、数字字段 hint（`chanNumberHint`）、密钥行 hint（`chanSecretHintPaste/Configured`）、提及词 saved/cleared 后缀（`chanSavedLiveSuffix` / `chanSavedRestartSuffix`）。
4. 其余 800+ 行是 dart format 重排（函数签名换行、`const InputDecoration(...)` 拆多行、`unawaited(...)` 换行等）。

**用户可见影响**：外部脚本可以自助创建"事件来源"，支持轮换密钥/停用/删除；「事件与告警」这一项现在同时管入站 webhook、文件唤醒与外部事件来源。

**建议：`仅参考`（抄那张卡的交互，不抄文件）**

- 本地 `/api/ingress-sources`、`ingress-source-*` 命令 **0 命中**，摘了整张卡就是 404 空态。
- 这是本次**冲突面最大**的文件（上游 +1110/−290，本地 2020 行、上游 2840 行；两侧都从 beta13 出发但本地未动它，所以是纯上游改动 → 技术上可以直接覆盖，但会**把整页按 80 列重排**，之后本地任何一行改动都要重排一次）。
- 值得抄的是设计：**token 只出现一次 + 轮换按钮 + wake 策略三档**这套"密钥类资源"的交互约定，与本地插件 `/api/plugin/*` 的密钥处理可以对齐。

---

### J. 其他既有页面（小改）

| 文件 | 变了什么 | 用户可见影响 | 建议 |
|---|---|---|---|
| `chat_page.dart` (+67/−45) | ① 新 `_ItemKind.webhook` + `_BubbleItem.webhook`：外部 webhook 投递不摆成 `them` 气泡，复用右侧提醒卡、徽章改"外部事件"；② 新增 `_aliases`（`/api/sessions` 的 `aliases`），名字优先级 **用户填的 > 她记的 > 未命名**；③ 带 `agentId` 的事件不进主对话流（子代理自己的活动归子代理页） | 通道消息卡不再一律显示"未命名会话"；外部事件不再伪装成对话 | **`值得摘` ②**：本地 `/api/sessions` 的 `aliases` 字段**已经在**（21 个文件命中），本地 chat_page 却只查 `_contacts` → 同样的"未命名会话"毛病本地也有。①②③ 里 ③ 在本地是 no-op（`agentId` 0 命中），无害 |
| `overview_page.dart` (+16/−19) | 建议清单**只留死信**（`dead-letters`），砍掉"待确认超时/缓存偏低/日志久未归档/人格久未演化"四条 + `personaIsSeed` 那条，渲染条件仍是 `_advice.isNotEmpty` | 运行情况页少四块"该做的事"，只在有失败消息时才出现 | **`值得摘`**：纯前端过滤，一行条件 + 删一段，后端不用动 |
| `logs_widgets.dart` / `logs_rows.dart` (+76/−? ) | 事件类型→人话的 `_typeLabel()` 走 `AppStrings`（`affect/appraised`、`sticker/*` 六种）；`_summary()` 新增 affect（原因·主导情绪·强度）与 sticker（来源/标签/位置/候选数）摘要，另加 `_dominantImpulse()` 只在**事件里的原始 impulse** 上取最大，不重算公式 | 日志里情绪/表情包事件不再是一坨 JSON | **`仅参考`**：本地不产生 `affect/appraised`、`sticker/*`（插件命名空间是 `linre-affect`），这些分支永不命中。但"**摘要只读账本真值、不重算**"这条纪律值得照抄到本地插件事件的摘要里 |
| `extensions_page.dart` (+99/−? ) | 插件段（与本地同源）+ `plugin-uninstall` toast 分支 + 注释更新 | 见 §G | 见 §G |
| `auth_gate.dart` (+7/−7) | 两处"忘记密码"提示从两句长话缩成一句「忘记密码：删掉 data/.auth.json 后重启主进程，重设一次。」 | 少了一整段"这道门防什么"的如实说明（安全话术退化） | **`不要摘`**：这是**降级**，不是改进。本地若摘反而丢信息 |
| `settings_page.dart` (+2/−2) | `guiVersion` beta.13 → beta.16 | 版本号 | 摘的时候**只改数字，别抄注释**（文件里已经警告过） |
| `tool/spawn_probe.dart`（新，25 行） | 命令行探针，验 `spawnDetachedNoWindow` | 无 | 随 `win_spawn` 一起，`不摘` |

---

## 与本地自研 UI 的冲突点

下表是"**若摘上游会撞哪里**"，逐文件。三列：冲突类型 / 具体撞点 / 处理建议。

| 文件（两侧都改） | 冲突类型 | 具体撞点 | 处理 |
|---|---|---|---|
| `theme.dart` | **类名硬冲突** | 两侧都在文件尾新增 `MoodPalette`：本地是实例类（`.light`/`.dark`/`of(context)`，被 `plugin_view.dart` 12 处 + `stickers_page.dart` 用），上游是 `abstract final class` 全静态（被 `mood_kit`/`mood_page`/`subagents_page` 用） | **不要整块覆盖**。若真要上游那几个字段（hover/sheetBg/cardShadow/chartArea*），把它们**加进本地 `MoodPalette` 的实例字段**，再让 `mood_kit` 改读 `MoodPalette.of(context).xxx` |
| `pages/mood_page.dart` | **add/add 冲突** | 上游新建 4872 行，本地新建 449 行（且是死代码） | 本地这份可直接删（无引用）。但删了也只是清死代码，不代表要建上游那页 |
| `pages/plugins_panel.dart` | add/add（**同源**） | 两侧都从 `c8d7903` 出发；本地 = 上游 beta14 版（`git diff c8d7903 HEAD` 为空） | 冲突可机械解决（取上游）。真正的门在 §G 的 `plugin-uninstall` 后端命令 |
| `pages/extensions_page.dart` | 同源 + 1 处分支 | 同上；上游多一个 `plugin-uninstall` 的 toast 分支 | 同 plugins_panel |
| `app.dart` | 结构冲突 | ① `navPages`/`morePages` 条数与顺序完全不同（本地 6+6，上游 7+4）；② 本地在 `morePages` 里塞了 `mood`/`stickers`/`plugin-views` 三个 `PluginViewPage` 入口，上游的 `mood` 是一级 `MoodPage`；③ 上游 `AppState` 新增的子代理角标/`affectRevision` 在本地无端点 | **只摘块，不摘文件**：`deadSeconds`、幽灵条目清理、`ApiStaleRequest` catch、`ValueKey('nav-…')`。导航表按本地现状重写，不跟上游 |
| `shell/tray.dart` | 语义冲突 | 本地已把托盘图标安装整段删掉（本地 commit「托盘只留保活那一个；保活启动界面不再闪控制台」），只留保活那一个托盘；上游这文件只改了一行注释（"左侧"→"侧栏"） | 上游那行**没有摘的价值**，直接跳过。反向提醒：**不要**因为摘上游其它文件把 `tray_manager` 那段装回来 |
| `i18n/app_strings.dart` | 巨量伪冲突 | 见 §7 | 只摘"你要用的那几个 key 的三份实现"，其余不动 |
| `i18n/strings_override.dart` | 巨量伪冲突 + 静默漏项 | 见 §7 | 同上，且 `stringsAsMap` 必须同步补 |
| `test/extensions_page_test.dart` | 同源 | 本地 +1 行（= `c8d7903` 那次），上游共 +2 行（后续又动过一处） | 无冲突 |
| `test/plugins_panel_test.dart` | 同源分叉 | 本地 280 行、上游 328 行（多 uninstall 与审核清单用例） | 按 §G 走哪步就摘哪步的用例 |
| `pages/plugin_view.dart`（本地独有） | **概念重复** | 插件自描述渲染器（16 种 block），承载本地"情绪/表情包/插件页"三个入口 | 上游没有对应物；若将来上上游的 mood_page，本地这三个入口要重排 |
| `pages/stickers_page.dart`（本地独有） | 死代码 | 与本地 `mood_page.dart` 一样无引用 | 可删（与摘不摘上游无关） |

**一句话判据**：两侧 GUI 的重叠**不是"改了同一行"**，而是"**用两种架构回答同一批问题**"（插件页 vs 一级页面）。所以任何按文件级别的 cherry-pick 都会把架构选择一起带进来；能按块摘的只有 §B/§C/§D/§J 那几处。

---

## Top 5 最值得参考的前端改动

| # | 改动 | 能否只抄思路不抄代码 | 说明 |
|---|---|---|---|
| 1 | **`api.dart` 请求代际 + `ApiStaleRequest`** | 不能，建议**连代码带 352 行测试一起摘** | 本地 `api.dart` 与 beta13 一致，零冲突、后端无关。这是本次唯一"整文件搬过去就是净收益"的东西。抄思路也行（每次 await 后核对 generation），但并发竞态这种活自己写容易漏 await 点 |
| 2 | **`onboardingFlagKeyOf()` 按实例作用域** | 可以，20 行 | 抄思路即可：任何"一台机器一份"的界面标志，在多实例 fork 里都要按 `dataDir` 分片，且读写必须共用同一个函数 |
| 3 | **`instances.dart` 三处独立小修**（端口从 7789 起 + 跳过已登记端口 / `canDelete = !running` / `--config`） | 可以，都是局部改动 | 本地同构问题（多实例、幽灵条目、端口抢占）都在，且这三处不碰 launcher |
| 4 | **插件审核面"把权限摊开给人看"**（permissions / net.allow / hooks / runtime） | 可以，也可以直接摘三个纯函数 + 6 个 Text | 这是本次唯一与本地插件平台**同向**的产品改进：审核弹窗从"一段话"变成"事实清单"。本地后端字段齐，纯前端 |
| 5 | **`home.dart` 的 `ValueKey('nav-${page.id}')` + `_navLabel()` 的"只迁新入口、不全局重命名"** | 可以 | 抄的是**纪律**：新入口进 i18n，旧入口不趁机动，免得把既有测试断言一起带偏。这条纪律在本地 `copy_coverage_test` 的棘轮里已经有对应机制 |

备选（差一点进前五）：`chat_page` 的 **"她记的别名"作为第二张名字表**（优先级：用户填的 > 她记的 > 未命名）。本地 `/api/sessions` 已经有 `aliases` 字段，本地界面没用 → 这是"后端已备、前端未接"的现成缺口，摘它成本最低。

---

## Top 5 不要碰的地方

| # | 位置 | 为什么不能碰 |
|---|---|---|
| 1 | `pages/mood_page.dart` + `mood_kit.dart` + `theme.dart::MoodPalette` 三件套 | 后端 `/api/affect`、`/api/intimacy` **全缺**；本地情绪是 `linre-affect` 插件（命名空间 `linre-affect`）出的；`MoodPalette` 同名类 API 不兼容，摘了连编译都过不去；且与本地"插件页"路线正面冲突 |
| 2 | `pages/subagents_page.dart`(3718) + 两个测试(1479) | `/api/subagents` 本地 0 命中；还 `import mood_kit` → 被 #1 连坐。除非先把后端端点开出来，否则是纯死重 |
| 3 | `pages/stickers_panel.dart`(1096) | `/api/stickers`、`/api/stickers/:id`、`/api/stickers/events`、`sticker-harvest` 本地全 0；本地表情包是插件 + `/api/plugin/linre-stickers/ui/stickers`，数据模型不同 |
| 4 | `channels_page.dart` 整文件覆盖 | 800+ 行是 format 重排（覆盖后本地每次改动都要重排）；功能性部分是 `ingress-sources` 全套（本地 0 命中）。**只可抄那张卡的设计** |
| 5 | `win_spawn.dart` + `instances.dart` 的 launcher 分支 | 本地**没有 `packaging/launcher.mjs`**，也没有 `--spawn-instance`。摘了会在缺 launcher 时落到 FFI 直起 node，命中上游自己注释里的"后端一写 stdout 就崩、界面只看到一直没就绪"。同理 `backend_stop_marker` 需要同时改 `linre-keepalive.ps1`（本地看护脚本不认 marker） |

补充一条"不要摘但原因不同"：**`auth_gate.dart` 的两句提示**。上游把"这道门防的是什么"整段删了，只留操作步骤 —— 那是安全话术的退化，本地照抄会丢信息，不是移植问题。

---

## i18n 合并风险提示

### 风险 1：真正的改动量只有 5 处，但 diff 有 7505 行

- `app_strings.dart`：`+5367 / −2138`。逐 key 核对（两侧共有的无参 getter 962 个）后，**文案真正被改的只有 5 个**：

  | key | beta13 | beta16 |
  |---|---|---|
  | `composerHint` | `输入消息…（/reset 清空上下文、/dream 叫她整理记忆）` | `输入消息…`（两个命令提示被删） |
  | `extPageSubtitle` | `技能、MCP 服务、内置工具与执行点钩子` | `技能、本地插件、MCP 服务、内置工具与执行点钩子` |
  | `chanHookTitle` | `Webhook 与文件监听` | `事件与告警` |
  | `chanHookBlurb` | `告警出口 · 入站监听` | `告警出口 · 文件唤醒 · 事件来源` |
  | `pickerBody` | 中文同；**英文是整段**（"The previous instance has ended… their own edit rights."） | 中文同；**英文缩成一句** `Pick one to continue, or create a new instance.` |

  其余 2138 行删除几乎全是 **dart format 换页宽**（`=> '…'` 从一行变成折行、`const InputDecoration(...)` 拆成多行）。也就是说：**任何整体覆盖或 cherry-pick 这 7505 行，99% 是纯格式噪音，而且会把本地那 17 个插件 key 一起冲掉。**

- `strings_override.dart`：`+3828 / −1983`，其中 `'key': s.key,` 形式的 map 行新增 1239 条，剩下是 `loadStringsOverride` / `exportStringsTemplate` 里 `publish(StringsOverrideSnapshot(...))` 的**纯换行重排**（同一个调用从"参数内联"变成"trailing comma 多行"）。语义零变化。

### 风险 2：本地已有 17 个插件 key 在上游同名，其中 2 个文案语义不同

本地新增 17 个无参 key（`extSectionPlugins`、`extPluginInstall`、`extPluginReview*`、`extPluginEnable/Disable`、`extPluginStat`…），**17 个上游全都有**，其中 2 个文案不同且**差异是实质性的**：

| key | 本地（对） | 上游（对上游后端才对） |
|---|---|---|
| `extPluginRestartBody` | 人工启停只写入下一份生效状态，重启主进程后才接管；不会立即改变当前贡献 | 代码插件会即时启动或停止；声明式包只写入… |
| `extSectionPluginsBlurb` | 按整包哈希审核 Skills、Hooks 与 MCP 贡献；人工启停在重启后生效 | 按整包哈希审核贡献、代码权限与网络白名单；代码插件即时起停，声明式包重启后生效 |

本地插件运行时**没有"代码插件即时起停"**这档能力，照抄上游会把界面变成假话。合并时这 2 个 key **必须保本地**。

### 风险 3：`stringsAsMap` 是手写全量清单，漏一行会静默失效

`strings_override.dart` 的第三层（用户可改界面文字）靠 `stringsAsMap(AppStrings s)` 里逐行列出**每个无参 getter**。新增 key 却忘了补这张表 → 那个键**无法被用户覆盖**，界面上不会报错、只会"改了没反应"。

好消息：`gui/test/strings_override_test.dart` 里有断言专门守这条（注释原话："`AppStrings` 加了新 getter 却忘了补 `stringsAsMap`，这条会红"）。**摘 i18n 必须一起跑这个测试**，否则漏项无声。

注意两个边角：
- **带参句子**（`String xxx(String a, int b)`）**不进** `stringsAsMap`，覆盖机制也支持不了它们；摘上游时若把某个无参 key 改成带参，那张表里对应的行要删掉，否则 `stringsAsMap` 引用不存在的 getter → 编译错。
- `contentHash` 一类**判据字符串**（`'shyness'`、`'c2c'`、事件 type）**永远不进 i18n**；上游这次守住这条（`_emotionLabels` 之类都按后端键渲染），本地也应守住。

### 风险 4：中文棘轮（`copy_coverage_test.dart`）两边都在动

- 上游把 `'lib/app.dart': 33 → 35`，并在表里写明理由（新增「情绪」「子代理」两个导航标签，且"新增导航标签是唯一允许抬高的情形"）。
- 本地 `app.dart` 新增了 **3 个导航标签 + 2 句副标题**（「情绪」/「表情包」/「插件页」/「此刻的状态；由 linre-affect 插件提供」/「可配图目录；由 linre-stickers 插件提供」），但 **`copy_coverage_test.dart` 里的数字没动**（仍是 33）。

**需进一步确认**：本地这个棘轮测试当前很可能是红的（本次未运行 `flutter test`，避免在 `gui/` 下产生构建产物）。若确实红了，正确做法不是抄上游的 35，而是按本地实际值重算并把理由写进表里；顺带把 5 个导航/副标题字面量迁进 `AppStrings`（本地已有 `navMore` 这类先例），比抬棘轮干净。

### 风险 5：key 数量与域分布（决定"能不能只摘一页"）

上游新增 373 个去重 key，按域：

| 域 | 新增 key | 对应页面 |
|---|---|---|
| intimacy | 105 | mood_page 的「亲密」tab（本地后端无 `/api/intimacy`） |
| mood | 65 | 情绪 tab |
| subagents | 62 | 子代理页 |
| stickers | 54 | 表情包面板 |
| plugin | 36 | 插件面板（本地已有 17 个） |
| ingress | 23 | 消息适配器的 Ingress 卡 |
| logs | 13 | 日志摘要 |
| 其他 | 14 | 版本/杂项 |
| channels | 1 | 消息适配器正文（其余复用旧 key） |

结论：**i18n 是"跟着页面走"的**，不存在"先合 i18n 再合页面"的安全顺序 —— 只合 i18n 会带进 356 个无人使用的 key（并让 `stringsAsMap` 膨胀 356 行）。正确姿势是**按页面成对摘**：摘某页时才摘它那批 key 的三份实现 + `stringsAsMap` 的一行。

---

## 附：审查方法与未决项

**怎么得出上面这些结论**（便于复核）：

```powershell
git diff --stat 5e9748a upstream/main -- gui
git diff --name-only 5e9748a upstream/main -- gui | Compare-Object (git diff --name-only 5e9748a HEAD -- gui)   # 交集 11 / 本地独有 2
git diff c8d7903 HEAD -- gui/lib/pages/plugins_panel.dart        # 空 → 同源
git grep -n "mood_page" -- gui                                    # 空 → 本地死代码
# i18n：按 key 提取两侧实现后逐条比对（962 共有 getter → 仅 5 处文案变化）
```

**未决 / 需进一步确认**（本次没有下结论的）：

1. **本地 `copy_coverage_test` 棘轮是否已红** —— 未运行 `flutter test`（会在 `gui/` 下写 `.dart_tool/`，与"只读 gui/"的约束冲突）。按字面量计数（39 处含中文，其中 5 处是本次新增入口）与棘轮里的 33 对照，倾向"已红"，需实跑确认。
2. **本地插件运行时是否支持"代码插件"** —— 影响 §G 的文案取舍。本地 `src/plugin/` 有包管理，`linre-affect` 的 `plugin.json` 用 `apiVersion: 2` + `adapters[].worker`（adapter 形态），但没有"代码插件即时启停"的直接证据，未深挖。
3. **`plugins_panel` 审核清单里 `net` / `runtime` 两个字段本地后端是否都返回** —— 只确认了 `/api/plugins` 端点存在与 `permissions` 在用；`net` / `runtime` 缺失时上游代码已做兜底（显示 `—`），所以不阻塞，但要不要显示空行由产品定。
4. **`channels_page` 的功能性新增精确占比** —— 我给的"约 250–350 行"是抽样判断（读了三个大 hunk + `-w` 统计对比），不是逐行分类的结论。
