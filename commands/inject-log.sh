#!/bin/bash
# ============================================================================
# mcmInjectLog - 查看自动注入日志 (v2.4)
# ----------------------------------------------------------------------------
# 设计动机:
#   原本 hook 注入对用户完全不可见——用户不知道"为什么这次 Claude 突然提到了
#   某个旧记忆"。本命令显示最近若干次注入事件（哪个记忆、什么得分、什么关键词
#   触发的、什么时间），便于排查"为什么注入了/没注入"。
# ----------------------------------------------------------------------------
# Usage:
#   mcmInjectLog                  # 默认 tail 20
#   mcmInjectLog --tail 50        # 看最近 50 条
#   mcmInjectLog --tail 0         # 全部
#   mcmInjectLog --clear          # 清空日志
#   mcmInjectLog --json           # JSON 输出
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"
source "$LIB_DIR/inject.sh"   # 引入 INJECT_LOG_FILE / INJECT_PAUSE_FILE

TAIL_N=20
ACTION="show"
JSON=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tail)   TAIL_N="$2"; shift 2 ;;
            --clear)  ACTION="clear"; shift ;;
            --json)   JSON=true; shift ;;
            --help)
                cat <<'EOF'
用法: mcmInjectLog [--tail N] [--clear] [--json]

查看自动注入事件日志，便于了解"哪些记忆在什么时间被注入"。

选项:
  --tail N    显示最近 N 条（0 = 全部），默认 20
  --clear     清空日志
  --json      JSON 输出

日志格式（管道分隔）：
  时间 | 事件 | 记忆名 | 得分 | 关键词

事件类型:
  session_start  - SessionStart hook 加载项目记忆/auto 记忆
  prompt_submit  - UserPromptSubmit 智能注入
  paused         - 因 mcmAutoInject pause 跳过
EOF
                exit 0
                ;;
            *) shift ;;
        esac
    done
}

show_log() {
    if [ ! -f "$INJECT_LOG_FILE" ] || [ ! -s "$INJECT_LOG_FILE" ]; then
        if [ "$JSON" = true ]; then
            echo "[]"
        else
            echo "（注入日志为空）"
            echo ""
            echo "提示：自动注入开启后，每次 SessionStart 或 UserPromptSubmit"
            echo "      触发的事件都会写入此日志。"
        fi
        return
    fi

    local lines
    if [ "$TAIL_N" = "0" ]; then
        lines=$(cat "$INJECT_LOG_FILE")
    else
        lines=$(tail -n "$TAIL_N" "$INJECT_LOG_FILE")
    fi

    if [ "$JSON" = true ]; then
        $PYTHON -c "
import json, sys
out = []
for raw in sys.stdin:
    raw = raw.rstrip('\n')
    if not raw:
        continue
    parts = raw.split('|', 4)
    while len(parts) < 5:
        parts.append('')
    out.append({
        'ts': parts[0],
        'event': parts[1],
        'memory': parts[2],
        'score': parts[3],
        'keywords': parts[4],
    })
print(json.dumps(out, indent=2, ensure_ascii=False))
" <<< "$lines"
        return
    fi

    # 文本输出：对齐为表格
    echo "## 自动注入日志（最近 $TAIL_N 条，文件: $INJECT_LOG_FILE）"
    echo ""
    printf '%-25s %-15s %-25s %-6s %s\n' "时间" "事件" "记忆" "得分" "关键词"
    printf '%-25s %-15s %-25s %-6s %s\n' "----" "----" "----" "----" "----"
    echo "$lines" | while IFS='|' read -r ts event memory score keywords; do
        [ -z "$ts" ] && continue
        printf '%-25s %-15s %-25s %-6s %s\n' \
            "$ts" "$event" "${memory:--}" "${score:--}" "${keywords:--}"
    done

    # 暂停状态提示
    if [ -f "$INJECT_PAUSE_FILE" ]; then
        local until_ts
        until_ts=$(cat "$INJECT_PAUSE_FILE" 2>/dev/null)
        local now=$(date +%s)
        if [ -n "$until_ts" ] && [ "$now" -lt "$until_ts" ]; then
            local until_str
            until_str=$(date -d "@$until_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "@$until_ts")
            echo ""
            echo "⏸  当前已暂停注入（恢复时间: $until_str）"
            echo "    立刻取消: mcmAutoInject resume"
        fi
    fi
}

clear_log() {
    if [ -f "$INJECT_LOG_FILE" ]; then
        : > "$INJECT_LOG_FILE"
        echo "已清空 $INJECT_LOG_FILE"
    else
        echo "日志文件不存在: $INJECT_LOG_FILE"
    fi
}

main() {
    parse_args "$@"
    case "$ACTION" in
        show)  show_log ;;
        clear) clear_log ;;
    esac
}

main "$@"
