# 上游 beta13 → beta16 后端差异评估（LINRE 本地 fork 视角）

- 审查对象：`5e9748a`（beta13，同时是本地与上游的 merge-base）→ `upstream/main`（`8fdddf1`，v0.1.0-beta.16）
- 本地 HEAD：`4024e47`（领先 merge-base 10 个自研提交）
- 范围：`src/`、`scripts/`、`tools/`、`config.example.json`、`ARCHITECTURE.md`（前端另审）
- 规模：上游 12 个提交 / 335 文件 / **+71961 −6228**；本报告范围内的后端部分 **124 文件 / +26756 −870**
- 重叠：全仓 67 个文件两边都改过，本报告范围内 **26 个**（见"冲突与重复"一节）

**一句话结论**：上游这一批主要是"新内核化功能"（情绪/亲密/贴纸/子代理/灰港/插件市场），对本地大多是**架构冲突**；真正值得摘的是夹在里面的**后端韧性小补丁**——事件日志写路径、循环看门狗、鉴权竞态、更新检查限量、重连/双实例守卫。这五类全部是"加法式、无数据格式变更、落点文件本地未被改动或只改了无关区域"。

---

## 〇、先行结论（读这一段就够）

1. **本地已经吃到过的上游补丁，不要再摘第二遍**：`src/plugin/circuit-breaker.ts`、`src/plugin/failures.ts` 与上游逐字节相同；`src/skill/skills.ts` 的 `packageRoots`/`trustCandidate`、`src/skill/index-snapshot.ts` 的"非空→空写墓碑"、`src/mcp/client.ts` 的 `handshakeCompleted`/`onSystemicFailure`/`resourceSamples` 等待，本地都已具备。
2. **上游 v87 把"思维链 300K 字符帽"整个取消了**（同时删掉 `echo-chars` 这条压缩触发）。本地仍在 v75 口径。这是一对**配套判据**，不能只摘一半；建议整体不动，先按本地实测决定（见风险清单）。
3. **插件平台是两条平行演化线**，且**同一个 `apiVersion: 2` 在两套宿主里字段集互斥**（本地 v2 的 `allowedKeys` 不含 `runtime/config/meta/net`、`contributions` 允许 `adapters/tools/events/views`；上游 v2 恰好相反：允许 `runtime/config/meta/net/hooks`、`contributions` 只允许 `skills/hooks/mcp`）。上游的 `devtools`/`plugin-contract.mjs`/`create-plugin.mjs`/市场全部无法直接落地，硬拼会让本地插件包体系直接崩。
4. 后端真正高性价比的摘取目标是 **5 个补丁包，合计约 420 行改动**，见第五节。

---

## 一、src/model

### 1.1 `ds-client.ts`：重试上限 5 → 3，`effort` 枚举加 `medium`

- 变了：`DEFAULT_MAX_ATTEMPTS` 5→3；`DsReasoningEffort` 增加 `'medium'`，注释改为"传输层原样透传，provider 支持面由调用方检查，失败不得静默改档"。
- 影响：一次模型请求的最坏耗时从 5 轮退避降到 3 轮（约 500ms+1s 起指数退避），失败更快落到 `invalid`/死信；`medium` 只是类型放宽，运行期没有调用点使用。
- 建议：**仅参考**。理由：本地 `DEFAULT_MAX_ATTEMPTS` 仍是 5（`src/model/ds-client.ts:89`），改小是产品取舍（失败更快 vs 抗抖动能力下降），不构成缺陷修复；`medium` 枚举本地若没有对应 provider 检查逻辑，加了反而埋"静默降档"的坑。

### 1.2 `render.ts`：`RENDER_VERSION` 86 → **88**，v87/v88 两代口径

- 变了：`REASONING_ECHO_POLICY` 默认不再设 `maxTotalChars`（只追加、不截一条思维链）；`step/start` 显式记录 `reasoningEchoMaxChars`（`null` = 只追加）；回放按收据还原旧上限，无收据的旧日志沿用 300K；`v88` 把 `speak`/`report`/`send_media` 的 `to` 改成必填、回执文案改"已投递/未投递"、取消 25 字软提醒。
- 影响：任何一条改动都会改变请求前缀 ⇒ **每个实例一次缓存前缀 miss**；`v87` 还改变了压缩触发集合（见 2.1）。
- 建议：**不要摘**（整代）。理由：与本地 `src/model/render.ts`（本地已改 +183 行）强耦合，且 v87 是本地上游两条不同取舍；若确实要摘，只摘 `step/start.reasoningEchoMaxChars` 这个**观测收据**（纯加法，本地日志多一格，不影响字节），再谈口径。

### 1.3 `self-brief.ts`：人格/规范文本大改（147 行改写）

- 变了：删掉"不拿牺牲当筹码""试探先看反应、他不接就退回来""不趁脆弱逼他答应"等约束句；新增 §6「情绪与欲望」、§3.4「优雅地搪塞」、§8「子代理」整节；`speak` 段落改成"to 必填 + 口语化 + 一句一句说"。
- 影响：`instructions` 字节变化 ⇒ 前缀 miss；同时这是**人格与安全口径的产品决策**，不是技术修复。
- 建议：**不要摘**。理由：本地人格基线（SOUL/SELF_BRIEF 维护方式）与上游不同步，摘文本等于替用户改人格；其中"子代理"整节依赖本地不存在的功能，摘了会让她调用不存在的工具。

---

## 二、src/runtime

### 2.1 `agent-loop.ts`：平衡点很多，但九成是 affect/intimacy 接线

- 变了（去掉情绪相关后剩三条）：
  1. **任务卡标题改口径**：`taskCard.title` 从 `wakeTitle(首条唤醒)` + 提及替换，改为**只读 STATE.md 的第一项未完成任务**（新增 `persona/todo-state.ts` 的 `currentTaskTitle`，`agent-loop.ts:3168` 一带）。理由写在注释里："群消息不该看起来像派给她的活"。
  2. **压缩触发收窄**：删掉 `echo-chars` 第二条进门路，`trigger` 只剩 `'history-tokens'`（`compactionDecision`，对应 `render.ts` v87）。
  3. `contextGuard`（发送前上下文预算闸）、`reasoningEffort`（子代理冻结思考档）、`agentId` 事件字段。
- 影响：① 是**语义变化**：本地当前"谁叫醒她 = 任务卡标题"，上游改成"她自己写的待办 = 任务卡标题"，空态固定为「（STATE.md 未写当前任务）」。这会改变每逢群消息的任务卡内容（影响请求字节，也影响她"这活是谁派的"判断）。② 与 1.2 绑定。
- 建议：① **仅参考**（属产品口径，且本地 `agent-loop.ts` 已被自研改动 +68 行，摘了要重跑渲染基线）；② **不要摘**（除非同批摘 v87）；③ `contextGuard` **仅参考**（本地已有 `checkBeforeStep` 预算闸，功能重叠）。

### 2.2 `real-loop.ts`：**循环看门狗 + 402 告警**（本批最值得摘的运行时补丁）

