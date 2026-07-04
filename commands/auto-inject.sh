#!/bin/bash
# ============================================================================
# mcmAutoInject - 一键开启/关闭/暂停自动记忆注入 (v2.4)
# ============================================================================
# Usage:
#   mcmAutoInject [on|off|status] [--scope project|user]
#   mcmAutoInject pause <duration>    # 临时暂停注入（不改 settings.json）
#   mcmAutoInject resume              # 立即取消暂停
#
# duration 支持: 30m, 2h, 1d, 600s（不带单位 = 秒）
# pause 通过 $MEMORY_BASE/.paused_until 时间戳文件实现，hook 启动时检测。
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
source "$SKILL_DIR/lib/core.sh"

ACTION=""
SCOPE="project"
DURATION=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            on|off|status|pause|resume|stop|unstop)
                ACTION="$1"; shift
                # pause 后面跟 duration
                if [ "$ACTION" = "pause" ] && [ -n "$1" ] && [[ "$1" != --* ]]; then
                    DURATION="$1"; shift
                fi
                ;;
            --scope)        SCOPE="$2"; shift 2 ;;
            --help)         usage "用法: mcmAutoInject on|off|status|pause <dur>|resume|stop|unstop [--scope project|user]" ;;
            *)              shift ;;
        esac
    done
    [ -z "$ACTION" ] && ACTION="status"
    return 0   # set -e 下避免 [ -z ... ] 表达式整体返回 1 让函数退出
}

# ----------------------------------------------------------------------------
# duration 解析：30m / 2h / 1d / 600s / 600（裸数字 = 秒）
# 返回秒数
# ----------------------------------------------------------------------------
parse_duration_to_seconds() {
    local d="$1"
    [ -z "$d" ] && { echo 0; return; }
    local num="${d%[smhd]}"
    local unit="${d##*[0-9]}"
    case "$unit" in
        s|"") echo "$num" ;;
        m)    echo $((num * 60)) ;;
        h)    echo $((num * 3600)) ;;
        d)    echo $((num * 86400)) ;;
        *)    echo 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# pause / resume：在 $MEMORY_BASE/.paused_until 写入"恢复时间戳"
# ----------------------------------------------------------------------------
PAUSE_FILE="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.paused_until"
STOP_FILE="${MEMORY_BASE:-$HOME/.claude/mcMemories}/.stop"

