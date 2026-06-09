# mcMemory v3.0 架构升级指导

> **版本目标**：从"基于 Bash 脚本的文件型记忆系统"演进为"具备语义检索、可观测性、可扩展存储后端的记忆中间件"
> **撰写日期**：2026-06-09
> **基线版本**：v2.4（10 个 P0+P1 commit 后的工作树）
> **预计开发周期**：4-6 周

---

## 0. TL;DR

v2.x 在"能用、不崩"上已经收敛（48 项测试 + P0/P1 全清）。但作为面向 AI 长期共生的记忆系统，仍有 **5 个架构级缺陷** 阻挡它走向"真正智能"：

| # | 缺陷 | 当前症状 | v3.0 目标 |
|---|------|----------|-----------|
| A1 | **关键词检索天花板** | bigram + BM25 在中文长尾仍误召回；同义词、概念簇全无 | 向量召回 + BM25 混合（hybrid search） |
| A2 | **AI 浓缩流程半人工** | 占位 chunk 需 AI 手动 Read+Edit；漏掉就成"死内存" | 异步浓缩 worker + 元数据驱动状态机 |
| A3 | **数据层单点 = 文件树** | 锁/原子写靠 flock+mv；扩展到多主机/多 Claude 实例无解 | 抽象 `StorageBackend`，默认文件，可选 SQLite/Redis |
| A4 | **可观测性只覆盖 inject** | sync/init/delete 全无指标；性能回归无法量化 | 统一事件总线 + `mcmMetrics` 命令 |
| A5 | **测试只测纯函数** | hook 路径、并发、超大数据集无覆盖；P0 真因链全部是集成 bug | 分层测试（unit / integration / soak） |

此外还有 **8 个中等问题**（B 类）和 **6 个轻量优化**（C 类），见 §3。

---

## 1. 现状架构盘点

### 1.1 物理结构

```
~/.claude/mcMemories/                  ← MEMORY_BASE
├── projects/<tag>/<name>/             ← 项目记忆（按 git root basename 绑定）
│   ├── summary.md          (L1)
│   ├── index.md            (L2)
│   ├── chunks/*.md         (L3) ← YAML frontmatter + Markdown
│   ├── .claude/            (L4) ← 相对路径 symlink/.source 回指源文件
│   └── hash.json           ← workspace-relative path → {hash, mtime}
├── global/<mode>/<name>/              ← 个人记忆（mode = auto | on_demand | ...）
├── .search_index                      ← 单文件合并索引，delimiter-separated
├── .inject_state/*.last               ← 冷却时间戳
├── .inject_log                        ← v2.4 注入事件流
├── .paused_until                      ← v2.4 暂停标记
├── .trash/<name>_<timestamp>_<rand>/  ← 软删除
└── .locks/                            ← flock 文件锁
```

### 1.2 控制流

```
                       ┌─────────────┐
SessionStart  ────────▶│ inject.sh   │──load L1+auto L3──▶ context
                       │ (hook)      │
UserPromptSubmit ─────▶│             │──BM25(top3) ────────▶ context
                       └──────┬──────┘
                              │
                              ▼
PreCompact ───────▶ precompact_save ──read session_notes──▶ L3 chunk + index

                       ┌─────────────┐
mcm* CLI ─────────────▶│ command.sh  │──flock──▶ mutate files ──▶ atomic mv index
                       └─────────────┘
```

### 1.3 代码体量

```
lib/core.sh        1038 行 (43 函数)   ← 已逼近"单文件可维护"的红线
lib/inject.sh       566 行 (11 函数)
commands/*.sh      2400 行 (15 命令)
hooks/*.sh          153 行 (3 hook)
tests/test_core.sh  612 行 (48 断言)
────────────────────────────────────
                  ~5400 行
```

### 1.4 数据规模假设

设计时（v2.0）的隐含假设：
- 项目记忆数 ≤ 50
- 每项目 chunks ≤ 100
- 单 chunk ≤ 200 行
- 索引文件 ≤ 5 MB
- 单次 sync ≤ 30 文件