- 变了：
  - 新增 `DEFAULT_TICK_STUCK_MS = 3 分钟`；`RealLoopDeps.tickStuckMs` 注入点；三个字段（`tickStuckTimer`/`tickAbortTimer`/`tickStuckReported`）+ `tickLastProgressAt`/`tickStartedAt`。
  - `start()` 里挂 `log.onAppend(event => noteTickProgress(event.type))`——**进展判据来自 EventLog 全漏斗**（含 AgentLoop 直写的事件），正则 `TICK_PROGRESS_TYPE_RE` 只认 `turn/start|step/|tool/|message/|budget/|model/|speak/|compaction/|…`。
  - `armTickWatchdog()`：无进展 3 分钟告警（`tick-stuck` / warn / 走 notifier），无进展 6 分钟 `stopController.abort(...)` 掉当前 turn；`tick()` 的 `finally` 清两个定时器、复位标志、收尾补一句"恢复正常"。
  - `turn 结束`处：`reason.kind === 'error'` 且 `/402|insufficient[ _]?balance/` ⇒ 一条 `model-balance` 告警（"充值后会自动恢复；期间消息重试两次后进死信"）。
- 影响：这是"界面看起来像她不说话"这一类现场（长 turn 卡死、双实例、余额耗尽）的**唯一主动信号**；本地目前只有 `stall`（人级别）和 `runtime/slow-tick`（事后观测），没有"卡住就中断"。402 告警让"充钱就能好"的故障不再被误读成"她坏了"。
- 建议：**值得摘**（Top 2）。补丁纯加法：`tickStuckMs` 可选、`onAppend` 默认零开销、定时器 `unref`、`tick()` 里只在 `finally` 清。本地 `real-loop.ts` 虽已自研 +293 行，但这段落在 `start()`/`tick()`/turn 收尾三个**独立位置**，可以逐 hunk 手搬，不必整文件合并。
- 依赖：`EventLog.onAppend`（见 5.1/7.1）。

### 2.3 `recover.ts` + `state/fold.ts`：重建时跳过坏事件（`FoldSkipHandler`）

- 变了：`applyEvent/applyOne/fold/foldFromSnapshot` 全部加可选 `onSkip(event, error)`；`fold` 对 `affect/appraised`/`intimacy/updated` 的 `applyOne` 包 try/catch；`recover.ts` 收集被跳过的事件，**重建完成后**一次性写进 `repairs/` 与 warn 日志（"原事件仍留在日志里"）。
- 影响：一条坏账不再让整份日志折不出来、进程起不来；代价是**损坏被降级为告警**，可能掩盖系统性问题。
- 建议：**仅参考**。理由：本地 `applyOne` 全部是 switch + 类型守卫，几乎不抛；为不存在的 affect 内核引入"吞异常"路径不划算。若将来本地也引入会抛的 fold，再按这份实现抄"收集→重建后统一报告"的形状（不要在 fold 里直接写日志，这一点值得学）。

### 2.4 `subagent-*`（13 文件 ≈ 7000 行）：可续聊子代理 P1

- 变了：`delegate` / `subagent`（status/message/cancel）两件工具；`AgentSession` 持久化、profile 冻结（researcher/worker/scribe）、workspace/projectRoot、隔离 MCP/技能/包、压缩、截图、健康检查；配套 `wake/subagent` 唤醒源与 `agentId` 事件字段。
- 影响：极大（新增执行面与信任面），且与 `ARCHITECTURE.md` 里"**不做**多 Agent 协作"的既有表述直接矛盾（上游这一版自己打了自己的脸，见 9.1）。
- 建议：**不要摘**。理由：7000 行强耦合 `affect`/`plugin host`/`skill packageRoots`/`mcp`，本地 `src/runtime/subagent.ts`（839 行，legacy `task` 工具）仍是活的；两套并存会产生两套"子会话/事件归属"语义。可参考的点只有一个：**"子代理的模型调用不得计入主循环 failStreak"** 这个判据（上游用 `data.affectEvaluation !== true` 这种标记实现，见 `fold.ts`）。

### 2.5 `python-probe.ts`（新 166 行）／`trust.ts`（+55）

- 变了：Python 解释器探测（给插件 python runner 用）；`trust.ts` 增加 plugin 贡献的信任推导。
- 建议：**仅参考**。本地插件运行时是 adapter worker（node），没有 python runner 需求。

---

## 三、src/channel

### 3.1 `onebot.ts`：**重连代际守卫**（真 bug 修复）+ `onReady`

- 变了：新增 `private generation = 0`；`start()` 时 `++generation`、`stop()` 时 `++generation`；`openOnce(generation)` 在**每一个 await 之后**重新校验 `generation !== this.generation`（连接前、连接后、`get_login_info` 后）；`onMessage` 回调额外校验 `this.client === client`；旧连接被取代时 `client.close(1000, 'connection superseded')`；重连定时器捕获当时的 `generation`。另加 `onReady` 回调（`markReady` 处触发，宿主给插件发 `channel.ready`）。
- 影响：**本地存在同一竞态**（`src/channel/onebot.ts` 本地无 `generation`）。`stop()` 立刻 `start()`（界面重启通道、配置热更重连）时，上一轮 `openOnce` 仍可能在 `await connect()` 之后执行 `this.client = client`，把新连接踢掉；旧 socket 的 `onMessage` 也可能继续 `handleIncoming` ⇒ 同一批消息重复进日志/重复唤醒。
- 建议：**值得摘**（Top 5 内）。改动集中（约 +40 行，7 个落点），`onReady` 可只摘代际部分。
- 注意：本地 `onebot.ts` 已被自研改 +307 行（新增了不少方法），照抄会冲突，需按"每个 await 后插一行判据"的方式手工落。

### 3.2 `qq-official.ts`：`onReady`（READY/RESUMED 各触发一次）

- 建议：**仅参考**。`onReady` 只服务插件平台的 `channel.ready`，本地没有该订阅面；代际守卫在 QQ 官方通道上不适用（网关自己有 session 状态机）。

### 3.3 `qq-app-id-guard.ts`（新 66 行）：**同一 bot 被两个实例抢事件，启动前拒绝**

- 变了：读 `instances.json` 里 pid 仍活的其它实例 → 读各自 `<dataDir>/.keys.json` 的 `qqAppId` → 与当前 appId 比较；命中则**只拒绝本实例的 QQ 官方通道**（不阻止启动），日志点名另一实例与端口，不打印 appId。边界写得很实：只比 `.keys.json`；两台同时首启仍有竞态。
- 影响：本地已有 `instance-registry.ts`/`instance-lock.ts`/`keys.ts`（三件依赖都在），可以直接落；双实例抢消息在本地是"她有时收到有时没收到"的经典幽灵故障。
- 建议：**值得摘**（Top 5 内，与 3.1 同一包）。新增文件零冲突，`main.ts` 只需在 QQ 通道工厂里插 6 行（`dataDir !== null` 时调 `findQqAppIdConflict`）。

### 3.4 `greyharbor.ts`（新 393 行）+ `tools/send-greyharbor.*`

