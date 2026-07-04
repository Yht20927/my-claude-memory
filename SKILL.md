---
name: mcMemory
description: mcMemory (mcm) - 分层记忆管理系统。命令以 "mcm" 开头。项目记忆支持 L1-L4 层级，个人记忆支持 L1-L3 层级。存储于 ~/.claude/mcMemories/。
allowed-tools: ["Bash", "Read", "Write", "Grep"]
---

# mcm - mcMemory 分层记忆管理系统

分层记忆管理系统。项目记忆支持 L1-L4，个人全局记忆支持 L1-L3。

> **存储路径**: `~/.claude/mcMemories/` (原 `~/.claude/memory/`)

## 命令列表

| 命令 | 功能 | 入口 |
|------|------|------|
| `mcmInit` | 初始化项目/个人记忆 | [commands/init.sh](commands/init.sh) |
| `mcmSync` | 增量同步已有记忆 | [commands/sync.sh](commands/sync.sh) |
| `mcmLoad <名称>` | 加载记忆到当前会话上下文 | [commands/load.sh](commands/load.sh) |
| `mcmSearch <关键词>` | 全文搜索记忆 | [commands/search.sh](commands/search.sh) |
| `mcmList` | 列出所有已注册记忆 | [commands/list.sh](commands/list.sh) |
| `mcmStatus` | 记忆健康总览 | [commands/status.sh](commands/status.sh) |
| `mcmDelete <名称>` | 删除记忆（移至回收站） | [commands/delete.sh](commands/delete.sh) |
| `mcmUpdate <名称>` | 更新记忆元数据 | [commands/update.sh](commands/update.sh) |
| `mcmExport <名称>` | 导出记忆为归档 | [commands/export.sh](commands/export.sh) |
| `mcmImport <文件>` | 从归档导入记忆 | [commands/import.sh](commands/import.sh) |
| `mcmRestore <条目>` | 从回收站恢复 | [commands/restore.sh](commands/restore.sh) |
| `mcmEmptyTrash` | 清空回收站 | [commands/empty-trash.sh](commands/empty-trash.sh) |
| `mcmAutoInject` | 一键开启/关闭/暂停自动注入 | [commands/auto-inject.sh](commands/auto-inject.sh) |
| `mcmInjectLog [--tail N]` | 查看自动注入事件日志 | [commands/inject-log.sh](commands/inject-log.sh) |
| `mcmJournal <文本>` | 一行命令追加会话笔记（PreCompact 时归档为 L3 chunk） | [commands/journal.sh](commands/journal.sh) |
| `mcmDoctor [--fix]` | 健康检查 + 自动迁移脏 tag 目录 + 占位 chunk 报告 | [commands/doctor.sh](commands/doctor.sh) |

## 公共参数

- `--global` - 对全局个人记忆操作（而非项目记忆）
- `--json` - 机器可读 JSON 输出（list / search / status 支持）
- `--scope` - 作用域：`project`（默认）或 `user`
- `--help` - 显示帮助信息

## Hook 配置（自动注入）

本 skill 提供 3 个 Hook 脚本实现自动记忆注入：

| Hook 事件 | 脚本 | 功能 |
|-----------|------|------|
| `SessionStart` | [hooks/session-start.sh](hooks/session-start.sh) | 新会话自动加载项目 L1 + auto 全局 L3 |
| `UserPromptSubmit` | [hooks/prompt-submit.sh](hooks/prompt-submit.sh) | 智能提取关键词，检索相关记忆注入 |
| `PreCompact` | [hooks/pre-compact.sh](hooks/pre-compact.sh) | 上下文压缩前保存会话摘要 |

**一键开启**:
```
mcmAutoInject on          # 当前项目启用
mcmAutoInject on --scope user   # 全局启用
mcmAutoInject status      # 查看状态
mcmAutoInject off         # 关闭

# 临时暂停（不改 settings.json，到点自动恢复）
mcmAutoInject pause 30m   # 暂停 30 分钟
mcmAutoInject pause 2h    # 暂停 2 小时
mcmAutoInject resume      # 立即取消

# 查看注入日志（哪些记忆在什么时间被注入、得分、关键词）
mcmInjectLog              # 最近 20 条
mcmInjectLog --tail 50
mcmInjectLog --json
```

注入策略:
- **BM25 评分** (v2.4/v3.1): 标准 BM25 (k1=1.2, b=0.75) + Robertson IDF + 中英文关键词提取；header 命中权重 ×3
- **冷却机制**: 同一记忆 120 秒内不重复注入
- **相关性阈值**: BM25 score ≥ `INJECT_BM25_MIN_SCORE`（默认 0，即任何正分；可调）
- **长度控制**: 单次注入最多 3 个记忆，总内容受 token 预算限制
- **搜索索引优先**: 使用预建索引进行快速匹配
- **可观测** (v3.0): 全部 16 命令接入 NDJSON 事件总线；`mcmInjectLog` 查看注入历史

## 目录结构

