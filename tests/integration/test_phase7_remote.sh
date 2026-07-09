#!/bin/bash
# ============================================================================
# 集成测试 10: Phase 7.2 mcmRemote + 派生重建 (v4.0)
# ----------------------------------------------------------------------------
# 覆盖: mcmRemote init(幂等)/add/list/remove/device, .gitignore 分类(派生忽略、
#       l4/ 跟踪), .gitattributes(union/eol), rebuild_derived 重建
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"

# git 身份确定性（不依赖全局配置）
export GIT_AUTHOR_NAME="mcm-test"
export GIT_AUTHOR_EMAIL="mcm@test.local"
export GIT_COMMITTER_NAME="mcm-test"
export GIT_COMMITTER_EMAIL="mcm@test.local"

REMOTE_SH="$PROJECT_DIR/commands/remote.sh"

# 在 fixture 里铺一个项目记忆（含真记忆 + 派生 + L4），供 init/check-ignore 用
_seed_store() {
    local mem="$PROJECTS_DIR/tools/seed"
    mkdir -p "$mem/chunks" "$mem/.claude/l4"
    echo "# real chunk" > "$mem/chunks/1_X.md"
    echo "# summary" > "$mem/summary.md"
    echo "# log" > "$mem/log.md"
    echo "# ledger" > "$mem/ledger.md"
    echo "{}" > "$mem/hash.json"
    echo "idx" > "$SEARCH_INDEX"
    mkdir -p "$MEMORY_BASE/.locks"
    printf '%s\n' '{"device":"seedbox","sources":{"X.md":"../../chunks/1_X.md"}}' \
        > "$mem/.claude/l4/seedbox.json"
}

# ----------------------------------------------------------------------------
# init 创建 git 仓库 + 配置 + .device + 首次提交
# ----------------------------------------------------------------------------
it_remote_init_creates_repo() {
    _seed_store

    bash "$REMOTE_SH" init >/dev/null 2>&1

    assert_file_exists "$MEMORY_BASE/.git/HEAD" "git 仓库已初始化(.git/HEAD)"
    assert_file_exists "$MEMORY_BASE/.gitignore" ".gitignore 已写入"
    assert_file_exists "$MEMORY_BASE/.gitattributes" ".gitattributes 已写入"
    assert_file_exists "$MEMORY_BASE/.device" ".device 已盖戳"

    local commits
    commits=$(cd "$MEMORY_BASE" && git rev-list --count HEAD 2>/dev/null || echo 0)
    assert_equal "1" "$commits" "首次提交已创建(1 commit)"
}

# ----------------------------------------------------------------------------
# init 幂等: 二次不重复提交
# ----------------------------------------------------------------------------
it_remote_init_idempotent() {
    _seed_store
    bash "$REMOTE_SH" init >/dev/null 2>&1
    local c1
    c1=$(cd "$MEMORY_BASE" && git rev-list --count HEAD 2>/dev/null || echo 0)

    # 二次 init
    bash "$REMOTE_SH" init >/dev/null 2>&1
    local c2
    c2=$(cd "$MEMORY_BASE" && git rev-list --count HEAD 2>/dev/null || echo 0)

    assert_equal "$c1" "$c2" "二次 init 不新增提交"
}

# ----------------------------------------------------------------------------
# .gitignore 分类: 派生/本地态忽略, 真记忆 + L4 跟踪
# ----------------------------------------------------------------------------
it_gitignore_classification() {
    _seed_store
    bash "$REMOTE_SH" init >/dev/null 2>&1
    cd "$MEMORY_BASE"

    # 应被忽略
    local ignored_ignored=0
    for f in .search_index projects/tools/seed/hash.json .locks; do
        if git check-ignore "$f" >/dev/null 2>&1; then ignored_ignored=$((ignored_ignored+1)); fi
    done
    assert_equal "3" "$ignored_ignored" "派生/本地态被忽略(3 个)"

    # 应被跟踪
    local tracked=0
    for f in projects/tools/seed/summary.md projects/tools/seed/log.md \
             projects/tools/seed/ledger.md projects/tools/seed/.claude/l4/seedbox.json; do
        if git check-ignore "$f" >/dev/null 2>&1; then :; else tracked=$((tracked+1)); fi
    done
    assert_equal "4" "$tracked" "真记忆 + L4 被跟踪(4 个)"

    # 关键: l4/ 否定模式生效(.claude/* 但 !.claude/l4/)
    if git check-ignore projects/tools/seed/.claude/l4/seedbox.json >/dev/null 2>&1; then
        echo -e "  ${RED}FAIL${NC} l4/ 被误忽略(否定模式失效)"
        FAILED=$((FAILED+1))
    else
        echo -e "  ${GREEN}PASS${NC} l4/ 否定模式生效(不被忽略)"
        PASSED=$((PASSED+1))
    fi
}

# ----------------------------------------------------------------------------
# .gitattributes: union merge for log/ledger, eol=lf
# ----------------------------------------------------------------------------
it_gitattributes_content() {
    _seed_store
    bash "$REMOTE_SH" init >/dev/null 2>&1

    local ga
    ga=$(cat "$MEMORY_BASE/.gitattributes")
    assert_contains "log.md" "$ga" ".gitattributes 含 log.md"
    assert_contains "merge=union" "$ga" ".gitattributes 含 merge=union"
    assert_contains "ledger.md" "$ga" ".gitattributes 含 ledger.md"
    assert_contains "eol=lf" "$ga" ".gitattributes 含 eol=lf"
}