- 变了：灰港游戏服务器的 observer WS（只读事件流）+ HTTP `/commands` 发言；`greyharbor:group|c2c:` 回投地址；welcome/events/observation 帧、cursor、心跳、退避重连、command 超时。
- 影响：单一游戏的专用通道，配置面 `channels.greyharbor`。
- 建议：**不要摘**。理由：本地没有灰港服务器，`characterId` 无从配置；通道实现质量尚可（有重连与超时），但不是通用能力。

### 3.5 `gif-matrix.ts`（新 231 行）+ `attachment-store.ts` / `tools/vision.ts` 接线

- 变了：多帧 GIF → 帧序列矩阵图（PowerShell 5.1 + `System.Drawing`，零外部依赖）；默认 0.7s 采样、24 帧上限、顶部标题、`#1..#N` 标号、`GIF_MATRIX_VERSION` 内容寻址缓存；`attachment-store.ensureAttachment` 先转矩阵再压缩，`readAttachmentImage` 优先读矩阵；`tools/vision.ts` 的 `vision_read` 同样改走矩阵；`VISION_QUERY_TIMEOUT_MS` 10s→30s。
- 影响：**"她能不能看懂动图"** 的能力从"只读首帧"变成"看 12 格序列"；失败一律回退原图，不丢消息。代价是每张 GIF 起一次 PowerShell（20s 超时）。
- 建议：**仅参考 → 想要就摘**。理由：这是功能而非修复，但落点干净（`attachment-store.ts` 本地未改、`vision.ts` 本地未改、`gif-matrix.ts` 是纯新文件）。**若要摘，必须先改一个缺陷**：`vision.ts` 里 `gifMatrixPath(options.dataDir, file)` 用的是**绝对路径**当 key（`gif-matrix.ts:39` 只做 `sha256(version + key)`），而 `ensureGifMatrix` 命中"目标已存在且非空"就直接返回 ⇒ **同一路径下换了内容会复用旧矩阵图**（静默给模型看旧图）。应先改成按文件内容 sha256 寻址（`attachment-store` 那条路用的是内容 key，所以只有 vision 这条路有该问题）。

### 3.6 `inbound.ts`（新 176 行）：插件 filter/指令的唯一收口

- 变了：`message.received` 插件过滤（串行、每条 2s）→ 聊天指令 → 原有唤醒/信箱分流，三处一个结论；`drop`/改写 `text`/`additionalContext` 三种返回。
- 建议：**不要摘**。理由：强依赖上游 `PluginHost` 的 `dispatchMessageReceived`/`runCommand`（本地 adapter v3 没有这组口）；本地 `main.ts` 的 `onChannelMessage` 已被自研改写，另起一条分流链会出现两套结论。

---

## 四、src/plugin（与本地平行实现，整体不合并）

### 4.1 事实先摆清：两条线的分叉点

| | 上游 beta16 | 本地 |
|---|---|---|
| 清单 `apiVersion: 2` | `allowedKeys` = `apiVersion/id/version/engine/contributions/permissions/**runtime/config/meta/net/net.allow/hooks**`（`manifest.ts:387-390`）；`contributions` 只允许 `skills/hooks/mcp`（`:407`） | `allowedKeys` = `apiVersion/id/version/engine/contributions/permissions`（**不含** `runtime/config/meta/net/hooks`，`manifest.ts:120`）；`contributions` 允许 `skills/hooks/mcp/adapters/tools/events/views`（`:129`，adapters 可选） |
| 运行面 | `host-services.ts`(2297) + `protocol.ts`(362) + `hook-registry.ts`(690) + `runtime-process.ts`(809) + `runners/` | `src/adapter/`（capability-broker/policy/supervisor）+ `contributions.ts` + `seed.ts` + `plugins-src/` |
| 生态 | `market.ts`/`market-http.ts`(1893)、`net-fetch.ts`(562)、`package-store` 签名链 | 无市场；包来自内置种子与本地目录 |
| 工具链 | `devtools.ts`（check/smoke）、`scripts/plugin-contract.mjs`、`scripts/create-plugin.mjs`(522) | 无 |

- 影响：**同一个 `apiVersion: 2` 在两套宿主里字段集互斥**。上游包带 `runtime` ⇒ 本地 `exactKeys` 直接抛（`runtime` 不在允许集）；本地包带 `adapters` ⇒ 上游 `contributions` 的 `exactKeys` 也直接拒。所以"插件商店/插件包"这类资产**不可互操作**，连"拿上游 `devtools` 校验本地包"这条路也走不通（它按上游 schema 判）。
- 建议：**不要摘**（市场、host-services、hook-registry、devtools、create-plugin、contract）。理由：不是补丁而是第二套宿主；一旦摘进来，本地已发布的 `linre-affect`/`linre-stickers`/`linre-presence` 全部装不上。
- **值得单独学的一点点**（不进 Top5，记在这里）：
  1. `filter-regex.ts`：插件提供的正则**放进一次性 worker** 执行（`resourceLimits` 16MB、50ms 匹配预算、2 个并发、64 队列），宿主事件循环绝不被 ReDoS 拖死。本地 adapter 若有任何"插件给正则/给过滤条件"的面，这条纪律直接适用。
  2. `failures.ts` 的 `PluginProbeCancelledError` 语义："关停导致的探针取消不算失败，不得让隔离期翻倍、不得写一条假 `plugin/quarantined`"。本地已有同一份（逐字节相同），**无需再摘**，但要确认本地探测池关停时确实抛这个类型。
  3. `devtools.ts` 的 smoke 设计：临时 dataDir + 假 registry + `netDisabled` + 合成模型回执 + `finally` 里 `stopAll` + 断言"进程真的回收"，最后一句文案固定"未连接真实聊天、模型或网络"。本地若要做插件自检，照这个形状抄最省事。

### 4.2 `contributions.ts` / `manager.ts` / `package-store.ts` / `manifest.ts`

- 建议：**仅参考**。本地同名文件已分叉（`manager.ts` 本地 379 行 vs 上游 575 行），上游新增的隔离/半开探测状态机本地有自研等价物；不要试图对齐。

---

## 五、src/config

### 5.1 `config.ts`：四段新配置（affect/intimacy/stickers/subagents）+ `plugins` 市场段 + `channels.greyharbor` + `channels.*.stickers`

- 变了：新增 `AffectConfig`/`IntimacyConfig`（`privateOnly` 非法值**直接报错**而非忽略）/`StickersConfig`（概率统一走新的 `pickProbability` 0..1 校验）/`SubagentsConfig`；`PluginsConfig`（`marketEnabled` 默认 **true**、`marketIndexUrl` 默认 `https://irmia.me/plugins/index.json`，非 http(s)、带凭据直接报错）；`channels.greyharbor`；`channels.qqOfficial.stickers`/`channels.onebot.stickers`（群聊贴纸开关，默认 false）；`IRMIA_AFFECT_ENABLED` 环境变量覆盖（只认明确的开/关，拼错回退配置）。
- 影响：配置面扩大；`pickProbability`/`pickMarketIndexUrl` 两个校验器是通用可复用件；`privateOnly: true` 的"硬边界写成硬报错"是个好范式。
- 建议：**仅参考**（除 `pickProbability` 可顺手抄）。理由：这些字段只在对应功能存在时有意义；本地 `config.ts` 已自研 +60 行，逐字段搬会留一堆死配置。
- ⚠️ 若摘 `plugins.marketEnabled` 默认 true：等于**给一个默认开启的外联**（GET 官方静态索引），与本地"插件来自内置种子"的信任模型冲突，需要明确决断。

