#!/bin/bash
# ============================================================================
# mcMemory PreCompact Hook
# ============================================================================
# 配置到 settings.json 的 hooks.PreCompact 中
# 在上下文压缩前，读取 AI 写入的 .claude/session_notes.md，
# 生成 L3 chunk 存入项目记忆，并清空笔记文件。
#
# 用法: bash hooks/pre-compact.sh [workspace_path]
#
# 安全机制（v2.4）:
#   - 调用包裹 timeout（默认 MCM_HOOK_TIMEOUT_COMPACT=5s）
#     PreCompact 通常涉及写入，给较宽容的预算
#   - 任何失败都静默吞噬（|| true），不阻断压缩
# ============================================================================

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HOOK_DIR")"

WORKSPACE="${1:-$(pwd)}"

# 引入事件总线（v3.0 / A4-min）
source "$SKILL_DIR/lib/core.sh" 2>/dev/null
HOOK_START_MS=$(_mcm_now_ms 2>/dev/null || echo 0)
emit_event hook.invoke kind=pre_compact workspace="$WORKSPACE"

MCM_HOOK_TIMEOUT="${MCM_HOOK_TIMEOUT_COMPACT:-5s}"
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
fi

HOOK_EXIT=0
if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD "$MCM_HOOK_TIMEOUT" bash -c '
        SKILL_DIR="$1"
        WORKSPACE="$2"
        source "$SKILL_DIR/lib/core.sh" 2>/dev/null
        source "$SKILL_DIR/lib/inject.sh" 2>/dev/null
        precompact_save "$WORKSPACE"
    ' _ "$SKILL_DIR" "$WORKSPACE" 2>/dev/null || HOOK_EXIT=$?
else
    source "$SKILL_DIR/lib/inject.sh" 2>/dev/null
    precompact_save "$WORKSPACE" 2>/dev/null || HOOK_EXIT=$?
fi

HOOK_END_MS=$(_mcm_now_ms 2>/dev/null || echo "$HOOK_START_MS")
emit_event hook.complete kind=pre_compact \
    duration_ms=$((HOOK_END_MS - HOOK_START_MS)) \
    exit="$HOOK_EXIT"
