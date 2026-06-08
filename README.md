# mcMemory (mcm) — 分层记忆管理系统

[![Version](https://img.shields.io/badge/version-2.2-blue)](SKILL.md)
[![Bash](https://img.shields.io/badge/language-bash-green)](#)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)](#)
[![Tests](https://img.shields.io/badge/tests-46%2F46-brightgreen)](#)

为 Claude Code 打造的分层记忆管理系统，让 AI 在跨会话间持久化项目与个人知识。

---

## 目录

- [核心思想](#核心思想)
- [架构设计](#架构设计)
- [四层记忆模型](#四层记忆模型)
- [目录结构](#目录结构)
- [安装](#安装)
- [快速开始](#快速开始)
- [命令参考](#命令参考)
  - [mcmInit — 初始化记忆](#mcminit--初始化记忆)
  - [mcmSync — 增量同步](#mcmsync--增量同步)
  - [mcmLoad — 加载记忆](#mcmload--加载记忆)
  - [mcmSearch — 全文搜索](#mcmsearch--全文搜索)
  - [mcmList — 列出记忆](#mcmlist--列出记忆)
  - [mcmStatus — 健康总览](#mcmstatus--健康总览)
  - [mcmAutoInject — 自动注入](#mcmautoinject--自动注入)
  - [mcmDelete — 删除记忆](#mcmdelete--删除记忆)
  - [mcmUpdate — 更新元数据](#mcmupdate--更新元数据)
  - [mcmExport / mcmImport — 导出导入](#mcmexport--mcmimport--导出导入)
  - [mcmRestore / mcmEmptyTrash — 回收站](#mcmrestore--mcmemptytrash--回收站)
  - [PreCompact 会话压缩](#precompact-会话压缩)
- [工作流示例](#工作流示例)
- [AI 记忆浓缩](#ai-记忆浓缩)
- [配置与自定义](#配置与自定义)
- [跨平台兼容](#跨平台兼容)
- [安全设计](#安全设计)
- [项目结构](#项目结构)
- [常见问题](#常见问题)
- [版本历史](#版本历史)
- [许可](#许可)

---

## 核心思想

在长期与 Claude Code 协作的过程中，AI 的上下文窗口是有限的。每次新会话开始，Claude 对之前讨论的项目背景、设计决策、编码偏好等信息会"遗忘"。**mcMemory** 通过将关键信息结构化地持久化到磁盘上，使这些记忆可以在未来会话中被检索和加载，从而：

- **跨会话记忆复用**：项目的架构决策、接口约定、已知坑点不再需要反复说明
- **分层信息管理**：从概览到细节逐层深入，按需加载，不耗尽上下文
- **个人知识沉淀**：编码习惯、偏好、常用命令等个人知识跨项目共享
- **AI 自动维护**：哈希驱动的增量同步，源文件变化自动检测更新
- **纯 Bash 零依赖**：核心逻辑仅需 bash 即可运行，Python 仅用作跨平台兼容层

### 两种记忆类型

| 类型 | 范围 | 层级 | 触发方式 | 示例 |
|------|------|------|----------|------|
| **项目记忆** | 绑定单个 Git 仓库 | L1-L4 | 进入项目目录自动关联 | 项目架构、API 约定、技术栈、已知问题 |
| **个人记忆** | 跨项目全局共享 | L1-L3 | 关键词触发 / 自动加载 | 编码风格偏好、快捷键习惯、常用工具链 |

---

## 架构设计

```
┌─────────────────────────────────────────────────────────┐
│                    Claude Code Session                    │
│                                                          │
│   mcmInit ──→ mcmSync ──→ mcmLoad ──→ mcmSearch         │
│       │            │           │             │           │
│       ▼            ▼           ▼             ▼           │
│  ┌──────────────────────────────────────────────────┐   │
│  │              lib/core.sh (共享库 v2.0)            │   │
│  │  ┌────────────────────────────────────────────┐  │   │
│  │  │ hash · mtime · find · sync · index · L4   │  │   │
│  │  │ lock · trash · search_index · split · tag │  │   │
│  │  └────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  commands/                                        │   │
│  │  init.sh · sync.sh · load.sh · search.sh          │   │
│  │  list.sh · status.sh · delete.sh · update.sh       │   │
│  │  export.sh · import.sh · restore.sh · empty-trash  │   │
│  └──────────────────────────────────────────────────┘   │
│                         │                                │
│                         ▼                                │
│  ┌──────────────────────────────────────────────────┐   │
│  │  ~/.claude/mcMemories/ (数据存储)                  │   │
│  │  projects/ · global/ · .trash/ · .search_index    │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 设计原则

- **库模式** — 所有命令共享 `lib/core.sh`，零重复代码
- **步骤化执行** — 每个命令遵循 Step 1/2/3/N 的清晰执行流
- **哈希驱动同步** — `hash.json` 存储 SHA-256 指纹，仅变更文件触发重新生成
- **数据与逻辑分离** — 记忆数据存储在 `~/.claude/mcMemories/`，独立于 skill 安装目录
- **被动源检测** — 自动发现 `CLAUDE.md`、`MEMORY.md`、`CONTEXT.md`、`.claude/*.md`、`package.json` 等源文件
- **动态标签** — 标签从目录结构自动发现，不再硬编码
- **并发安全** — 写操作使用 flock/mkdir 互斥锁，防止多会话竞态
- **回收站保护** — 删除操作移至 `.trash/`，支持恢复

---

## 四层记忆模型

```
L1  项目文件夹              名称 + 简介 + 标签
    ──────────              summary.md
L2  大纲索引                标题 · 标签 · 摘要句 · 行号范围 · 文件类型
    ──────────              index.md
L3  浓缩内容                AI 加工后的结构化知识块（大文件自动按标题拆分）
    ──────────              chunks/*.md（带 YAML frontmatter）
L4  原始链接                指向源文件的引用，优先相对路径
    ──────────              .claude/（symlink 或 .source 文件）
```

- **L1** — 顶层目录，包含项目名称、一句话简介和标签（`summary.md`）
- **L2** — 结构化索引入口，列出所有源文件及其类型、标签、摘要和行号范围
- **L3** — 核心层，每个源文件对应一个或多个 chunk，存储 AI 浓缩后的知识内容，带 YAML 头（源文件路径、最后同步时间、文件哈希）。大文件（>200 行）按 `##` 标题自动拆分为多个子 chunk
- **L4** — 原始文件引用层，通过相对路径 symlink 或 `.source` 引用文件指向原始文件

> **个人全局记忆** 仅支持 L1-L3，无 L4 原始链接层。

---

## 目录结构

### Skill 安装目录

```
mcMemory/
├── SKILL.md                    # Claude Code skill 注册清单
├── README.md                   # 本文件
├── CLAUDE.md                   # Claude Code 项目指南
├── lib/
│   ├── core.sh                 # 共享工具库 (~945 行)
│   └── inject.sh               # 自动注入逻辑库 (v2.1)
├── hooks/
│   ├── session-start.sh        # SessionStart hook
│   ├── prompt-submit.sh        # UserPromptSubmit hook
│   └── pre-compact.sh          # PreCompact hook (v2.2 会话压缩)
├── commands/
│   ├── init.sh                 # mcmInit 命令入口
│   ├── sync.sh                 # mcmSync 命令入口
│   ├── load.sh                 # mcmLoad 命令入口
│   ├── search.sh               # mcmSearch 命令入口
│   ├── list.sh                 # mcmList 命令入口
│   ├── status.sh               # mcmStatus 命令入口
│   ├── auto-inject.sh          # mcmAutoInject 命令入口 (v2.1)
│   ├── delete.sh               # mcmDelete 命令入口
│   ├── update.sh               # mcmUpdate 命令入口
│   ├── export.sh               # mcmExport 命令入口
│   ├── import.sh               # mcmImport 命令入口
│   ├── restore.sh              # mcmRestore 命令入口
│   └── empty-trash.sh          # mcmEmptyTrash 命令入口
└── tests/
    └── test_core.sh            # 核心函数单元测试 (46 项断言)
```

### 数据存储目录 (`~/.claude/mcMemories/`)

```
~/.claude/mcMemories/
├── projects/                           # 项目记忆
│   ├── index.md                        # 项目总索引
│   ├── {tag}/                          # 按标签分组（动态发现，自由扩展）
│   │   └── <project-name>/
│   │       ├── summary.md              # L1: 项目简介
│   │       ├── index.md                # L2: 大纲索引
│   │       ├── hash.json               # 文件哈希快照（workspace 相对路径 key）
│   │       ├── chunks/                 # L3: 浓缩内容（大文件自动拆分）
│   │       │   ├── 1_CLAUDE.md
│   │       │   ├── 2_ARCHITECTURE.md
│   │       │   └── ...
│   │       └── .claude/                # L4: 原始链接（优先相对路径）
│   │           ├── CLAUDE.md → ../../../../project/CLAUDE.md
│   │           └── ARCHITECTURE.md.source
├── global/                             # 个人全局记忆
│   ├── index.md                        # 全局总索引
│   ├── auto/                           # 自动加载型（编码习惯、偏好等）
│   │   └── <memory-name>/
│   │       ├── summary.md
│   │       ├── index.md
│   │       └── chunks/
│   ├── on_demand/                      # 关键词触发型（杂记等）
│   │   └── <memory-name>/
│   │       ├── summary.md
│   │       ├── index.md
│   │       └── chunks/
│   └── {custom}/                       # 自定义标签
├── .trash/                             # 回收站（new）
│   ├── <name>_20260427_210000/         # 被删除的记忆
│   └── .<name>_20260427_210000.origin  # 原始路径记录
├── .search_index                       # 合并搜索索引（new）
└── .locks/                             # 并发锁目录（new）
```

---

## 安装

### 前置条件

- **Git** — 项目记忆依赖 Git 仓库检测
- **Bash** — 4.0+（Linux/macOS 自带；Windows 推荐 Git Bash 或 WSL）
- **Python** (可选) — 用于跨平台兼容层（路径解析、哈希、时间戳）

### 方式一：通过 Skill 工具安装

```bash
# 在 Claude Code 会话中执行
/skill-install https://github.com/your-org/mcMemory.git
```

### 方式二：手动安装

```bash
git clone https://github.com/your-org/mcMemory.git ~/.claude/skills/mcMemory
mcmList
```

---

## 快速开始

### 场景 1：为现有项目创建记忆

```bash
cd /path/to/your-project
mcmInit --name "my-project" --tags "backend" --description "用户服务后端，Go + PostgreSQL"
mcmList
mcmSearch "数据库"
mcmSearch "API" --expand

# 源文件变化后增量同步
mcmSync

# 加载记忆到当前会话
mcmLoad "my-project" --layer L3

# 查看健康状态
mcmStatus

# 更新记忆元信息
mcmUpdate "my-project" --description "用户服务 v2.0，新增缓存层" --tags "backend,microservices"
```

### 场景 2：创建个人全局记忆

```bash
# 创建编码习惯记忆（自动加载型）
mcmInit --global --name "coding-habits" --tags "auto" --description "我的编码偏好和习惯"

# 创建技术笔记（按需触发型）
mcmInit --global --name "linux-tips" --tags "on_demand" --description "Linux 常用命令和技巧"

# AI 会自动在会话启动时加载 auto 标签的记忆
mcmSearch "编码" --global
mcmLoad "coding-habits" --global --layer L3
```

### 场景 3：清理不再需要的记忆

```bash
# 删除（移至回收站）
mcmDelete "old-project"

# 查看回收站
mcmRestore --list

# 恢复
mcmRestore "old-project_20260427_210000"

# 彻底清空回收站
mcmEmptyTrash --force
```

### 场景 4：分享记忆

```bash
# 导出
mcmExport "my-project" --output ./my-project-memory.tar.gz

# 导入到另一台机器
mcmImport ./my-project-memory.tar.gz --tags "backend"
```

---

## 命令参考

所有命令以 `mcm` 为前缀。公共参数：
- `--global` - 操作个人全局记忆
- `--json` - 机器可读 JSON 输出（list/search/status 支持）
- `--help` - 显示帮助信息

### mcmInit — 初始化记忆

```
mcmInit [--name NAME] [--tags TAGS] [--description DESC] [--global] [--workspace PATH]
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--name` | 记忆名称 | 项目：Git 根目录名；全局：交互输入 |
| `--tags` | 分组标签（逗号分隔多标签） | 项目：`tools`；全局：`auto` |
| `--description` | 记忆描述（L1 简介） | `项目记忆: <name>` |
| `--global` | 创建个人全局记忆 | 默认创建项目记忆 |
| `--workspace` | 工作目录路径 | 当前目录 |

**执行流程：**

1. **Step 1 — 深度阅读**：自动检测 `CLAUDE.md`、`MEMORY.md`、`CONTEXT.md`、`.claude/*.md`、以及 `package.json`、`Makefile`、`docker-compose.yml` 等配置文件
2. **Step 2 — 生成大纲**：为每个源文件创建 L2 索引条目（含文件类型、行数、拆分标记）
3. **Step 3 — 生成 Chunk**：创建带 YAML frontmatter 的 L3 chunk，大文件自动按 `##` 标题拆分，生成 `hash.json`
4. **Step 4 — 创建 L4 链接**：建立源文件的相对路径 symlink 或 `.source` 引用（仅项目）

> 无源文件时，提示用户创建 `CLAUDE.md` 模板。

**标签说明：**

| 类型 | 默认标签 | 含义 |
|------|----------|------|
| 项目 | `frontend`, `backend`, `tools`, ... | 自定义标签，动态发现 |
| 全局 | `auto`, `on_demand`, ... | `auto`=自动加载，`on_demand`=关键词触发 |

---

### mcmSync — 增量同步

```
mcmSync [--workspace PATH] [--global] [--name NAME]
```

**执行流程：**

1. **Step 0 — 健康检查**：统计 L4 symlink 状态（有效/损坏/副本数）
2. **Step 1 — 哈希比对**：读取 `hash.json`（workspace 相对路径 key），重新计算源文件哈希，识别变更文件
3. **Step 2 — 增量重生成**：更新变更文件对应的 chunk frontmatter（hash + last_sync），重建完整 `hash.json`
4. **Step 3 — 更新 L4 链接**：刷新 symlink 或 `.source` 引用（保持相对路径）

> 使用并发锁保护。完成后自动重建搜索索引。

---

### mcmLoad — 加载记忆

```
mcmLoad <名称> [--layer L1|L2|L3|all] [--global]
```

| 参数 | 说明 |
|------|------|
| `--layer` | 加载层级：L1(概览) / L2(索引) / L3(内容) / all(全部) |
| `--global` | 加载个人全局记忆 |

将记忆内容输出到标准输出，Claude 可直接消费。加载策略：
- `auto` 标签的全局记忆应在会话启动时自动 `mcmLoad --layer L3`
- 进入项目目录后自动加载对应项目记忆

---

### mcmSearch — 全文搜索

```
mcmSearch <关键词> [--expand] [--global] [--json]
```

| 参数 | 说明 |
|------|------|
| `--expand` | 展开显示完整 chunk 内容 |
| `--global` | 搜索个人全局记忆 |
| `--json` | JSON 格式输出 |

**搜索优化**：优先使用合并搜索索引 `$SEARCH_INDEX`（sync/init 时自动重建），回退到遍历 chunks。

---

### mcmList — 列出记忆

```
mcmList [--json]
```

动态发现所有标签分组，列出全部已注册的项目记忆和个人记忆。

---

### mcmStatus — 健康总览

```
mcmStatus [--json]
```

展示所有记忆的健康状态表格：名称、标签、简介摘要、hash.json 有无、chunk 数量、L4 链接状态、新鲜度（30天未同步标记）。同时显示回收站条目数。

---

### mcmAutoInject — 自动注入

```
mcmAutoInject [on|off|status] [--scope project|user]
```

| 参数 | 说明 |
|------|------|
| `on` | 开启自动记忆注入（注册 SessionStart + UserPromptSubmit + PreCompact hook） |
| `off` | 关闭自动注入（移除 mcMemory hooks） |
| `status` | 显示注入状态和最近的注入记录 |

**Hook 事件：**

| Hook | 功能 |
|------|------|
| `SessionStart` | 自动加载项目记忆 L1 + auto 全局记忆 L3 |
| `UserPromptSubmit` | 提取关键词，智能检索相关记忆并注入（含冷却机制） |
| `PreCompact` | 读取 AI 写入的 `.claude/session_notes.md`，生成 L3 chunk 存入记忆 |

> 注入策略：冷却 120s、相关性阈值 2 分、最多 3 个记忆、header 行匹配 ×3 权重、chunk 数量归一化。

### PreCompact 会话压缩

PreCompact hook 实现真正的会话知识保存：

1. AI 在会话中主动写入 `.claude/session_notes.md`（触发：架构决策、bug 修复、新约定、用户说"记住这个"）
2. Hook 在上下文压缩前读取笔记 → 生成带时间戳的 L3 chunk（`chunks/session_YYYYMMDD_HHMMSS.md`）
3. 增量更新搜索索引，清空笔记文件
4. 后续可通过 `mcmSearch` 检索历史会话决策

```markdown
## <简短标题>
**决策**: <一句话描述>
**原因**: <为什么这样做>
**涉及文件**: <相关文件路径>
```

### mcmDelete — 删除记忆

```
mcmDelete <名称> [--force] [--global] [--dry-run]
```

| 参数 | 说明 |
|------|------|
| `--force` | 跳过确认提示 |
| `--global` | 删除个人全局记忆 |
| `--dry-run` | 预览模式，不实际执行 |

> **v2.0**：删除操作将记忆移至 `$TRASH_DIR`（而非永久删除），可用 `mcmRestore` 恢复。

---

### mcmUpdate — 更新元数据

```
mcmUpdate <名称> [--name <新名>] [--description <描述>] [--tags <标签>] [--global]
```

**v2.0 改进**：`--tags` 参数已完整实现。变更标签时会移动目录到新分组并同步索引；无参数时进入交互模式。

---

### mcmExport / mcmImport — 导出导入

```
mcmExport <名称> [--output PATH] [--global]
mcmImport <文件> [--tags TAGS] [--global]
```

导出记忆为 tar.gz 归档，支持跨机器迁移。导入时自动重建搜索索引。

---

### mcmRestore / mcmEmptyTrash — 回收站

```
mcmRestore <回收站条目名>
mcmRestore --list
mcmEmptyTrash [--force]
```

- `mcmRestore` 将回收站中的记忆恢复到原始路径
- `mcmRestore --list` 列出回收站所有条目及其原始路径
- `mcmEmptyTrash` 永久清空回收站

---

## 工作流示例

### 典型开发工作流

```bash
# ===== 第 1 天：项目启动 =====
cd ~/projects/my-api
echo "# My API\nGo + Gin + PostgreSQL" > CLAUDE.md

mcmInit --name "my-api" --tags "backend"
# → 扫描 CLAUDE.md + package.json 等
# → 生成 L2 index.md + L3 chunks + L4 symlinks
# → AI 自动浓缩源文件内容到 L3 chunks

# ===== 第 3 天：架构变更 =====
vim CLAUDE.md
vim package.json  # 新增依赖

mcmSync
# → 检测到 2 个文件 hash 变化
# → 增量更新对应 chunk frontmatter
# → 刷新 L4 symlink，重建搜索索引

# ===== 排查问题时 =====
mcmSearch "PostgreSQL" --expand
# → 使用合并搜索索引，亚秒级响应

# ===== 加载方案讨论 =====
mcmLoad "my-api" --layer L3
# → 一次性加载所有浓缩内容到上下文

# ===== 项目归档时 =====
mcmExport "my-api" --output ./my-api-memory.tar.gz
mcmDelete "my-api" --force  # 移至回收站
```

### 个人知识管理

```bash
cd ~
cat > .claude/coding-style.md << 'EOF'
# 我的编码风格
- Go: 偏好显式错误处理，不用 panic
- 命名: 驼峰命名，导出函数首字母大写
- 注释: 英文注释，关键逻辑加中文说明
EOF

mcmInit --global --name "coding-style" --tags "auto" \
  --workspace "$HOME" \
  --description "Go/JS 编码风格偏好"

# 以后在新项目中搜索相关偏好
mcmSearch "错误处理" --global
mcmLoad "coding-style" --global --layer L3
```

---

## AI 记忆浓缩

mcMemory 的 L3 层依赖 AI 自动浓缩源文件内容。当 chunk 文件中出现 `[待AI补充：浓缩内容]` 占位符时，Claude 会自动：

1. 读取 chunk frontmatter 中的 `source_file` 字段
2. 读取对应源文件完整内容
3. 生成结构化浓缩内容（保留关键决策、API 签名、配置要点，目标长度为原文的 10-30%）
4. 原地更新 chunk 文件

`auto` 标签的全局记忆在会话启动时自动加载到上下文。

---

## 配置与自定义

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `MEMORY_BASE` | 记忆数据根目录 | `$HOME/.claude/mcMemories` |
| `PYTHON` | Python 解释器路径 | 自动检测 (`python3`/`python`/`py`) |
| `CHUNK_SPLIT_THRESHOLD` | 大文件拆分行数阈值 | `200` |
| `SOURCE_PATTERNS` | 额外源文件 glob 模式（空格分隔） | 空 |
| `MAX_INJECT_TOKENS_ESTIMATE` | 单次注入 token 预算 | `2000` |
| `MAX_INJECT_MEMORIES` | 单次注入最多记忆数 | `3` |
| `INJECT_COOLDOWN_SEC` | 注入冷却时间（秒） | `120` |

**示例：**

```bash
export MEMORY_BASE="/mnt/data/claude-memories"
export CHUNK_SPLIT_THRESHOLD=150
export SOURCE_PATTERNS="*.toml *.yaml"
```

### 扩展新标签

无需修改代码。直接使用即可：

```bash
mcmInit --tags "mobile,iOS" --name "my-ios-app"
# 标签 "mobile" 和 "iOS" 会自动创建，list/search 动态发现
```

### 自定义源文件检测

通过 `SOURCE_PATTERNS` 环境变量或直接编辑 `lib/core.sh` 中 `detect_source_files()` 的模式列表。

---

## 跨平台兼容

| 平台 | symlink | sha256sum | Python fallback | 状态 |
|------|---------|-----------|-----------------|------|
| Linux | `ln -sf` (相对路径) | `sha256sum` | ✅ | 完全支持 |
| macOS | `ln -sf` (相对路径) | `shasum -a 256` | ✅ | 完全支持 |
| Windows (Git Bash) | `.source` 文件 | Python `hashlib` | ✅ | L4 降级但功能完整 |
| Windows (WSL) | `ln -sf` (相对路径) | `sha256sum` | ✅ | 完全支持 |

**降级策略：**

- **Symlink 不可用 → `.source` 引用文件**：存储相对路径文本
- **`sha256sum` 不可用 → `shasum` → Python `hashlib`**：自动链式 fallback
- **`realpath` 不可用 → Python `os.path.realpath`**：自动 fallback
- **`flock` 不可用 → `mkdir` 原子性互斥锁**：并发保护不丢失

---

## 安全设计

- **路径白名单防护** — `safe_rm()` 拒绝删除 `~/.claude/mcMemories/` 之外的任何路径
- **Python 注入防护** — v2.0 全部 Python 调用使用 `sys.argv` 传参，杜绝路径字符串插值注入
- **并发锁保护** — 写操作获取 flock/mkdir 锁，防止多会话竞态损坏数据
- **回收站机制** — `mcmDelete` 默认移至 `.trash/`，支持恢复，防止误删
- **确认机制** — `mcmDelete` 和 `mcmEmptyTrash` 默认要求输入 `yes` 确认
- **预览模式** — `mcmDelete --dry-run` 支持操作前的安全预览
- **幂等操作** — `mcmInit` 和 `mcmSync` 可重复执行，不会产生重复数据

---

## 项目结构

```
mcMemory/
│
├── SKILL.md              # Claude Code Skill 注册文件
│                         # 声明名称、描述、允许的工具、AI 浓缩指令
│
├── README.md             # 项目文档（本文件）
│
├── CLAUDE.md             # Claude Code 项目指南（架构、设计要点）
│
├── lib/
│   ├── core.sh           # 共享工具库 (v2.2, ~945 行)
│   │   ├── 配置区         # MEMORY_BASE, PROJECTS_DIR, GLOBAL_DIR, TRASH_DIR, LOCK_DIR, SEARCH_INDEX
│   │   ├── 日志函数       # log(), error(), usage()
│   │   ├── 路径解析       # resolve_path(), calculate_relative_path() — macOS 兼容
│   │   ├── 并发锁         # acquire_lock(), release_lock() — flock → mkdir 回退
│   │   ├── Git 工具       # is_git_project(), get_git_root()
│   │   ├── Hash 计算      # calculate_hash() — sha256sum → shasum → Python (sys.argv)
│   │   ├── 文件时间       # get_mtime(), batch_file_info(), read_batch_info()
│   │   ├── 安全工具       # sed_escape(), sed_i() (跨平台 sed -i), safe_rm()
│   │   ├── 源文件检测     # detect_source_files() — .md + 常见配置文件扩展
│   │   ├── 标签发现       # get_project_tags(), get_global_modes() — 目录扫描
│   │   ├── 索引管理       # update_global_index(), ensure_index_file()
│   │   ├── L4 健康检查    # check_l4_health()
│   │   ├── L4 链接创建    # create_l4_link() — 优先相对路径
│   │   ├── Hash JSON 读写 # build_hash_json(), read_hash_keys(), read_hash_value() — 相对路径 key
│   │   ├── 大文件拆分     # split_source_file() — 按 ## 标题自动拆分
│   │   ├── 目录结构创建   # create_project_structure(), create_global_structure()
│   │   ├── Summary 生成   # generate_summary_md()
│   │   ├── 记忆查找       # find_project_memory_dir(), find_project_tag(), find_memory_path()
│   │   ├── 回收站         # move_to_trash(), list_trash(), restore_from_trash(), empty_trash()
│   │   └── 搜索索引       # rebuild_search_index(), update_search_index(), remove_from_search_index(), append_to_search_index() (v2.2 增量)
│   └── inject.sh          # 自动注入逻辑库 (v2.1, ~318 行)
│       ├── 关键词提取     # extract_keywords()
│       ├── 相关性匹配     # find_relevant_memories() — header 加权 + chunk 归一化 (v2.2)
│       ├── 冷却管理       # is_in_cooldown(), mark_injected()
│       ├── 注入格式化     # format_injection()
│       ├── 会话启动       # session_start_inject()
│       ├── 提示提交       # prompt_submit_inject()
│       └── 会话压缩       # precompact_save() — session_notes.md → L3 chunk (v2.2)
│
├── hooks/
│   ├── session-start.sh   # SessionStart hook — 自动加载项目+auto 全局记忆
│   ├── prompt-submit.sh   # UserPromptSubmit hook — 关键词智能检索注入
│   └── pre-compact.sh     # PreCompact hook — 会话笔记 → L3 chunk (v2.2)
│
├── commands/
│   ├── init.sh            # mcmInit — 初始化记忆 (v2.2 批量文件信息)
│   ├── sync.sh            # mcmSync — 增量同步 (v2.2 sys.argv 注入修复)
│   ├── load.sh            # mcmLoad — 加载记忆到会话
│   ├── search.sh          # mcmSearch — 全文搜索 (v2.2 scope 过滤 + JSON 注入修复)
│   ├── list.sh            # mcmList — 列出记忆 (v2.2 JSON 注入修复)
│   ├── status.sh          # mcmStatus — 健康总览
│   ├── auto-inject.sh     # mcmAutoInject — 一键开启/关闭自动注入 (v2.1)
│   ├── delete.sh          # mcmDelete — 删除（回收站，v2.2 增量索引）
│   ├── update.sh          # mcmUpdate — 更新元数据 (v2.2 sed_i)
│   ├── export.sh          # mcmExport — 导出 tar.gz
│   ├── import.sh          # mcmImport — 导入 tar.gz (v2.2 增量索引)
│   ├── restore.sh         # mcmRestore — 从回收站恢复 (v2.2 增量索引)
│   └── empty-trash.sh     # mcmEmptyTrash — 清空回收站
│
└── tests/
    └── test_core.sh       # 核心函数单元测试（46 项断言，bats/独立运行兼容）
```

---

## 常见问题

### Q: 记忆存储在哪里？
`~/.claude/mcMemories/` 目录下，独立于 skill 安装路径。

### Q: v2.0 和 v1.0 兼容吗？
数据目录结构兼容。v2.0 的 hash.json 新增 `mtime` 字段、key 改用相对路径，重新运行 `mcmInit` 即可迁移。回收站、搜索索引、锁目录均为新增，不影响已有数据。

### Q: 如何自定义标签？
直接使用任意标签名称即可，系统从目录结构动态发现，无需预定义。例如 `mcmInit --tags "mobile,iOS"`。

### Q: 大文件如何处理？
超过 200 行（可配置 `CHUNK_SPLIT_THRESHOLD`）的源文件自动按 `##` 标题拆分为多个 L3 chunk，便于按需加载。

### Q: 如何分享记忆？
`mcmExport` 导出为 tar.gz，`mcmImport` 在新机器导入。

### Q: 误删了记忆怎么办？
`mcmDelete` 移至回收站而非永久删除。使用 `mcmRestore --list` 查看，`mcmRestore <条目>` 恢复。

### Q: 多会话同时操作安全吗？
v2.0 加入并发锁机制（优先 flock，回退 mkdir 原子锁），防止写操作竞态。

### Q: L4 链接会因项目移动而断裂吗？
v2.0 优先使用相对路径 symlink，项目目录移动后 L4 引用仍然有效。

---

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| **v2.2** | 2026-06-04 | PreCompact 真正会话压缩（session_notes.md → L3 chunk）、增量搜索索引（O(chunks_in_memory) 替代 O(all_chunks)）、消除双次 split_source_file 调用、search.sh scope 过滤修复、批量文件信息 batch_file_info()、sed_i() 跨平台兼容、JSON 注入修复（json.dumps）、搜索相关性 header 加权 + chunk 归一化、46 项测试 |
| v2.1 | 2026-04-27 | 自动注入系统（mcmAutoInject + SessionStart/UserPromptSubmit/PreCompact hooks）、inject.sh 注入逻辑库、hook_config 修复、find_relevant_memories 全文扫描、global auto 标记注入冷却 |
| v2.0 | 2026-04-27 | **重大升级**：动态标签发现、回收站机制、并发锁、搜索索引、大文件自动拆分、L4 相对路径、Python sys.argv 注入防护、macOS realpath fallback、非 .md 源文件支持、JSON 输出、新增 6 个命令（load/status/export/import/restore/empty-trash）、AI 浓缩指令、21 项单元测试 |
| v1.0 | 2026-04-27 | 初始发布，纯 bash 版，Python 自动检测，Windows L4 兼容，完整增量同步 |

---

## 许可

MIT License

---

*Built for the Claude Code community.*
