# 本地 Issue Tracker

非 GitHub issue 的常驻问题登记处。**问题现象 / 触发根因 / 修复方案 / 状态**四栏齐全再写进来，不写"以后可能要看看"这种空条目。

状态只有三种：`已解决`、`待跟进`、`已记录（暂不修，写明为什么）`。

---

## LINRE-001 · 前端没有「重试中」提示

**状态**：已解决（2026-11-22，重试那一半；`model/degraded` 那一半见下方"未做"）

### 问题现象

模型调用内部重试期间，界面只有一行「思考中…」，看不出是在正常推理还是在第 N 次退避等待。一次 30 次重试的调用最长可以压到 15 秒/次，界面看起来就是**卡死不动**。

`model/degraded`（连续失败改道发生）同样是 `internal` 可见性，只在终端日志留一行，界面无任何提示——"她卡住了我得知道"这件事，前端一无所得。

### 触发根因

`DsClient.subscribeRetry` 是进程级多播，但只有两个消费者，都不服务界面：

- `src/main.ts:2420` —— 只有对端 `Retry-After` 被封顶时才写一行终端日志，其余情况**什么都不做**。
- `src/runtime/agent-loop.ts:1602` —— 只做 `this.retryCount += 1`，一个整数。

而 `retryCount` 的唯一出口是 `budget/consumed.retryCount`，那是在**调用结束之后**才写的事件。所以重试的整个过程对前端不可见。

另：`stream()` 的重试是**静默**的（`withRetry` 的 `sleep` 走 `defaultSleep`，只是 `setTimeout`），没有任何中间事件。

### 修复方案（已落地）

照仓库既有的正面先例 `step/reasoning-progress` 做，三处：

1. **`src/log/types.ts`** —— 新增 `ModelRetryProgress`（载荷 `turn/step/attempt/delayMs/kind/lane`，**没有错误正文**），登记进 `AppEvent` 联合类型，可见性表里写 `'model/retry-progress': 'internal'`。
2. **`src/runtime/agent-loop.ts`** —— `subscribeRetry` 的回调里除了 `retryCount += 1` 之外调 `reportRetryProgress(info)`。节流：同一 attempt 不重发，且距上一条 ≥`RETRY_PROGRESS_MIN_INTERVAL_MS`（3 秒；比 `step/reasoning-progress` 的 5 秒还长，因为 attempt 自己就会去重）。
3. **`gui/lib/pages/chat_page.dart`** —— `ThinkingProgress` 加 `retryAttempt`/`retryDelayMs` 两格；新增 `model/retry-progress` 分支；`thinkingLine()` 在四格之后**追加**「第 N 次重试 · 等 M 秒」（追加而非替换，因为重试期间她仍在想）。换步与 `message/assistant` 时清除。

文案在 `gui/lib/i18n/app_strings.dart` 的 `retryLine(int attempt, String delay)`，中英双份；`strings_override.dart` 直接转发 base（带参数的量不开放覆盖）。

### 踩到的坑（值得记住）

`ThinkingProgress` 原先的 `operator ==` 只比了 `turn/step/chars/since/phase`。重试事件到来那一刻这五个字段**一个都没变**，于是 `ValueNotifier` 判定"新值和旧的相等"，**既不赋值也不通知** —— 表现极具误导性：`thinkingNow.value = next` 之后立刻读回，拿到的是**旧对象**（`identical` 为 false、`retry` 为 null），看起来像赋值失效。修法是把 `retryAttempt`/`retryDelayMs` 一起算进 `==` 与 `hashCode`。

### 验证

- `test/retry-progress.test.ts`（新增 5 条）：事件必须落地、载荷恰好六个键、同 attempt 不重发、间隔不够被压掉、`internal` 且投影无痕。
- `gui/test/chat_progress_test.dart`（新增 4 条）：重试段出现且四个读数并存、换步不跟过来、成功后立刻撤掉、`turn/end` 收掉。
- 反向验证：把 `==` 里的 retry 两格去掉 ⇒ 前端那 4 条里 2 条变红。
- `tsc --noEmit` 与 `flutter analyze` 均干净；后端全量 3545 条里 3517 过、23 条为既有失败（改动前后一致）。

### 未做

`model/degraded`（改道发生那一刻）仍然只在终端日志留一行，界面无提示。它与 LINRE-002 是同一条链上的两件事：A 修好之后改道真的会发生，但发生的那一刻人还是看不见。要接的话同样照 `model/retry-progress` 这条路的形状做。

---

## LINRE-002 · heavy 降级不生效（stream 路径失败不计入连续失败计数）

**状态**：已解决（2026-11-22）

### 问题现象