### 5.2 `watcher.ts`：热更白名单从 1 项扩到 7 项

- 变了：`HOT_RELOAD_FIELDS = ['mcp.servers','affect.enabled','affect.evaluatorEnabled','intimacy.','stickers.','channels.qqOfficial.stickers','channels.onebot.stickers']`。
- 影响：`'intimacy.'` / `'stickers.'` 是**带尾点的前缀项**，`classifyConfigField` 的前缀匹配会把该段下任意字段都判成可热更——等于把两个整段开放给热更，粒度与注释里"填一项就得有一项的证据"自相矛盾。
- 建议：**不要摘**。理由：这是本批最松的一处判据，且本地只有 `mcp.servers` 一项，摘了等于引入"整段热更"的隐性行为。

---

## 六、src/affect（7 文件 +270）、src/intimacy（5 文件 +711）

### 6.1 内核化实现（与本地插件架构的正面冲突）

- 变了：
  - **affect**：`types.ts` 定版本（事件公式 v1 / 投影形状 v3）、6 维情绪 + 7 参评价（r,s,u,g,b,n,z,c,q）、`AffectCause` 因果池（按强度×衰减排序取前 8）、`EvaluatedIndex` 去重位图（1024-seq 稀疏桶，稠密时 128 字节 bitmap）、`affectAt()` 纯视图（时钟推移**不改**投影）、`makeAppraisedData()` 把**原始冲动**存进事件（"ledger truth 是存下来的冲动，不是未来的公式"）。
  - **intimacy**：独立状态机（intimacy/desire/satisfaction/restraint 四读数、`satisfaction` 余韵压制 desire、`refractoryUntilMs` 不应期、`INTIMACY_DAILY_CAP=2`、深夜 23:00–05:00 ×4 倍率、`dayKeyOf` 用配置时区而非 UTC）；只接受用户来源；`privateOnly` 由配置层硬拒。
  - 两者都往 `step/start` 写**渲染收据**（`affect: {version,atMs,renderedLine}` / `intimacy: {…,renderedLine,estrus,phase}`），供 replay 还原历史请求后缀，而不是按现态补写。
- 影响：这是"**派生状态进核心投影**"的架构选择：可重放、可快照、可校验形状，但**快照/缓存版本必须升**（`PROJECTION_CACHE_VERSION` 2→5、`SNAPSHOT_VERSION` 2→5），且 `basicProjectionShape` 开始**硬校验** affect/intimacy 的每个字段（缺一格就整份缓存/快照作废 → 下次全量折叠）。
- 建议：**不要摘**。理由：本地 `plugins/builtin/linre-affect/lib/emotion.mjs` 已经**逐条复刻**了上游 `engine.ts` 的语义（同一套半衰期、同一套 mood 基线、同一套 impulse 公式），只是把"状态存哪"换了位置（插件自己的事件命名空间 + worker `lastSeq`，不进核心投影）。两套并存 = 同一套公式两份实现，必然漂移。
- **但必须明确记下这个取舍的代价**（本地当前方案的三个已知缺口）：
  1. **replay 不复现**：`affect` 行由插件在 `prompt.inject` 时机注入，历史 `step/start` 没有收据 ⇒ `replay <turn> <step>` 重建出的请求与当时那份不一致（上游正是为此加收据）。
  2. **去重只靠 `lastSeq` 单调**：崩溃重启后 worker 的 `lastSeq` 若丢失/回退，同一 `sourceSeq` 会被二次评价（上游用位图 + `hasAppraised()`）。
  3. **形状无校验**：插件状态坏了不会被 `basicProjectionShape` 挡住，只会在渲染时表现为一行怪字。
- 若要补：**只补第 3 条的"插件状态自校验"**（照 `assertIntimacyState` 的形状：数值范围、时间戳整数、cause 数上限 8、版本号），不要搬内核。

### 6.2 `web/affect-view.ts` / `web/intimacy-view.ts`（新 118 / 142 行）

- 变了：两个只读投影端点 `/api/affect`、`/api/intimacy`（带时间轴/原因/阶段）。
- 建议：**不要摘**（跟随 6.1）。

---

## 七、src/log

### 7.1 `event-log.ts`：**写路径加固（本批最值得摘，且本地文件未改过）**

- 变了（5 处，+123 行）：
  1. `writeShardLine(fd, line, rollbackTo, sync)`：`writeSync` 带**显式位置** `rollbackTo + written`；`sync` 时写入后立即 `fsyncSync`（原来 fsync 在 `writeEntry` 里、且失败路径不 fsync）。
  2. `ShardWriteError` 携带 `rollbackSucceeded`；回滚失败 ⇒ 置 `writeFailure`，此后 `nextSeq/append/flush/writeEntry` 全部走 `assertWritable()` **立即拒绝**（"写入状态不确定，已停止写入"），而不是继续往坏分片里写。
  3. `ensureActiveShard`：活动空分片只有在 `startSeq === nextSeq` 时才复用；首条失败留下的空分片（文件名带旧 seq）**删掉重建**。
  4. 打开模式 `'a' → 'r+'`、`'ax' → 'wx+'`（注释："Windows 的 append 句柄不能可靠 ftruncate；定位写入使失败回滚可用"）。
  5. `flushBuffer` 改为**逐条提交账**（`finally` 里把已写条目从 buffer 摘掉、`bufferBytes` 只减已写），自动 flush 失败时条目仍在缓冲、`lastAppendedSeq` 保持已占用（不重复接收同一 seq）；`close()` 在 `flushBuffer` 抛错时**仍然关 fd**。
- 影响：本地当前 `writeShardLine` 用无位置写入 + O_APPEND 句柄 + `ftruncateSync` 回滚。在 Windows 上，append 句柄的 `SetEndOfFile` 可能被拒 ⇒ **回滚失败、半个行留在分片中间**，下次启动 `scanShard` 判坏行（本地注释自己写了"下次启动会自愈并写 log/repaired"，但那是**事后**修补，中间那一段读取会静默丢失）。且一旦回滚失败，本地仍继续接受写入 ⇒ 损坏扩散。
- 建议：**值得摘（Top 1）**。理由：本地 `src/log/event-log.ts` 未被自研改动（不在 26 个重叠文件内），可整段替换；事件日志是"唯一真相源"，这条链的加固收益最高。风险点是**行为变化**：磁盘满/只读 fd 后本地变成"写不进去就明确失败"，需要确认 `main.ts` 的 append 调用点能承受抛错（本地已有 `appendSync` 的 try/catch 观测，需逐点核）。
- 附带：同文件新增 `onAppend(listener)` 订阅口（同步、吞异常、默认零开销）——2.2 的看门狗依赖它，两件一起摘最省事。

