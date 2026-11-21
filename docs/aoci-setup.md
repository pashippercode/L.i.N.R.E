# AOCI 接入说明

AOCI 是本仓库的**仓库级认知索引**：一份机器可校验、可增量维护的代码地图，Agent 读它拿到"这个仓库长什么样、哪个文件负责什么、边界在哪"，而不必每次从零扫全仓。

索引本体是仓库根的 `aoci.txt` / `aoci.meta.txt` / `aoci.code.txt`，由 `aoci` 校验、绑定与记账；语义由模型读源码后逐条写进去。

---

## 配置为什么是通用的

`.mcp.json` 与 `.codex/config.toml` **不含任何机器路径**，且已入库：

```json
{ "mcpServers": { "aoci": { "command": "aoci", "args": ["mcp"] } } }
```

成立的前提只有一条：`aoci` 在 PATH 上。

**为什么不需要 `--repo`**：`aoci` 不带 `--repo` 时会**从 cwd 往上自动发现仓库**（认 `aoci.txt`）。从仓库根、或 `src/` 这类任意子目录启动都落到同一个仓库，所以配置里不该写绝对路径——写了就绑死在一台机器上，换人 clone 就废。

> 历史教训：`aoci init --agent all` 生成的 `.mcp.json` 会把当前机器的绝对路径写进 `args`，并把文件塞进 `.gitignore`。那份配置**只能在这台机器上用**。改成上面的形态后才叫"仓库通用"。

---

## 新机器上怎么接

1. 把 `aoci` 放到 PATH 上。本机的做法是 `C:\Users\admin\Documents\_tools\aoci` 加进 User 作用域的 `Path`：

   ```powershell
   [Environment]::SetEnvironmentVariable('Path',
     [Environment]::GetEnvironmentVariable('Path','User').TrimEnd(';') + ';C:\Users\admin\Documents\_tools\aoci',
     'User')
   ```

   改完**要开新 shell**（正在跑的进程继承的是旧环境）。

2. 验证：

   ```bash
   cd <repo> && aoci status
   ```

   期望第一行是 `Repository <本仓库绝对路径>`、且有 `Index Entries` / `Baseline` 两行。

3. Agent 侧无需额外配置——`.mcp.json`（Alma / Claude Code / Cursor）与 `.codex/config.toml`（Codex）都在仓库里。Codex 首次打开本仓库会问一次信任，批准即可。

---

## 当前状态与维护

```bash
aoci status              # 条目数 / 基线 / 治理状态，一眼看缺什么
aoci index agent guide   # 当前该做什么（stage / next_action）
aoci scan                # 重建基线指纹（改了文件但没动语义时用）
aoci verify              # 列出未索引的文件与被判 stale 的条目
```

写条目的两条路：

- **MCP 工具**（`aoci_update_entry` / `aoci_maintain`）—— Agent 会话里的常规路径，走完整批次校验与原子 Apply。
- **CLI**（`aoci update-entry --repo . --path <file> --entry "<FRAS>" --source-sha256 <sha>`）—— 单条、可 `--preview` 先看 diff。`--source-sha256` 可省略：不给时由服务端从已发布的批次里取。

条目格式是单行 FRAS：`文件名[TAG]: F:职责 | R:依赖 | A:关键符号 | S:非显然但重要的约束`。

**字段长度有硬上限**（实测）：`F` ≤ 160 字符（含 `F:` 前缀）、`S` ≤ 200 字符。超了报的是 `impact_candidate_fras_invalid`——那个错名看起来像索引结构问题，实际只是某一格太长。

---

## 现状

- 基线：934 个文件指纹。
- 已写条目：16 条，集中在**模型调用链**（`src/model/**` 全部 14 个文件 + `src/main.ts` + `src/runtime/agent-loop.ts`）。
- 待写：约 489 个文件，按场景按需补，不必一次写完。