**实际数据**（开发机当前）：21 chunks / 22 KB 索引 / 2 项目 — 远未触达上限。
**v3.0 目标规模**：项目 ≥ 500、chunks ≥ 10000、索引 ≥ 100 MB、并发 ≥ 5 实例。

---

## 2. 五大架构级缺陷（A 类）

### A1. 关键词检索是天花板

**现状**：v2.4 已升级到 BM25，但 token 提取仍是 `[一-鿿]+ → bigram` 启发式。

**根本缺陷**：

1. **同义词不可达**：用户问"如何加锁"，记忆里写的是"flock 实现"，永远不会命中。
2. **概念簇丢失**：`auto-inject`、`session-start`、`prompt-submit` 是同一概念簇，BM25 把它们当独立 term。
3. **bigram 噪声**：`"如何使用 mcMemory"` 切出 `如何/何使/使用/用mc`…等 7 个 bigram，4 个是噪声，污染 IDF 计算。
4. **跨语言失效**：`"BM25 评分"` 在记忆里写作 `"相关性算法"`，零交集。

**v3.0 方案**：**Hybrid Search（BM25 + 向量）**

```
                    ┌──── BM25  (现有)  ──┐
query → tokenize ───┤                      ├── RRF 融合 → top-N
                    └──── 向量  (新增)   ──┘
                              ▲
                              │
                    ┌─────────┴─────────┐
                    │ embed cache (NEW) │
                    │ .embed/<chunk>.npy│
                    └───────────────────┘
```

**实现要点**：

- **嵌入模型**：默认调用 `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`（278 MB，CPU 可跑，中英双语）。检测 Python `sentence_transformers` 是否安装，没装则降级到纯 BM25 — 保持 Bash skill 的"零依赖"承诺。
- **离线嵌入**：`mcmSync` 在生成 chunk 后调用 `embed_chunks()`，结果存 `<memory_path>/.embed/<chunk_basename>.npy`（每文件一个 384 维 float32 = 1.5 KB）。
- **在线检索**：`find_relevant_memories_hybrid()` 对 query 现算 embedding，与所有 chunk embedding 算余弦，取 top-K；并行跑 BM25；用 **Reciprocal Rank Fusion**（`score = Σ 1/(60+rank)`）合并。
- **回退路径**：embedding 文件缺失（旧记忆未升级）→ 仅 BM25。
- **性能预算**：100 chunks 余弦搜索 < 20 ms（numpy 向量化）；query embedding 首次启动 ~300 ms，后续走 daemon 缓存（见 A2）。

**风险与对策**：
- *风险*：sentence-transformers 启动慢，hook 路径会超时
- *对策*：常驻 `mcmd` daemon（A2）持有模型；hook 通过 UNIX socket 发请求，命中 < 10 ms

---

### A2. AI 浓缩流程依赖人工触发

**现状**：

```
mcmSync 生成 chunks/X.md（含 [待AI补充] 占位）
    ↓
    （AI 在某次对话中读到 mcmStatus 提示）
    ↓
AI 手动: Read source_file → Edit chunk
```

**根本缺陷**：

1. **悬空内存**：占位 chunk 进了搜索索引但内容是占位符。v2.4 注入层做了 `is_placeholder_chunk` 过滤，但搜索/list/load 依然把它当"已就绪"。
2. **触发不可控**：用户不主动开会话、AI 不主动读 status，占位就永远是占位。开发机当前 21 chunk 里 1 个仍是占位。
3. **批量浓缩低效**：100 个占位需要 100 次 Read+Edit；AI 上下文窗口塞不下。
4. **无质量门**：AI 浓缩出来的内容长度/结构无校验，可能比原文还长。

**v3.0 方案**：**异步浓缩 worker + 状态机**

