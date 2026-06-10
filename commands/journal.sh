#!/bin/bash
# ============================================================================
# mcmJournal - 追加一行/多行会话笔记到 .claude/session_notes.md (v2.4)
# ----------------------------------------------------------------------------
# 设计动机:
#   PreCompact hook (pre-compact.sh) 依赖 AI 主动写 .claude/session_notes.md，
#   但 AI 用 Write 工具写文件门槛高，结果"会话压缩→保存摘要"功能名存实亡。
#   mcmJournal 提供一行命令的低门槛入口，让 AI 在解决问题的任何时刻都能
#   随手 append："这一步发现了什么、决定了什么、为什么"。
# ----------------------------------------------------------------------------
# Usage:
#   mcmJournal "本次完成 X，发现了 Y 这个坑"
#   mcmJournal --append "继续补充"        # 等价于不带 flag
#   echo "..." | mcmJournal --stdin       # 多行从 stdin 读
#   mcmJournal --show                     # 打印当前 session_notes.md 内容
#   mcmJournal --clear                    # 清空（一般由 PreCompact 自动做）
#   mcmJournal --workspace PATH "..."     # 指定工作区（默认 $PWD）
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
source "$LIB_DIR/core.sh"

WORKSPACE="$(pwd)"
ACTION="append"
TEXT=""
FROM_STDIN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --append)    ACTION="append"; shift ;;
            --show)      ACTION="show"; shift ;;
            --clear)     ACTION="clear"; shift ;;
            --stdin)     FROM_STDIN=true; shift ;;
            --workspace) WORKSPACE="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
用法: mcmJournal [选项] [文本]

向 .claude/session_notes.md 追加会话笔记。

选项:
  --append              追加模式（默认）
  --show                打印当前 session_notes.md 内容
  --clear               清空 session_notes.md
  --stdin               从 stdin 读取多行内容
  --workspace PATH      指定工作区，默认 $PWD

示例:
  mcmJournal "v2.4 修复了 inject 永不注入的 bug"
  echo -e "决策 A\n决策 B" | mcmJournal --stdin
  mcmJournal --show
EOF
                exit 0
                ;;
            *)
                if [ -z "$TEXT" ]; then
                    TEXT="$1"
                else
                    TEXT="$TEXT $1"
                fi
                shift
                ;;
        esac
    done
}

# 确保 .claude 目录与 session_notes.md 存在
# 注意：不在文件中写入模板说明，因为 PreCompact 会把全文归档为 chunk，
# 模板文字反而成噪声。模板放在 SKILL.md / README.md 即可。
ensure_notes_file() {
    local workspace="$1"
    local claude_dir="$workspace/.claude"
    mkdir -p "$claude_dir"
    local notes="$claude_dir/session_notes.md"
    [ -f "$notes" ] || : > "$notes"
    echo "$notes"
}

main() {
    parse_args "$@"

    local notes
    notes=$(ensure_notes_file "$WORKSPACE")

    case "$ACTION" in
        show)
            if [ -s "$notes" ]; then
                cat "$notes"
            else
                echo "（session_notes.md 为空）"
            fi
            ;;
        clear)
            : > "$notes"
            log "已清空 $notes"
            ;;
        append)
            if [ "$FROM_STDIN" = true ]; then
                TEXT=$(cat)
            fi
            if [ -z "$TEXT" ]; then
                error "用法: mcmJournal <文本> 或 mcmJournal --stdin"
            fi

            local ts
            ts=$(date '+%H:%M:%S')
            {
                echo ""
                echo "- [$ts] $TEXT"
            } >> "$notes"
            log "已追加 ($(wc -c < "$notes") 字节): $TEXT"
            ;;
    esac
}

mcm_run_command main "$@"
