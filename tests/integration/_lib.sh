#!/bin/bash
# ============================================================================
# 集成测试公共工具（v3.0 / Phase 0 A5-first）
# ============================================================================
# 用法：每个集成测试脚本 `source` 此文件，定义 it_xxx 函数，最后调用 run_its
#
# 与 tests/test_core.sh 的区别:
#   - 单元测试针对纯函数；集成测试跑真实 commands/hooks，断言事件流
#   - 每个 it_xxx 用独立 MEMORY_BASE fixture（mktemp 目录）
#   - 共享同一组 assert_* 风格输出（pass/fail 染色统计）
# ============================================================================

set -u   # 集成测试不能容忍未定义变量

INT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$INT_TEST_DIR")")"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASSED=0
FAILED=0
CURRENT_IT=""

# ----------------------------------------------------------------------------
# fixture 管理
# ----------------------------------------------------------------------------
INT_FIXTURE_DIR=""

it_setup() {
    INT_FIXTURE_DIR=$(mktemp -d -t mcm-int-XXXXXX)
    export MEMORY_BASE="$INT_FIXTURE_DIR/mcm"
    export MCM_EVENTS_FILE="$MEMORY_BASE/.events.ndjson"
    export PROJECTS_DIR="$MEMORY_BASE/projects"
    export GLOBAL_DIR="$MEMORY_BASE/global"
    export TRASH_DIR="$MEMORY_BASE/.trash"
    export SEARCH_INDEX="$MEMORY_BASE/.search_index"
    mkdir -p "$MEMORY_BASE"
}

it_teardown() {
    if [ -n "$INT_FIXTURE_DIR" ] && [ -d "$INT_FIXTURE_DIR" ]; then
        rm -rf "$INT_FIXTURE_DIR"
    fi
    INT_FIXTURE_DIR=""
}

# it "描述" fn_name —— setup → 调 fn → teardown
# fn 直接在主壳运行（不开子壳），让 PASSED/FAILED 累加可见
it() {
    CURRENT_IT="$1"
    local body="$2"

    echo ""
    echo -e "${YELLOW}--- it: $CURRENT_IT ---${NC}"

    it_setup
    # 临时关 set -e，单个断言失败不影响后续
    set +e
    "$body"
    set -e 2>/dev/null || true
    it_teardown
}

# ----------------------------------------------------------------------------
# 断言（与 test_core.sh 同风格）
# ----------------------------------------------------------------------------
assert_equal() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local msg="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    expected to contain: '$needle'"
        echo "    in: '$(printf '%s' "$haystack" | head -c 200)'"
        FAILED=$((FAILED + 1))
    fi
}

assert_not_contains() {
    local needle="$1"
    local haystack="$2"
    local msg="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    must NOT contain: '$needle'"
        FAILED=$((FAILED + 1))
    else
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASSED=$((PASSED + 1))
    fi
}

assert_ge() {
    local actual="$1"
    local floor="$2"
    local msg="$3"
    if [ "$actual" -ge "$floor" ] 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    expected >= $floor, got $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="$2"
    if [ -f "$path" ]; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    file missing: $path"
        FAILED=$((FAILED + 1))
    fi
}

# ----------------------------------------------------------------------------
# 事件流断言：count_events TYPE  /  events_field
# ----------------------------------------------------------------------------
count_events() {
    local type_pattern="$1"
    [ -f "$MCM_EVENTS_FILE" ] || { echo 0; return; }
    local n
    n=$(grep -c "\"type\":\"${type_pattern}" "$MCM_EVENTS_FILE" 2>/dev/null)
    echo "${n:-0}"
}

events_field() {
    local type_pattern="$1"
    local field="$2"
    [ -f "$MCM_EVENTS_FILE" ] || { echo "[]"; return; }
    $PYTHON -c "
import json, re
out = []
with open('$MCM_EVENTS_FILE') as f:
    for line in f:
        try: obj = json.loads(line)
        except: continue
        if re.match(r'^${type_pattern}$', obj.get('type','')):
            out.append(obj.get('$field', ''))
print(json.dumps(out, ensure_ascii=False))
"
}

# ----------------------------------------------------------------------------
# run_its TITLE — 在测试脚本末尾调用，跑所有 it_xxx 函数（按定义顺序）
# 通过 compgen 找 it_xxx 函数；若不存在则报错
# ----------------------------------------------------------------------------
run_its() {
    local title="$1"; shift
    echo ""
    echo "=========================================="
    echo "  集成测试: $title"
    echo "=========================================="

    # 调用方传入的 it 序列（"描述" fn_name "描述" fn_name ...）
    while [ $# -ge 2 ]; do
        it "$1" "$2"
        shift 2
    done

    echo ""
    echo "=========================================="
    echo -e "  结果: ${GREEN}$PASSED${NC} 通过, ${RED}$FAILED${NC} 失败"
    echo "=========================================="
    [ "$FAILED" -gt 0 ] && exit 1
    exit 0
}
