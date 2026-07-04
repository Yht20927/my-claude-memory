#!/bin/bash
# ============================================================================
# mcmInjectLog - 查看自动注入日志 (v3.0)
# ----------------------------------------------------------------------------
# v3.0 数据源切换:
#   旧版从 .inject_log（管道分隔）读取；v3.0 改为从 .events.ndjson 过滤
#   type=inject.* 事件。CLI 接口与 JSON schema 完全保持兼容。
#
# 设计动机:
#   原本 hook 注入对用户完全不可见——用户不知道"为什么这次 Claude 突然提到了
#   某个旧记忆"。本命令显示最近若干次注入事件（哪个记忆、什么得分、什么关键词
#   触发的、什么时间），便于排查"为什么注入了/没注入"。
# ----------------------------------------------------------------------------
# Usage:
#   mcmInjectLog                  # 默认 tail 20
#   mcmInjectLog --tail 50        # 看最近 50 条
#   mcmInjectLog --tail 0         # 全部
#   mcmInjectLog --clear          # 清空 inject.* 事件（其他事件保留）
#   mcmInjectLog --json           # JSON 输出
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"   # v3.5: 不再 source inject.sh —— pause 路径内联惰性求值

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
  --clear     清空 inject.* 事件（事件总线中其他事件保留）
  --json      JSON 输出

数据源: $MCM_EVENTS_FILE（type=inject.* 的事件）

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

# 把 .events.ndjson 里的 inject.* 事件抽出来，映射回 v2.x 5 字段格式
# 输出到 stdout：每行 5 字段，制表符分隔，便于后续渲染
_extract_inject_records() {
    [ -f "$MCM_EVENTS_FILE" ] || return 0
    $PYTHON -c '
import json, sys
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        obj = json.loads(raw)
    except Exception:
        continue
    t = obj.get("type", "")
    if not t.startswith("inject."):
        continue
    event = t[len("inject."):]
    # 制表符分隔（inject.* 字段不含 \t，安全）
    print("\t".join([
        obj.get("ts", ""),
        event,
        obj.get("memory", ""),
        obj.get("score", ""),
        obj.get("keywords", ""),
    ]))
' < "$MCM_EVENTS_FILE"
}

show_log() {
    local records
    records=$(_extract_inject_records)

    # 应用 tail
    local lines
    if [ -z "$records" ]; then
        lines=""
    elif [ "$TAIL_N" = "0" ]; then
        lines="$records"
    else
        lines=$(echo "$records" | tail -n "$TAIL_N")
    fi

    if [ -z "$lines" ]; then
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

    if [ "$JSON" = true ]; then
        $PYTHON -c '
import json, sys
out = []
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    parts = raw.split("\t", 4)
    while len(parts) < 5:
        parts.append("")
    out.append({
        "ts": parts[0],
        "event": parts[1],
        "memory": parts[2],
        "score": parts[3],
        "keywords": parts[4],
    })
print(json.dumps(out, indent=2, ensure_ascii=False))
' <<< "$lines"
        return
    fi

    # 文本输出：对齐为表格
    echo "## 自动注入日志（最近 $TAIL_N 条，数据源: $MCM_EVENTS_FILE）"
    echo ""
    printf '%-25s %-15s %-25s %-6s %s\n' "时间" "事件" "记忆" "得分" "关键词"
    printf '%-25s %-15s %-25s %-6s %s\n' "----" "----" "----" "----" "----"
    echo "$lines" | while IFS=$'\t' read -r ts event memory score keywords; do
        [ -z "$ts" ] && continue
        printf '%-25s %-15s %-25s %-6s %s\n' \
            "$ts" "$event" "${memory:--}" "${score:--}" "${keywords:--}"
    done

    # 暂停状态提示（v3.5: 路径惰性求值，不依赖 inject.sh 冻结常量）
    local pause_file="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.paused_until"
    if [ -f "$pause_file" ]; then
        local until_ts
        until_ts=$(cat "$pause_file" 2>/dev/null)
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

# 清空仅 inject.* 事件（不动 cmd.* / hook.* 等）
# Python 原子重写 .events.ndjson
clear_log() {
    if [ ! -f "$MCM_EVENTS_FILE" ]; then
        echo "事件文件不存在: $MCM_EVENTS_FILE"
        return
    fi

    local before after
    before=$(grep -c '"type":"inject\.' "$MCM_EVENTS_FILE" 2>/dev/null || true)
    [ -z "$before" ] && before=0

    local tmp="${MCM_EVENTS_FILE}.tmp.$$"
    $PYTHON -c '
import json, sys
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    try:
        obj = json.loads(raw)
        if obj.get("type", "").startswith("inject."):
            continue
    except Exception:
        # 解析失败的行保留（不丢数据）
        pass
    print(raw)
' < "$MCM_EVENTS_FILE" > "$tmp" && mv -f "$tmp" "$MCM_EVENTS_FILE" || { rm -f "$tmp"; error "清空失败"; }

    after=$(grep -c '"type":"inject\.' "$MCM_EVENTS_FILE" 2>/dev/null || true)
    [ -z "$after" ] && after=0
    echo "已清空 inject.* 事件: ${before} → ${after}（其他事件保留）"
}

main() {
    parse_args "$@"
    case "$ACTION" in
        show)  show_log ;;
        clear) clear_log ;;
    esac
}

mcm_run_command main "$@"