```
chunk.frontmatter.status:
  ├── raw          ← 刚切出的原文段（不进索引）
  ├── pending      ← 已入队待浓缩（不进索引）
  ├── condensing   ← worker 正在调用 API
  ├── ready        ← 浓缩完成，进入索引
  └── failed       ← API 失败 N 次，标红待人工
```

**两种 worker 实现**：

| 模式 | 触发 | API 来源 | 适用场景 |
|------|------|----------|----------|
| **inline** | `mcmSync --condense` | 用户的 ANTHROPIC_API_KEY（独立调用） | 单机用户，偶尔批量 |
| **daemon** | `mcmd` 后台进程 | 同上 + 复用 embedding 模型 | 长期使用、多项目 |

**inline 模式（v3.0 必做）**：

```bash
mcmSync                    # 同 v2.x，生成 status=pending 占位
mcmSync --condense         # 生成后立即同步浓缩（阻塞）
mcmSync --condense=async   # 后台 nohup 浓缩（不阻塞）
mcmCondense --all          # 单独浓缩所有 pending
mcmCondense --memory NAME  # 浓缩指定记忆
mcmCondense --retry-failed # 重试 failed 状态
```

实现：用 `claude` CLI（或 `curl` 直调 Anthropic API）+ 模板 prompt：
```
读取以下源文件，生成 10-30% 长度的浓缩版本，保留所有 API/决策/配置。
不要说明任何元信息，直接输出浓缩内容。
---
$(cat $source_file)
```

**daemon 模式（v3.1 可选）**：见 §4 路线图。

**质量门**：浓缩输出长度必须 ∈ [原文 ×0.05, 原文 ×0.5]；超界标 `failed`。

---

### A3. 数据层是单点文件树

**现状**：所有状态散落在 `~/.claude/mcMemories/` 下，靠 `flock` 串行化。

**根本缺陷**：

1. **跨主机失败**：synced via Dropbox/iCloud 时，`.search_index` 经常被同步冲突文件污染（`.search_index (conflicted copy).md`）。
2. **多 Claude 实例**：用户开 3 个 Claude Code 窗口同时 sync 不同项目 → flock 串行化导致最慢窗口卡 30 s。
3. **索引重建成本**：当前 22 KB 没问题；到 100 MB 时 `rebuild_search_index` 单线程扫描 + 临时文件 + mv 会成 sync 路径的瓶颈。
4. **查询表达力弱**：想问"所有 30 天内 sync 过的项目"必须 shell glob + stat 遍历，没有 `WHERE updated_at > ...`。
5. **数据完整性弱**：chunk frontmatter 损坏后无 schema 校验；hash.json 半写状态恢复靠运气。

**v3.0 方案**：**抽象 `StorageBackend` 接口 + 默认文件后端 + 可选 SQLite 后端**

```
lib/storage/
├── interface.sh          ← 定义 storage_get/put/list/lock/search 等
├── file_backend.sh       ← 现有实现（默认，零依赖）
└── sqlite_backend.sh     ← v3.0 新增（依赖 sqlite3 CLI）
```

**接口契约**（示例 6 个核心调用）：

```
storage_init                              # 创建/迁移 schema
storage_put_chunk MEM CHUNK_NAME PATH     # 存一个 chunk
storage_get_chunk MEM CHUNK_NAME          # 取内容
storage_list_memories [--tag] [--global]  # 枚举
storage_search QUERY [--limit N]          # 返回 chunk 引用列表
storage_lock SCOPE                        # 加锁（scope = memory|global）
```

**SQLite schema**（极简，全在一个文件 `~/.claude/mcMemories/mcm.db`）：

