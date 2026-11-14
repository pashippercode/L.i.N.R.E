# 上游 beta13 → beta16 未处理 diff 台账

基线 `5e9748a`（beta13 快照）→ `upstream/main` `8fdddf1`（v0.1.0-beta.16）。
上游 12 提交 / 335 文件 / +71961 −6228。本表只记**去向**，细节见
`docs/upstream-beta16-review-backend.md` 与 `docs/upstream-beta16-review-frontend.md`。

原则：与上游平行更新，只选择性摘取；不 merge、不以上游为新基线。

---

## 一、已处理（第一批，2 项）

| 文件 | 做法 | 状态 |
|---|---|---|
| `src/log/event-log.ts` | 整段替换（上游 +100/−23） | ✅ 已上线，启动正常 |
| `src/runtime/real-loop.ts` | 手工移植：看门狗（3 分钟告警 / 6 分钟 abort）+ 402 告警 | ✅ 已上线，观察 2 分钟零误报 |

备份：`src/log/event-log.ts.bak-20261112-142000`；运行目录 `dist/log/event-log.js.bak-20261112-142237`。

---

## 二、后端待摘（第二批）— 已完成

| # | 文件 | 内容 | 状态 |
|---|---|---|---|
| 1 | `src/web/auth.ts` | setup 派生后 409、登录/改密/新密码派生共 4 处 `this.file !== file` 代际校验 | ✅ |
| 2 | `src/process/kill-tree.ts` | `taskkill` 加 2 秒超时；仅 `exit 0 && !error` 才早退 | ✅ |
| 3 | `src/update/check.ts` + `src/util/bounded-response.ts` | 流式限量替代 `response.text()`，超限即 cancel | ✅ |
| 4 | `src/update/service.ts` | 切通道 generation 代际 + `tracked` 防旧 promise 清空新 inFlight | ✅ |
| 5 | `src/state/snapshot.ts` | 缺失版本号即拒（`rawVersion !== SNAPSHOT_VERSION`） | ✅ |
| 6 | `src/channel/onebot.ts` | 重连 generation 守卫（7 处）+ `stop()` 换代 | ✅ |
| 7 | `src/channel/qq-app-id-guard.ts` | 同一 bot 两实例抢事件 | ⏭ 跳过：本地 QQ 官方通道默认关闭（`channels.qqOfficial.enabled=false`），接入点在启动链，收益为零 |
| 8 | `src/tools/vision.ts` | `VISION_QUERY_TIMEOUT_MS` 10s → 30s | ✅ |

全部通过 `tsc --noEmit` 零错误；2026-11-15 00:00 构建同步并重启，OneBot 正常连上（self_id=1018168937）。

### 附：两处故意没跟

- **`SNAPSHOT_VERSION` 没升到 5**：上游升版是因为 Affect v2 / intimacy 投影形状变了，本地没有这两个字段，跟着升只会白白丢一次全量折叠。
- **`vision.ts` 的 GIF 帧矩阵没摘**：依赖 `gif-matrix.ts`；且上游 `vision.ts` 拿绝对路径当缓存键，同一路径换了内容会复用旧矩阵 —— 是先有 bug 再谈功能。

### 新发现

`%APPDATA%\Irmia\instances.json` 写入报 `EPERM`：目录 ACL、文件属性、手动试写全部正常，
只有后端进程写不进去 —— 是进程完整性级别问题，不是文件问题。启动不受影响，只是界面侧看不到实例登记。
2026-11-12 用 WMI 拉起后端时也是同一条报错。


---

## 三、后端待评估（第三批，需判断后定）

