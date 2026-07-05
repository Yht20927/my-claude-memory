#!/bin/bash
# ============================================================================
# mcmLedger - 会话决策日志 (v3.6 Phase 6)
# ============================================================================
# Usage:
#   mcmLedger add <type> <text> [opts...]     追加决策/待办/阻断条目
#   mcmLedger list [opts...]                  列出条目（支持过滤）
#   mcmLedger resolve <id> [note]             关闭条目（追加 done + resolves）
#   mcmLedger show <id>                       显示单条目全文
#
#   type ∈ {decision, blocker, todo, learning, done, note}
#   actor ∈ {user, agent, system}
#
# Examples:
#   mcmLedger decision "采用 BM25 替代向量检索"
#   mcmLedger todo "实现 ledger list" --context "需要 --status 过滤"
#   mcmLedger blocker "bigram 误召回" --refs chunks/1_SEARCH.md
#   echo "多行 context" | mcmLedger note "标题" --stdin
#   mcmLedger list --type todo --status open --since 7
#   mcmLedger resolve 2026-07-04T23:30:00 "已实现，见 commit abc123"
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"
source "$LIB_DIR/ledger.sh"

SUBCMD=""
TYPE=""
TEXT=""
MEMORY_NAME=""
IS_GLOBAL=false
CONTEXT=""
REFS=""
ACTOR="user"
FROM_STDIN=false
WORKSPACE="$(pwd)"

# list 过滤
FILTER_TYPE=""
FILTER_STATUS=""
FILTER_SINCE=""
FILTER_LIMIT=""
FORMAT_JSON=false

VALID_LEDGER_TYPES="decision blocker todo learning done note"
VALID_ACTORS="user agent system"

# ----------------------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------------------