```sql
CREATE TABLE memories (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  scope TEXT NOT NULL,      -- 'project' | 'global'
  tag  TEXT NOT NULL,
  description TEXT,
  created_at INTEGER, updated_at INTEGER,
  UNIQUE (name, scope)
);

CREATE TABLE chunks (
  id INTEGER PRIMARY KEY,
  memory_id INTEGER REFERENCES memories(id) ON DELETE CASCADE,
  chunk_name TEXT NOT NULL,
  source_file TEXT,          -- 相对路径
  content TEXT,              -- 浓缩内容
  raw_content TEXT,          -- 原文（可选，做 diff）
  status TEXT NOT NULL,      -- raw|pending|condensing|ready|failed
  source_hash TEXT,
  embed BLOB,                -- numpy bytes
  updated_at INTEGER,
  UNIQUE (memory_id, chunk_name)
);

CREATE VIRTUAL TABLE chunks_fts USING fts5(
  content, raw_content,
  content='chunks', content_rowid='id'
);

CREATE TABLE inject_log (
  ts INTEGER, event TEXT, memory TEXT, score REAL, keywords TEXT
);
```

**收益**：
- FTS5 提供原生倒排索引，搜索从 O(N 行扫描) → O(log N) ✓
- 事务保证原子性（替代 flock + tmp+mv 组合拳）✓
- BLOB 列直接存 embedding，省去 .embed 目录 ✓
- `sqlite3 mcm.db ".dump"` 一键备份/迁移 ✓

**迁移策略**：
1. v3.0.0 发布时 `mcmMigrate --to sqlite` 命令，把现有文件树灌入 SQLite
2. 默认仍是 file backend，用户显式 `mcmConfig set backend sqlite` 切换
3. 保留 2 个版本（v3.0/v3.1）双后端共存，v3.2 删掉 file backend 或仅作只读
4. .source 链接、.trash 等"非索引数据"仍在文件系统（SQLite 不适合存大文件）

**风险**：
- *风险*：用户已经习惯了 `cat ~/.claude/mcMemories/projects/xxx/chunks/yyy.md`
- *对策*：提供 `mcmExport --as files <dir>` 随时导出回文件树；SKILL.md 强调"内部表示，请用 mcm* 命令访问"

---

### A4. 可观测性只覆盖 inject

**现状**：v2.4 加了 `.inject_log` 和 `mcmInjectLog`，但 `mcmSync` 跑 5 分钟、`mcmInit` 失败一半、`mcmDelete` 误删都无任何日志。

**根本缺陷**：

1. **性能回归不可见**：v2.3 → v2.4 的 BM25 改造若不慎写差，没有 baseline 比对。
2. **错误模式无沉淀**：用户报 bug 时无法说"sync 跑了多久卡在哪一步"。
3. **使用模式无统计**：哪些记忆从未被注入？哪些 chunk 永远 cooldown？没法基于真实数据收敛策略。

**v3.0 方案**：**统一事件总线 + `mcmMetrics`**

```
lib/events.sh:
  emit_event TYPE KEY=val KEY=val   ← 单一入口
                ↓
            ~/.claude/mcMemories/.events.ndjson
                ↓
       mcmMetrics [--last 24h] [--type sync|inject|condense]
```

**事件类型**（最小集）：

| Type | 字段 | 触发点 |
|------|------|--------|
| `cmd.start` | cmd, args_hash, ts | 每个命令脚本入口 |
| `cmd.end`   | cmd, duration_ms, exit_code | 出口（trap EXIT） |
| `sync.scan` | memory, files_total, files_changed, duration_ms | sync.sh |
| `chunk.condense` | memory, chunk, status, in_tokens, out_tokens, model | condense worker |
| `inject` | event, memory, score, kw_count | 已有，迁入 events.ndjson |
| `error` | cmd, err_msg, stack | error() helper |

**实现**：单行 NDJSON 追加（POSIX `< 4096` 字节 write 原子）；老朋友 `mcmInjectLog` 改为 `mcmMetrics --type inject` 的语法糖以兼容。

**`mcmMetrics` 输出示例**：
```
$ mcmMetrics --last 24h --summary

Cmd            Count  P50ms  P95ms  Errors
mcmSync           12    340    920       0
mcmSearch         87     45     78       0
mcmInit            1   3200   3200       0

Inject hits   124  (paused 2, no-match 56, cooldown 38, success 28)

Top condensed memories (last 24h):
  my-claude-memory   5 chunks  avg 4.2k→1.1k tokens
```