备用路由（`models.degraded`）配置齐全、启动日志也打印了，但 heavy 主循环从来不触发改道。运行日志里三条 `model/degraded` **全部是 `lane: light`**，heavy 零条。

### 触发根因

两个独立的坑，A 是 heavy 的直接死因：

**A. `stream()` 的失败不计入降级计数。** `stream()` 在拿到响应头时就调 `noteSuccess()`，把 `failureAttempts` 清零；随后如果 2xx 但一个 SSE 帧都没收到，`pump` 返回 `interrupted`，而 `resendOnNoOutput` 因 `laneForced`（显式 `chat-completions` 档）返回 null，于是 `stream()` **正常返回**这个结果、**不抛错** ⇒ 进不了 `catch` ⇒ `trackFailure` / `noteRouteFailure` 一次都不执行 ⇒ 降级计数永远 0。

**B. 改道后 model 名没换。** `stream()` / `generate()` 都写 `request.model ?? this.modelFor(lane)`，而 `agent-loop` 的 `toDsRequest` **总是**带 `rendered.model`（`render.ts:3357`、`agent-loop.ts:1799` 在改道前就固定了）。改道后打到备用端点的是主路由的模型名。

### 修复方案

A 已修（`src/model/ds-client.ts`）：

- `noteSuccess()` 从「收到响应头」挪到「确认正常收尾之后」，由新增的 `noteDelivered()` 在 `pump` 之后统一结算成功/失败。
- 零内容失败计入 `noteRouteFailure`。
- 语义边界守住：调用方拿到的**仍是 `interrupted` 结果而不是异常**（已交付增量不可重放），失败判据仍只有 `DsStreamResult.failure`；`aborted` 不算失败。

验证：`test/route-failover.test.ts` 新增回归用例「stream 的零内容失败计入连续失败」，摘掉修复那行即变红；端到端改前 5 次全打主路由、改后第 3 次改道。

B **未修**。

### 待办

- B 那个坑还在：改道后 model 名仍是主路由的。修法方向是让 `modelFor()` 的改道结论能覆盖 `request.model`（`toDsRequest` 那条路要跟着改），但这会动到请求字节与缓存前缀，要单独评估。
- 本机 8000 端口的 heavy 代理已停，所以 heavy 现在每次都失败——这是环境现状，不是代码问题。

---

## LINRE-003 · 她这一轮失败时界面一个字都不说（「跑过了没反应」）

**状态**：已解决（2026-11-22）

### 问题现象

用户 2026-11-21 报「跑过了但是没反应」。查下去发现她**一直在失败**：那两小时跑了 7 轮 turn，每轮都是

```
turn/end  {"kind":"error","code":"http_403",
           "message":"请求被拒绝（403）：重试同样的请求必然同样失败（服务端原话：insufficient balance）"}
```

而界面上从头到尾只有「思考中…」出现又消失，**一个字都没解释为什么**。

### 触发根因

`gui/lib/pages/chat_page.dart` 的 `turn/end` 分支只做一件事：`_endThinking()` 收掉那行进度条，`data.reason` 整个字段一个字节都不读。于是

- 「她没能说完」（`kind:'error'`）
- 「她说完了但判断这次不开口」（`kind:'completed', spoke:false`）

在界面上**长得一模一样**——都是那一行消失、然后一段空白。这不是"少一个提示"，是**把一种故障说成了一种事实**。

顺带查清的另外两条（同一个问题链）：

- 那条 `403 insufficient balance` 属于 `invalid`，`RETRYABLE_KINDS` 里没有它 ⇒ `retryable=false` ⇒ **一次都不会重试**。所以 LINRE-001 加的重试提示在这条路径上本来就没有内容可显示，不是它坏了。
- 已装的 GUI 是 11-16 的构建（`gui/data/app.so` 时间戳 2026-11-16 17:09），本轮所有 GUI 改动都还在源码里。要肉眼看到必须先出安装包。

### 修复方案

`gui/lib/pages/chat_page.dart` 新增 `_TurnFailure` 与 `_turnFailureBanner`：

- `turn/end{kind:'error'}` ⇒ 记下最近一次失败（`turn` 单调，防 SSE 补拉旧轮次反超）；
- `turn/end{kind:'completed'}` 或 `message/assistant` ⇒ 清掉（她已经好了就不能继续宣称她坏了）；
- `aborted` / `interrupted` / `blocked` / `incomplete` / `budget-exhausted` / `rate-limited` / `max-tokens` 一律不进——它们要么是人自己掐的，要么各有出口，全报成"坏了"是假话；
- 横幅落在**输入框正上方**（就是「思考中…」刚收掉的那个位置），标题 + 服务端原话（两行截断，完整版在日志）+ 错误码小字，可以自己关掉；
- 服务端没给原因时明说「服务端没给原因」，不自己编一句"网络异常"。

