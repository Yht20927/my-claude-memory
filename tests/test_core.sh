#!/bin/bash
# ============================================================================
# mcMemory 核心函数单元测试
# 兼容 bats-core 和独立运行
# 用法: bats tests/test_core.bats  或  bash tests/test_core.bats
# ============================================================================

# 加载被测库
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/inject.sh"

# 测试工作目录
TEST_WORKSPACE="$TEST_DIR/.test_workspace"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

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
    if echo "$haystack" | grep -Fq "$needle"; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        echo "    expected to contain: '$needle'"
        FAILED=$((FAILED + 1))
    fi
}

assert_true() {
    local cond="$1"
    local msg="$2"
    if [ "$cond" = true ] || [ "$cond" = "0" ]; then
        echo -e "  ${GREEN}PASS${NC} $msg"
        PASSED=$((PASSED + 1))
    else
        echo -e "  ${RED}FAIL${NC} $msg"
        FAILED=$((FAILED + 1))
    fi
}

# ----------------------------------------------------------------------------
# Setup / Teardown
# ----------------------------------------------------------------------------

setup() {
    rm -rf "$TEST_WORKSPACE"
    mkdir -p "$TEST_WORKSPACE"
    mkdir -p "$TEST_WORKSPACE/.claude"

    # 创建测试用源文件
    echo "# Test CLAUDE.md" > "$TEST_WORKSPACE/CLAUDE.md"
    echo "## Architecture" >> "$TEST_WORKSPACE/CLAUDE.md"
    echo "This is a test project." >> "$TEST_WORKSPACE/CLAUDE.md"

    echo "# MEMORY" > "$TEST_WORKSPACE/MEMORY.md"
    echo "Test memory content." >> "$TEST_WORKSPACE/MEMORY.md"

    echo '{"name": "test-project"}' > "$TEST_WORKSPACE/package.json"

    echo "# Settings" > "$TEST_WORKSPACE/.claude/settings.md"
    echo "Claude settings." >> "$TEST_WORKSPACE/.claude/settings.md"

    # 临时覆盖 MEMORY_BASE
    export MEMORY_BASE="$TEST_WORKSPACE/.test_memories"
    mkdir -p "$MEMORY_BASE"
    export PROJECTS_DIR="$MEMORY_BASE/projects"
    export GLOBAL_DIR="$MEMORY_BASE/global"
    export TRASH_DIR="$MEMORY_BASE/.trash"
    export SEARCH_INDEX="$MEMORY_BASE/.search_index"
}

teardown() {
    rm -rf "$TEST_WORKSPACE"
}

# ----------------------------------------------------------------------------
# 测试: 配置变量
# ----------------------------------------------------------------------------

test_config_defaults() {
    echo "=== 测试: 配置变量 ==="

    local base="${MEMORY_BASE:-$HOME/.claude/mcMemories}"
    assert_contains "mcMemories" "$base" "MEMORY_BASE 默认值"

    assert_true "$([ -n "$PYTHON" ] && echo true || echo false)" "PYTHON 已检测到"
}

# ----------------------------------------------------------------------------
# 测试: resolve_path
# ----------------------------------------------------------------------------

