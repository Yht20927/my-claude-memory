#!/bin/bash
# ============================================================================
# 集成测试 13: Phase 7.5 远程共享端到端 (v4.0)
# ----------------------------------------------------------------------------
# 完整 bootstrap 叙事（spec §9）:
#   A: mcmRemote init + mcmInit + mcmPush
#   B: git clone + mcmDoctor(重建派生) + mcmInit --name(绑定 .workspace + 记 boxB L4)
#      -> 验证 B 可用(mcmSearch/mcmLoad) + 双 device L4 共存
#   round-trip: B 改 + push, A pull
#   auto-pull e2e: A push 新内容, B SessionStart ff-only 拉到
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
PULL_SH="$PROJECT_DIR/commands/pull.sh"
INIT_SH="$PROJECT_DIR/commands/init.sh"
DOCTOR_SH="$PROJECT_DIR/commands/doctor.sh"
SEARCH_SH="$PROJECT_DIR/commands/search.sh"
LOAD_SH="$PROJECT_DIR/commands/load.sh"

# ----------------------------------------------------------------------------
# it_e2e_bootstrap_new_machine
# ----------------------------------------------------------------------------
it_e2e_bootstrap_new_machine() {
    local BARE="$INT_FIXTURE_DIR/bare.git"
    git init -q --bare "$BARE"

    # --- A: init remote + memory + push ---
    local A_BASE="$INT_FIXTURE_DIR/A/mcm"
    local A_WS="$INT_FIXTURE_DIR/A/ws"
    mkdir -p "$A_BASE" "$A_WS"
    ( cd "$A_WS" && git init -q && git config user.email t@x && git config user.name t )
    printf '# Project Doc\n\n关键决策：采用 BM25。\n' > "$A_WS/CLAUDE.md"
    MEMORY_BASE="$A_BASE" bash "$REMOTE_SH" init --remote "$BARE" --device boxA >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$INIT_SH" --name proj --tags tools \
        --description "e2e project" --workspace "$A_WS" >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    git -C "$BARE" symbolic-ref HEAD refs/heads/main

    # --- B: clone + doctor + mcmInit --name ---
    local B_BASE="$INT_FIXTURE_DIR/B/mcm"
    local B_WS="$INT_FIXTURE_DIR/B/ws"
    mkdir -p "$(dirname "$B_BASE")" "$B_WS"
    git clone -q "$BARE" "$B_BASE"
    git -C "$B_BASE" checkout -q main 2>/dev/null || true
    # B 的本地项目源（与 A 同名文件，不同路径）
    printf '# Project Doc\n\n关键决策：采用 BM25。\n' > "$B_WS/CLAUDE.md"
    ( cd "$B_WS" && git init -q && git config user.email t@x && git config user.name t )

    # clone 后派生文件缺失
    assert_not_contains "search_index" "$(ls -a "$B_BASE" 2>/dev/null | tr '\n' ' ')" "clone 后无 .search_index(被 gitignore)"

    # mcmDoctor 重建派生
    MEMORY_BASE="$B_BASE" bash "$DOCTOR_SH" >/dev/null 2>&1
    assert_file_exists "$B_BASE/.search_index" "doctor 重建了 .search_index"
    assert_file_exists "$B_BASE/projects/tools/proj/index.md" "doctor 重建了 index.md"

    # B 设本机 device（盖戳 .device，L4 将记到 boxB）
    MEMORY_BASE="$B_BASE" bash "$REMOTE_SH" device set boxB >/dev/null 2>&1

    # mcmInit --name 绑定 B 的 workspace + 记录 boxB L4（不破坏 A 的 chunks）
    MEMORY_BASE="$B_BASE" bash "$INIT_SH" --name proj --tags tools \
        --description "e2e project" --workspace "$B_WS" >/dev/null 2>&1
    assert_file_exists "$B_BASE/projects/tools/proj/.claude/l4/boxA.json" "B 保留 A 的 boxA.json"
    assert_file_exists "$B_BASE/projects/tools/proj/.claude/l4/boxB.json" "B 记录了自己的 boxB.json"

    # B 可用：mcmSearch 命中（chunk 含 "# CLAUDE.md"，验证 rebuild 后搜索管线工作）
    local sout
    sout=$(MEMORY_BASE="$B_BASE" bash "$SEARCH_SH" CLAUDE 2>/dev/null)
    assert_not_contains "未找到匹配结果" "$sout" "B mcmSearch 命中（搜索管线可用）"

    # B 可用：mcmLoad L2（index.md 重建后）
    local lout
    lout=$(MEMORY_BASE="$B_BASE" bash "$LOAD_SH" proj --layer L2 2>/dev/null)
    assert_contains "大纲索引" "$lout" "B mcmLoad L2 可读 index.md"
}