### 7.2 `types.ts`：事件面扩张（+348）

- 变了：`WakeSource` 加 `'subagent'`；`attachments[]` 加 `fileId?`（OneBot/QQ 官方两条通道都填）；`wake/channel.data` 加 `pluginContext?`；`wake/webhook.data` 加 `source/kind/severity/title/message/observedAt/wake?`；`budget/consumed.data` 加 `affectEvaluation?/intimacyEvaluation?/stickerTagging?`；`step/start.data` 加四格收据；`compaction/decision` 的 `echoChars*`/`trigger` 语义收窄（`echo-chars` 只留给旧日志读）。
- 影响：**全是可选字段（加法）**，本地 `fold` 的 default 分支会忽略不认识的事件类型（`fold.ts` 显式注释"新增事件类型在此显式落进 default 是有意为之"），所以**用本地代码打开 beta16 的 dataDir 不会崩**，只会静默丢掉新事件（affect/intimacy/sticker/subagent 全部不折）。
- 建议：**仅参考**。理由：字段跟着功能走；`fileId` 若要摘必须同时摘 3.5/`resolve_attachment`（否则渲染出 `file_id: xxx` 却没有解析工具）。`budget/consumed` 的 `affectEvaluation` 标记值得记：**辅助模型调用不得计入主循环 failStreak**（本地若有插件触发的 light 调用，应同样打标并让 `fold` 跳过 `failStreak/lastModelSuccessAt`）。

---

## 八、src/state

### 8.1 `snapshot.ts`：**缺失版本号也不再当合法输入**

- 变了：`rawVersion !== undefined && rawVersion !== SNAPSHOT_VERSION` → `rawVersion !== SNAPSHOT_VERSION`（缺失即拒），注释理由："靠 shape 兜底会把'不知道哪一版写的派生状态'当合法输入；形状校验只认字段，不认口径。"
- 影响：本地当前 `if (rawVersion !== undefined && rawVersion !== SNAPSHOT_VERSION)`（`src/state/snapshot.ts:215`）⇒ **没有 version 字段的历史快照会被当成合法**，只要 shape 过就续算。这是"半旧半新的派生状态被贴上当前口径标签"的入口。
- 建议：**值得摘（Top 5 候补，1 行）**。理由：本地 `SNAPSHOT_VERSION` 仍是 2，不需要跟着升到 5；只把这一个判据改成严格版，代价是首次启动丢一次快照做全量折叠（注释里说了这代价是"换来一份能对账的账"）。
- 注意：同文件 `SNAPSHOT_VERSION` 2→5 与 affect/intimacy 形状**不要跟**（本地没有那两个投影字段，盲目升版只会让所有快照作废一次而没有任何新形状可校验）。

### 8.2 `projection-cache.ts` / `fold.ts`

- 变了：`PROJECTION_CACHE_VERSION` 2→5、形状校验里硬编码 affect v3 + intimacy 校验、`fold` 增加 `onSkip`。
- 建议：**不要摘**（跟随 6.1）。唯一可抄的是"**版本号必须与 shape 校验配对**"的注释纪律——本地已有一条同样的注释，保持即可。

---

## 九、src/web

### 9.1 `auth.ts`：**并发改密 / 首设密码的竞态（安全，23 行）**

- 变了：三处"scrypt 派生返回后校验凭据代际"：
  1. `setup()`：派生期间若 `this.file !== null`（另一条 setup 已完成）⇒ 返回 **409 already-initialized**，不覆盖。
  2. `verify()`：派生期间 `this.file !== file`（密码被改过）⇒ 返回 401，**不签发新票、也不给新代际累加退避**。
  3. `changePassword()`：两段（校验旧密码后、派生新密码后）都校验 `this.file !== file`，避免覆盖另一条已成功的改密。
- 影响：本地存在同一竞态（`src/web/auth.ts` 未被自研改动）。scrypt 是**异步、数十毫秒到数百毫秒**的窗口：并发两条 `setup` 可双双成功（第二条覆盖第一条，用户设的密码突然不是自己设的那个）；改密期间用旧密码 `verify` 可拿到一张"改密后仍有效"的票。
- 建议：**值得摘（Top 3）**。理由：纯加法（每处 4-7 行），语义精确（"对象身份 = 凭据代际，会话增删不换代"），是安全相关的正确性修复；文件本地零冲突。

### 9.2 `server.ts`（+706）+ `ingress-sources.ts`（新 194）

- 变了：`/api/affect`、`/api/intimacy`、`/api/stickers*`、`/api/plugins/market*`、`/api/subagents*`、`/api/ingress-sources*`、`PATCH /api/config`、`/api/commands/stickers-purge`；`ingress-sources` 是"一条来源 = 独立 token（盘上只存 sha256）+ 独立 wake 策略（always/critical/never）+ 独立开关"的多来源注册表，旧全局 webhook token 降级为 legacy 来源。
- 影响：`ingress-sources` 的**形状值得学**：每来源独立 token、只存 hash、token 只出现一次、轮换即刻失效旧 token、legacy 兼容不改变旧投递形状。
- 建议：**仅参考**。理由：本地 `web/server.ts` 已自研 +249 行，且这些端点全部服务本地没有的功能；`ingress-sources` 若本地确实只有单一 webhook secret，可作为后续独立小改造（与本批其它功能解耦，风险低）。

---

## 十、src/tools

### 10.1 `admin.ts`（整批 536 行改写，其中 beta16 占 444）：`to` 必填 + 贴纸参数 + `resolve_attachment`

- 变了：`speak`/`report`/`send_media` 的 `to` 从"可选（缺省回本轮会话）"改为 **`required: ['text','to']`**，空白 sid 在任何发言/打字等待/网络投递**之前**退回；`speak` 增加 `sticker`/`stickerPos`（纯贴纸可省 `text`）；新增 `resolve_attachment`（用 message_id + index 反查临时地址）。
- 影响：`to` 必填消灭了"发错会话"这一整类事故（旧行为：不填就默默发回本轮），但也让"回本轮"变成必须显式写 sid；这是**工具契约变更**，老日志回放/旧提示词都会受影响。
- 建议：**仅参考**。理由：本地 `tools/admin.ts` 已被自研改 +374 行（媒体/通知/会话面都有自研扩展），整段合并必冲突；`to` 必填属于产品取舍（且与本地 self-brief 文案要同步改，否则模型会漏填）。若只想拿一条：**"非法 sid 在任何副作用之前退回"** 的位置纪律（本地注释显示已有一部分），值得逐条核对 `send_media` 是否也做到了。

### 10.2 `vision.ts`：`VISION_QUERY_TIMEOUT_MS` 10s → 30s（+GIF 矩阵）

- 影响：单个视觉调用（描述/问答）在复杂图 + 排队时会稳定踩 10s 红线；30s 更贴合 light lane 实际。
- 建议：**值得摘（半行）**——本地 `VISION_QUERY_TIMEOUT_MS = 10_000`，改成 30s 是一行、无耦合。GIF 矩阵部分见 3.5（要摘就先修 path-key 的缓存缺陷）。

