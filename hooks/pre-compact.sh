#!/bin/bash
# ============================================================================
# mcMemory PreCompact Hook
# ============================================================================
# 配置到 settings.json 的 hooks.PreCompact 中
# 在上下文压缩前，读取 AI 写入的 .claude/session_notes.md，
# 生成 L3 chunk 存入项目记忆，并清空笔记文件。
#
# 用法: bash hooks/pre-compact.sh [workspace_path]
# ============================================================================

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HOOK_DIR")"
source "$SKILL_DIR/lib/core.sh"
source "$SKILL_DIR/lib/inject.sh"

WORKSPACE="${1:-$(pwd)}"

# 读取 session_notes.md → 生成 L3 chunk → 清空源文件 → 更新搜索索引
precompact_save "$WORKSPACE" 2>/dev/null || true