---

### A5. 测试只测纯函数

**现状**：48 项断言全是 `lib/core.sh` 的纯函数；hook、并发、超大数据、网络（condense API）零覆盖。本轮 P0 的真因链（中文 token、score 二次过滤、超时、TOCTOU）**没有一个**被现有测试拦住。

**根本缺陷**：

1. **集成 bug 必逃测**：任何"两个函数组合起来出问题"的 bug 都进不了 CI。
2. **性能回归无 benchmark**：BM25 改造前后没有自动化对比。
3. **并发场景全靠手测**：3.3 TOCTOU 修了但没自动化验证再次回归。

**v3.0 方案**：**分层测试 + benchmark gate**

```
tests/
├── unit/                ← 现有 612 行迁入这里
│   └── test_core.sh
├── integration/         ← v3.0 新增
│   ├── test_hook_e2e.sh        ← 模拟 hook stdin/stdout
│   ├── test_inject_chain.sh    ← keyword→find→score→inject 全链路
│   ├── test_sync_idempotent.sh ← sync→sync 应无变更
│   └── test_doctor_migrate.sh  ← 脏数据 → fix → 干净
├── soak/                ← 慢测试，CI 周跑
│   ├── test_concurrent.sh      ← 10 sync × 100 inject 并发
│   ├── test_large_index.sh     ← 生成 10k chunks 测搜索延迟
│   └── test_corrupt_recovery.sh← 索引半写、hash 损坏的恢复
└── bench/               ← 性能门禁
    ├── bench_inject.sh         ← 20 keywords inject 必须 < 100 ms
    ├── bench_sync.sh           ← 100 file sync 必须 < 5 s
    └── baseline.json           ← P50/P95 历史值，每次回归比对
```

**关键约束**：
- unit 必须 < 5 s 总时间（开发机每次保存触发）
- integration < 30 s（git push 前触发）
- soak < 5 min（CI 每日触发）
- bench 比 baseline 慢 > 20% → 失败

**首批必写的 integration 测试**（拦本轮 P0）：

```
test_inject_chain.sh:
  - 给定空索引 → inject 输出空，不崩
  - 给定中文 prompt + 中文 chunk → inject 命中
  - 给定占位 chunk only → inject 输出"待补充"提示
  - pause 后注入跳过 + 日志记 paused

test_sync_idempotent.sh:
  - mcmInit → 索引行数 N
  - 立即 mcmSync → 索引行数仍 N，hash.json 不变
  - 改一个源文件 → mcmSync 仅那个 chunk 更新

test_concurrent.sh:
  - 启 10 个 sync 同一记忆 → 至多 1 个进入临界区，其余等待，无 corrupt
  - sync 进行中并发 inject → inject 读到一致索引（旧版或新版，不撕裂）
```

---

## 3. 中等问题（B 类，可单独 PR）

### B1. `lib/core.sh` 已达 1038 行 — 切割时机已到

**问题**：43 个函数挤在一个文件，PR diff 难审、新人难找入口。

**方案**：按职责切分
```
lib/
├── core.sh          ← 通用：log/error/usage/path/hash/python_call
├── lock.sh          ← acquire/release_lock, lock-state inspector
├── storage_file.sh  ← 当前的 build_hash_json / batch_update_chunk / search index
├── memory.sh        ← create_project_structure / find_memory_path / generate_summary
├── trash.sh         ← move_to_trash / restore / empty
└── inject.sh        ← 不变
```

切分时**保留 `source lib/core.sh` 兼容**：让 core.sh 反向 source 其他文件，老脚本零改动。

### B2. `find_project_memory_dir` 假设"项目名 = git root basename"

**问题**：上轮调试时已发现：`mcmInit --name FOO` 后 `find_project_memory_dir` 找不到。precompact 在自定义命名场景下静默失效。