do_pause() {
    local dur="${DURATION:-30m}"
    local seconds
    seconds=$(parse_duration_to_seconds "$dur")
    if [ "$seconds" -le 0 ]; then
        error "无法解析时长: $dur (示例: 30m / 2h / 1d / 600s)"
    fi
    local until_ts=$(( $(date +%s) + seconds ))
    mkdir -p "$(dirname "$PAUSE_FILE")"
    echo "$until_ts" > "$PAUSE_FILE"
    local until_str
    until_str=$(date -d "@$until_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "@$until_ts")
    echo "已暂停自动注入 $dur"
    echo "  恢复时间: $until_str"
    echo "  立刻取消: mcmAutoInject resume"
}

do_resume() {
    if [ -f "$PAUSE_FILE" ]; then
        rm -f "$PAUSE_FILE"
        echo "已取消自动注入暂停"
    else
        echo "当前未处于暂停状态"
    fi
}

# ----------------------------------------------------------------------------
# stop / unstop（v3.2 Phase 2）：全局无条件 kill-switch
# 与 pause（带时长自动恢复）互补：STOP 需显式 unstop 取消
# ----------------------------------------------------------------------------
do_stop() {
    mkdir -p "$(dirname "$STOP_FILE")"
    date '+%Y-%m-%dT%H:%M:%S' > "$STOP_FILE"
    echo "🛑 已全局停止自动注入（所有 hook 跳过注入，session_start/prompt_submit 均不触发）"
    echo "  恢复: mcmAutoInject unstop"
}

do_unstop() {
    if [ -f "$STOP_FILE" ]; then
        rm -f "$STOP_FILE"
        echo "已取消全局停止，自动注入恢复"
    else
        echo "当前未处于全局停止状态"
    fi
}

# 在 status 中显示 pause 状态
show_pause_status() {
    if [ ! -f "$PAUSE_FILE" ]; then
        return
    fi
    local until_ts
    until_ts=$(cat "$PAUSE_FILE" 2>/dev/null)
    [ -z "$until_ts" ] && return
    local now
    now=$(date +%s)
    if [ "$now" -ge "$until_ts" ]; then
        echo "  ⚠ pause 时间已过期（hook 下次启动将自动清理）"
        return
    fi
    local remain=$((until_ts - now))
    local until_str
    until_str=$(date -d "@$until_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "@$until_ts")
    echo ""
    echo "⏸  注入已暂停"
    echo "    恢复时间: $until_str (还剩 ${remain}s)"
    echo "    立刻取消: mcmAutoInject resume"
}

# 在 status 中显示全局 STOP 状态
show_stop_status() {
    if [ ! -f "$STOP_FILE" ]; then
        return
    fi
    local stopped_at
    stopped_at=$(cat "$STOP_FILE" 2>/dev/null)
    echo ""
    echo "🛑 注入已全局停止（自 $stopped_at）"
    echo "    所有 hook 跳过注入；恢复: mcmAutoInject unstop"
}

# ----------------------------------------------------------------------------
# 确定 settings.json 路径
# ----------------------------------------------------------------------------

settings_path() {
    if [ "$SCOPE" = "user" ]; then
        echo "$HOME/.claude/settings.json"
    else
        local git_root=$(get_git_root 2>/dev/null || echo "$(pwd)")
        echo "$git_root/.claude/settings.json"
    fi
}

hook_config() {
    cat <<HOOK_JSON
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $SKILL_DIR/hooks/session-start.sh \$(pwd)"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $SKILL_DIR/hooks/prompt-submit.sh"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $SKILL_DIR/hooks/pre-compact.sh \$(pwd)"
          }
        ]
      }
    ]
  }
}
HOOK_JSON
}

# ----------------------------------------------------------------------------
# 合并 JSON（使用 Python 深度合并）
# ----------------------------------------------------------------------------

merge_hooks_json() {
    local settings_file="$1"
    local hooks_json="$2"

    $PYTHON -c "
import json, sys, os

def get_first_command(handler):
    hooks = handler.get('hooks', [])
    if hooks:
        return hooks[0].get('command', '')
    return handler.get('command', '')

settings_file = sys.argv[1]
hooks_str = sys.argv[2]

existing = {}
if os.path.exists(settings_file):
    with open(settings_file) as f:
        try:
            existing = json.load(f)
        except:
            pass

new_hooks = json.loads(hooks_str)

existing.setdefault('hooks', {})
for event, handlers in new_hooks.get('hooks', {}).items():
    existing['hooks'].setdefault(event, [])
    existing_cmds = {get_first_command(h) for h in existing['hooks'][event]}
    for h in handlers:
        if get_first_command(h) not in existing_cmds:
            existing['hooks'][event].append(h)

os.makedirs(os.path.dirname(settings_file), exist_ok=True)
with open(settings_file, 'w') as f:
    json.dump(existing, f, indent=2, ensure_ascii=False)
print('OK')
" "$settings_file" "$hooks_json" 2>/dev/null
}

# ----------------------------------------------------------------------------
# 移除 mcMemory hooks
# ----------------------------------------------------------------------------