文案走 i18n（`turnFailedTitle` / `turnFailedNoReason`，中英各一份），并补进 `strings_override.dart` 的 `stringsAsMap` 键表——那份是手写清单，`AppStrings` 加了 getter 不补它，`strings_override_test.dart` 的三条棘轮会当场红（本轮踩到）。

### 踩到的坑

- `_trackThinking` 作用域里没有 `ts` 变量（那是 `_consume` 的局部量），要用 `event['ts']`。
- 圆角常量在 `Shape.radiusControl`，不是 `IrmiaTheme.radiusControl`。
- 本机 `flutter analyze` 在这个 shell 里会报 `PowerShell executable not found`，改用 `dart analyze`（Dart SDK 在 `flutter/bin/cache/dart-sdk/bin`）。
- `git-bash` 的 `timeout` 会被 Windows 自带的 `TIMEOUT.EXE` 抢走，必须写 `/usr/bin/timeout`。

### 验证

- `gui/test/chat_progress_test.dart` 新增一组 7 条用例，全文件 47/47 通过。
- 反向验证两次：摘掉布局里那行 ⇒ 6 条红；把 `kind == 'error'` 放宽成 `kind != 'completed'` ⇒ 3 条红（`aborted` 那档自己冒出来）。
- 整套 GUI：945 pass / 14 fail，与 stash 基线逐条比对后**新增 0 条**（11 条基线失败全是旧的：`advice_act` 5、`copy_coverage` 2、`auth_gate` 1、`instance_picker` 1、`widget_test` 1、`strings_override` 1）。
- `dart analyze` 三个改动文件 0 issue。

### 部署

`build-gui.yml` run 44953482214 成功（`windows-2022` / Flutter 3.35.4）。产物已装：

- `%LOCALAPPDATA%\Irmia\Agent\gui\data\app.so` 换成新构建（Dart AOT 里按 UTF-16-LE 搜得到「她这一轮没能说完」，旧那份搜不到）；
- `irmia_gui.exe` 与几个 plugin dll 与旧构建同版本、且被运行中的进程占用，未替换（不替换也不影响：改动全在 `app.so`）；
- 备份在 `~/.config/alma/scratch/gui-bak-20261122/`。

**尚未生效**：GUI 进程（pid 2944）还在跑旧的那份 `app.so`，重启才加载新内容。

### 未做

- **真机验证**：重启 GUI 之后才能看到横幅本身。
- **`model/degraded` 仍未接到界面**（LINRE-001 剩下的那一半），改道那一刻还是只有终端日志。
- **本机 heavy 路由不可用**（另一个问题，不属于本条）：`models.heavy` = `gemini-auto @ http://127.0.0.1:8000/v1`，而 8000 上没有任何监听（绕开 `HTTP_PROXY=127.0.0.1:7890` 直连返回 000）。注意 `curl` 走代理时会拿到一个假的 `502 Bad Gateway`，别拿它当"端点活着但上游挂了"的证据。degenerated 走 `xcmapi.org` 也是 403 insufficient balance（欠费）。当前只有 `light`（yuki）能出话。

## LINRE-004 · 重复的 `tool_call_id` 让她永久说不了话 —— 已解决（2026-11-22）

### 现象

切到 yuki 主路由、重启后端与 GUI 之后，她跑一轮还是不出话。后端事件日志
（`data/events/000000378473.jsonl`，turn 3565）写的是：

```
turn/end { kind: 'error', code: 'http_400',
  message: '请求被拒绝（400）：… 服务端原话：{"error":{"message":"Prefill server error
    (400 Bad Request): … Duplicate value for 'tool_call_id'
    of call_1c1a797d63390afdb8bd1e57 in message[15]"}}' }
```

紧接着 turn 3566 直接 `403 insufficient balance`（改道到了 xcm）。看着像"服务端抽风"，
其实和网络无关。

### 根因

**模型自己在同一个 turn 里把同一个 `call_id` 发了多次**，我们原样记进了日志；那份历史
留在可见区，于是**此后每一轮**的请求都带着重复 id 被拒。

真机读数（turn 3426，`data/events/000000350730.jsonl`，20 次工具调用）：

| 步骤 | callId | 工具 | arguments |
|---|---|---|---|
| 5 | `call_1c1a797d63390afdb8bd1e57` | `todo` | sha256 `3d7bec04…` |
| 10 | `call_1c1a797d63390afdb8bd1e57` | `todo` | sha256 `3d7bec04…`（逐字节相同） |
| 15 / 16 / 19 | `call_c595353a3755177c338a43cc` | `speak` | 三次都是 sha256 `e0e7032b…` |