**方案**：在项目记忆内写一个 `.binding` 文件，记录所有绑定的 workspace 路径（绝对路径）；`find_project_memory_dir` 反向查找。

```
~/.claude/mcMemories/projects/tools/my-claude-memory/
  └── .binding   ← 一行一个 absolute path
```

`mcmInit` 自动写当前 workspace；`mcmBind <name> <path>` 显式补绑。

### B3. `INJECT_COOLDOWN_SEC=120` 是硬编码全局值

**问题**：用户问 5 次相关问题时，第 2-5 次都被冷却跳过，体感"hook 不工作"。

**方案**：
- 改为 per-memory 冷却（已是文件粒度）
- 暴露 `MCM_INJECT_COOLDOWN_SEC` 环境变量
- `mcmAutoInject status` 显示当前值
- v3.0 进一步：冷却长度按 score 反比缩放（高分相关，冷却短）

### B4. `precompact_save` 依赖 `find_project_memory_dir` 即 B2 的同一 bug

**问题**：自定义命名项目 PreCompact 静默失败，用户笔记永久丢失。

**方案**：B2 修完即解。同时 precompact_save 失败时**不要清空** session_notes.md，写一行 `[PreCompact failed: <reason>]` 到 `.precompact_errors` 让用户可见。

### B5. `mcmSearch` 与 `find_relevant_memories` 两套搜索路径

**问题**：两套代码、两套 BM25 调参、两套排序逻辑，长期会漂移。

**方案**：v3.0 抽统一的 `lib/search.sh`，提供 `search_chunks QUERY [--mode bm25|vector|hybrid]`，两个调用方都用它。

### B6. `mcmDoctor` 检查项太薄

**当前**仅检测脏 tag 目录 + 占位计数。**应加**：
- chunk frontmatter schema 校验（缺字段、坏 YAML）
- L4 链接断裂（symlink 指向不存在源文件）
- hash.json 与实际文件 hash 漂移
- search_index 与 chunks 不一致
- trash 中 > 30 天的条目（提示清理）
- inject_log 异常模式（连续 100 条 paused）

`mcmDoctor --json` 输出供 CI 消费。

### B7. 全局变量散落

**问题**：`MEMORY_BASE / PROJECTS_DIR / SEARCH_INDEX / INJECT_*` 大量散落在 lib/inject.sh 顶层 `source` 时执行的赋值。容易在 hook 重新 source 时被覆盖意外环境。

**方案**：聚合到 `lib/config.sh`，所有变量带 `MCM_` 前缀；废弃裸名（向下兼容期 1 个版本）。

### B8. 错误信息无 actionable hint

**当前**：`error "记忆已存在"` — 用户不知该怎么办。
**目标**：
```
error "记忆 'foo' 已存在 (tools 标签下)
  → 查看现有: mcmList foo
  → 强制重建: mcmInit --force"
```
所有 `error()` 调用统一审查。

---

## 4. 轻量优化（C 类）

| # | 项 | 一句话 |
|---|----|--------|
| C1 | `MEMORY.md` 索引文件 | 给 mcm 系统本身写一个 README-of-readmes，AI 看 1 个文件知全貌 |
| C2 | `mcmDiff <name>` | 显示 chunk 自上次 sync 后的差异（依赖 raw_content + diff） |
| C3 | `mcmAutoInject pause --until 'tomorrow 9am'` | 支持 `date -d` 自然语言 |
| C4 | trash TTL 自动清理 | `mcmConfig set trash.ttl_days 30`，sync 时顺手清 |
| C5 | `--quiet` / `--verbose` 统一 | 所有命令支持，替代散乱的 `log` 函数 |
| C6 | Shell completion | bash/zsh tab 补全所有 mcm* 命令 + 记忆名 |

---

## 5. v3.0 渐进路线图

### Phase 0：基线巩固（1 周）

> 不写新功能，只为后续重构铺路