remove_hooks_json() {
    local settings_file="$1"

    $PYTHON -c "
import json, sys, os

def is_mcMemory_handler(handler):
    # Check old-format flat command field
    cmd = handler.get('command', '')
    if any(pat in cmd for pat in ['mcMemory', 'hooks/session-start', 'hooks/prompt-submit', 'hooks/pre-compact']):
        return True
    # Check new-format nested hooks array
    for hk in handler.get('hooks', []):
        cmd = hk.get('command', '')
        if any(pat in cmd for pat in ['mcMemory', 'hooks/session-start', 'hooks/prompt-submit', 'hooks/pre-compact']):
            return True
    return False

settings_file = sys.argv[1]
if not os.path.exists(settings_file):
    print('no settings file')
    sys.exit(0)

with open(settings_file) as f:
    data = json.load(f)

hooks = data.get('hooks', {})
removed = 0
for event in list(hooks.keys()):
    if not isinstance(hooks[event], list):
        continue
    before = len(hooks[event])
    hooks[event] = [h for h in hooks[event] if not is_mcMemory_handler(h)]
    removed += (before - len(hooks[event]))

data['hooks'] = hooks
with open(settings_file, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('removed ' + str(removed) + ' handlers')
" "$settings_file" 2>/dev/null
}

# ----------------------------------------------------------------------------
# 显示状态
# ----------------------------------------------------------------------------

show_status() {
    local settings_file=$(settings_path)

    echo "## mcMemory 自动注入状态"
    echo ""
    echo "作用域: $SCOPE"
    echo "配置文件: $settings_file"
    echo ""

    if [ ! -f "$settings_file" ]; then
        echo "状态: **未配置**"
        echo ""
        echo "运行 \`mcmAutoInject on\` 开启自动注入"
        return
    fi

    local active=false
    if grep -q 'session-start\|prompt-submit\|pre-compact' "$settings_file" 2>/dev/null; then
        active=true
    fi

    if [ "$active" = true ]; then
        echo "状态: **已开启**"
        echo ""
        echo "已注册的 Hook 事件:"
        grep -E '(SessionStart|UserPromptSubmit|PreCompact)' "$settings_file" -B1 2>/dev/null | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | sort -u | while read -r event; do
            echo "  - $event"
        done

        if [ -d "$MEMORY_BASE/.inject_state" ]; then
            local count=$(ls "$MEMORY_BASE/.inject_state"/*.last 2>/dev/null | wc -l)
            echo ""
            echo "已追踪 ${count##* } 个注入记忆"
            echo ""
            echo "最近的注入记录:"
            for f in "$MEMORY_BASE/.inject_state"/*.last; do
                [ -f "$f" ] || continue
                local name=$(basename "$f" .last)
                local ts=$(cat "$f")
                local time_str=$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")
                echo "  - $name: $time_str"
            done
        fi
    else
        echo "状态: **未配置**"
    fi

    echo ""
    echo "---"
    echo "操作:"
    echo "  mcmAutoInject on             开启自动注入"
    echo "  mcmAutoInject off            关闭自动注入"
    echo "  mcmAutoInject status         查看状态"
    echo "  mcmAutoInject pause <dur>    临时暂停 (30m / 2h / 1d)"
    echo "  mcmAutoInject resume         立即取消暂停"
    echo "  mcmAutoInject stop           全局停止（无条件，需 unstop 取消）"
    echo "  mcmAutoInject unstop         取消全局停止"
    echo ""
    echo "作用域:"
    echo "  --scope project  当前项目（默认）"
    echo "  --scope user     全局用户"

    show_pause_status
    show_stop_status
}

# ----------------------------------------------------------------------------
# 主函数
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    local settings_file=$(settings_path)

    case "$ACTION" in
        on)
            log "开启自动注入: $settings_file"
            local hooks=$(hook_config)
            merge_hooks_json "$settings_file" "$hooks"
            log "自动注入已开启"
            echo ""
            echo "已配置以下 Hook:"
            echo "  SessionStart      → 自动加载项目记忆 + auto 全局记忆"
            echo "  UserPromptSubmit   → 智能检索相关记忆并注入"
            echo "  PreCompact         → 会话压缩前保存摘要"
            echo ""
            echo "注意: 修改后需重启 Claude Code 会话生效"
            ;;

        off)
            log "关闭自动注入: $settings_file"
            remove_hooks_json "$settings_file"
            log "自动注入已关闭"
            echo "自动注入已关闭。修改后需重启 Claude Code 会话生效。"
            ;;

        status)
            show_status
            ;;

        pause)
            do_pause
            ;;

        resume)
            do_resume
            ;;

        stop)
            do_stop
            ;;

        unstop)
            do_unstop
            ;;
    esac
}

mcm_run_command main "$@"
