#!/bin/bash
# ============================================================================
# mcMemory-events - 统一事件总线 (v3.0 Phase 0 / A4-min)
# ============================================================================
# 提供单行 NDJSON 事件追加 + 命令生命周期采集，是 mcmMetrics（Phase 1）
# 与 bench gate（Phase 3）与集成测试断言的共同基础设施。
#
# 设计原则：
#   1. 写入路径绝不能拖垮主流程：失败静默（沿用 log_injection 的哲学）
#   2. POSIX < PIPE_BUF（~4KB）的 O_APPEND 单行写在 Linux 上是原子的，
#      记录短到不需要 flock（参考 lib/inject.sh:60 注释）
#   3. 截尾路径 tmp+mv 原子替换（参考 _atomic_write_index）
#   4. 字段转义按"够用"水平：仅 " 与换行；不追求完整 JSON 转义
#
# 依赖：core.sh 必须已 source（提供 MCM_EVENTS_FILE / MCM_EVENTS_MAX_BYTES
#       / MCM_EVENTS_TAIL_LINES 三个配置）。
# ============================================================================

# ----------------------------------------------------------------------------
# 内部：返回当前毫秒时间戳（Linux GNU date 优先，否则 Python，否则秒×1000）
# ----------------------------------------------------------------------------
_mcm_now_ms() {
    local ms
    ms=$(date +%s%3N 2>/dev/null)
    # GNU date 返回 13 位；BSD date 不识别 %3N 会返回带字面 %3N 的串
    if [[ "$ms" =~ ^[0-9]{13}$ ]]; then
        printf '%s' "$ms"
        return
    fi
    if [ -n "$PYTHON" ]; then
        "$PYTHON" -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return
    fi
    printf '%s000' "$(date +%s)"
}

# ----------------------------------------------------------------------------
# 内部：JSON 字符串转义（仅 \ " 与控制字符常见三个）
# ----------------------------------------------------------------------------
_mcm_json_escape() {
    local s="$1"
    # 反斜杠先转，避免后续转义被重复处理
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# emit_event TYPE [key=val ...]
#
# 追加一行 NDJSON 到 $MCM_EVENTS_FILE。
# 例:
#   emit_event cmd.start cmd=mcmSync
#   emit_event inject.prompt_submit memory=foo score=2.34 keywords=a,b,c
#
# 写入失败（磁盘满 / 路径不可写）静默吞掉 — 事件总线绝不能拖垮主流程。
# ----------------------------------------------------------------------------
emit_event() {
    local type="$1"; shift
    [ -z "$type" ] && return 0

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)
    [ -z "$ts" ] && ts="unknown"

    local out
    out=$(printf '{"ts":"%s","type":"%s"' "$ts" "$(_mcm_json_escape "$type")")

    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        # 若没有 = 号，整段当 key，val 为空
        if [ "$key" = "$kv" ]; then
            val=""
        fi
        out+=$(printf ',"%s":"%s"' "$(_mcm_json_escape "$key")" "$(_mcm_json_escape "$val")")
    done
    out+="}"

    # 确保父目录存在（cheap idempotent）
    mkdir -p "$(dirname "$MCM_EVENTS_FILE")" 2>/dev/null

    # O_APPEND 单行原子写
    printf '%s\n' "$out" >> "$MCM_EVENTS_FILE" 2>/dev/null || return 0

    _truncate_events_if_large
}

# ----------------------------------------------------------------------------
# _truncate_events_if_large
#
# 文件 > $MCM_EVENTS_MAX_BYTES 时，截尾保留 $MCM_EVENTS_TAIL_LINES 行。
# 用 wc -c < FILE（POSIX，跨平台）替代 stat -c '%s'（GNU 专有，BSD 不兼容）。
# ----------------------------------------------------------------------------
_truncate_events_if_large() {
    [ -f "$MCM_EVENTS_FILE" ] || return 0
    local size
    size=$(wc -c < "$MCM_EVENTS_FILE" 2>/dev/null | tr -d ' ')
    [ -z "$size" ] && return 0
    if [ "$size" -gt "${MCM_EVENTS_MAX_BYTES:-1048576}" ]; then
        local tmp="${MCM_EVENTS_FILE}.tmp.$$"
        tail -n "${MCM_EVENTS_TAIL_LINES:-2000}" "$MCM_EVENTS_FILE" > "$tmp" 2>/dev/null \
            && mv -f "$tmp" "$MCM_EVENTS_FILE" \
            || rm -f "$tmp"
    fi
}

