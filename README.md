# mcMemory (mcm) — AI 编程助手的分层记忆管理系统

[![Version](https://img.shields.io/badge/version-2.3-blue)](SKILL.md)
[![Bash](https://img.shields.io/badge/language-bash-green)](#)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)](#)
[![Tests](https://img.shields.io/badge/tests-48%2F48-brightgreen)](#)

> 让 AI 编程助手拥有跨会话记忆。纯 Bash 实现，零外部依赖。

---

## 它解决什么问题？

你和 AI 编程助手反复讨论一个项目——架构决策、技术选型、编码规范、踩过的坑。但每次新会话开始，AI 对这些一无所知。你不得不重复解释同样的背景。

**mcMemory** 把这些知识结构化地持久化到磁盘上，AI 在需要时检索加载。你不再重复自己。

---

## 目录

- [它解决什么问题？](#它解决什么问题)
- [核心设计](#核心设计)
- [两种记忆类型](#两种记忆类型)
- [四层记忆模型](#四层记忆模型)
- [快速开始](#快速开始)
- [命令参考](#命令参考)
- [自动注入（Hook 系统）](#自动注入hook-系统)
- [AI 浓缩工作流](#ai-浓缩工作流)
- [配置](#配置)
- [跨平台兼容](#跨平台兼容)
- [安全设计](#安全设计)
- [项目结构](#项目结构)
- [FAQ](#faq)
- [版本历史](#版本历史)
- [许可](#许可)

---

## 核心设计

```
┌─────────────────────────────────────────────────────────┐
│                  AI 编程助手 (任意)                        │
│                                                          │
│   mcmInit ──→ mcmSync ──→ mcmLoad ──→ mcmSearch         │
│       │            │           │             │           │
│       ▼            ▼           ▼             ▼           │
│  ┌──────────────────────────────────────────────────┐   │
│  │              lib/core.sh (共享库)                  │   │
│  │  hash · mtime · find · sync · index · L4         │   │
│  │  lock · trash · search_index · split · tag       │   │
│  └──────────────────────────────────────────────────┘   │
│                         │                                │
│                         ▼                                │
│  ┌──────────────────────────────────────────────────┐   │
│  │  ~/.claude/mcMemories/ (数据存储)                  │   │
│  │  projects/ · global/ · .trash/ · .search_index    │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

**设计原则：**

| 原则 | 说明 |
|------|------|
| **纯 Bash** | 核心逻辑仅需 bash 4.0+，Python 仅用于跨平台兼容层 |
| **哈希驱动** | SHA-256 指纹检测变更，仅更新变化的文件 |
| **分层加载** | 从概览到细节逐层深入，按需加载，不浪费上下文窗口 |
| **并发安全** | flock/mkdir 互斥锁，多会话同时操作不损坏数据 |
| **回收站** | 删除即移至 `.trash/`，支持恢复，防误删 |
| **动态标签** | 标签从目录结构自动发现，无需预定义 |
| **零配置** | 开箱即用，合理默认值 |

---

## 两种记忆类型

| 类型 | 范围 | 层级 | 用途 |
|------|------|------|------|
| **项目记忆** | 绑定单个 Git 仓库 | L1-L4 | 项目架构、API 约定、技术栈、已知问题 |
| **个人记忆** | 跨项目全局共享 | L1-L3 | 编码风格、偏好、常用命令、工具链 |

---

## 四层记忆模型

```
L1  项目文件夹              名称 + 简介 + 标签
    ──────────              summary.md
L2  大纲索引                标题 · 标签 · 摘要句 · 行号范围 · 文件类型
    ──────────              index.md
L3  浓缩内容                AI 加工后的结构化知识块（大文件自动按标题拆分）
    ──────────              chunks/*.md（带 YAML frontmatter）
L4  原始链接                指向源文件的引用，优先相对路径（仅项目记忆）
    ──────────              .claude/（symlink 或 .source 文件）
```

- **L1** — 顶层目录：项目名称、一句话简介、标签
- **L2** — 结构化索引：所有源文件的类型、标签、摘要、行号范围
- **L3** — 核心层：AI 浓缩后的知识块，带 YAML 头（源文件路径、哈希、同步时间）。大文件（>200 行）按 `##` 标题自动拆分
- **L4** — 原始文件引用：相对路径 symlink 或 `.source` 文件

---

## 快速开始

### 前置条件

- **Bash** 4.0+（Linux/macOS 自带；Windows 推荐 Git Bash 或 WSL）
- **Git**（项目记忆依赖 Git 仓库检测）
- **Python**（可选，仅用于跨平台兼容层）

### 为项目创建记忆

```bash
cd /path/to/your-project

# 初始化
mcmInit --name "my-project" --tags "backend" --description "用户服务后端"

# 查看所有记忆
mcmList

# 搜索
mcmSearch "数据库"
mcmSearch "API" --expand

# 源文件变化后增量同步
mcmSync

# 加载记忆到当前会话
mcmLoad "my-project" --layer L3

# 查看健康状态
mcmStatus
```

### 创建个人全局记忆

```bash
# 编码习惯（会话启动时自动加载）
mcmInit --global --name "coding-habits" --tags "auto" --description "我的编码偏好"

# 技术笔记（按需搜索）
mcmInit --global --name "linux-tips" --tags "on_demand" --description "Linux 技巧"

# 搜索个人记忆
mcmSearch "编码" --global
```

### 管理记忆

```bash
# 更新元数据
mcmUpdate "my-project" --description "v2.0，新增缓存层" --tags "backend,microservices"

# 删除（移至回收站）
mcmDelete "old-project"

# 查看回收站 / 恢复
mcmRestore --list
mcmRestore "old-project_20260427_210000"

# 导出 / 导入（跨机器迁移）
mcmExport "my-project" --output ./backup.tar.gz
mcmImport ./backup.tar.gz --tags "backend"
```

---

## 命令参考

所有命令以 `mcm` 为前缀。

| 命令 | 功能 |
|------|------|
| `mcmInit` | 初始化项目/个人记忆 |
| `mcmSync` | 增量同步（哈希驱动） |
| `mcmLoad <名称>` | 加载记忆到当前会话 |
| `mcmSearch <关键词>` | 全文搜索 |
| `mcmList` | 列出所有记忆 |
| `mcmStatus` | 健康总览 |
| `mcmUpdate <名称>` | 更新名称/描述/标签 |
| `mcmDelete <名称>` | 删除（移至回收站） |
| `mcmExport <名称>` | 导出为 tar.gz |
| `mcmImport <文件>` | 从 tar.gz 导入 |
| `mcmRestore <条目>` | 从回收站恢复 |
| `mcmEmptyTrash` | 清空回收站 |
| `mcmAutoInject` | 开启/关闭自动注入 |

**公共参数：** `--global`（操作个人记忆）、`--json`（JSON 输出）、`--help`

### mcmInit

```
mcmInit [--name NAME] [--tags TAGS] [--description DESC] [--global] [--workspace PATH]
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--name` | 记忆名称 | Git 根目录名 |
| `--tags` | 分组标签（逗号分隔） | `tools`（项目）/ `auto`（全局） |
| `--description` | 描述 | `项目记忆: <name>` |
| `--global` | 创建个人全局记忆 | — |
| `--workspace` | 工作目录 | 当前目录 |

**执行流程：**

1. 自动检测源文件（`CLAUDE.md`、`package.json`、`Makefile`、`docker-compose.yml` 等）
2. 生成 L2 大纲索引
3. 生成 L3 chunk（大文件自动拆分），写入 `hash.json`
4. 创建 L4 链接（仅项目记忆）

### mcmSync

```
mcmSync [--workspace PATH] [--global] [--name NAME]
```

读取 `hash.json`，重新计算源文件哈希，仅更新变化的文件。自动重建搜索索引。

### mcmLoad

```
mcmLoad <名称> [--layer L1|L2|L3|all] [--global]
```

| 层级 | 内容 |
|------|------|
| L1 | 项目概览（名称、简介） |
| L2 | 大纲索引 |
| L3 | 浓缩内容（推荐） |
| all | 全部层级 |

### mcmSearch

```
mcmSearch <关键词> [--expand] [--global] [--json]
```

- `--expand` — 展开完整 chunk 内容
- `--json` — JSON 格式输出

使用预建搜索索引，亚秒级响应。

---

## 自动注入（Hook 系统）

mcMemory 支持通过 Hook 实现自动记忆管理，无需手动操作：

| Hook 事件 | 功能 |
|-----------|------|
| `SessionStart` | 新会话自动加载项目 L1 + 个人 auto 记忆 L3 |
| `UserPromptSubmit` | 用户提问时智能检索相关记忆并注入 |
| `PreCompact` | 上下文压缩前自动保存会话要点到 L3 |

**一键配置：**

```bash
mcmAutoInject on              # 当前项目启用
mcmAutoInject on --scope user # 全局启用
mcmAutoInject status          # 查看状态
mcmAutoInject off             # 关闭
```

**注入策略：** 冷却 120s · 相关性阈值 2 分 · 最多 3 个记忆 · header 行匹配 ×3 权重

### PreCompact 会话压缩

AI 在会话中主动写入 `.claude/session_notes.md`，PreCompact hook 在上下文压缩前自动：

1. 读取会话笔记
2. 生成带时间戳的 L3 chunk（`chunks/session_YYYYMMDD_HHMMSS.md`）
3. 增量更新搜索索引
4. 清空笔记文件

这样跨会话的决策不会丢失，可通过 `mcmSearch` 检索。

---

## AI 浓缩工作流

mcMemory 的 L3 层依赖 AI 自动浓缩源文件内容：

1. `mcmInit` / `mcmSync` 生成带 `[待AI补充：浓缩内容]` 占位符的 chunk
2. AI 读取 chunk frontmatter 中的 `source_file` 字段
3. AI 读取源文件，生成结构化浓缩内容（原文 10-30%）
4. AI 原地更新 chunk 文件

浓缩原则：保留关键决策、API 签名、配置要点，省略冗余描述。

---

## 配置

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `MEMORY_BASE` | 记忆数据根目录 | `~/.claude/mcMemories` |
| `PYTHON` | Python 解释器路径 | 自动检测 |
| `CHUNK_SPLIT_THRESHOLD` | 大文件拆分行数阈值 | `200` |
| `SOURCE_PATTERNS` | 额外源文件 glob 模式 | 空 |
| `MAX_INJECT_TOKENS_ESTIMATE` | 单次注入 token 预算 | `2000` |
| `MAX_INJECT_MEMORIES` | 单次注入最多记忆数 | `3` |
| `INJECT_COOLDOWN_SEC` | 注入冷却时间（秒） | `120` |

```bash
# 示例
export MEMORY_BASE="/mnt/data/claude-memories"
export CHUNK_SPLIT_THRESHOLD=150
export SOURCE_PATTERNS="*.toml *.yaml"
```

### 自定义标签

无需修改代码，直接使用：

```bash
mcmInit --tags "mobile,iOS" --name "my-ios-app"
# 标签自动创建，list/search 动态发现
```

---

## 跨平台兼容

| 平台 | symlink | sha256sum | Python fallback | 状态 |
|------|---------|-----------|-----------------|------|
| Linux | `ln -sf` | `sha256sum` | ✅ | 完全支持 |
| macOS | `ln -sf` | `shasum -a 256` | ✅ | 完全支持 |
| Windows (Git Bash) | `.source` 文件 | Python `hashlib` | ✅ | L4 降级但功能完整 |
| Windows (WSL) | `ln -sf` | `sha256sum` | ✅ | 完全支持 |

**降级策略：** symlink 不可用 → `.source` 引用文件 · `sha256sum` 不可用 → `shasum` → Python · `flock` 不可用 → `mkdir` 原子锁

---

## 安全设计

| 机制 | 说明 |
|------|------|
| 路径白名单 | `safe_rm()` 拒绝删除数据目录之外的路径 |
| Python 注入防护 | 全部 Python 调用使用 `sys.argv` 传参 |
| 并发锁 | flock/mkdir 互斥锁保护写操作 |
| 回收站 | 删除移至 `.trash/`，支持恢复 |
| 确认机制 | 删除/清空默认要求确认 |
| 预览模式 | `--dry-run` 安全预览 |
| 幂等操作 | `mcmInit`/`mcmSync` 可重复执行 |

---

## 项目结构

```
mcMemory/
├── SKILL.md                    # Skill 注册清单
├── README.md                   # 本文档
├── CLAUDE.md                   # 项目指南
├── lib/
│   ├── core.sh                 # 共享工具库
│   └── inject.sh               # 自动注入逻辑
├── hooks/
│   ├── session-start.sh        # SessionStart hook
│   ├── prompt-submit.sh        # UserPromptSubmit hook
│   └── pre-compact.sh          # PreCompact hook
├── commands/
│   ├── init.sh                 # mcmInit
│   ├── sync.sh                 # mcmSync
│   ├── load.sh                 # mcmLoad
│   ├── search.sh               # mcmSearch
│   ├── list.sh                 # mcmList
│   ├── status.sh               # mcmStatus
│   ├── auto-inject.sh          # mcmAutoInject
│   ├── delete.sh               # mcmDelete
│   ├── update.sh               # mcmUpdate
│   ├── export.sh               # mcmExport
│   ├── import.sh               # mcmImport
│   ├── restore.sh              # mcmRestore
│   └── empty-trash.sh          # mcmEmptyTrash
└── tests/
    └── test_core.sh            # 单元测试（48 项断言）
```

### 数据存储

```
~/.claude/mcMemories/
├── projects/                           # 项目记忆
│   ├── index.md                        # 总索引
│   ├── {tag}/                          # 按标签分组
│   │   └── <project>/
│   │       ├── summary.md              # L1
│   │       ├── index.md                # L2
│   │       ├── hash.json               # 文件哈希快照
│   │       ├── chunks/                 # L3 浓缩内容
│   │       └── .claude/                # L4 原始链接
├── global/                             # 个人记忆
│   ├── auto/                           # 自动加载型
│   └── on_demand/                      # 按需触发型
├── .trash/                             # 回收站
├── .search_index                       # 合并搜索索引
└── .locks/                             # 并发锁
```

---

## FAQ

**记忆存储在哪里？**
`~/.claude/mcMemories/`，独立于安装路径。

**大文件怎么处理？**
超过 200 行的源文件按 `##` 标题自动拆分为多个 chunk。阈值可通过 `CHUNK_SPLIT_THRESHOLD` 调整。

**如何跨机器分享记忆？**
`mcmExport` 导出为 tar.gz，`mcmImport` 在新机器导入。

**误删了怎么办？**
`mcmDelete` 移至回收站而非永久删除。`mcmRestore --list` 查看，`mcmRestore <条目>` 恢复。

**多会话同时操作安全吗？**
写操作使用 flock/mkdir 互斥锁，幂等设计，可安全并发。

**项目移动后 L4 链接会断吗？**
L4 优先使用相对路径 symlink，项目目录移动后引用仍然有效。

**如何自定义标签？**
直接使用任意标签名即可，系统从目录结构动态发现，无需预定义。

---

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| **v2.3** | 2026-06-08 | flock fd 自动分配消除碰撞风险、subshell 修复使 local 生效、O(n²)→O(n) 文件拆分、sed_escape 纯 sed 实现、索引快速路径统一、批量 frontmatter 更新、搜索索引增量更新优化、48 项测试 |
| v2.2 | 2026-06-04 | PreCompact 会话压缩、增量搜索索引、消除双次 split、scope 过滤修复、批量文件信息、JSON 注入修复、header 加权相关性、46 项测试 |
| v2.1 | 2026-04-27 | 自动注入系统（SessionStart/UserPromptSubmit/PreCompact hooks）、hook_config 修复、全文扫描注入、global auto 冷却标记 |
| v2.0 | 2026-04-27 | 动态标签、回收站、并发锁、搜索索引、大文件拆分、L4 相对路径、Python 注入防护、macOS 兼容、非 .md 源文件、JSON 输出、6 个新命令 |
| v1.0 | 2026-04-27 | 初始发布 |

---

## 许可

MIT License