```
~/.claude/mcMemories/
├── projects/                    # 项目记忆（L1-L4）
│   ├── index.md                 # 项目总索引
│   ├── {tag}/                   # 按标签分组的项目目录（自由标签）
│   │   └── <project-name>/
│   │       ├── summary.md       # L1
│   │       ├── index.md         # L2
│   │       ├── hash.json        # 文件哈希（相对路径 key）
│   │       ├── chunks/          # L3
│   │       └── .claude/         # L4
├── global/                      # 个人全局记忆（L1-L3）
│   ├── index.md
│   ├── auto/                    # 自动加载型
│   └── on_demand/               # 关键词触发型
└── .trash/                      # 回收站
```

## 层级说明

| 层级 | 内容 | 说明 |
|------|------|------|
| L1 | 项目文件夹 | 项目名 + 简介 |
| L2 | 大纲索引 | 标题 + 标签 + 摘要句 + 行号范围 |
| L3 | 浓缩内容 | 从原始文件 AI 浓缩的核心内容（chunks/*.md） |
| L4 | 原始链接 | 指向源文件的引用（仅项目，优先相对路径 symlink） |

## 架构说明 (v2.0)

- **纯 bash 脚本**: 所有命令为 `.sh` 文件，直接 `source lib/core.sh`
- **动态标签**: 标签不再硬编码，从目录结构自动发现
- **相对路径**: hash.json 和 L4 链接优先使用相对路径
- **并发锁**: 写操作使用 flock/mkdir 互斥锁
- **回收站**: 删除操作移至 `.trash/` 而非永久删除
- **搜索索引**: sync 时自动重建合并搜索索引，加速搜索
- **大文件拆分**: 超过 `CHUNK_SPLIT_THRESHOLD` (默认 200 行) 的源文件按 ## 标题自动拆分为多个 chunk
- **非 .md 源文件**: 自动检测 package.json, Makefile, docker-compose.yml 等配置文件

## AI 记忆浓缩指令

> **重要**: 当 `mcmInit` 或 `mcmSync` 完成后，如果 chunk 文件包含 `[待AI补充：浓缩内容]` 占位符，Claude 应执行以下流程：

1. 读取 `chunks/` 目录中每个包含占位符的 chunk 文件
2. 从 chunk frontmatter 的 `source_file` 字段找到对应源文件
3. 使用 `Read` 工具读取源文件完整内容
4. 生成结构化的浓缩内容，替换 `[待AI补充：浓缩内容]` 占位符
5. 浓缩原则：
   - 保留关键决策、架构约定、API 签名、配置要点
   - 省略冗余描述和显而易见的内容
   - 目标长度：源文件的 10-30%
   - 保持 Markdown 格式，包含代码块
6. 使用 `Edit` 工具原地更新 chunk 文件

## 加载策略

自动注入模式（推荐）:
- 运行 `mcmAutoInject on` 一次配置 Hook
- SessionStart: 自动加载项目记忆 L1 + auto 全局记忆 L3
- UserPromptSubmit: 用户提问时智能检索并注入相关记忆
- PreCompact: 上下文压缩前自动保存会话要点（见下方）

手动模式:
- 会话启动时，Claude 应自动运行 `mcmList` 了解可用记忆
- 对 `auto` 标签的全局记忆，自动调用 `mcmLoad --layer L3` 加载浓缩内容
- 对项目记忆，进入项目目录后自动调用 `mcmLoad` 加载相关记忆
- 提问涉及特定领域时，先 `mcmSearch` 检索相关记忆再回答

## 会话笔记（PreCompact 保存）

> **重要**: 在会话过程中，当出现以下情况时，Claude 应**主动**追加到 `.claude/session_notes.md`：

触发写入的场景:
- 做出了重要的架构或设计决策
- 发现并修复了 bug（记录根因和修复方式）
- 学习了新的项目约定或工作流程
- 用户明确表示"记住这个"
- 在回答复杂问题前搜集了有价值的上下文

**推荐方式（v2.4+）**: 使用 `mcmJournal` 一行命令，免去 Write 工具的门槛：
```bash
mcmJournal "决策: 用 BM25 替换 sqrt(n) 归一化；原因: 后者无理论依据"
mcmJournal "Bug fix: prompt_submit_inject 永不注入；根因: score 二次过滤"
echo -e "决策 A\n决策 B" | mcmJournal --stdin    # 多行
mcmJournal --show                                  # 查看当前笔记
```

或直接 Write `.claude/session_notes.md` 添加结构化条目：
```markdown
## <简短标题>

**决策**: <一句话描述>
**原因**: <为什么这样做>
**涉及文件**: <相关文件路径>
```

pre-compact.sh hook 会在压缩前自动:
1. 读取 `.claude/session_notes.md`
2. 生成带时间戳的 L3 chunk（`chunks/session_YYYYMMDD_HHMMSS.md`）
3. 增量更新搜索索引
4. 清空 `.claude/session_notes.md` 以备下次会话

> 这样不会丢失跨会话的决策上下文，且可在 `mcmSearch` 中检索到。

## 执行命令

当用户调用 `mcmXxx` 时，执行对应的 `commands/xxx.sh`。

## 共享工具库

公共函数位于 `lib/core.sh` (v2.0)，各命令通过 `source` 加载。

---

*版本: v3.1 | BM25 注入 | NDJSON 事件总线 | .workspace 标记(B2) | 单一 BM25 评分(B5) | 动态标签 | 并发锁 | 回收站 | 相对路径 | 搜索索引 | 会话压缩 | 2026-07-04*