- [ ] **B1**：切分 `lib/core.sh` 为 5 个文件
- [ ] **B7**：所有全局变量加 `MCM_` 前缀
- [ ] **A5 首批**：写 `test_inject_chain.sh` / `test_sync_idempotent.sh` / `test_concurrent.sh`
- [ ] **A4 最小集**：`emit_event` + `.events.ndjson` 落地，`cmd.start/end` 接入所有命令

**退出标准**：现有 48 测试 + 新增 15 集成测试全绿；events.ndjson 有数据。

### Phase 1：可见性 & 修小坑（1 周）

- [ ] **B2 + B4**：`.binding` 文件 + `find_project_memory_dir` 反向查找
- [ ] **B3**：冷却时间可配 + status 显示
- [ ] **B5**：抽 `lib/search.sh` 统一搜索
- [ ] **B6**：`mcmDoctor` 扩到 6 大类检查
- [ ] **B8**：所有 error() 加 actionable hint
- [ ] **A4 完整**：`mcmMetrics` 命令

**退出标准**：dogfood 一周无新 bug；mcmMetrics 能跑出 P50/P95。

### Phase 2：智能化（2 周）

- [ ] **A1**：sentence-transformers 嵌入 + Hybrid Search + RRF
- [ ] **A2 inline**：`mcmCondense` 命令 + Anthropic API 调用 + 状态机
- [ ] **C2**：`mcmDiff` 命令

**退出标准**：盲测同 20 个中文 prompt，Hybrid 召回 P@3 > 纯 BM25 ≥ 30%；占位 chunk 数能自动降到 0。

### Phase 3：可扩展（1-2 周）

- [ ] **A3**：`StorageBackend` 接口 + SQLite 后端
- [ ] **A5 完整**：soak + bench gate
- [ ] **A2 daemon**：`mcmd` 后台进程（共享模型 + condense 队列）

**退出标准**：`mcmConfig set backend sqlite` 可切换且数据零丢；bench P95 不退化 > 5%。

---

## 6. 不做的事（明确边界）

为了避免"v3.0 想做啥都加进来"的陷阱，明确以下方向**不在本周期**：

| 拒绝项 | 理由 |
|--------|------|
| 跨设备同步（自己实现 sync 协议） | 让用户用 Dropbox/git remote/syncthing；mcm 只保证单点正确 |
| Web UI | 命令行 + Claude 自己解读已足够 |
| 加密存储 | 现有目录权限 700 已满足 99% 场景，加密引入密钥管理复杂度 |
| 多语言 SDK（Python/JS 客户端） | SKILL.md + Bash 命令即 API，不重复造轮 |
| 替换 Bash 为 Go/Rust | 体量未达临界点；Bash 仍是 Claude Code skill 生态最契合的形态 |
| 接入第三方 LLM（OpenAI/Gemini）做浓缩 | 默认 Claude（同生态），多模型留给 v4.0 |

---

## 7. 度量成功

v3.0 发布时，下述指标应**全部**满足：

| 指标 | v2.4 baseline | v3.0 目标 |
|------|----------------|-----------|
| 中文 prompt P@3 召回 | ~40% (本轮估算) | ≥ 70% |
| 100 文件 sync 时长 | 未测 | ≤ 5 s |
| 占位 chunk 在 24h 内浓缩率 | 0%（纯人工） | ≥ 90% |
| 100 chunks 搜索 P95 | < 50 ms | < 30 ms |
| 测试断言数 | 48 (unit) | ≥ 120 (40 unit + 60 integ + 20 soak) |
| 单个 lib 文件 LOC | core.sh 1038 | 所有文件 ≤ 600 |
| `mcmStatus` 输出可定位绑定 | ✓ | ✓ 保留 |
| 多实例并发 sync 不丢数据 | 靠 flock，未压测 | soak 测试覆盖 |

---

## 8. 开放问题（需在 Phase 0 决定）

启动开发前需确认以下决策（建议各开 issue 单线讨论）：

1. **Q1**：sentence-transformers 是新增硬依赖还是 optional 降级？
   - 推荐：optional + 缺失时降级到 BM25 + 在 `mcmStatus` 提示安装