为什么是"永久"：`400` 属 `invalid` kind ⇒ `retryable === false` ⇒ **不重试**；连"改道"也
救不了（改道目标是欠费的 xcm）。所以这不是一次失败，是一条把所有后续轮次一起堵死的死路。

### 修复方案

只能改渲染这一侧——**铁律 2（历史只可遮蔽、不可改写）不许回头改日志**，而服务端硬规则是
"一次请求里 `call_id` 唯一"（Chat 与 Responses 同一条）。

`src/model/render.ts`：

- 新增 `renderedCallId`（`tool/call` 的 seq → 渲染用的 call_id）：同一个 id 第 2、3… 次出现时
  加确定性后缀 `#N`；**第一次出现保持原样** ⇒ 没受影响的日志逐字节不变；
- 配对键从 `callId` 换成 **`tool/result.callSeq`**（它精确指向那一次 `tool/call` 的 seq）：
  `callId` 一重复，光凭它就分不清回执属于哪一次（三条 speak 会全部配到最后一条）。
  老日志缺 `callSeq` 时退回按 `callId` 找；
- `function_call` 与它的 `function_call_output` **同步改名**，配对完整性不受影响；
- `RENDER_VERSION` 89 → 90（请求体形状确实变了，照例递增一次）。

### 踩到的坑

- **反向验证时"只修一半"才是有价值的那一半**：只把 id 改名、回执仍按原 `callId` 登记，
  ①（无重复 id）和②（配对齐全）都会**绿**，只有③（各自配到自己那条回执）会红。
  所以夹具里必须给每次调用**内容不同**的回执——真机上那两条回执逐字节相同，照抄真机的话
  测不出错配。
- 回执正文外面套着 `renderToolOutput` 的模板（工具名/状态/纪律三段），断言不能写等值，
  要按"含"判。
- "重复"这个判据要在 `function_call` **内部**数：一次调用天然贡献两条同 id 的 item
  （call + output），把两类混起来数会把正常日志也判成重复。

### 验证

- `test/tool-call-id-unique.test.ts` 新增 7 条用例（清 7/7）；夹具照 turn 3426 的真实形状
  （step 5/10 重复 + step 15/16/19 三次重复）。
- 反向验证两次：退回 v89 行为（不加后缀）⇒ ①⑥ 红；只改名不改配对 ⇒ ③ 红。
- 渲染相关四套（`render` / `reasoning-shape` / `protocol-bytes` / `tool-call-id-unique`）
  178/178 通过；`tsc --noEmit` 干净。

### 顺带做掉的（本轮同批）

- **heavy 切到 yuki**：`gemini-auto @ 127.0.0.1:8000` 那个网关在本机**没有监听**（直连返回
  000，走代理时那个 `502` 是代理自己的回包），xcm 备用也是 403 欠费。`models.heavy` 改成
  `deepseek-v4.1-flash @ https://cli.yukira1n.com/v1`（与 light 同一条），启动日志已确认
  `heavy=deepseek-v4.1-flash @ https://cli.yukira1n.com/v1`。
- **运行实例读的是 `%LOCALAPPDATA%\Irmia\Agent\config.json`**，不是仓库 `config.json` ——
  改模型路由必须改那一份（本轮先改了仓库那份，白改一次）。
- GUI 已重启（新 pid），加载了含失败横幅的 `app.so`。

### 未做

- **`#N` 后缀只是让请求能发出去**：它不改写历史，所以日志里那两次重复调用仍然是两次
  （她会看到自己"发了两遍同样的话"）。要不要在源头（`agent-loop` 收响应时）就重编 id，
  是另一个决定——那会动到"日志即事实"这条边界，需要单独评估。
- `model/degraded` 仍未接到界面（LINRE-001 剩下的那一半）。

### 真机验收（2026-11-22 06:43，turn 3567）

修复部署并重启后她自己跑完了一整轮，这是 11-19 以来第一次：

```
turn/start 3567 → read_channel → read_channel → speak（3 条 speak/sent）
              → plugin__linre-ambient__peek_host → pwsh → speak（3 条 speak/sent）
              → turn/end {"kind": "completed"}
```

对照：同一份历史在旧渲染器下渲染出 2 处重复 id（`call_1c1a797d…` ×2、`call_c595353a…` ×3），
新渲染器 0 处、43 次调用配对齐全（378,586 条真实事件，脚本 `~/.config/alma/scratch/verify-dup.mjs`）。
