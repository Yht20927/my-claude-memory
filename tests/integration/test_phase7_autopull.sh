#!/bin/bash
# ============================================================================
# 集成测试 12: Phase 7.4 SessionStart auto-pull (v4.0)
# ----------------------------------------------------------------------------
# 覆盖: 默认 off、MCM_AUTOPULL=1 ff-only 快进、非 ff 跳过不阻塞、
#       STOP/pause kill-switch 跳过
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/inject.sh"

export GIT_AUTHOR_NAME="mcm-test"
export GIT_AUTHOR_EMAIL="mcm@test.local"
export GIT_COMMITTER_NAME="mcm-test"
export GIT_COMMITTER_EMAIL="mcm@test.local"

REMOTE_SH="$PROJECT_DIR/commands/remote.sh"
PUSH_SH="$PROJECT_DIR/commands/push.sh"
INIT_SH="$PROJECT_DIR/commands/init.sh"

_setup_pair() {
    BARE="$INT_FIXTURE_DIR/bare.git"
    git init -q --bare "$BARE"

    A_BASE="$INT_FIXTURE_DIR/A/mcm"
    A_WS="$INT_FIXTURE_DIR/A/ws"
    mkdir -p "$A_BASE" "$A_WS"
    ( cd "$A_WS" && git init -q && git config user.email t@x && git config user.name t )
    echo "# doc" > "$A_WS/CLAUDE.md"

    MEMORY_BASE="$A_BASE" bash "$REMOTE_SH" init --remote "$BARE" --device boxA >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$INIT_SH" --name proj --tags tools \
        --description "orig" --workspace "$A_WS" >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    git -C "$BARE" symbolic-ref HEAD refs/heads/main

    B_BASE="$INT_FIXTURE_DIR/B/mcm"
    mkdir -p "$(dirname "$B_BASE")"
    git clone -q "$BARE" "$B_BASE"
    git -C "$B_BASE" checkout -q main 2>/dev/null || true
    MEMORY_BASE="$B_BASE" bash "$REMOTE_SH" device set boxB >/dev/null 2>&1
}

# 在 B 上跑 session_start_inject（带可选 env 前缀）
# 用法: _ss_b "MCM_AUTOPULL=1"  或  _ss_b ""
_ss_b() {
    local env_prefix="$1"
    env $env_prefix MEMORY_BASE="$B_BASE" bash -c '
        source "'"$PROJECT_DIR"'/lib/core.sh" 2>/dev/null
        source "'"$PROJECT_DIR"'/lib/inject.sh" 2>/dev/null
        session_start_inject "'"$INT_FIXTURE_DIR"'" >/dev/null 2>&1
    '
    return 0
}

# ----------------------------------------------------------------------------
# 默认 off: A 加内容后 B session_start 不拉
# ----------------------------------------------------------------------------
it_autopull_off_default() {
    _setup_pair
    echo "## [newA] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1

    _ss_b ""   # 无 MCM_AUTOPULL
    local n
    n=$(grep -c 'newA' "$B_BASE/projects/tools/proj/log.md" 2>/dev/null || true)
    assert_equal "0" "$n" "默认 off: B 未拉取 A 的新内容"
}

# ----------------------------------------------------------------------------
# MCM_AUTOPULL=1: ff-only 快进, 拉到 A 的新内容
# ----------------------------------------------------------------------------
it_autopull_ff() {
    _setup_pair
    echo "## [newA] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1

    _ss_b "MCM_AUTOPULL=1"
    local n
    n=$(grep -c 'newA' "$B_BASE/projects/tools/proj/log.md" 2>/dev/null || true)
    assert_equal "1" "$n" "MCM_AUTOPULL=1: B ff-pull 拉到 newA"
}

# ----------------------------------------------------------------------------
# 非 ff(B 本地有 commit): auto-pull 跳过, 不阻塞(exit 0)
# ----------------------------------------------------------------------------
it_autopull_nonff_skips() {
    _setup_pair
    # B 本地加 commit 并推
    echo "## [Blocal] op (user)" >> "$B_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # A 加分叉 commit 并推(origin 与 B 分叉)
    echo "## [A2] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" 2>/dev/null >/dev/null

    _ss_b "MCM_AUTOPULL=1"
    local rc=$?
    assert_equal "0" "$rc" "非 ff 时 auto-pull 跳过, 不阻塞(exit 0)"
    # B 不应含 A2(未合并)
    local n
    n=$(grep -c 'A2' "$B_BASE/projects/tools/proj/log.md" 2>/dev/null || true)
    assert_equal "0" "$n" "非 ff 跳过: B 未拿到 A2(需手动 mcmPull)"
}

# ----------------------------------------------------------------------------
# STOP: auto-pull 跳过
# ----------------------------------------------------------------------------
it_autopull_stop_skips() {
    _setup_pair
    echo "## [newA] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    touch "$B_BASE/.stop"

    _ss_b "MCM_AUTOPULL=1"
    local n
    n=$(grep -c 'newA' "$B_BASE/projects/tools/proj/log.md" 2>/dev/null || true)
    assert_equal "0" "$n" "STOP 时 auto-pull 跳过(未拉 newA)"
    rm -f "$B_BASE/.stop"
}

# ----------------------------------------------------------------------------
# pause: auto-pull 跳过
# ----------------------------------------------------------------------------
it_autopull_pause_skips() {
    _setup_pair
    echo "## [newA] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # 写 .paused_until 到未来（epoch 秒，is_inject_paused 用 date +%s 比较）
    local future
    future=$(date -d '+1 hour' +%s 2>/dev/null || echo 9999999999)
    echo "$future" > "$B_BASE/.paused_until" 2>/dev/null

    _ss_b "MCM_AUTOPULL=1"
    local n
    n=$(grep -c 'newA' "$B_BASE/projects/tools/proj/log.md" 2>/dev/null || true)
    assert_equal "0" "$n" "pause 时 auto-pull 跳过(未拉 newA)"
}

run_its "Phase 7.4 SessionStart auto-pull" \
    "默认 off"          it_autopull_off_default \
    "ff-only 快进"      it_autopull_ff \
    "非 ff 跳过不阻塞"  it_autopull_nonff_skips \
    "STOP 跳过"          it_autopull_stop_skips \
    "pause 跳过"         it_autopull_pause_skips