| # | 文件 | 内容 | 为什么不直接摘 |
|---|---|---|---|
| 1 | `src/model/ds-client.ts` | 重试上限 5 → 3、`effort` 枚举加 `medium` | 会改模型调用节奏，需先看本地现有上限 |
| 2 | `src/runtime/recover.ts` + `src/state/fold.ts` | `FoldSkipHandler`：重建时跳过坏事件 | 可靠性收益高，但要确认与本地 fold 逻辑不冲突 |
| 3 | `src/channel/qq-official.ts` | `onReady`（READY / RESUMED 各触发一次） | 依赖本地是否有对应生命周期钩子 |
| 4 | `src/runtime/python-probe.ts`（新 166 行） | Python 环境探测 | 看本地是否需要（工具链已有 python 3.15） |
| 5 | `src/runtime/trust.ts`（+55） | `ownerIdsFrom` 等 | 与 7 共用面 |
| 6 | `src/mcp/client.ts` | `DEFAULT_REQUEST_TIMEOUT_MS` 120s→180s、`callTool` 取 `Math.min` | 上游注释自相矛盾，且本地 MCP 门默认值未确认 |
| 7 | `src/channel/gif-matrix.ts` + `attachment-store.ts` / `tools/vision.ts` 接线 | GIF 帧矩阵 | **摘前必须先修** `vision.ts` 用绝对路径当 key 的缺陷（同路径换内容会复用旧矩阵图） |
| 8 | `scripts/copy-assets.mjs` | 把非 TS 资源搬进 `dist/` | 本地 `dist` 无 runner 资源，当前不适用；将来打包若缺资源再摘 |
| 9 | `scripts/plugin-contract.mjs` / `create-plugin.mjs` | 插件脚手架与契约快照 | 与本地包格式互斥，除非只借思路 |

---

## 四、后端明确不摘（有硬理由）

| 范围 | 文件 | 理由 |
|---|---|---|
| 情绪内核化 | `src/affect/*`（7 文件 +270）、`web/affect-view.ts` | 本地已用 `plugins/builtin/linre-affect` 复刻同一套公式 |
| 亲密层内核化 | `src/intimacy/*`（5 文件 +711）、`web/intimacy-view.ts` | 同上，且要整份快照作废 |
| 子代理 | `src/runtime/subagent-*`（13 文件 ≈7000 行） | 与 `ARCHITECTURE.md`「不做多 Agent 协作」矛盾，强耦合 plugin/affect/skill |
| 插件宿主 | `src/plugin/devtools.ts` / `market*.ts` / `host-services.ts` / `hook-registry.ts` / `model-call.ts` / `net-fetch.ts` / `runner-paths.ts` / `runners/*` / `runtime-process.ts` / `protocol.ts` | 第二套宿主；`apiVersion: 2` 字段集与本地互斥（本地禁 runtime/config/meta/net，上游禁 adapters/tools/events/views）⇒ 包不可互操作 |
| 灰港通道 | `src/channel/greyharbor.ts`（393 行）+ `tools/send-greyharbor.*` | 单一游戏服务器专用 |
| 贴纸内核 | `src/stickers/*`（store/service/runtime/tagger/harvest/phash-backfill） | 本地已有 `linre-stickers` / `linre-meme-photo`，再引内核会两套存储两套去重 |
| 入站收口 | `src/channel/inbound.ts`（新 176 行） | 插件 filter/指令的唯一收口，与本地插件架构冲突 |
| 配置扩张 | `src/config/config.ts` 四段新配置（affect/intimacy/stickers/subagents）+ plugins 市场段 + `channels.greyharbor` + `channels.*.stickers` | 配套功能不摘，配置也不摘 |
| 热更白名单 | `src/config/watcher.ts`（1 → 7 项） | 同上 |
| 渲染代际 | `src/model/render.ts`（RENDER_VERSION 86→88，v87/v88 口径）、`src/model/self-brief.ts`（147 行改写） | v87 取消 300K 字符帽与删 echo-chars 触发是**一对配套判据**，只摘一半会错；整体 reprogram 会造成每实例一次前缀 miss |
| 主循环接线 | `src/runtime/agent-loop.ts` | 九成是 affect/intimacy 接线，与看门狗无关 |
| 事件面扩张 | `src/log/types.ts`（+348） | 全是可选字段，不摘也不会崩；但**不要在 beta16 事件写过的 dataDir 上回写** |
| 服务端 | `src/web/server.ts`（+706）、`web/ingress-sources.ts`（新 194） | 配套 ingress / 新页面 API |
| 工具层 | `src/tools/admin.ts`（`to` 必填 + 贴纸参数 + `resolve_attachment`）、`catalog.ts` | 配套 speak 改造，本地 speak 口径不同 |
| MCP 图片 | `src/mcp/attach-image.ts`（新 98 行） | 新功能，非优化 |
| 状态缓存 | `src/state/projection-cache.ts` | 无独立收益 |

---

## 五、前端待摘（6 项 + 1 个清理）

