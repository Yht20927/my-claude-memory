#!/bin/bash
# ============================================================================
# mcMemory SessionStart Hook
# ============================================================================
# 配置到 settings.json 的 hooks.SessionStart 中
# 自动加载项目记忆 + 全局 auto 记忆到新会话
# ============================================================================

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HOOK_DIR")"
source "$SKILL_DIR/lib/core.sh"
source "$SKILL_DIR/lib/inject.sh"

WORKSPACE="${1:-$(pwd)}"

# 确保搜索索引存在
if [ ! -f "$SEARCH_INDEX" ] || [ ! -s "$SEARCH_INDEX" ]; then
    rebuild_search_index 2>/dev/null || true
fi

# 注入项目记忆 + 全局 auto 记忆
INJECTION=$(session_start_inject "$WORKSPACE")

if [ -n "$INJECTION" ]; then
    echo "$INJECTION"
fi