# ----------------------------------------------------------------------------
# mcm_on_exit 'cmd'
#
# 追加式注册 EXIT trap：不覆盖已有 trap，而是串联在前者之后。
# 之所以这么做：现有 6 个带锁命令已用 `trap '...' EXIT` 释放锁；本机制
# 引入的 cmd.end emit 必须与它共存而不互相覆盖。
#
# 实现：解析 `trap -p EXIT` 当前命令，拼接新 cmd，再 trap 回去。
# 解析失败（不同 bash 版本格式差异）时退化为覆盖 — 事件丢失但锁仍释放。
# ----------------------------------------------------------------------------
mcm_on_exit() {
    local new_cmd="$1"
    [ -z "$new_cmd" ] && return 0

    local cur_line cur
    cur_line=$(trap -p EXIT 2>/dev/null)
    # bash 输出格式: trap -- 'CMD' EXIT
    # 用 sed 抠出 'CMD' 之间内容；失败则 cur 为空
    cur=$(printf '%s' "$cur_line" | sed -n "s/^trap -- '\(.*\)' EXIT$/\1/p")

    if [ -n "$cur" ]; then
        # 串联：先跑旧 trap，再跑新 cmd（用 ; 分隔）
        # 注意 cur 内可能含 \'（bash 转义），重新 trap 时单引号语义需保留
        trap "${cur}; ${new_cmd}" EXIT
    else
        trap "$new_cmd" EXIT
    fi

    # 标记本进程已挂过 mcm 钩子（供 mcm_clear_exit_handlers 检测）
    _MCM_HAS_EXIT_HOOK=1
}

# ----------------------------------------------------------------------------
# mcm_clear_exit_handlers
#
# 清空当前 EXIT trap。供命令脚本在主路径成功释放锁后调用，等效于原
# `trap - EXIT`，但语义上更明确"这是 mcm 钩子管理"。
#
# 注意：cmd.end 事件不依赖 trap，而是在 mcm_run_command 末尾显式发，
# 所以清掉 trap 不会丢 cmd.end。
# ----------------------------------------------------------------------------
mcm_clear_exit_handlers() {
    trap - EXIT
    unset _MCM_HAS_EXIT_HOOK
}

# ----------------------------------------------------------------------------
# mcm_run_command FN [args...]
#
# 包裹 main 入口：emit cmd.start，运行 FN，捕获 exit code 与耗时，
# emit cmd.end。
#
# 用法（所有 commands/*.sh 末行）：
#     mcm_run_command main "$@"
#
# 说明：cmd.end 在两个路径都会发：
#   - 正常退出：FN 返回后显式 emit
#   - 异常退出（set -e 触发 / 信号）：通过 mcm_on_exit 注册的兜底 trap
# 用 _MCM_CMD_END_EMITTED 标记防止双发。
# ----------------------------------------------------------------------------
mcm_run_command() {
    local fn="$1"; shift
    local cmd_name
    cmd_name=$(basename "${BASH_SOURCE[1]:-$0}")

    local start_ms
    start_ms=$(_mcm_now_ms)

    _MCM_CMD_NAME="$cmd_name"
    _MCM_CMD_START_MS="$start_ms"
    _MCM_CMD_END_EMITTED=0

    emit_event cmd.start cmd="$cmd_name"

    # 注册兜底 trap：异常退出时也能发 cmd.end
    mcm_on_exit '_mcm_emit_cmd_end_once $?'

    local exit_code=0
    "$fn" "$@" || exit_code=$?

    _mcm_emit_cmd_end_once "$exit_code"

    return "$exit_code"
}

# ----------------------------------------------------------------------------
# 内部：发 cmd.end 事件（带去重）
# ----------------------------------------------------------------------------
_mcm_emit_cmd_end_once() {
    [ "${_MCM_CMD_END_EMITTED:-0}" = "1" ] && return 0
    _MCM_CMD_END_EMITTED=1

    local exit_code="${1:-0}"
    local end_ms duration_ms
    end_ms=$(_mcm_now_ms)
    duration_ms=$((end_ms - ${_MCM_CMD_START_MS:-$end_ms}))
    [ "$duration_ms" -lt 0 ] && duration_ms=0

    emit_event cmd.end \
        cmd="${_MCM_CMD_NAME:-unknown}" \
        duration_ms="$duration_ms" \
        exit="$exit_code"
}