| # | 项 | 规模 | 风险 |
|---|---|---|---|
| 1 | `gui/lib/api.dart` 请求代际 + `ApiStaleRequest`（本地与 beta13 一致，零冲突，自带 352 行单测） | 整文件 | 无 |
| 2 | `gui/lib/onboarding.dart` 引导标志按实例作用域 | ~20 行 | 低（修「新建实例不再弹引导」真 bug） |
| 3 | `gui/lib/instances.dart` 三处小修：端口 7789 起 + 跳过已登记、`canDelete=!running`、`--config` | 小 | 低（本地 `main.ts` 已支持 `--config`） |
| 4 | `gui/lib/pages/plugins_panel.dart` 审核面摊开 permissions / net / hooks / runtime（上游 delta +120 行） | 中 | 低，与本地插件平台同向 |
| 5 | `gui/lib/pages/chat_page.dart` 名字优先级加「她记的别名」（`/api/sessions` 已有 `aliases`，前端未用） | 小 | 低 |
| 6 | `gui/lib/pages/overview_page.dart` 建议清单只留死信；`home.dart` 的 `ValueKey('nav-<id>')` | 一行 + 一行 | 无 |
| 7 | **删除死代码**：`gui/lib/pages/mood_page.dart`(449) + `stickers_page.dart`(316)（全仓零引用，app.dart 走 `PluginViewPage`） | 清理 | 无 |

---

## 六、前端明确不摘

| 范围 | 理由 |
|---|---|
| `mood_page.dart` / `mood_kit.dart` / `theme.dart` 的 `MoodPalette` | `/api/affect`、`/api/intimacy` 本地 0 命中；且本地已有**同名不同语义**的 `MoodPalette`（实例类 `.light/.dark/.of()`，被 `plugin_view.dart` 12 处使用），上游是 `abstract final` 全静态 ⇒ 摘了编译不过 |
| `subagents_page.dart`(3718) | `/api/subagents` 本地 0 命中，且 `import mood_kit` 被连坐 |
| `stickers_panel.dart`(1096) | `/api/stickers` 全族 0 命中，本地表情包是插件 |
| `channels_page.dart` 整文件覆盖 | 800+ 行是 format 重排，`ingress-sources` 本地 0 命中 |
| `win_spawn.dart` + instances 的 launcher 分支 | 本地无 `packaging/launcher.mjs`、无 `--spawn-instance` |
| `backend_stop_marker.dart` | 要与 `linre-keepalive.ps1` 同步改，本地看护不认 marker |
| `auth_gate` 两句提示 | 上游是安全话术退化，别抄 |

### 美术层：不摘

色值与上游逐字节相同（`shell 0xFFF8FBFD` / `ink 0xFF25394E` / 六个情绪色）。
上游美术增量只有 `mood_kit` 版式件与图表渐变（`chartAreaTop/Bottom`），动效仍克制。
本地已有 `ui_kit.dart` / `extensions_kit.dart` / `BreathDot` / `HerFace`，无需跟。

---

## 七、i18n（不整体摘，按页面成对摘）

- 7505 行 diff 里**真改文案只有 5 个 key**，其余是 `dart format` 换页宽。
- 本地 17 个新 key 上游都有，但 **2 个语义相反**：`extPluginRestartBody`、`extSectionPluginsBlurb`（「代码插件即时启停」在本地是假话）⇒ 合并必须保本地。
- `stringsAsMap` 是手写全量清单，漏一行 = 该键静默无法覆盖；摘 i18n 必须先跑 `strings_override_test`。
- 中文棘轮 `copy_coverage_test`：上游 33→35，本地新增 3 标签 + 2 副标题却没动数字（仍 33）⇒ **本地可能已红**。建议把 5 个字面量迁进 `AppStrings`，而不是抬棘轮。
- 373 新 key 域分布：intimacy 105 / mood 65 / subagents 62 / stickers 54 / plugin 36 / ingress 23 / logs 13 ⇒ 不存在「先合 i18n」，只能按页面成对摘。

---

## 八、需进一步确认（不臆测）

1. `event-log.ts` 换成 `'r+'`/`'wx+'` 后，`scanShard` 的自愈路径是否需要同步调整。**旁证**：本地自愈路径本身已用 `openSync('r+')` + `ftruncateSync`（原文 `:419-423`），写路径用 `'a'` 才是例外；摘时只改写路径，别碰自愈路径（它 `:401` 用 `'a'` 追加换行是刻意的）。
2. 本地 MCP 执行器那条门的默认 `timeoutMs` 具体值（若仍是 60s，`Math.min` 对齐后只会更短，不能照抄 180s）。
3. `plugins/builtin/linre-affect` 的 `lastSeq` 持久化位置与崩溃语义（决定「重复评价」是否真会发生）。
4. `scripts/render-baseline*.mts` 是否与本地渲染基线测试同源（若同源，动 `RENDER_VERSION` 时要同步更新基线）。
5. 本地是否有代码假设 MCP 工具超时 `=== DEFAULT_REQUEST_TIMEOUT_MS`（`Math.min` 之后等式不再成立）。

