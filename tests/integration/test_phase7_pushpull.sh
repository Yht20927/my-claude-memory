#!/bin/bash
# ============================================================================
# 集成测试 11: Phase 7.3 mcmPush / mcmPull + 冲突 UX (v4.0)
# ----------------------------------------------------------------------------
# 覆盖: 双机 round-trip、union 合并(log/ledger 无冲突)、改写式冲突不静默、
#       --ours/--theirs/--continue/--abort、per-device L4 无冲突、错误边界
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"

export GIT_AUTHOR_NAME="mcm-test"
export GIT_AUTHOR_EMAIL="mcm@test.local"
export GIT_COMMITTER_NAME="mcm-test"
export GIT_COMMITTER_EMAIL="mcm@test.local"

REMOTE_SH="$PROJECT_DIR/commands/remote.sh"
PUSH_SH="$PROJECT_DIR/commands/push.sh"
PULL_SH="$PROJECT_DIR/commands/pull.sh"
INIT_SH="$PROJECT_DIR/commands/init.sh"

# 双机 fixture: bare remote + A(init+push) + B(clone)
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

# ----------------------------------------------------------------------------
# 基础 round-trip: A push, B pull, 内容一致
# ----------------------------------------------------------------------------
it_push_pull_roundtrip() {
    _setup_pair
    # A 加内容 push
    echo "## [A] entry" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # B pull
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" >/dev/null 2>&1

    assert_contains "## [A] entry" "$(cat "$B_BASE/projects/tools/proj/log.md")" "B pull 拿到 A 的 log 内容"
    assert_file_exists "$B_BASE/projects/tools/proj/chunks/1_CLAUDE.md" "B 拿到 chunks"
}

# ----------------------------------------------------------------------------
# union 合并: 双方并发追加 log.md, pull 无冲突
# ----------------------------------------------------------------------------
it_union_merge_log() {
    _setup_pair
    # A 追加 [A1], push
    echo "## [A1] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # B 拉到 [A1], 追加 [B1], push
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" >/dev/null 2>&1
    echo "## [B1] op (user)" >> "$B_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # A 本地追加 [A2](分叉), 先 commit 再 pull -> union 合并 [B1]
    echo "## [A2] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$PULL_SH" >/dev/null 2>&1

    local a_log
    a_log=$(cat "$A_BASE/projects/tools/proj/log.md")
    assert_contains "[A1]" "$a_log" "union 合并后含 A1"
    assert_contains "[A2]" "$a_log" "union 合并后含 A2"
    assert_contains "[B1]" "$a_log" "union 合并后含 B1(无冲突丢失)"
}

# ----------------------------------------------------------------------------
# union 合并: ledger.md 同理
# ----------------------------------------------------------------------------
it_union_merge_ledger() {
    _setup_pair
    echo "## [ts1] todo (user)" >> "$A_BASE/projects/tools/proj/ledger.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" >/dev/null 2>&1
    echo "## [ts2] todo (user)" >> "$B_BASE/projects/tools/proj/ledger.md"
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    echo "## [ts3] todo (user)" >> "$A_BASE/projects/tools/proj/ledger.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$PULL_SH" >/dev/null 2>&1

    local l
    l=$(cat "$A_BASE/projects/tools/proj/ledger.md")
    assert_contains "ts2" "$l" "union 合并 ledger 含 B 的 ts2"
    assert_contains "ts3" "$l" "union 合并 ledger 含 A 的 ts3"
}

