#!/bin/bash
# ============================================================================
# mcMemory SessionStart Hook
# ============================================================================
# 配置到 settings.json 的 hooks.SessionStart 中
# 自动加载项目记忆 + 全局 auto 记忆到新会话
#
# 安全机制（v2.4）:
#   - inject 调用包裹 timeout（默认 MCM_HOOK_TIMEOUT_SESSION=3s）
#     SessionStart 允许稍长（首次启动可能需要重建索引），但仍有硬上限
#   - 任何失败都静默返回，不影响会话启动
# ============================================================================

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HOOK_DIR")"

WORKSPACE="${1:-$(pwd)}"

# 超时控制
MCM_HOOK_TIMEOUT="${MCM_HOOK_TIMEOUT_SESSION:-3s}"
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
fi

INJECTION=""
if [ -n "$TIMEOUT_CMD" ]; then
    INJECTION=$($TIMEOUT_CMD "$MCM_HOOK_TIMEOUT" bash -c '
        SKILL_DIR="$1"
        WORKSPACE="$2"
        source "$SKILL_DIR/lib/core.sh" 2>/dev/null
        source "$SKILL_DIR/lib/inject.sh" 2>/dev/null
        if [ ! -f "$SEARCH_INDEX" ] || [ ! -s "$SEARCH_INDEX" ]; then
            rebuild_search_index 2>/dev/null || true
        fi
        session_start_inject "$WORKSPACE"
    ' _ "$SKILL_DIR" "$WORKSPACE" 2>/dev/null) || INJECTION=""
else
    # 无 timeout 工具：直接调用（接受可能的卡顿风险）
    source "$SKILL_DIR/lib/core.sh" 2>/dev/null
    source "$SKILL_DIR/lib/inject.sh" 2>/dev/null
    if [ ! -f "$SEARCH_INDEX" ] || [ ! -s "$SEARCH_INDEX" ]; then
        rebuild_search_index 2>/dev/null || true
    fi
    INJECTION=$(session_start_inject "$WORKSPACE" 2>/dev/null) || INJECTION=""
fi

if [ -n "$INJECTION" ]; then
    echo "$INJECTION"
fi