# ----------------------------------------------------------------------------
# device show / set
# ----------------------------------------------------------------------------
it_device_show_set() {
    _seed_store
    bash "$REMOTE_SH" init >/dev/null 2>&1

    # set
    bash "$REMOTE_SH" device set mybox >/dev/null 2>&1
    assert_equal "mybox" "$(cat "$MEMORY_BASE/.device")" "device set 写入 .device"

    # show 反映 set 的值
    local out
    out=$(bash "$REMOTE_SH" device show 2>/dev/null)
    assert_contains "mybox" "$out" "device show 反映 .device"

    # MCM_DEVICE 覆盖优先（不依赖 .device）
    export MCM_DEVICE="envoverride"
    out=$(bash "$REMOTE_SH" device show 2>/dev/null)
    assert_contains "envoverride" "$out" "MCM_DEVICE 覆盖优先"
    unset MCM_DEVICE
}

# ----------------------------------------------------------------------------
# add / list / remove remote
# ----------------------------------------------------------------------------
it_remote_add_list_remove() {
    _seed_store
    bash "$REMOTE_SH" init >/dev/null 2>&1

    bash "$REMOTE_SH" add origin /tmp/orig.git >/dev/null 2>&1
    bash "$REMOTE_SH" add team /tmp/team.git >/dev/null 2>&1

    local out
    out=$(cd "$MEMORY_BASE" && bash "$REMOTE_SH" list 2>/dev/null)
    assert_contains "orig.git" "$out" "list 含 origin"
    assert_contains "team.git" "$out" "list 含 team"

    # remove
    bash "$REMOTE_SH" remove team >/dev/null 2>&1
    out=$(cd "$MEMORY_BASE" && bash "$REMOTE_SH" list 2>/dev/null)
    assert_contains "orig.git" "$out" "remove 后 origin 仍在"
    if printf '%s' "$out" | grep -q "team.git"; then
        echo -e "  ${RED}FAIL${NC} remove 后 team 仍存在"
        FAILED=$((FAILED+1))
    else
        echo -e "  ${GREEN}PASS${NC} remove 后 team 已移除"
        PASSED=$((PASSED+1))
    fi
}

# ----------------------------------------------------------------------------
# rebuild_derived: 模拟 pull 后(派生缺失)重建 index.md + .search_index
# ----------------------------------------------------------------------------
it_rebuild_derived_after_pull() {
    _seed_store
    # 给 chunk 带 frontmatter(source_file)以便 index.md 重建分组
    cat > "$PROJECTS_DIR/tools/seed/chunks/1_X.md" <<'CK'
---
source_file: /ws/X.md
type: md
---
# X content
line2
CK

    # 模拟 pull 后:派生文件缺失
    rm -f "$PROJECTS_DIR/tools/seed/index.md" "$SEARCH_INDEX"

    # 直接调 rebuild_derived（mcmPull 的核心步骤）
    rebuild_derived >/dev/null 2>&1

    assert_file_exists "$PROJECTS_DIR/tools/seed/index.md" "index.md 已从 chunks 重建"
    assert_file_exists "$SEARCH_INDEX" ".search_index 已重建"
    assert_contains "## X.md" "$(cat "$PROJECTS_DIR/tools/seed/index.md")" "index.md 按 source_file 分组"
    assert_contains "1_X.md" "$(cat "$PROJECTS_DIR/tools/seed/index.md")" "index.md 含 chunk 名"

    # 二次 rebuild 幂等：同 chunks -> 同输出（index.md 总是重建，但内容一致）
    local before after
    before=$(cat "$PROJECTS_DIR/tools/seed/index.md")
    rebuild_derived >/dev/null 2>&1
    after=$(cat "$PROJECTS_DIR/tools/seed/index.md")
    assert_equal "$before" "$after" "二次 rebuild 幂等(同 chunks 同输出)"
}

# ----------------------------------------------------------------------------
# doctor 在 .search_index 缺失时触发 rebuild_derived
# ----------------------------------------------------------------------------
it_doctor_rebuilds_missing_index() {
    _seed_store
    bash "$REMOTE_SH" init >/dev/null 2>&1
    # 删 .search_index 模拟新机 clone
    rm -f "$SEARCH_INDEX"

    local out
    out=$(bash "$PROJECT_DIR/commands/doctor.sh" 2>/dev/null)
    assert_contains "搜索索引缺失" "$out" "doctor 报告索引缺失"
    assert_file_exists "$SEARCH_INDEX" "doctor 触发了 .search_index 重建"
}

run_its "Phase 7.2 mcmRemote + 派生重建" \
    "init 创建仓库"          it_remote_init_creates_repo \
    "init 幂等"              it_remote_init_idempotent \
    "gitignore 分类"          it_gitignore_classification \
    "gitattributes 内容"      it_gitattributes_content \
    "device show/set"        it_device_show_set \
    "add/list/remove"        it_remote_add_list_remove \
    "rebuild_derived 重建"    it_rebuild_derived_after_pull \
    "doctor 触发重建"         it_doctor_rebuilds_missing_index
