#!/bin/bash
# ============================================================================
# mcMemory UserPromptSubmit Hook
# ============================================================================
# 配置到 settings.json 的 hooks.UserPromptSubmit 中
# 从用户提问中提取关键词，智能检索并注入相关记忆
# ============================================================================

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HOOK_DIR")"
source "$SKILL_DIR/lib/core.sh"
source "$SKILL_DIR/lib/inject.sh"

# prompt 文本通过 stdin 传入
USER_PROMPT=$(cat)

# 太短的提示不做注入（如 "yes", "ok" 等）
PROMPT_LEN=${#USER_PROMPT}
if [ "$PROMPT_LEN" -lt 10 ]; then
    echo "$USER_PROMPT"
    exit 0
fi

# 智能检索注入
INJECTION=$(prompt_submit_inject "$USER_PROMPT")

if [ -n "$INJECTION" ]; then
    # 注入内容放在用户提示之前
    echo "$INJECTION"
fi

# 原样输出用户提示
echo "$USER_PROMPT"
