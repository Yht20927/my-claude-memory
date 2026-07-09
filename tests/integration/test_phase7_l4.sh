#!/bin/bash
# ============================================================================
# 集成测试 9: Phase 7.1 L4 device-keyed registry (v4.0)
# ----------------------------------------------------------------------------
# 覆盖: current_device_id 三级解析、record_l4_source/resolve_l4_source、
#       check_l4_health 读 JSON 判 valid/broken、多设备独立文件、init 端到端
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"

# 每个用例独立 MEMORY_BASE fixture（it_setup 提供）；MCM_DEVICE 显式管理避免泄漏
_reset_device() {
    unset MCM_DEVICE
    rm -f "$MEMORY_BASE/.device"
}

_seed_ws() {
    local ws="$INT_FIXTURE_DIR/p7-ws"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    echo "# project root doc" > "$ws/CLAUDE.md"
    echo "# memory doc" > "$ws/MEMORY.md"
    echo "$ws"
}

# ----------------------------------------------------------------------------
# current_device_id 三级解析: MCM_DEVICE > .device > hostname
# ----------------------------------------------------------------------------
it_device_id_resolution() {
    _reset_device

    # Level 1: MCM_DEVICE 环境变量最高优先
    export MCM_DEVICE="envbox"
    assert_equal "envbox" "$(current_device_id)" "MCM_DEVICE 覆盖优先"

    # Level 2: 无 env 时读 .device 文件
    unset MCM_DEVICE
    echo "filebox" > "$MEMORY_BASE/.device"
    assert_equal "filebox" "$(current_device_id)" ".device 文件次优先"

    # Level 3: 无 env 无 .device 时回退 hostname
    rm -f "$MEMORY_BASE/.device"
    local hn
    hn=$(hostname 2>/dev/null || echo unknown)
    assert_equal "$hn" "$(current_device_id)" "hostname 回退"
    [ -n "$hn" ] && { echo -e "  ${GREEN}PASS${NC} device id 非空"; PASSED=$((PASSED+1)); }
}

# ----------------------------------------------------------------------------
# record_l4_source 写 device JSON，结构正确，幂等覆盖
# ----------------------------------------------------------------------------
it_record_writes_device_json() {
    _reset_device
    export MCM_DEVICE="testbox"
    local mem="$INT_FIXTURE_DIR/mem"
    local ws="$INT_FIXTURE_DIR/ws"
    mkdir -p "$mem" "$ws"
    echo "# a" > "$ws/a.md"
    echo "# b" > "$ws/b.py"

    record_l4_source "$mem" "$ws/a.md" >/dev/null 2>&1
    record_l4_source "$mem" "$ws/b.py" >/dev/null 2>&1

    local json="$mem/.claude/l4/testbox.json"
    assert_file_exists "$json" "device JSON 已创建"
    assert_contains '"device": "testbox"' "$(cat "$json")" "device 字段正确"
    assert_contains '"a.md"' "$(cat "$json")" "含 a.md 源"
    assert_contains '"b.py"' "$(cat "$json")" "含 b.py 源"

    # 幂等：重复记录同源不重复
    record_l4_source "$mem" "$ws/a.md" >/dev/null 2>&1
    local n
    n=$(grep -c '"a.md"' "$json")
    assert_equal "1" "$n" "幂等：重复记录不产生重复条目"
}

# ----------------------------------------------------------------------------
# check_l4_health 读 JSON 判 valid/broken，删源后变 broken
# ----------------------------------------------------------------------------
it_health_counts_valid_broken() {
    _reset_device
    export MCM_DEVICE="testbox"
    local mem="$INT_FIXTURE_DIR/mem"
    local ws="$INT_FIXTURE_DIR/ws"
    mkdir -p "$mem" "$ws"
    echo "# a" > "$ws/a.md"
    echo "# b" > "$ws/b.py"
    record_l4_source "$mem" "$ws/a.md" >/dev/null 2>&1
    record_l4_source "$mem" "$ws/b.py" >/dev/null 2>&1

    assert_equal "2 0 0" "$(check_l4_health "$mem/.claude")" "两源均 valid"

    # 删一个源 -> 1 valid 1 broken
    rm -f "$ws/b.py"
    assert_equal "1 1 0" "$(check_l4_health "$mem/.claude")" "删源后 1 valid 1 broken"

    # 无 JSON 时 0 0 0
    rm -rf "$mem/.claude"
    assert_equal "0 0 0" "$(check_l4_health "$mem/.claude")" "无 registry 时 0 0 0"
}

# ----------------------------------------------------------------------------
# resolve_l4_source 命中/缺失
# ----------------------------------------------------------------------------
it_resolve_returns_path() {
    _reset_device
    export MCM_DEVICE="testbox"
    local mem="$INT_FIXTURE_DIR/mem"
    local ws="$INT_FIXTURE_DIR/ws"
    mkdir -p "$mem" "$ws"
    echo "# a" > "$ws/a.md"
    record_l4_source "$mem" "$ws/a.md" >/dev/null 2>&1

    local resolved
    resolved=$(resolve_l4_source "$mem" "a.md")
    assert_contains "ws/a.md" "$resolved" "resolve 返回源路径"
    [ -e "$resolved" ] && { echo -e "  ${GREEN}PASS${NC} resolved 路径实际存在"; PASSED=$((PASSED+1)); }

    # 未记录的源 -> 空
    local miss
    miss=$(resolve_l4_source "$mem" "nope.md")
    assert_equal "" "$miss" "未记录源返回空"
}