parse_args() {
    local -a positional=()

    # 第一轮：收 flags 和 positionals
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --memory)       MEMORY_NAME="$2"; shift 2 ;;
            --global)       IS_GLOBAL=true; shift ;;
            --context)      CONTEXT="$2"; shift 2 ;;
            --stdin)        FROM_STDIN=true; shift ;;
            --refs)         REFS="$2"; shift 2 ;;
            --actor)        ACTOR="$2"; shift 2 ;;
            --workspace)    WORKSPACE="$2"; shift 2 ;;
            --type)         FILTER_TYPE="$2"; shift 2 ;;
            --status)       FILTER_STATUS="$2"; shift 2 ;;
            --since)        FILTER_SINCE="$2"; shift 2 ;;
            --limit)        FILTER_LIMIT="$2"; shift 2 ;;
            --json)         FORMAT_JSON=true; shift ;;
            --help)         _usage; exit 0 ;;
            *)              positional+=("$1"); shift ;;
        esac
    done

    # 第二轮：从 positionals 识别子命令 / type
    if [ ${#positional[@]} -gt 0 ]; then
        local first="${positional[0]}"
        case "$first" in
            add|list|resolve|show)
                SUBCMD="$first"
                positional=("${positional[@]:1}")
                ;;
            *)
                SUBCMD="add"
                TYPE="$first"
                positional=("${positional[@]:1}")
                ;;
        esac
    fi

    # 剩余 positional 合并为 TEXT
    if [ ${#positional[@]} -gt 0 ]; then
        TEXT="${positional[*]}"
    fi
}

_usage() {
    cat <<'EOF'
用法: mcmLedger <子命令> [选项]

子命令:
  add <type> <text>     追加条目（type 可省略 add）
  list                  列出条目
  resolve <id> [note]   关闭条目
  show <id>             显示单条目全文

type: decision, blocker, todo, learning, done, note

选项:
  --memory <名>         指定记忆名称（默认当前 workspace 项目）
  --global              对全局记忆操作
  --context <文本>      补充背景
  --stdin               从 stdin 读取文本（与 --context 配合）
  --refs <路径>         引用文件/ chunk，逗号分隔
  --actor user|agent|system  默认 user
  --workspace PATH      指定工作区
  --type <type>         list: 按类型过滤
  --status open|resolved|superseded  list: 按状态过滤
  --since N             list: 最近 N 天
  --limit N             list: 最多 N 条
  --json                list/show: JSON 输出
EOF
}

_validate() {
    if [ -z "$SUBCMD" ]; then
        echo "用法: mcmLedger <add|list|resolve|show> ..."
        exit 1
    fi

    if [ "$SUBCMD" = "add" ]; then
        if [ -z "$TYPE" ]; then
            echo "错误: add 需要指定 type"
            exit 1
        fi
        if ! printf '%s\n' $VALID_LEDGER_TYPES | grep -Fxq -- "$TYPE"; then
            echo "错误: type 必须是 decision|blocker|todo|learning|done|note 之一"
            exit 1
        fi
        if ! printf '%s\n' $VALID_ACTORS | grep -Fxq -- "$ACTOR"; then
            echo "错误: actor 必须是 user|agent|system 之一"
            exit 1
        fi
    fi
}

# ----------------------------------------------------------------------------
# Step 1: 定位记忆
# ----------------------------------------------------------------------------

step1_detect() {
    local memory_path=""

    if [ -n "$MEMORY_NAME" ]; then
        memory_path=$(find_memory_path "$MEMORY_NAME" "$IS_GLOBAL")
    elif [ "$IS_GLOBAL" = true ]; then
        # global 未指定名称 → 错误
        echo "错误: global 记忆需指定 --memory <名称>" >&2
        exit 1
    else
        memory_path=$(find_project_memory_dir "$WORKSPACE")
    fi

    if [ -z "$memory_path" ] || [ ! -d "$memory_path" ]; then
        echo "错误: 未找到记忆" >&2
        exit 1
    fi

    echo "$memory_path"
}

# ----------------------------------------------------------------------------
# Step 2: 执行子命令
# ----------------------------------------------------------------------------

step2_action() {
    local memory_path="$1"
    local mem_name
    mem_name=$(basename "$memory_path")
    local ledger_file
    ledger_file=$(ledger_path "$memory_path")

    case "$SUBCMD" in
        add)
            # stdin 模式
            if [ "$FROM_STDIN" = true ]; then
                local stdin_text
                stdin_text=$(cat)
                if [ -n "$stdin_text" ]; then
                    if [ -n "$CONTEXT" ]; then
                        CONTEXT="$CONTEXT\n$stdin_text"
                    else
                        CONTEXT="$stdin_text"
                    fi
                fi
            fi

            if [ -z "$TEXT" ] && [ "$FROM_STDIN" != true ]; then
                echo "错误: add 需要提供文本内容" >&2
                exit 1
            fi

            local id
            id=$(ledger_add "$memory_path" "$TYPE" "$TEXT" "$ACTOR" "$CONTEXT" "$REFS")
            echo "$id"

            # op-log + event
            log_memory_op "$memory_path" "ledger" "type=$TYPE id=$id" "$ACTOR"
            emit_event "ledger.add" type="$TYPE" memory="$mem_name" id="$id"
            ;;

        list)
            if [ ! -f "$ledger_file" ]; then
                echo "（无决策日志）"
                return 0
            fi

            export LEDGER_FILTER_TYPE="$FILTER_TYPE"
            export LEDGER_FILTER_STATUS="$FILTER_STATUS"
            export LEDGER_FILTER_SINCE="$FILTER_SINCE"
            export LEDGER_FILTER_LIMIT="$FILTER_LIMIT"
            export LEDGER_FORMAT_JSON="$([ "$FORMAT_JSON" = true ] && echo 1 || echo 0)"

            local out
            out=$(ledger_list "$ledger_file")

            if [ "$FORMAT_JSON" = true ]; then
                echo "$out"
            else
                echo "## ledger: $mem_name"
                echo "$out"
            fi
            ;;

        resolve)
            local target_id="$TEXT"
            local note="已完成"
            # TEXT 可能包含 "id note"，拆分
            if [[ "$TEXT" == *" "* ]]; then
                target_id="${TEXT%% *}"
                note="${TEXT#* }"
            fi

            if [ -z "$target_id" ]; then
                echo "错误: resolve 需要指定 <id>" >&2
                exit 1
            fi

            local new_id
            new_id=$(ledger_resolve "$memory_path" "$target_id" "$note" "$ACTOR")

            echo "$new_id"

            # op-log + event
            log_memory_op "$memory_path" "ledger" "resolve id=$target_id new_id=$new_id" "$ACTOR"
            emit_event "ledger.resolve" memory="$mem_name" target_id="$target_id" new_id="$new_id"
            ;;

        show)
            local target_id="$TEXT"
            if [ -z "$target_id" ]; then
                echo "错误: show 需要指定 <id>" >&2
                exit 1
            fi

            if [ "$FORMAT_JSON" = true ]; then
                # JSON 输出：找到对应条目并输出 JSON
                local parsed
                parsed=$(ledger_parse "$ledger_file")
                $PYTHON - "$parsed" "$target_id" <<'PY' 2>/dev/null
import json, sys
entries = json.loads(sys.argv[1])
target = sys.argv[2]
for e in entries:
    if e['id'] == target:
        print(json.dumps(e, ensure_ascii=False))
        sys.exit(0)
print(json.dumps({"error": "未找到条目"}))
PY
            else
                ledger_show "$ledger_file" "$target_id"
            fi
            ;;
    esac
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    _validate

    local memory_path
    memory_path=$(step1_detect)

    local lock_name
    lock_name="ledger_$(basename "$memory_path")"
    local lock_token
    lock_token=$(acquire_lock "$lock_name")
    mcm_on_exit "release_lock '$lock_name' '$lock_token'"

    step2_action "$memory_path"

    release_lock "$lock_name" "$lock_token"
    mcm_clear_exit_handlers
}

mcm_run_command main "$@"
