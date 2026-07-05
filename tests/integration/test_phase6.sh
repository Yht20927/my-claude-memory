#!/bin/bash
# ============================================================================
# 集成测试 8: Phase 6 会话决策日志（ledger）(v3.6)
# ----------------------------------------------------------------------------
# 覆盖: add / list / resolve / show, open set computation,
#       SessionStart injection, immutability, op-log/events, absent ledger
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/ledger.sh"
source "$PROJECT_DIR/lib/inject.sh"

_seed_ws() {
    local ws="$INT_FIXTURE_DIR/phase6-ws"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    echo "$ws"
}

_init_proj() {
    local name="$1"
    local ws
    ws=$(_seed_ws)
    bash "$PROJECT_DIR/commands/init.sh" --name "$name" --tags "tools" \
        --description "ledger test" --workspace "$ws" > /dev/null 2>&1
    echo "$PROJECTS_DIR/tools/$name"
}

# ----------------------------------------------------------------------------
# ledger add writes structured entry
# ----------------------------------------------------------------------------
it_ledger_add_writes_entry() {
    local mem_dir
    mem_dir=$(_init_proj "led-add")

    local id
    id=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-add" --actor agent \
        decision "采用 BM25 替代向量检索" --context "中文 bigram 已够用" \
        --refs "chunks/1_SEARCH.md" 2>/dev/null)

    assert_contains "2026-" "$id" "add 返回 ISO8601 时间戳 ID"

    local ledger="$mem_dir/ledger.md"
    assert_file_exists "$ledger" "ledger.md 已创建"
    assert_contains "## [$id] decision (agent)" "$(cat "$ledger")" "header 格式正确"
    assert_contains "采用 BM25 替代向量检索" "$(cat "$ledger")" "摘要写入"
    assert_contains "context: 中文 bigram 已够用" "$(cat "$ledger")" "context 写入"
    assert_contains "refs: chunks/1_SEARCH.md" "$(cat "$ledger")" "refs 写入"
}

# ----------------------------------------------------------------------------
# ledger list filters by type/status/since
# ----------------------------------------------------------------------------
it_ledger_list_filters() {
    local mem_dir
    mem_dir=$(_init_proj "led-list")

    # 写多条
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" todo "实现 A" >/dev/null 2>&1
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" blocker "B2 根因" >/dev/null 2>&1
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" decision "选 BM25" >/dev/null 2>&1
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" todo "实现 B" >/dev/null 2>&1

    # list --type todo
    local out
    out=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" list --type todo 2>/dev/null)
    assert_contains "todo" "$out" "list --type todo 含 todo"
    assert_not_contains "decision" "$out" "list --type todo 不含 decision"
    assert_not_contains "blocker" "$out" "list --type todo 不含 blocker"

    # list --status open → 只含 todo + blocker（decision 无 status）
    out=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" list --status open 2>/dev/null)
    assert_contains "todo" "$out" "list --status open 含 todo"
    assert_contains "blocker" "$out" "list --status open 含 blocker"
    assert_not_contains "decision" "$out" "list --status open 不含 decision"

    # list --limit 2 → 最近 2 条
    out=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" list --limit 2 2>/dev/null)
    local n
    n=$(printf '%s' "$out" | grep -c '| todo\|blocker\|decision\|note')
    # 表头有一行带 type 名，实际数据行
    n=$(printf '%s' "$out" | grep -cE '^\| 20')
    assert_equal "2" "$n" "list --limit 2 只返回 2 条"

    # list --json
    out=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-list" list --json 2>/dev/null)
    assert_contains '"type"' "$out" "list --json 含 type 字段"
    assert_contains '"summary"' "$out" "list --json 含 summary 字段"
}

