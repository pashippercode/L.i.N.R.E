# 上游 beta13 → beta16 文档层分析

基线 `5e9748a` → `upstream/main` `8fdddf1`。范围：`*.md` 全仓。

## 一、总量：7 万行代码，文档只加了 345 行

| 文件 | 变更 |
|---|---|
| `CHANGELOG.md` | +70 |
| `skills/irmia-framework/SKILL.md` | +261 |
| `ARCHITECTURE.md`（根） | +16 −6 |
| `docs/ARCHITECTURE.md` | +2 −2 |
| 其它 docs/*.md | **0** |

上游这轮新增了插件包、情绪、表情包、亲密层、子代理、灰港、GIF 矩阵、Ingress Bridge（≈7 万行），
**没有配套设计文档**。`docs/` 目录除 ARCHITECTURE 两行外一个字没动。

## 二、上游引用了不存在的文档

beta.15 的 CHANGELOG 写：

> 兼容与废弃规则见 `docs/plugin-compatibility.md`。

实测：

```
git cat-file -e upstream/main:docs/plugin-compatibility.md
fatal: path 'docs/plugin-compatibility.md' does not exist in 'upstream/main'
```

该文件在上游 HEAD 里根本不存在。说明发布前没人核对引用，或文档被删后没改引用。

## 三、本地对照：架构文档已经对齐，不需要同步

| 文档 | 本地 | 上游 | 结论 |
|---|---|---|---|
| `ARCHITECTURE.md`「三、插件平台（P0）」 | **已有**，内容与上游新增段落几乎逐字一致 | 新加 | 不用动 |
| `ARCHITECTURE.md` 其余章节 | 已含 | 未变 | 不用动 |
| `docs/ARCHITECTURE.md` | 已含 | +2 行（多实例 / 热更口径） | 见第四节 |
| `docs/plugin-api-v2.md` | 有（12.1KB） | 无 | 本地更全 |
| `docs/design/plugin-api-v3.md` | 有（16KB） | 无 | 本地更全 |
| `docs/design/plugin-ui-schema.md` | 有（5.8KB） | 无 | 本地更全 |
| `docs/plugin-compatibility.md` | 无 | **也无** | 双方都没有 |

结论：本地文档比上游更完整，没有需要从上游摘的文档。

## 四、`docs/ARCHITECTURE.md` 的两处语义变化（值得知道）

### 4.1 多实例的配置语义（新）

上游新增：

> **多实例下每个实例有自己的 `dataDir` 与 `config.json`**（启动器在 `--spawn-instance` 时从安装根配置播种，
> 重写 `dataDir` 并清空 `channels.mentionKeywords`）；安装根那份只属于默认实例。

对本地的影响：本地 `instances.dart` 目前**没有** `--spawn-instance` / `packaging/launcher.mjs`，
所以这条语义本地不成立。但如果将来做多实例，必须复制这套播种规则（重写 dataDir + 清空 mentionKeywords），
否则两个实例会抢同一个 dataDir。

### 4.2 热更白名单扩容（新）

旧口径：只有 `mcp.servers` 一项热更。
新口径：`mcp.servers` + 情绪/亲密开关 + `stickers.*` / `channels.*.stickers`。

对本地的影响：本地是旧口径（1 项）。本地情绪走 `linre-affect` 插件，**不需要**跟这个扩容 ——
插件开关本来就由插件管理器管。

### 4.3 `intimacy` 是独立于情绪的字段（新）

新口径明确写进「数据放在哪」表：

> 状态投影 ... 其中 `intimacy` 是独立于情绪的亲密/情欲字段

对本地的影响：无。本地没有 intimacy 内核，`linre-affect` 插件的情绪是插件自己的数据。

## 五、唯一有阅读价值的增量：`SKILL.md` 的 Ingress Bridge 章节

`skills/irmia-framework/SKILL.md` +261 行，全部是新增的第 12 章「Ingress Bridge（外部事件入口）」：

```
12.1 先分清谁创建来源
12.2 外部脚本怎么投
12.3 三种唤醒策略
12.4 请求字段
12.5 场景示例
12.6 管理 API（用户/本地会话）
12.7 排障
12.8 你自己的边界
12.9 当前限制
```

这是 beta16 `src/web/ingress-sources.ts`（新 194 行）+ `/api/ingress` 的对外契约说明。

**它的价值不在功能（本地 0 命中 `ingress-sources`），而在契约设计**：
「外部事件入口」是一个标准化的端口 —— 外部脚本投事件、三种唤醒策略、字段定义、边界声明。
如果本地将来要把 QQ 以外的来源（webhook、文件、定时器）统一进来，这套契约定式可以直接参考。

**当前不建议摘**：它是配套 `server.ts`（+706）的新 API 面，且本地 `wake` 已有 `timer/file/webhook/manual`
四种来源，能力上不缺。

## 六、CHANGELOG 反推的上游产品面（本地对照）

| 上游 beta14–16 | 本地状态 |
|---|---|
| 插件包（内容寻址、安装即隔离、人工确认） | **已自研**，更彻底（含 adapter/effect/capability） |
| 代码插件（Node/Python 子进程 + 能力白名单） | **已自研**（3 个 adapter-worker） |
| 插件市场 HTTP 读取/安装 | 本地无（用户自述缺「插件仓库发布 + 更新检查」） |
| 情绪系统（六维 + 心境） | **插件实现**（`linre-affect`），上游是内核 |
| 表情包（九标签 + 被动补图 + 静默采收 + pHash） | **插件实现**（`linre-stickers` / `linre-meme-photo`） |
| 亲密/情欲四读数状态机 | 本地无 |
| 子代理（可续聊 P1） | 本地无（且架构声明「不做多 Agent」） |
| 灰港通道 | 本地无（单一游戏专用） |
| GIF 帧矩阵 | 本地无（对表情包插件可能有用） |
| Ingress Bridge | 本地无（能力上不缺） |
| MCP 图片进上下文 | 本地无 |
| 循环看门狗 / 402 告警 | **已摘**（本会话上线） |
| 重试 5 → 3 | 待评估（见未处理台账） |
| 快照版本丢弃重建 | 待评估（`snapshot.ts` 1 行） |

## 七、结论

1. **文档层没有可摘的东西。** 上游这轮是"代码先行"，文档严重滞后，甚至引用了不存在的文件。
2. **本地文档反而更完整**（plugin-api-v2/v3、ui-schema），架构章节已与上游对齐。
3. **唯一值得读的是 SKILL.md 第 12 章 Ingress Bridge** —— 借契约设计，不借实现。
4. `docs/ARCHITECTURE.md` 的两处语义变化只对"将来做多实例 / 做内核化情绪"有意义，当前都不用跟。
5. 上游 CHANGELOG 暴露了一个事实：**beta14 是个大版本**（插件包 + 情绪 + 表情包 + 亲密层），
   但它是按"内核化"路线做的，与本地"插件平台"路线正面分叉 —— 这也解释了为什么 207/211 个新增文件不能要。