# ----------------------------------------------------------------------------
# 改写式冲突不静默: summary.md 双方改, pull 报冲突
# ----------------------------------------------------------------------------
it_conflict_summary_reports() {
    _setup_pair
    # A 改 summary push
    echo "# A summary" > "$A_BASE/projects/tools/proj/summary.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # B 改 summary commit(分叉), pull 报冲突
    echo "# B summary" > "$B_BASE/projects/tools/proj/summary.md"
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    local out
    out=$(MEMORY_BASE="$B_BASE" bash "$PULL_SH" 2>&1)

    assert_contains "检测到冲突" "$out" "pull 报告检测到冲突(不静默)"
    assert_contains "summary.md" "$out" "冲突清单含 summary.md"
    assert_contains "mcmPull --continue" "$out" "引导含 --continue"
    # 冲突文件确实未自动解决
    local unmerged
    unmerged=$(cd "$B_BASE" && git diff --name-only --diff-filter=U 2>/dev/null)
    assert_contains "summary.md" "$unmerged" "summary.md 处于未合并状态"
    # 清理: abort 回到干净态
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" --abort >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# --ours + --continue: 取本方, 提交, 推送 merge commit
# ----------------------------------------------------------------------------
it_conflict_resolve_ours_continue() {
    _setup_pair
    echo "# A summary" > "$A_BASE/projects/tools/proj/summary.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    echo "# B summary" > "$B_BASE/projects/tools/proj/summary.md"
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" >/dev/null 2>&1 || true

    # --ours 取 B 的版本
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" --ours projects/tools/proj/summary.md >/dev/null 2>&1
    assert_equal "# B summary" "$(head -1 "$B_BASE/projects/tools/proj/summary.md")" "--ours 取本方版本"

    # --continue 提交合并
    local cout
    cout=$(MEMORY_BASE="$B_BASE" bash "$PULL_SH" --continue 2>&1)
    assert_contains "合并已提交" "$cout" "--continue 提交合并"

    # push 应推送 merge commit(非跳过)
    local pout
    pout=$(MEMORY_BASE="$B_BASE" bash "$PUSH_SH" 2>&1)
    assert_contains "origin/main" "$pout" "push 推送了 merge commit"
    assert_not_contains "无变更，跳过推送" "$pout" "未误跳过(有未推送 merge commit)"

    # A pull 拿到 B 选的版本
    MEMORY_BASE="$A_BASE" bash "$PULL_SH" >/dev/null 2>&1
    assert_equal "# B summary" "$(head -1 "$A_BASE/projects/tools/proj/summary.md")" "A 拉到 B(--ours)的版本"
}

# ----------------------------------------------------------------------------
# --abort: 回到合并前
# ----------------------------------------------------------------------------
it_conflict_abort() {
    _setup_pair
    echo "# A summary" > "$A_BASE/projects/tools/proj/summary.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    echo "# B summary" > "$B_BASE/projects/tools/proj/summary.md"
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" >/dev/null 2>&1 || true
    # 冲突中 -> abort
    local out
    out=$(MEMORY_BASE="$B_BASE" bash "$PULL_SH" --abort 2>&1)
    assert_contains "已放弃合并" "$out" "--abort 放弃合并"
    # B 回到自己的版本(合并前)
    assert_equal "# B summary" "$(head -1 "$B_BASE/projects/tools/proj/summary.md")" "abort 后 B 回到自己版本"
    # 无残留未合并
    local unmerged
    unmerged=$(cd "$B_BASE" && git diff --name-only --diff-filter=U 2>/dev/null)
    [ -z "$unmerged" ] && { echo -e "  ${GREEN}PASS${NC} abort 后无未合并文件"; PASSED=$((PASSED+1)); } \
        || { echo -e "  ${RED}FAIL${NC} abort 后仍有未合并: $unmerged"; FAILED=$((FAILED+1)); }
}

# ----------------------------------------------------------------------------
# per-device L4: 两设备各写各的 JSON, pull 无冲突
# ----------------------------------------------------------------------------
it_l4_per_device_no_conflict() {
    _setup_pair
    # A(boxA) 已有 L4 boxA.json(来自 init); B(boxB) pull 后写自己的 boxB.json
    assert_file_exists "$B_BASE/projects/tools/proj/.claude/l4/boxA.json" "B 拉到 A 的 boxA.json"
    MEMORY_BASE="$B_BASE" bash "$INIT_SH" --name proj --tags tools \
        --description "orig" --workspace "$INT_FIXTURE_DIR/A/ws" >/dev/null 2>&1
    # B 重新 init 会记录 boxB 的 L4(若源文件在 B 的 workspace 路径)
    # 用 record_l4_source 直接写 boxB 条目(模拟 B 在本机探测源)
    MEMORY_BASE="$B_BASE" bash -c '
        source "'"$PROJECT_DIR"'/lib/core.sh" 2>/dev/null
        record_l4_source "'"$B_BASE"'/projects/tools/proj" "'"$INT_FIXTURE_DIR"'/A/ws/CLAUDE.md" >/dev/null 2>&1
    '
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$PULL_SH" >/dev/null 2>&1

    # A 现在两个 device 文件都有
    assert_file_exists "$A_BASE/projects/tools/proj/.claude/l4/boxA.json" "A 仍有 boxA.json"
    assert_file_exists "$A_BASE/projects/tools/proj/.claude/l4/boxB.json" "A 拉到 boxB.json(per-device 无冲突)"
}

# ----------------------------------------------------------------------------
# 边界: 无 remote 时 push 报错
# ----------------------------------------------------------------------------
it_push_no_remote_errors() {
    # 不用 _setup_pair; 单机 init 不带 --remote
    A_BASE="$INT_FIXTURE_DIR/solo/mcm"
    A_WS="$INT_FIXTURE_DIR/solo/ws"
    mkdir -p "$A_BASE" "$A_WS"
    ( cd "$A_WS" && git init -q && git config user.email t@x && git config user.name t )
    echo "# doc" > "$A_WS/CLAUDE.md"
    MEMORY_BASE="$A_BASE" bash "$REMOTE_SH" init --device solo >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$INIT_SH" --name p --tags tools --description x --workspace "$A_WS" >/dev/null 2>&1

    local out
    out=$(MEMORY_BASE="$A_BASE" bash "$PUSH_SH" 2>&1)
    assert_contains "未配置 remote" "$out" "无 remote 时 push 报错"
}

# ----------------------------------------------------------------------------
# 边界: 无变更时 push 跳过
# ----------------------------------------------------------------------------
it_push_no_changes_skips() {
    _setup_pair
    # 刚 setup 已 push; 再 push 无变更
    local out
    out=$(MEMORY_BASE="$A_BASE" bash "$PUSH_SH" 2>&1)
    assert_contains "无变更" "$out" "无变更时 push 跳过"
}

# ----------------------------------------------------------------------------
# 边界: 工作区脏时 pull 拒绝
# ----------------------------------------------------------------------------
it_pull_dirty_refused() {
    _setup_pair
    # B 有未提交变更 + 远程有新内容
    echo "## [A] new" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    echo "dirty change" >> "$B_BASE/projects/tools/proj/summary.md"  # 未提交

    local out
    out=$(MEMORY_BASE="$B_BASE" bash "$PULL_SH" 2>&1)
    assert_contains "未提交变更" "$out" "工作区脏时 pull 拒绝"
    assert_not_contains "合并完成" "$out" "脏工作区未执行 merge"
}

run_its "Phase 7.3 mcmPush / mcmPull + 冲突 UX" \
    "round-trip"           it_push_pull_roundtrip \
    "union 合并 log"        it_union_merge_log \
    "union 合并 ledger"     it_union_merge_ledger \
    "冲突不静默"            it_conflict_summary_reports \
    "--ours + --continue"  it_conflict_resolve_ours_continue \
    "--abort"              it_conflict_abort \
    "per-device L4 无冲突"  it_l4_per_device_no_conflict \
    "无 remote 报错"       it_push_no_remote_errors \
    "无变更跳过"           it_push_no_changes_skips \
    "脏工作区拒绝 pull"    it_pull_dirty_refused