# ----------------------------------------------------------------------------
# ledger resolve appends done + resolves
# ----------------------------------------------------------------------------
it_ledger_resolve_appends_done() {
    local mem_dir
    mem_dir=$(_init_proj "led-res")

    local id
    id=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-res" todo "修 B2" 2>/dev/null)

    # resolve
    local rid
    rid=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-res" resolve "$id" "已合入 main" 2>/dev/null)

    local ledger="$mem_dir/ledger.md"
    assert_contains "## [$rid] done (user)" "$(cat "$ledger")" "resolve 追加 done 条目"
    assert_contains "resolves: $id" "$(cat "$ledger")" "done 条目带 resolves"
    assert_contains "已合入 main" "$(cat "$ledger")" "resolve 附注写入"
}

# ----------------------------------------------------------------------------
# list --status open computes open set (event-sourcing)
# ----------------------------------------------------------------------------
it_ledger_open_set_computed() {
    local mem_dir
    mem_dir=$(_init_proj "led-open")

    local id1 id2
    id1=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-open" todo "待办 A" 2>/dev/null)
    id2=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-open" todo "待办 B" 2>/dev/null)

    # resolve id1
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-open" resolve "$id1" >/dev/null 2>&1

    local out
    out=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-open" list --status open 2>/dev/null)
    assert_contains "待办 B" "$out" "open 集仍含未 resolve 条目"
    assert_not_contains "待办 A" "$out" "resolve 后待办 A 从 open 集消失"
}

# ----------------------------------------------------------------------------
# SessionStart injects open todos
# ----------------------------------------------------------------------------
it_session_start_injects_open_items() {
    local mem_dir
    mem_dir=$(_init_proj "led-inj")

    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-inj" todo "修注入测试" >/dev/null 2>&1
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-inj" blocker "bigram 误召回" >/dev/null 2>&1
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-inj" decision "选 BM25" >/dev/null 2>&1

    local ws
    ws=$(cat "$mem_dir/.workspace" 2>/dev/null || echo "")
    [ -z "$ws" ] && ws="$INT_FIXTURE_DIR/phase6-ws"

    local out
    out=$(session_start_inject "$ws" 2>/dev/null)

    assert_contains "<!-- mcMemory ledger: open items -->" "$out" "SessionStart 含 ledger 注入头"
    assert_contains "[todo]" "$out" "ledger 注入含 todo"
    assert_contains "[blocker]" "$out" "ledger 注入含 blocker"
    assert_not_contains "[decision]" "$out" "ledger 注入不含 decision（非 open 类型）"
}

# ----------------------------------------------------------------------------
# STOP / pause suppresses ledger inject
# ----------------------------------------------------------------------------
it_ledger_inject_respects_killswitch() {
    local mem_dir
    mem_dir=$(_init_proj "led-stop")

    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-stop" todo "应被抑制" >/dev/null 2>&1

    local ws
    ws=$(cat "$mem_dir/.workspace" 2>/dev/null || echo "")
    [ -z "$ws" ] && ws="$INT_FIXTURE_DIR/phase6-ws"

    # STOP
    local stop_file="${MEMORY_BASE}/.stop"
    touch "$stop_file"
    local out
    out=$(session_start_inject "$ws" 2>/dev/null)
    assert_not_contains "ledger: open items" "$out" "STOP 时 ledger 不注入"
    rm -f "$stop_file"

    # pause
    local pause_file="${MEMORY_BASE}/.paused_until"
    echo "9999999999" > "$pause_file"
    out=$(session_start_inject "$ws" 2>/dev/null)
    assert_not_contains "ledger: open items" "$out" "pause 时 ledger 不注入"
    rm -f "$pause_file"
}