### 10.3 `executor.ts` / `catalog.ts`

- 变了：PostToolUse 允许**代码级插件**改写工具结果正文（`updatedResult`，外部进程钩子永远填不了这一格）；`catalog` 接线 `stickerRuntime`/`attachmentResolver`/MCP `callTimeoutMs`。
- 建议：**不要摘**。理由：本地没有"代码级插件工具钩子"这一层；`updatedResult` 的语义（"结果已产生、还没喂回模型之前"）可以记进本地 adapter 的设计备忘，但不要在本批落地。

---

## 十一、src/mcp

### 11.1 超时口径：`DEFAULT_REQUEST_TIMEOUT_MS` 120s → **180s**，`DEFAULT_MCP_TOOL_TIMEOUT_MS` 改为 180s，`callTool` 加 `Math.min(工具超时, 连接每请求超时)`

- 影响：本地两个常量都是 120s。MCP 工具跑测试/装依赖/查大仓在 120s 被砍是现场反复出现的问题（本地注释里那条"60s vs 120s 互相抢短"的历史就是同一类）。`Math.min` 的作用是**把两个时钟显式对齐**，避免"执行器门比连接门长、于是永远到不了"。
- 建议：**仅参考（想要就摘，2 行）**。理由：数值调整，本地 `mcp/client.ts` 已被自研 +48 行，但这两个常量在文件顶部、独立。摘之前先确认本地执行器那条门的默认值（若执行器仍是 60s，`Math.min` 只会更短）。
- 顺带一条**上游自己的注释错误**（不要照抄）：新注释写"连接自己的每请求软超时仍是 120s"，而同一提交把 `DEFAULT_REQUEST_TIMEOUT_MS` 改成了 180s。照抄会把读者带沟里。

### 11.2 `attach-image.ts`（新 98 行）：MCP 工具结果里的 `type:image` 交给宿主落盘并进上下文

- 建议：**仅参考**。理由：需要 `image/attached` 事件与 `imagesToContext` 开关的完整接线；本地 `tools/vision` + blob 外置已有等价能力，收益不明。

---

## 十二、scripts/ 与 tools/

| 文件 | 规模 | 是什么 | 建议 |
|---|---|---|---|
| `scripts/plugin-contract.mjs` | 244 | 生成 manifest JSON Schema（apiVersion 1/2、permissions 枚举、hooks 选项），动态 import 上游 `manifest.ts`/`hook-registry.ts`/`protocol.ts` | **不要摘**（本地没有后两个模块；schema 与本地 v2 互斥） |
| `scripts/create-plugin.mjs` | 522 | 插件脚手架（读 Agent 版本、模板） | **不要摘**（生成上游形状的包，本地 `exactKeys` 直接拒） |
| `scripts/copy-assets.mjs` | 49 | 资源拷贝 | 仅参考 |
| `scripts/rebuild-affect-projection.mts` | 34 | 从日志重建 affect 投影 | 不要摘（跟随 6.1） |
| `scripts/render-baseline*.mts` | 82 | 渲染基线夹具/对比 | **仅参考**（本地已有渲染基线纪律；若要摘只取"把 fixtures 固定成文件再比对"的思路） |
| `scripts/generate_full_versions.py`、`selftest-generator.py` | 153 | 发布/自检生成器 | 仅参考（上游发版流程专用） |
| `tools/make-source-archive.ps1` | 347 | 源码归档（脱敏白名单） | 仅参考（本地发版不走上游流程） |
| `tools/sticker-smoke.mts` | 309 | 贴纸链路冒烟（入库/打标/选图/发送全假依赖） | **仅参考**（本地贴纸是插件，但"全假依赖 + 断言事件序列"的冒烟形状可抄） |
| `tools/send-greyharbor.ps1/.cmd` | 118 | 灰港手动发包 | 不要摘 |

---

## 十三、与本地实现的冲突或重复点（逐条明确）

1. **情绪层：内核 vs 插件（最大分歧）**
   - 本地：`plugins/builtin/linre-affect`（`emotion.mjs` 自述"与上游 `src/affect/engine.ts` 同一套语义，但没有位图去重与事件折叠"），状态在插件自己的事件命名空间（`linre-affect.appraised`）+ worker `lastSeq`；界面是插件自描述 view（`views: [{id:'mood'}]`）。
   - 上游：`src/affect/*` 进核心 `Projection.affect`，`state/fold.ts` 折、`state/snapshot.ts`+`projection-cache.ts` 校验形状（版本 2→5）、`step/start` 写收据、`replay` 按收据还原。
   - 冲突面：**同一套公式两份实现**（半衰期/mood 基线/impulse 全同）⇒ 漂移是时间问题；且上游的 `Projection.affect` 一旦引进，本地所有快照/缓存作废一次，GUI 的 `/api/affect` 还要重接。
2. **贴纸：内核 vs 插件**
   - 本地：`plugins/builtin/linre-stickers`（adapter + `picker.mjs` + skill）+ 另一个 `linre-meme-photo`；发送面走 `speak` 的插件包装。
   - 上游：`src/stickers/*`（`store`/`service`/`runtime`/`speak.ts` 的 `withStickerSpeak`/`phash`/`harvest`/`tagger`/`resize`，约 2000 行）+ 核心 `speak` 参数 + `/api/stickers*` 端点。
   - 冲突面：**同名同能、两套存储**（上游 `<dataDir>/stickers/packs`，本地插件自有目录）⇒ 不要混用，否则同一张图两份记录、去重失效。
3. **插件平台：两条平行线 + 清单语义互斥**（见 4.1）。本地 `src/adapter/` 的 capability-broker/policy/supervisor 与上游 `host-services.ts` 的 `PluginHost` 是**同一职责的两种实现**，接口不兼容。
4. **运行时装配层冲突（合并成本）**：`src/main.ts`（本地 +658 / 上游 +1108）、`src/runtime/real-loop.ts`（+293 / +676）、`src/web/server.ts`（+249 / +706）、`src/tools/admin.ts`（+374 / +444）、`src/model/render.ts`（+183 / +180）。**这五个文件不能整文件取上游**，只能逐 hunk 手搬。
5. **上游修过的、本地已经有的（重复提醒）**：
   - `src/plugin/circuit-breaker.ts`、`src/plugin/failures.ts`：与上游**逐字节相同**（本地 `4130cbf` 与上游 `c8d7903` 同名提交，即本地当时直接摘了插件平台后端）。
   - `src/skill/skills.ts` 的 `packageRoots`/`packageRevision`/`trustCandidate`；`src/skill/index-snapshot.ts` 的"非空→空写墓碑"。
   - `src/mcp/client.ts` 的 `handshakeCompleted`、`onSystemicFailure`/`onRequestSuccess`、`resourceSamples` 关机等待、`onRequestTimeout` 归因。
   - ⇒ 这四组**不要再派人重做**，只在合并时做"有没有冲突"检查。
6. **通道层**：本地 `onebot.ts`（+307）/`qq-official.ts`（+26）已自研；上游这批对这两文件的改动（代际守卫、`onReady`、`fileId`）**均为加法**，可局部落，但 `resolveAttachment` 依赖 `log/types.ts` 的 `fileId` 与 `admin.ts` 的新工具，不建议半摘。