# ----------------------------------------------------------------------------
# it_e2e_roundtrip
# ----------------------------------------------------------------------------
it_e2e_roundtrip() {
    local BARE="$INT_FIXTURE_DIR/bare.git"
    git init -q --bare "$BARE"
    local A_BASE="$INT_FIXTURE_DIR/A/mcm" A_WS="$INT_FIXTURE_DIR/A/ws"
    local B_BASE="$INT_FIXTURE_DIR/B/mcm" B_WS="$INT_FIXTURE_DIR/B/ws"
    mkdir -p "$A_BASE" "$A_WS" "$(dirname "$B_BASE")" "$B_WS"
    ( cd "$A_WS" && git init -q && git config user.email t@x && git config user.name t )
    echo "# doc" > "$A_WS/CLAUDE.md"
    ( cd "$B_WS" && git init -q && git config user.email t@x && git config user.name t )
    echo "# doc" > "$B_WS/CLAUDE.md"

    MEMORY_BASE="$A_BASE" bash "$REMOTE_SH" init --remote "$BARE" --device boxA >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$INIT_SH" --name proj --tags tools --description "e2e" --workspace "$A_WS" >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    git -C "$BARE" symbolic-ref HEAD refs/heads/main
    git clone -q "$BARE" "$B_BASE"; git -C "$B_BASE" checkout -q main 2>/dev/null || true
    MEMORY_BASE="$B_BASE" bash "$REMOTE_SH" device set boxB >/dev/null 2>&1

    # B 改 log + push
    echo "## [B-edit] op (user)" >> "$B_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # A pull 拿到
    MEMORY_BASE="$A_BASE" bash "$PULL_SH" >/dev/null 2>&1
    assert_contains "B-edit" "$(cat "$A_BASE/projects/tools/proj/log.md")" "round-trip: A 拉到 B 的 log 编辑"

    # A 改 + push
    echo "## [A-edit] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    # B pull（union 合并 A-edit 与本地 B-edit）
    MEMORY_BASE="$B_BASE" bash "$PUSH_SH" >/dev/null 2>&1   # B 本地无新变更，但有未推? 无 -> 跳过；先确保 clean
    MEMORY_BASE="$B_BASE" bash "$PULL_SH" >/dev/null 2>&1
    local bl
    bl=$(cat "$B_BASE/projects/tools/proj/log.md")
    assert_contains "A-edit" "$bl" "round-trip: B union 合并拉到 A-edit"
    assert_contains "B-edit" "$bl" "round-trip: B 仍有自己的 B-edit(union 无冲突)"
}

# ----------------------------------------------------------------------------
# it_e2e_autopull
# ----------------------------------------------------------------------------
it_e2e_autopull() {
    local BARE="$INT_FIXTURE_DIR/bare.git"
    git init -q --bare "$BARE"
    local A_BASE="$INT_FIXTURE_DIR/A/mcm" A_WS="$INT_FIXTURE_DIR/A/ws"
    local B_BASE="$INT_FIXTURE_DIR/B/mcm"
    mkdir -p "$A_BASE" "$A_WS" "$(dirname "$B_BASE")"
    ( cd "$A_WS" && git init -q && git config user.email t@x && git config user.name t )
    echo "# doc" > "$A_WS/CLAUDE.md"
    MEMORY_BASE="$A_BASE" bash "$REMOTE_SH" init --remote "$BARE" --device boxA >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$INIT_SH" --name proj --tags tools --description "e2e" --workspace "$A_WS" >/dev/null 2>&1
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1
    git -C "$BARE" symbolic-ref HEAD refs/heads/main
    git clone -q "$BARE" "$B_BASE"; git -C "$B_BASE" checkout -q main 2>/dev/null || true
    MEMORY_BASE="$B_BASE" bash "$REMOTE_SH" device set boxB >/dev/null 2>&1

    # A 加新内容并 push
    echo "## [A-new] op (user)" >> "$A_BASE/projects/tools/proj/log.md"
    MEMORY_BASE="$A_BASE" bash "$PUSH_SH" >/dev/null 2>&1

    # B SessionStart auto-pull（ff-only）
    MEMORY_BASE="$B_BASE" MCM_AUTOPULL=1 bash -c '
        source "'"$PROJECT_DIR"'/lib/core.sh" 2>/dev/null
        source "'"$PROJECT_DIR"'/lib/inject.sh" 2>/dev/null
        session_start_inject "'"$INT_FIXTURE_DIR"'" >/dev/null 2>&1
    '
    assert_contains "A-new" "$(cat "$B_BASE/projects/tools/proj/log.md")" "e2e auto-pull: B SessionStart 拉到 A-new"
}

run_its "Phase 7.5 远程共享端到端" \
    "新机 bootstrap"      it_e2e_bootstrap_new_machine \
    "双向 round-trip"     it_e2e_roundtrip \
    "SessionStart auto-pull e2e" it_e2e_autopull
