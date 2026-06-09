#!/bin/bash
# ============================================================================
# mcMemory UserPromptSubmit Hook
# ============================================================================
# 配置到 settings.json 的 hooks.UserPromptSubmit 中
# 从用户提问中提取关键词，智能检索并注入相关记忆
#
# 安全机制（v2.4）:
#   - inject 调用包裹 timeout（默认 MCM_HOOK_TIMEOUT=1.5s），防止索引
#     异常时卡住用户的每次提问
#   - inject 失败/超时静默吞噬错误，原样输出用户 prompt，保证主流程
#     不被记忆系统拖垮
# ============================================================================

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HOOK_DIR")"

# prompt 文本通过 stdin 传入
USER_PROMPT=$(cat)

# 太短的提示不做注入（如 "yes", "ok" 等）
PROMPT_LEN=${#USER_PROMPT}
if [ "$PROMPT_LEN" -lt 10 ]; then
    echo "$USER_PROMPT"
    exit 0
fi

# 超时控制：优先 timeout（GNU coreutils），回退 gtimeout（macOS brew），
# 都没有则直接运行（不强制依赖）
MCM_HOOK_TIMEOUT="${MCM_HOOK_TIMEOUT:-1.5s}"
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
fi

# 智能检索注入（带超时 + 错误吞噬）
INJECTION=""
if [ -n "$TIMEOUT_CMD" ]; then
    INJECTION=$($TIMEOUT_CMD "$MCM_HOOK_TIMEOUT" bash -c '
        source "$1" 2>/dev/null
        source "$2" 2>/dev/null
        prompt_submit_inject "$3"
    ' _ "$SKILL_DIR/lib/core.sh" "$SKILL_DIR/lib/inject.sh" "$USER_PROMPT" 2>/dev/null) || INJECTION=""
else
    # 无 timeout 工具：直接调用（接受可能的卡顿风险）
    source "$SKILL_DIR/lib/core.sh" 2>/dev/null
    source "$SKILL_DIR/lib/inject.sh" 2>/dev/null
    INJECTION=$(prompt_submit_inject "$USER_PROMPT" 2>/dev/null) || INJECTION=""
fi

if [ -n "$INJECTION" ]; then
    # 注入内容放在用户提示之前
    echo "$INJECTION"
fi

# 原样输出用户提示
echo "$USER_PROMPT"