---

## 九、未决风险

| 风险 | 说明 |
|---|---|
| v87 口径 | 取消 300K 思维链字符帽与删掉 `echo-chars` 压缩触发是配套判据，不能只摘一半；本地仍 v75 口径，建议整体不动、先实测 |
| RENDER_VERSION | 本地 86 / 上游 88；任何 render 侧摘取都会造成每实例一次前缀 miss，要摘就集中在一次 |
| gif-matrix | 摘前先修 `vision.ts` 用绝对路径当 key 导致「同路径换内容复用旧矩阵图」的缺陷 |
| 事件面 | beta16 日志用本地代码读不会崩，但 affect/intimacy/sticker/subagent 事件会被静默忽略 ⇒ **不要在那种状态下回写同一 dataDir** |
| 前端棘轮 | `copy_coverage_test` 可能已红，本机无 Flutter 环境，只能等 CI 验证 |
| 前端未决 | 本地插件运行时是否支持代码插件；`plugins_panel` 的 `net`/`runtime` 字段本地是否返回 |

---

## 十一、附：三个新增模块是什么

### greyharbor（灰港，393 行）

给 **Grayhaven 游戏**做的专用通道：WebSocket 只读订阅世界状态（`welcome/events/observation` —— 角色在哪、身边有谁、谁说了什么），说话走 HTTP `/v1/characters/:id/commands` 发 `say` / `direct_message`，默认连 `http://127.0.0.1:3000`。等于把 LINRE 变成该游戏里的 NPC/玩家。

**结论：不摘。** 写死了 Grayhaven 的协议与 observation 结构，换游戏即废。

### inbound（入站收口，176 行）

所有渠道消息进她之前的**唯一处理管线**：`插件过滤链 → 聊天指令 → 唤醒/信箱分流`。之所以收口，是因为三步共享同一个「这条消息接着去哪」的结论；分开写迟早出现「插件说 drop 了、消息还是被 wake 了」。

钩子语义：

| 返回 | 效果 |
|---|---|
| `{text}` | 改写正文，链式传递 |
| `{drop:true}` | 不进任何上下文，也不进信箱 |
| `{additionalContext}` | 只追加到本次唤醒的提示（`wake/channel` 的 `pluginContext`） |
| `/指令` 命中 | **默认不进上下文**，只回结果（除非 handler 返回 `keepInContext:true`） |

两条保护：每条插件订阅 **2 秒超时**、插件报错/超时只影响它自己，**消息原样继续**（绝不因插件坏了丢用户消息）；消息**串行**送入，保证同会话「先到先 wake」。

**结论：借思路，不搬代码。** 它 import 上游 `plugin/host-services.ts`（第二套宿主）。但「三态钩子 + 超时不丢消息 + 串行」这套收口语义，值得本地 adapter 框架将来做消息钩子时照抄。

### gif-matrix（GIF 帧矩阵，231 行）

模型看不了动图，只能看静帧；本模块把多帧 GIF 拆成**网格图**（顶部固定写「框架自动采样的gif动图表情，下为帧序列：」，每格标 `#1 #2 #3…`）。

- 不依赖 ffmpeg / ImageMagick，走 Windows 自带 PowerShell 5.1 + `System.Drawing`
- 默认 0.7s 采样，短 GIF 全取，长 GIF 上限 24 帧
- 产物按内容 hash 缓存：`data/blobs/images/<hash>.gif-matrix-v2.jpg`
- 转换在预取阶段异步做，读图时只同步读产物

**结论：本地可能要（表情包/GIF 识图），但摘前必须先修调用方缺陷** —— 上游 `vision.ts` 用**绝对路径**当缓存 key，同路径换内容会复用旧矩阵图；应改传内容 hash（`gif-matrix.ts` 自己已经 hash，是调用方传错了 key）。

---

## 十、剩余文件去向速查

335 文件里：

- 已处理：2
- 待摘（二/三批 + 前端）：8 + 9 + 7
- 明确不摘：上述第四、六节覆盖的其余全部
- 纯 format / 测试夹具 / 文档：随所属模块一起不动