---

## 十四、Top 5 最值得摘的后端补丁（按收益/风险排序）

### ① 事件日志写路径加固 —— `src/log/event-log.ts`
- 落点：`5e9748a..upstream/main -- src/log/event-log.ts`（+123：`writeShardLine` 471、`onAppend` 669、`ensureActiveShard` 768、`writeEntry` 800、`flushBuffer` 837、`openNewShard` 860、`assertWritable` 992）。
- 为什么：事件日志是唯一真相源；本地 O_APPEND + ftruncate 在 Windows 上的回滚不可靠（半行残留），且回滚失败后**继续写**。
- 风险：低-中。整文件替换（本地未改），需确认所有 `append` 调用点能承受"写失败即抛 + 后续全拒"。

### ② 循环看门狗 + 402 告警 —— `src/runtime/real-loop.ts`（依赖 ① 的 `onAppend`）
- 落点：`DEFAULT_TICK_STUCK_MS`(248)、`deps.tickStuckMs`(1534)、字段(1768-1780)、ctor(2203)、`start()` 订阅(2261-2267)、402(2950-2956)、`noteTickProgress`(3030)、`armTickWatchdog`(3039-3113)、`tick()` 的 arm/clear/finally。
- 为什么：长 turn 卡死目前没有任何主动信号；"她突然不说话"这类投诉的直接止血点。
- 风险：中。本地 `real-loop.ts` 已自研 +293 行，必须逐 hunk 搬；`tick()` 的 `finally` 里要同时保留本地 `tickInFlight=false` 与 `runtime/slow-tick` 记账。

### ③ 鉴权并发竞态 —— `src/web/auth.ts`
- 落点：`setup()`(401-415)、`verify()`(454)、`changePassword()`(507/520)。
- 为什么：安全正确性；scrypt 的 await 窗口内可双写、可签旧代际票。
- 风险：极低。纯加法、本地零冲突。

### ④ 小补丁包（4 个独立小件，可各开一 PR）
1. `src/process/kill-tree.ts`：`taskkill` 加 `timeout: 2_000`，且只有 `taskkillCode === 0 && error === undefined` 才提前返回（原来 `forceTree` 下即使 taskkill 失败也返回，进程树杀不掉）。**Windows 上 `spawnSync` 无超时会同步阻塞整个事件循环**——这是 3 行的高价值修复。
2. `src/update/check.ts` + `src/util/bounded-response.ts`：更新清单从 `response.text()` 全量读入再比长度，改为**流式限量**（读前按 `content-length` 预判、超限即 `cancel` 并返回 `too-large`），逐块累计、不缓冲无界响应。
3. `src/update/service.ts`：`generation` 代际，切通道（beta/stable）时 `generation++` 并丢弃在飞的旧结果；`inFlight` 用 `tracked` 自比较清空，避免旧 `finally` 把新请求的 `inFlight` 抹掉。
4. `src/state/snapshot.ts:219`：`rawVersion !== SNAPSHOT_VERSION`（缺失即拒），只改这一行、**不要**跟着升版本号。
- 风险：低。四个文件本地都未改或只改了无关区域。

### ⑤ 通道可靠性两件 —— `src/channel/onebot.ts` 代际守卫 + `src/channel/qq-app-id-guard.ts`
- 落点：`generation` 字段(910)、`start/stop`(997/1002 一带)、`openOnce`(1066-1107)、`scheduleReconnect`(1138-1145)、`fetchSelfId`(1336 一带)；`qq-app-id-guard.ts` 整文件 + `main.ts` QQ 工厂 6 行。
- 为什么：断线重连/通道重启的"旧 socket 复活"竞态是真 bug；双实例同 bot 抢事件是"她有时收到有时没收到"的根因之一。
- 风险：低-中。代际守卫需按本地改过的 `onebot.ts` 手工插 7 处判据（不要整文件覆盖）。

---

## 十五、Top 5 不要碰的地方

1. **`src/affect/` + `src/intimacy/` 内核化（含 `state/*` 版本 2→5、`web/*-view.ts`）**
   - 理由：与本地插件架构正面冲突；状态进入核心投影意味着快照/缓存全部作废一次、`basicProjectionShape` 收紧到"少一格就全量折叠"、replay 依赖收据链；而本地 `emotion.mjs` 已经复刻了公式，收益只有"可重放"这一条，代价是两条线永久同步。
2. **`src/runtime/subagent-*`（13 文件 ≈7000 行）+ 相关 `wake/subagent` / `agentId` / `tools/delegate`**
   - 理由：与 `ARCHITECTURE.md` 的"不做多 Agent 协作"直接冲突（上游自己没改那句）；强耦合 affect/plugin-host/skill-packageRoots/mcp；本地 legacy `task` 链还活着，两套并存会出现两套事件归属。
3. **`src/plugin/market*` + `net-fetch` + `host-services` + `hook-registry` + `devtools` + `scripts/plugin-contract.mjs` / `create-plugin.mjs`**
   - 理由：不是补丁，是第二套插件宿主；`apiVersion: 2` 的字段集两边互斥（本地禁 `runtime/config/meta/net`、上游禁 `adapters/tools/events/views`），硬拼会让本地内置插件全部装不上；`marketEnabled` 默认开还等于给一个默认外联。
4. **`src/channel/greyharbor.ts` + `tools/send-greyharbor.*` + `channels.greyharbor` 配置**
   - 理由：单一游戏服务器的专用通道，本地没有 `characterId` 可配；留着是死代码 + 一个常驻 WS 重连循环。
5. **`src/stickers/*`（约 2000 行内核）+ `speak` 的 `sticker`/`stickerPos` 参数**
   - 理由：本地已有 `linre-stickers` / `linre-meme-photo` 两个插件承担同一职责（选图、打分、发音），再引内核会出现"两套存储 + 两套去重 + 两套主动概率"；`speak` 参数属核心工具契约，改一次冻结前缀。

---

## 十六、风险清单

### 16.1 配置语义
- **`plugins.marketEnabled` 默认 true**：默认开启的对外 GET（`https://irmia.me/plugins/index.json`），与本地"内置种子 + 本地包"的信任模型不同；且注释明确"已装插件不受影响"，容易被误读成总开关。
- **`channels.*.stickers`（默认 false）+ `stickers.groups`（默认 false）双开关**：两个默认关的布尔量控制"群聊能不能发表情"，很容易配了一半（插件在发、通道在拒）。
- **`intimacy.privateOnly` 配 false 直接抛**：好范式，但如果本地的配置写入路径（`withConfigDoc` 回滚）不预期抛错，会让整个 `PATCH /api/config` 尴尬失败——摘配置字段前先确认异常语义。
- **热更白名单 `'intimacy.'` / `'stickers.'` 前缀项**：等于把整段开放热更，与"名单外必须重启"的纪律冲突（见 5.2）。
- **`DEFAULT_MAX_ATTEMPTS` 5→3 / `DEFAULT_REQUEST_TIMEOUT_MS` 120→180s / `VISION_QUERY_TIMEOUT_MS` 10→30s**：三个"看着无害"的数值改动都会改变失败/超时的现场表现，且本地 `test/` 里可能钉着旧值。