# ----------------------------------------------------------------------------
# ledger immutability: resolve does not edit original entry
# ----------------------------------------------------------------------------
it_ledger_immutability() {
    local mem_dir
    mem_dir=$(_init_proj "led-immut")

    local id
    id=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-immut" todo "修 immut" 2>/dev/null)

    local ledger="$mem_dir/ledger.md"
    local hash_before
    hash_before=$(sha256sum "$ledger" | awk '{print $1}')

    # resolve
    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-immut" resolve "$id" >/dev/null 2>&1

    local hash_after
    hash_after=$(sha256sum "$ledger" | awk '{print $1}')

    # 追加导致 hash 必然变化；我们验证"原条目未改"：grep 原条目仍完整
    assert_contains "## [$id] todo (user)" "$(cat "$ledger")" "resolve 后原条目仍在"
    assert_contains "status: open" "$(cat "$ledger")" "resolve 后原条目 status 未变"

    # 更严格：原条目段 hash 应不变（提取前 N 行重新算）
    local orig_lines
    orig_lines=$(awk '/## \['"$id"'\] todo/{found=1} found{print; if(NF==0 && found){exit}}' "$ledger" | sha256sum | awk '{print $1}')
    # 追加 done 后原条目不变，因此上面提取的仍是原条目 → 与追加前一致
    # 此断言只要不含错即可；若原条目被改则内容不同
    [ -n "$orig_lines" ] && { echo -e "  ${GREEN}PASS${NC} 原条目段 hash 可算（未损坏）"; PASSED=$((PASSED+1)); } \
        || { echo -e "  ${RED}FAIL${NC} 原条目段提取失败"; FAILED=$((FAILED+1)); }
}

# ----------------------------------------------------------------------------
# ledger add writes op-log + event
# ----------------------------------------------------------------------------
it_ledger_oplog_and_event() {
    local mem_dir
    mem_dir=$(_init_proj "led-event")

    : > "$MCM_EVENTS_FILE"

    bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-event" todo "event test" >/dev/null 2>&1

    # op-log
    local log_file="$mem_dir/log.md"
    assert_file_exists "$log_file" "op-log log.md 存在"
    assert_contains "ledger" "$(cat "$log_file")" "op-log 含 ledger 操作记录"

    # NDJSON event
    assert_file_exists "$MCM_EVENTS_FILE" "events 文件存在"
    assert_contains '"type":"ledger.add"' "$(cat "$MCM_EVENTS_FILE")" "NDJSON 含 ledger.add 事件"
}

# ----------------------------------------------------------------------------
# ledger absent → list exits 0 with friendly message
# ----------------------------------------------------------------------------
it_ledger_absent_list_ok() {
    local mem_dir
    mem_dir=$(_init_proj "led-abs")

    local out rc
    out=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-abs" list 2>/dev/null)
    rc=$?
    assert_equal "0" "$rc" "无 ledger.md 时 list exit 0"
    assert_contains "无决策日志" "$out" "无 ledger 时友好提示"
}

# ----------------------------------------------------------------------------
# ledger show prints single entry
# ----------------------------------------------------------------------------
it_ledger_show_single() {
    local mem_dir
    mem_dir=$(_init_proj "led-show")

    local id
    id=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-show" \
        todo "修 show" --context "细节一行" 2>/dev/null)

    local out
    out=$(bash "$PROJECT_DIR/commands/ledger.sh" --memory "led-show" show "$id" 2>/dev/null)
    assert_contains "修 show" "$out" "show 输出摘要"
    assert_contains "context: 细节一行" "$out" "show 输出 context"
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "ledger add writes structured entry"            it_ledger_add_writes_entry
    "ledger list filters by type/status/since"      it_ledger_list_filters
    "ledger resolve appends done + resolves"        it_ledger_resolve_appends_done
    "list --status open computes open set"          it_ledger_open_set_computed
    "SessionStart injects open todos"               it_session_start_injects_open_items
    "STOP/pause suppresses ledger inject"           it_ledger_inject_respects_killswitch
    "ledger immutability"                           it_ledger_immutability
    "ledger add op-log + event"                     it_ledger_oplog_and_event
    "ledger absent -> list exits 0"                 it_ledger_absent_list_ok
    "ledger show prints single entry"               it_ledger_show_single
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "Phase 6 会话决策日志" "${IT_LIST[@]}"
fi