# ----------------------------------------------------------------------------
# 多设备独立文件，health 各自只读自己
# ----------------------------------------------------------------------------
it_multi_device_independent() {
    _reset_device

    local mem="$INT_FIXTURE_DIR/mem"
    local ws="$INT_FIXTURE_DIR/ws"
    mkdir -p "$mem" "$ws"
    echo "# a" > "$ws/a.md"

    export MCM_DEVICE="boxA"
    record_l4_source "$mem" "$ws/a.md" >/dev/null 2>&1
    assert_file_exists "$mem/.claude/l4/boxA.json" "boxA JSON 存在"

    export MCM_DEVICE="boxB"
    record_l4_source "$mem" "$ws/a.md" >/dev/null 2>&1
    assert_file_exists "$mem/.claude/l4/boxB.json" "boxB JSON 存在"

    # 两文件独立
    assert_file_exists "$mem/.claude/l4/boxA.json" "boxA 仍在(未被 boxB 覆盖)"

    # health 各读各的
    export MCM_DEVICE="boxA"
    assert_equal "1 0 0" "$(check_l4_health "$mem/.claude")" "boxA health 读 boxA"
    export MCM_DEVICE="boxB"
    assert_equal "1 0 0" "$(check_l4_health "$mem/.claude")" "boxB health 读 boxB"
    export MCM_DEVICE="boxC"
    assert_equal "0 0 0" "$(check_l4_health "$mem/.claude")" "boxC 无条目 0 0 0"
}

# ----------------------------------------------------------------------------
# init 端到端: mcmInit 后 .claude/l4/<device>.json 存在, health 报 valid
# ----------------------------------------------------------------------------
it_init_creates_device_registry() {
    _reset_device
    export MCM_DEVICE="initbox"
    local ws
    ws=$(_seed_ws)

    bash "$PROJECT_DIR/commands/init.sh" --name "p7-proj" --tags "tools" \
        --description "l4 e2e" --workspace "$ws" >/dev/null 2>&1

    local mem="$PROJECTS_DIR/tools/p7-proj"
    local json="$mem/.claude/l4/initbox.json"
    assert_file_exists "$json" "init 后 device JSON 已生成"

    # init 探测到 CLAUDE.md + MEMORY.md 两个源
    assert_contains "CLAUDE.md" "$(cat "$json")" "registry 含 CLAUDE.md"
    assert_contains "MEMORY.md" "$(cat "$json")" "registry 含 MEMORY.md"

    # health 报两源 valid
    assert_equal "2 0 0" "$(check_l4_health "$mem/.claude")" "init 后 L4 两源 valid"

    # 旧格式无残留（无软链/.source 散落 .claude 根）
    local legacy
    legacy=$(find "$mem/.claude" -maxdepth 1 \( -type l -o -name '*.source' \) 2>/dev/null | wc -l)
    assert_equal "0" "$legacy" "无旧格式软链/.source 残留"
}

# ----------------------------------------------------------------------------
# 删源 -> drift 报 broken-l4（device 契约下仍成立）
# ----------------------------------------------------------------------------
it_drift_broken_l4_via_device() {
    _reset_device
    export MCM_DEVICE="driftbox"
    local ws
    ws=$(_seed_ws)

    bash "$PROJECT_DIR/commands/init.sh" --name "drift7" --tags "tools" \
        --description "drift" --workspace "$ws" >/dev/null 2>&1

    # 删已记录的源 -> L4 broken
    rm -f "$ws/CLAUDE.md"
    local out
    out=$(MCM_DRIFT_STALE_DAYS=30 bash "$PROJECT_DIR/commands/status.sh" --drift 2>/dev/null)
    assert_contains "broken-l4:" "$out" "drift 报 broken-l4 (device 契约)"
}

# ----------------------------------------------------------------------------
# device id 文件名安全化：防 MCM_DEVICE="../../../x" 路径遍历
# ----------------------------------------------------------------------------
it_device_id_sanitized() {
    _reset_device
    mkdir -p "$INT_FIXTURE_DIR/ws"
    echo "# x" > "$INT_FIXTURE_DIR/ws/x.md"

    # 恶意 device id 含路径分隔符
    export MCM_DEVICE='../../../etc/evil'
    local dev
    dev=$(current_device_id)
    assert_not_contains "/" "$dev" "device id 不含路径分隔符(防遍历)"

    # 记录后 JSON 必须在 .claude/l4/ 内,不逃逸到 .. 之外
    local mem="$INT_FIXTURE_DIR/mem"
    mkdir -p "$mem"
    record_l4_source "$mem" "$INT_FIXTURE_DIR/ws/x.md" >/dev/null 2>&1
    local escaped
    escaped=$(find "$INT_FIXTURE_DIR" -name '*.json' -not -path "$mem/.claude/l4/*" 2>/dev/null | head -1)
    [ -z "$escaped" ] && { echo -e "  ${GREEN}PASS${NC} 无逃逸文件(JSON 留在 l4/ 内)"; PASSED=$((PASSED+1)); } \
        || { echo -e "  ${RED}FAIL${NC} 逃逸文件: $escaped"; FAILED=$((FAILED+1)); }

    # 含空格/特殊字符的 device id 也被净化为单文件名
    export MCM_DEVICE='my box!@#'
    dev=$(current_device_id)
    assert_not_contains " " "$dev" "device id 不含空格"
}

run_its "Phase 7.1 L4 device-keyed registry" \
    "device id 三级解析"        it_device_id_resolution \
    "record 写 device JSON"     it_record_writes_device_json \
    "health valid/broken 计数"  it_health_counts_valid_broken \
    "resolve 命中/缺失"         it_resolve_returns_path \
    "多设备独立文件"            it_multi_device_independent \
    "init 端到端 device registry" it_init_creates_device_registry \
    "drift broken-l4 经 device" it_drift_broken_l4_via_device \
    "device id 安全化防遍历"   it_device_id_sanitized