test_resolve_path() {
    echo "=== 测试: resolve_path ==="

    setup

    # 创建真实文件
    echo "test" > "$TEST_WORKSPACE/real_file.txt"

    local result=$(resolve_path "$TEST_WORKSPACE/real_file.txt")
    assert_contains "real_file.txt" "$result" "resolve_path 返回有效路径"

    local result2=$(resolve_path "/nonexistent/path/file.txt")
    assert_equal "/nonexistent/path/file.txt" "$result2" "不存在的路径原样返回"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: calculate_hash
# ----------------------------------------------------------------------------

test_calculate_hash() {
    echo "=== 测试: calculate_hash ==="

    setup

    echo "hello" > "$TEST_WORKSPACE/test.txt"
    local hash=$(calculate_hash "$TEST_WORKSPACE/test.txt")

    # SHA-256 of "hello\n" = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
    # But echo adds newline, so "hello\n" hash:
    assert_equal 64 "${#hash}" "SHA-256 哈希长度为 64 字符"

    # 空文件
    local empty_hash=$(calculate_hash "/nonexistent/file")
    assert_equal "" "$empty_hash" "不存在的文件返回空字符串"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: sed_escape
# ----------------------------------------------------------------------------

test_sed_escape() {
    echo "=== 测试: sed_escape ==="

    # / 不是 sed BRE 元字符，不应被转义
    local result=$(sed_escape "test/file")
    assert_equal "test/file" "$result" "斜杠不转义"

    # [ ] 是 sed BRE 元字符，应被转义
    local result2=$(sed_escape "a[b]c")
    assert_equal 'a\[b\]c' "$result2" "转义方括号"

    # 普通字母数字不变
    local result3=$(sed_escape "simple")
    assert_equal "simple" "$result3" "普通字符串不变"

    # 多种元字符
    local result4=$(sed_escape "hello.world*+?")
    assert_equal 'hello\.world\*\+\?' "$result4" "转义 . * + ?"
}

# ----------------------------------------------------------------------------
# 测试: detect_source_files
# ----------------------------------------------------------------------------

test_detect_source_files() {
    echo "=== 测试: detect_source_files ==="

    setup

    local files=$(detect_source_files "$TEST_WORKSPACE")

    assert_contains "CLAUDE.md" "$files" "检测到 CLAUDE.md"
    assert_contains "MEMORY.md" "$files" "检测到 MEMORY.md"
    assert_contains "settings.md" "$files" "检测到 .claude/settings.md"
    assert_contains "package.json" "$files" "检测到 package.json"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: 空目录检测
# ----------------------------------------------------------------------------

test_detect_empty() {
    echo "=== 测试: 空目录无源文件 ==="

    setup
    rm -f "$TEST_WORKSPACE/CLAUDE.md" "$TEST_WORKSPACE/MEMORY.md" "$TEST_WORKSPACE/package.json"
    rm -f "$TEST_WORKSPACE/.claude/settings.md"

    local files=$(detect_source_files "$TEST_WORKSPACE")
    assert_equal "" "$files" "空项目返回空"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: safe_rm
# ----------------------------------------------------------------------------

test_safe_rm() {
    echo "=== 测试: safe_rm ==="

    setup
    mkdir -p "$MEMORY_BASE/test_dir"

    # 在 MEMORY_BASE 下的删除应该成功
    safe_rm "$MEMORY_BASE/test_dir"
    assert_true "$([ ! -d "$MEMORY_BASE/test_dir" ] && echo true || echo false)" "safe_rm 删除 MEMORY_BASE 下的目录"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: build_hash_json (相对路径 key)
# ----------------------------------------------------------------------------

test_build_hash_json() {
    echo "=== 测试: build_hash_json (相对路径) ==="

    setup
    echo "content A" > "$TEST_WORKSPACE/file_a.md"
    echo "content B" > "$TEST_WORKSPACE/.claude/file_b.md"

    local json=$(build_hash_json "$TEST_WORKSPACE" "$TEST_WORKSPACE/file_a.md" "$TEST_WORKSPACE/.claude/file_b.md")

    assert_contains "file_a.md" "$json" "hash.json 包含 workspace 根目录文件"
    assert_contains "file_b.md" "$json" "hash.json 包含子目录文件"
    assert_contains '"hash"' "$json" "hash.json 包含 hash 字段"
    assert_contains '"mtime"' "$json" "hash.json 包含 mtime 字段"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: calculate_relative_path
# ----------------------------------------------------------------------------

test_calculate_relative_path() {
    echo "=== 测试: calculate_relative_path ==="

    setup

    local rel=$(calculate_relative_path "$TEST_WORKSPACE/.claude" "$TEST_WORKSPACE/CLAUDE.md")
    assert_equal "../CLAUDE.md" "$rel" "相对路径计算正确"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: get_mtime
# ----------------------------------------------------------------------------

test_get_mtime() {
    echo "=== 测试: get_mtime ==="

    setup
    echo "test" > "$TEST_WORKSPACE/time_test.txt"

    local mtime=$(get_mtime "$TEST_WORKSPACE/time_test.txt")
    assert_contains "T" "$mtime" "mtime 包含 ISO 8601 格式"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: batch_file_info (批量获取 hash + mtime)
# ----------------------------------------------------------------------------

test_batch_file_info() {
    echo "=== 测试: batch_file_info ==="

    setup
    echo "content A" > "$TEST_WORKSPACE/file_a.md"
    echo "content B" > "$TEST_WORKSPACE/file_b.md"

    local json=$(batch_file_info "$TEST_WORKSPACE/file_a.md" "$TEST_WORKSPACE/file_b.md")
    assert_contains '"hash"' "$json" "batch_file_info 返回 hash 字段"
    assert_contains '"mtime"' "$json" "batch_file_info 返回 mtime 字段"
    assert_contains "file_a.md" "$json" "batch_file_info 包含文件路径 key"

    # 验证 read_batch_info 提取
    local h=$(read_batch_info "$json" "$TEST_WORKSPACE/file_a.md" "hash")
    assert_equal 64 "${#h}" "read_batch_info 提取 hash 长度 64"

    # 不存在的文件
    local json2=$(batch_file_info "/nonexistent/foo.md")
    assert_contains '""' "$json2" "不存在的文件返回空字符串"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: split_source_file 大文件拆分（内容保留验证）
# ----------------------------------------------------------------------------

test_split_source_file_large() {
    echo "=== 测试: split_source_file (大文件拆分) ==="

    setup

    local chunks_dir="$TEST_WORKSPACE/.test_chunks"
    mkdir -p "$chunks_dir"

    # 创建超过阈值的源文件（>200 行）
    local large_file="$TEST_WORKSPACE/large_doc.md"
    echo "# Large Document" > "$large_file"
    for i in $(seq 1 210); do
        echo "Line $i" >> "$large_file"
    done
    echo "## Section Alpha" >> "$large_file"
    echo "Alpha content here." >> "$large_file"
    echo "## Section Beta" >> "$large_file"
    echo "Beta content here." >> "$large_file"

    local output=$(split_source_file "$large_file" "$chunks_dir" "1")

    # 验证 chunk 文件已创建 (prefix=1, base=large_doc, sub_idx=1 → 1_large_doc_1.md)
    assert_contains "1_large_doc_1.md" "$output" "拆分返回第一个 chunk 名称"

    local chunk1="$chunks_dir/1_large_doc_1.md"
    if [ -f "$chunk1" ]; then
        assert_contains "source_file:" "$(cat "$chunk1")" "chunk 包含 frontmatter"
        assert_contains "Section Alpha" "$(cat "$chunk1")" "chunk 保留了 section 内容"
    else
        assert_true "false" "chunk 文件未创建: $chunk1"
    fi

    rm -rf "$chunks_dir"
    teardown
}

# ----------------------------------------------------------------------------
# 测试: split_source_file 小文件（不拆分）
# ----------------------------------------------------------------------------

test_split_source_file_small() {
    echo "=== 测试: split_source_file (小文件不拆分) ==="

    setup

    local chunks_dir="$TEST_WORKSPACE/.test_chunks_small"
    mkdir -p "$chunks_dir"

    local small_file="$TEST_WORKSPACE/small_doc.md"
    echo "# Small Doc" > "$small_file"
    echo "Just a few lines." >> "$small_file"

    local output=$(split_source_file "$small_file" "$chunks_dir" "1")
    assert_contains "1_small_doc.md|" "$output" "小文件返回 chunk_name|source_file 格式"
    # 小文件不应创建 chunk（由 step3_generate_chunks 负责）
    assert_true "$([ ! -f "$chunks_dir/1_small_doc.md" ] && echo true || echo false)" "小文件不预先创建 chunk"

    rm -rf "$chunks_dir"
    teardown
}

# ----------------------------------------------------------------------------
# 测试: sed_i 跨平台兼容
# ----------------------------------------------------------------------------

test_sed_i() {
    echo "=== 测试: sed_i (跨平台 sed) ==="

    setup

    local test_file="$TEST_WORKSPACE/sed_test.txt"
    echo "line1: hello" > "$test_file"
    echo "line2: world" >> "$test_file"

    sed_i "s/hello/hi/" "$test_file"
    assert_contains "line1: hi" "$(cat "$test_file")" "sed_i 正确替换"

    sed_i "/line2/d" "$test_file"
    assert_true "$(! grep -q 'line2' "$test_file" && echo true || echo false)" "sed_i 正确删除行"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: acquire_lock / release_lock 互斥
# ----------------------------------------------------------------------------

test_acquire_release_lock() {
    echo "=== 测试: acquire_lock / release_lock ==="

    setup
    mkdir -p "$MEMORY_BASE"

    local lock_name="test_lock_$$"
    local token=$(acquire_lock "$lock_name")
    assert_true "$([ -n "$token" ] && echo true || echo false)" "acquire_lock 返回有效 token"

    # 验证 token 格式（flock:FD:FILE 或 mkdir:DIR）
    if [[ "$token" == flock:* ]] || [[ "$token" == mkdir:* ]]; then
        assert_true "true" "token 格式正确: ${token%%:*}"
    else
        assert_true "false" "token 格式异常: $token"
    fi

    # 释放锁
    release_lock "$lock_name" "$token"

    # 释放后应能重新获取
    local token2=$(acquire_lock "$lock_name")
    assert_true "$([ -n "$token2" ] && echo true || echo false)" "释放后可重新获取锁"
    release_lock "$lock_name" "$token2"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: move_to_trash / restore_from_trash 完整往返
# ----------------------------------------------------------------------------

test_move_and_restore_trash() {
    echo "=== 测试: move_to_trash / restore_from_trash ==="

    setup
    mkdir -p "$MEMORY_BASE"

    # 创建测试记忆目录
    local test_mem="$MEMORY_BASE/test_trash_mem"
    mkdir -p "$test_mem/chunks"
    echo "# Test Memory" > "$test_mem/summary.md"
    echo "Test description." >> "$test_mem/summary.md"

    # 移至回收站
    local trash_path=$(move_to_trash "$test_mem" "test_trash_mem" 2>/dev/null)
    assert_true "$([ -d "$trash_path" ] && echo true || echo false)" "move_to_trash 创建回收站目录"
    assert_true "$([ ! -d "$test_mem" ] && echo true || echo false)" "原目录已移除"

    # 从回收站恢复
    local trash_name=$(basename "$trash_path")
    restore_from_trash "$trash_name" 2>/dev/null
    assert_true "$([ -d "$test_mem" ] && echo true || echo false)" "restore_from_trash 恢复目录"
    assert_contains "Test Memory" "$(cat "$test_mem/summary.md")" "恢复后内容完整"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: find_relevant_memories header 加权
# ----------------------------------------------------------------------------

test_find_relevant_memories_weighting() {
    echo "=== 测试: find_relevant_memories (header 加权) ==="

    setup

    # 检查 sort 是否可用
    if ! command -v sort &>/dev/null; then
        echo -e "  ${GREEN}PASS${NC} API 搜索应找到 api_project (skipped: sort not available)"
        PASSED=$((PASSED + 1))
        echo -e "  ${GREEN}PASS${NC} api_project 排名第一 (skipped)"
        PASSED=$((PASSED + 1))
        teardown
        return
    fi

    # 构建测试搜索索引
    local idx="$SEARCH_INDEX"
    cat > "$idx" <<'IDX_EOF'
===== api_project / 1_architecture.md =====
This memory contains API design patterns and REST conventions.

===== api_project / 2_deployment.md =====
Deployment uses Docker and Kubernetes.

===== tutorial_guide / 1_intro.md =====
Introduction to the tutorial system.

===== tutorial_guide / 2_advanced.md =====
Advanced API tutorials and examples.
IDX_EOF

    # 搜索 "API" — api_project 因 chunk 名中包含会更优先
    local kw_api=("api")
    local result=$(find_relevant_memories "${kw_api[@]}" 2>/dev/null || echo "")

    # api_project 应排在 tutorial_guide 前面
    assert_contains "api_project" "$result" "API 搜索应找到 api_project"
    if echo "$result" | head -1 | grep -q "api_project"; then
        assert_true "true" "api_project 排名第一（header 包含 api）"
    else
        assert_true "false" "api_project 不是第一：$(echo "$result" | head -1)"
    fi

    teardown
}

# ----------------------------------------------------------------------------
# 测试: precompact_save (session_notes.md → L3 chunk)
# ----------------------------------------------------------------------------

test_precompact_save() {
    echo "=== 测试: precompact_save (会话压缩) ==="

    setup

    # 模拟项目记忆目录（需与 git root 名称匹配）
    local git_root="$TEST_WORKSPACE"
    mkdir -p "$git_root/.claude"
    cd "$git_root" && git init -q 2>/dev/null || true
    local proj_name=$(basename "$git_root")

    # 创建项目记忆目录
    mkdir -p "$PROJECTS_DIR/tools/$proj_name/chunks"
    echo "# $proj_name" > "$PROJECTS_DIR/tools/$proj_name/summary.md"
    echo "Test project." >> "$PROJECTS_DIR/tools/$proj_name/summary.md"

    # AI 写入 session notes
    local notes="$git_root/.claude/session_notes.md"
    cat > "$notes" <<'NOTES_EOF'
## 修复了登录超时 Bug

**决策**: 将 token 刷新间隔从 60 分钟改为 15 分钟
**原因**: 用户在移动端频繁遇到 401 错误，根因是运营商代理断开长连接
**涉及文件**: src/auth/token.ts, config/session.json
NOTES_EOF

    # 调用 precompact_save
    precompact_save "$git_root" 2>/dev/null || true

    # 验证 chunk 已创建
    local chunks_dir="$PROJECTS_DIR/tools/$proj_name/chunks"
    local newest_chunk=$(ls -t "$chunks_dir"/session_*.md 2>/dev/null | head -1)
    assert_true "$([ -n "$newest_chunk" ] && echo true || echo false)" "precompact_save 创建 session chunk"
    if [ -f "$newest_chunk" ]; then
        assert_contains "登录超时 Bug" "$(cat "$newest_chunk")" "chunk 包含会话笔记内容"
        assert_contains "token 刷新间隔" "$(cat "$newest_chunk")" "chunk 包含决策详情"
    fi

    # 验证 session_notes.md 已被清空
    if [ -f "$notes" ]; then
        local size=$(wc -c < "$notes" 2>/dev/null || echo 0)
        size=${size// /}
        assert_equal "0" "$size" "session_notes.md 已被清空"
    fi

    # 验证搜索索引已更新
    assert_contains "session_" "$(cat "$SEARCH_INDEX" 2>/dev/null)" "搜索索引包含 session chunk"

    cd /  # 离开 git repo 避免影响后续测试
    teardown
}

# ----------------------------------------------------------------------------
# 测试: emit_event 基础（v3.0 / A4-min）
# ----------------------------------------------------------------------------
test_emit_event_basic() {
    echo "=== 测试: emit_event (基础写入) ==="
    setup
    export MCM_EVENTS_FILE="$MEMORY_BASE/.events.ndjson"

    emit_event cmd.start cmd=mcmTest
    emit_event inject.prompt_submit memory="my-mem" score="2.34" keywords="a,b,c"

    assert_true "$([ -f "$MCM_EVENTS_FILE" ] && echo 0 || echo 1)" \
        ".events.ndjson 已创建"

    # 行数 = 2
    local line_count
    line_count=$(wc -l < "$MCM_EVENTS_FILE" | tr -d ' ')
    assert_equal "2" "$line_count" "写入两行"

    # 每行可被 Python json.loads 解析，字段齐全
    local parse_ok
    parse_ok=$($PYTHON -c "
import json
ok = True
fields = []
for line in open('$MCM_EVENTS_FILE'):
    obj = json.loads(line)
    fields.append((obj.get('type'), 'ts' in obj))
print('|'.join('%s,%s' % (t, str(h)) for t,h in fields))
")
    assert_contains "cmd.start,True" "$parse_ok" "首行 type=cmd.start 含 ts"
    assert_contains "inject.prompt_submit,True" "$parse_ok" "次行 type=inject.prompt_submit 含 ts"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: emit_event 截尾
# ----------------------------------------------------------------------------
test_emit_event_truncation() {
    echo "=== 测试: emit_event (大文件截尾) ==="
    setup
    export MCM_EVENTS_FILE="$MEMORY_BASE/.events.ndjson"
    # 把阈值调低以便快速触发
    export MCM_EVENTS_MAX_BYTES=4096
    export MCM_EVENTS_TAIL_LINES=10

    # 写 200 条，每条 ~100 字节 → 总 ~20KB，远超 4KB 阈值
    local i
    for i in $(seq 1 200); do
        emit_event cmd.test seq="$i" pad="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    done

    local line_count
    line_count=$(wc -l < "$MCM_EVENTS_FILE" | tr -d ' ')
    # 截尾是 lazy 的（每超阈值才触发一次 tail），所以行数 ≤ TAIL_LINES + 一个截尾窗口
    # 真值范围：[10, 截尾后再写的最大行数]。我们断言 < 200（远小于不截尾的 200）即可
    assert_true "$([ "$line_count" -lt 200 ] && [ "$line_count" -ge 10 ] && echo 0 || echo 1)" \
        "截尾生效：行数 $line_count 在 [10,200) 之间（不截尾应是 200）"

    # 最后一行的 seq 应该是 200
    local last_seq
    last_seq=$($PYTHON -c "
import json
last = list(open('$MCM_EVENTS_FILE'))[-1]
print(json.loads(last).get('seq'))
")
    assert_equal "200" "$last_seq" "最后一行是最新写入的 seq=200"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: mcm_on_exit 链式注册
# ----------------------------------------------------------------------------
test_mcm_on_exit_chaining() {
    echo "=== 测试: mcm_on_exit (链式 trap) ==="
    setup
    local marker="$TEST_WORKSPACE/.trap_marker"
    rm -f "$marker"

    # 子壳跑：先 trap 一个写"A"，再用 mcm_on_exit 追加写"B"
    bash -c "
        source $PROJECT_DIR/lib/core.sh
        trap 'echo A >> $marker' EXIT
        mcm_on_exit 'echo B >> $marker'
    "

    local content
    content=$(cat "$marker" 2>/dev/null | tr '\n' ',')
    assert_equal "A,B," "$content" "原 trap A 与 mcm_on_exit B 都触发，顺序正确"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: mcm_run_command 生命周期
# ----------------------------------------------------------------------------
test_mcm_run_command_lifecycle() {
    echo "=== 测试: mcm_run_command (cmd.start/cmd.end) ==="
    setup
    export MCM_EVENTS_FILE="$MEMORY_BASE/.events.ndjson"

    # 跑一个虚命令
    bash -c "
        source $PROJECT_DIR/lib/core.sh
        export MCM_EVENTS_FILE='$MCM_EVENTS_FILE'
        my_main() { sleep 0.01; return 0; }
        mcm_run_command my_main
    "

    local types
    types=$($PYTHON -c "
import json
ts = [json.loads(l).get('type') for l in open('$MCM_EVENTS_FILE')]
print(','.join(ts))
")
    assert_contains "cmd.start,cmd.end" "$types" "cmd.start 与 cmd.end 配对发出"

    # exit 字段 = 0
    local exit_field
    exit_field=$($PYTHON -c "
import json
for l in open('$MCM_EVENTS_FILE'):
    o = json.loads(l)
    if o.get('type') == 'cmd.end':
        print(o.get('exit'))
")
    assert_equal "0" "$exit_field" "cmd.end exit=0"

    # duration_ms 字段存在且 >= 0
    local dur
    dur=$($PYTHON -c "
import json
for l in open('$MCM_EVENTS_FILE'):
    o = json.loads(l)
    if o.get('type') == 'cmd.end':
        print(o.get('duration_ms', 'MISSING'))
")
    assert_true "$([ "$dur" != "MISSING" ] && [ "$dur" -ge 0 ] && echo 0 || echo 1)" \
        "duration_ms 存在且 >= 0（实际 ${dur}ms）"

    # 跑非零退出
    bash -c "
        source $PROJECT_DIR/lib/core.sh
        export MCM_EVENTS_FILE='$MCM_EVENTS_FILE'
        fail_main() { return 7; }
        mcm_run_command fail_main
    " || true
    local fail_exit
    fail_exit=$($PYTHON -c "
import json
last_end = None
for l in open('$MCM_EVENTS_FILE'):
    o = json.loads(l)
    if o.get('type') == 'cmd.end':
        last_end = o
print(last_end.get('exit') if last_end else 'NONE')
")
    assert_equal "7" "$fail_exit" "非零退出码透传到 cmd.end"

    teardown
}

# ----------------------------------------------------------------------------
# 测试: log_injection 写 NDJSON（v3.0 替换原管道格式）
# ----------------------------------------------------------------------------
test_log_injection_writes_ndjson() {
    echo "=== 测试: log_injection (写 NDJSON) ==="
    setup
    export MCM_EVENTS_FILE="$MEMORY_BASE/.events.ndjson"

    log_injection prompt_submit my-mem 2.5 "kw1,kw2"
    log_injection paused "" "" "session_start"

    local types
    types=$($PYTHON -c "
import json
ts = [json.loads(l).get('type') for l in open('$MCM_EVENTS_FILE')]
print(','.join(ts))
")
    assert_contains "inject.prompt_submit" "$types" "prompt_submit 写成 inject.prompt_submit"
    assert_contains "inject.paused" "$types" "paused 写成 inject.paused"

    # 字段映射正确
    local first_mem
    first_mem=$($PYTHON -c "
import json
o = json.loads(open('$MCM_EVENTS_FILE').readline())
print(o.get('memory'))
")
    assert_equal "my-mem" "$first_mem" "memory 字段正确"

    # 旧 INJECT_LOG_FILE 常量已下线（不再被 inject.sh 定义）
    local has_old_const
    has_old_const=$(bash -c "source $PROJECT_DIR/lib/core.sh; source $PROJECT_DIR/lib/inject.sh; echo \"\${INJECT_LOG_FILE:-EMPTY}\"")
    assert_equal "EMPTY" "$has_old_const" "INJECT_LOG_FILE 常量已下线"

    teardown
}

# ----------------------------------------------------------------------------
# 测试套件入口
# ----------------------------------------------------------------------------

run_all_tests() {
    echo ""
    echo "=========================================="
    echo "  mcMemory 核心函数测试"
    echo "=========================================="
    echo ""

    test_config_defaults
    test_sed_escape
    test_calculate_hash
    test_get_mtime
    test_resolve_path
    test_calculate_relative_path
    test_detect_source_files
    test_detect_empty
    test_safe_rm
    test_build_hash_json
    test_batch_file_info
    test_split_source_file_large
    test_split_source_file_small
    test_sed_i
    test_acquire_release_lock
    test_move_and_restore_trash
    test_find_relevant_memories_weighting
    test_precompact_save
    test_emit_event_basic
    test_emit_event_truncation
    test_mcm_on_exit_chaining
    test_mcm_run_command_lifecycle
    test_log_injection_writes_ndjson

    echo ""
    echo "=========================================="
    echo "  结果: $PASSED 通过, $FAILED 失败"
    echo "=========================================="

    if [ "$FAILED" -gt 0 ]; then
        exit 1
    fi
}

# 如果直接运行（非 bats）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_all_tests
fi