### 16.2 数据格式
- `SNAPSHOT_VERSION` / `PROJECTION_CACHE_VERSION` **2 → 5**：跟随 affect/intimacy 形状；**只升版本不接形状 = 所有实例白丢一次全量折叠**。本地若只摘 8.1 的严格判据，`SNAPSHOT_VERSION` 保持 2。
- `step/start` 新增四格（`affect`/`intimacy`/`affectRules`/`intimacyRules`）+ `reasoningEchoMaxChars`：**回放字节依赖它们**；只摘一半（例如抄了 `replay` 的 `reasoningEchoPolicyForReplay` 但运行期不写收据）会让重建请求与当时那份必然不一致。
- `wake/channel.attachments[].fileId`（新字段）：渲染层会给模型看 `file_id: xxx`，但**没有解析工具**时它会把"取不到"读成"她的能力有缺陷"；摘字段必须同时摘 `resolve_attachment`（`tools/admin.ts` + 两个通道的 `resolveAttachment`）。
- `WakeSource` 加 `'subagent'`：类型是加法，但 `recover.ts` 的 `WAKE_TYPES` 白名单、`loop.ts` 的 `describeWake`/`userMessageSourceOf` 三处必须同步。本地 `WAKE_TYPES` 不含 `wake/subagent` ⇒ 崩溃重入队时"查不到原事件"会**直接丢**（`recover.ts` 的注释自己写了 IM 通道当年就是这么丢的），不是降级成手动唤醒。
- `budget/consumed.data` 的 `affectEvaluation/intimacyEvaluation/stickerTagging`：若不摘，但将来本地插件里出现辅助 light 调用，务必自己打标并让 `fold` 跳过 `failStreak`——否则"插件情绪评价失败"会被记成"模型连续失败"，触发失败刹车。

### 16.3 快照/缓存与迁移
- 本地 `dataDir` 与上游 `dataDir` **目录结构不同**（本地 `data/` 下有自己的插件目录与事件内容），互相指向会互相污染；不要拿 beta16 实例的数据目录做本地冒烟。
- 反向兼容尚可：本地 `readRange` 只校验 `seq/ts/type`，未知事件类型进 `fold` 的 default 分支被忽略 ⇒ **用本地代码打开 beta16 日志不会崩**，但 affect/intimacy/sticker/subagent 全部不折（界面表现为"这些数据消失"）。**不要**在这种状态下再写回同一目录（本地会继续追加自己的事件，形成混合日志）。
- `RENDER_VERSION` 86 → 87/88：任何 render 侧摘取都会造成**每个实例一次缓存前缀 miss**（首轮成本明显上升）。要摘就集中一次摘完，不要分三次。

### 16.4 安全/权限面
- 上游 `market` 把"外部代码进入执行面"的路径变成"人看权限 → 确认 → 启用"三步，包从官方静态索引下载；本地没有这条链路，也**没有对应的网络与哈希校验基建**（`net-fetch.ts` 的 SSRF 白名单、`package-store` 的签名/哈希链）。若要引入市场，这些必须一起引入，不能只引入 UI 与索引。
- `web/ingress-sources` 的"每来源独立 token、盘上只存 sha256"是好范式；若本地仍是单一 `webhookSecret`，考虑在**不带任何新功能**的前提下单独升级（低风险，独立收益）。
- `tools/admin.ts` 的 `to` 必填降低了"发错会话"风险；但本地 `send_media` 的路径/媒体校验（`isFetchableAttachmentUrl`、blob 外置）与上游不同，**不要**为了 `to` 必填去整体替换该文件。

### 16.5 需进一步确认（不臆测，留待实测）
1. 本地 `event-log` 换成 `'r+'`/`'wx+'` 后，`scanShard` 的"自愈 + `log/repaired`"路径是否需要同步调整（上游没改那段，但打开模式变了）。**旁证**：本地自愈路径本身就已经用 `openSync(path,'r+')` 再 `ftruncateSync`（`event-log.ts:419-423`），而不是用 `'a'`——同一个文件里"要截断就用 r+"已经是一条既成事实，写路径用 `'a'` 才是那个例外。摘的时候只改写路径，别碰自愈路径（它 `:401` 用 `'a'` 追加换行是刻意的）。
2. 本地 `mcp` 执行器那条门的默认 `timeoutMs` 具体值（若仍是 60s，则 `Math.min` 对齐后**只会更短**，不能照抄 180s）。
3. 本地 `plugins/builtin/linre-affect` 的 `lastSeq` 持久化位置与崩溃语义（决定"重复评价"是否真会发生；`emotion.mjs` 自述靠它去重）。
4. `scripts/render-baseline*.mts` 是否与本地渲染基线测试同源（若同源，摘 `RENDER_VERSION` 相关改动时需要同步更新基线文件）。
5. 本地是否有任何代码假设 MCP 工具超时 `=== DEFAULT_REQUEST_TIMEOUT_MS`（上游曾用"两者同源"的写法，`Math.min` 之后这个等式不再成立）。

---

## 十七、附：一张图看懂"摘什么"

```
src/log/event-log.ts            ✚✚✚✚✚  写路径加固（唯一真相源）        → 摘
src/runtime/real-loop.ts        ✚✚✚✚   看门狗 + 402 告警             → 摘（逐 hunk）
src/web/auth.ts                 ✚✚✚✚   并发改密竞态                 → 摘
src/process/kill-tree.ts        ✚✚✚    taskkill 超时 + 失败不早退    → 摘
src/update/check.ts + util/     ✚✚✚    流式限量                     → 摘
src/update/service.ts           ✚✚✚    通道切换代际                 → 摘
src/state/snapshot.ts:219       ✚✚     缺失版本即拒（1 行）          → 摘
src/channel/onebot.ts           ✚✚✚    重连代际守卫                 → 摘（手搬）
src/channel/qq-app-id-guard.ts  ✚✚     双实例抢 bot 预检            → 摘
src/tools/vision.ts             ✚      视觉超时 10→30s              → 摘（1 行）
src/channel/gif-matrix.ts       ✚✚     GIF 帧矩阵（先修 path-key）   → 选摘
src/mcp/client.ts（常量）        ✚      180s 口径                   → 选摘
src/model/ds-client.ts          ○      重试 5→3                    → 仅参考
src/model/render.ts + self-brief ○○     v87/v88 口径与人格文本       → 不摘
src/runtime/subagent-*          ✖✖✖✖✖  子代理 P1（7000 行）          → 不摘
src/affect + src/intimacy       ✖✖✖✖✖  内核化（与本地插件冲突）      → 不摘
src/stickers/*                  ✖✖✖✖   贴纸内核（本地已插件化）      → 不摘
src/plugin/{market,host,devtool}✖✖✖✖✖  第二套插件宿主               → 不摘
src/channel/greyharbor.ts       ✖✖✖✖   灰港专用通道                 → 不摘
```