2. **Q2**：SQLite 后端是 v3.0 必做还是延后？
   - 推荐：v3.0 实现接口 + file backend 抽象；SQLite 实现放 v3.1

3. **Q3**：`mcmCondense` 用 `claude` CLI 还是直调 Anthropic API？
   - 推荐：先 `claude -p` (CLI 复用用户认证)；v3.1 加 API 直调作为 daemon 路径

4. **Q4**：`emit_event` 失败时（磁盘满）是吞掉还是 error？
   - 推荐：吞掉（事件总线绝不能拖垮主流程），但写到 stderr 一次

5. **Q5**：v3.0 是不是引入版本号到 chunk frontmatter？
   - 推荐：是。`schema_version: 3` 让未来迁移有抓手

---

## 9. 参考实现片段

### 9.1 Hybrid Search 骨架（Python）

```python
def hybrid_search(query, k=3):
    bm25_top = bm25_search(query, limit=20)         # 现有
    if HAVE_EMBEDDINGS:
        q_vec = model.encode(query)
        vec_top = cosine_search(q_vec, limit=20)    # numpy
    else:
        vec_top = []
    return rrf_merge(bm25_top, vec_top, k=k)

def rrf_merge(*ranked_lists, k=3, rrf_k=60):
    scores = defaultdict(float)
    for lst in ranked_lists:
        for rank, item in enumerate(lst):
            scores[item] += 1.0 / (rrf_k + rank + 1)
    return sorted(scores, key=scores.get, reverse=True)[:k]
```

### 9.2 状态机迁移（SQL）

```sql
-- 标记一批 chunks 为浓缩中
UPDATE chunks
   SET status = 'condensing', updated_at = unixepoch()
 WHERE status = 'pending' AND memory_id = ?
 LIMIT 10
 RETURNING id, chunk_name, source_file;

-- worker 成功后
UPDATE chunks
   SET status = 'ready', content = ?, embed = ?, updated_at = unixepoch()
 WHERE id = ?;

-- worker 失败 N 次
UPDATE chunks
   SET status = 'failed', updated_at = unixepoch()
 WHERE id = ? AND (SELECT COUNT(*) FROM condense_attempts WHERE chunk_id = ?) >= 3;
```

### 9.3 事件 emit（Bash）

```bash
# lib/events.sh
emit_event() {
    local type="$1"; shift
    local ts=$(date +%s)
    local fields=""
    for kv in "$@"; do
        fields+=",\"${kv%%=*}\":\"${kv#*=}\""
    done
    printf '{"ts":%d,"type":"%s"%s}\n' "$ts" "$type" "$fields" \
        >> "$MCM_EVENTS_FILE" 2>/dev/null || true
}

# 命令脚本入口
trap 'emit_event cmd.end cmd='$0' duration='$(($(date +%s)-CMD_START))' exit='$?' EXIT
CMD_START=$(date +%s)
emit_event cmd.start cmd="$0"
```

---

## 10. 检查清单（PR 模板）

每个 Phase 0/1/2/3 的 PR 必须勾选：

- [ ] 新增/改动函数有对应 unit test
- [ ] 涉及 hook 路径的变更有 integration test
- [ ] 涉及索引/锁的变更有 soak test
- [ ] 性能敏感路径前后跑 bench 并附数字
- [ ] error() 调用包含 actionable hint
- [ ] 新增配置项在 `mcmConfig` 与 SKILL.md 注册
- [ ] 数据格式变化时 `mcmDoctor --fix` 覆盖迁移
- [ ] CLAUDE.md / SKILL.md / README.md 三处文档同步
- [ ] CHANGELOG 写"为什么"而不只是"做了什么"

---

**附**：本文档不可作为契约（cap-stone style），仅作下一周期的方向锚点。任何 Phase 的实际方案应在落地前用 issue 复议；落地后用 ADR（Architecture Decision Record，可放 `docs/adr/`）固化"为什么这么选"。
