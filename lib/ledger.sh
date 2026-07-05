#!/bin/bash
# ============================================================================
# mcMemory-ledger - 会话决策日志库 (v3.6 Phase 6)
# ============================================================================
# 提供结构化、append-only、跨会话的决策/待办/阻断日志。
# 与 op-log 同构格式：## [ISO8601] type (actor)
#
# 依赖：core.sh（提供 log_memory_op / emit_event / acquire_lock / release_lock）
#       inject.sh（提供 is_inject_stopped / is_inject_paused）
# ============================================================================

# 配置（SessionStart 注入）
MCM_LEDGER_INJECT="${MCM_LEDGER_INJECT:-1}"
MCM_LEDGER_INJECT_COUNT="${MCM_LEDGER_INJECT_COUNT:-5}"
MCM_LEDGER_INJECT_TYPES="${MCM_LEDGER_INJECT_TYPES:-todo,blocker}"
MCM_LEDGER_INJECT_SINCE_DAYS="${MCM_LEDGER_INJECT_SINCE_DAYS:-14}"

VALID_LEDGER_TYPES="decision blocker todo learning done note"

# ----------------------------------------------------------------------------
# ledger_path <memory_dir>
# ----------------------------------------------------------------------------
ledger_path() {
    local mem_dir="$1"
    echo "${mem_dir}/ledger.md"
}

# ----------------------------------------------------------------------------
# ledger_add <memory_dir> <type> <text> [actor] [context] [refs]
#   追加条目到 ledger.md，echo 生成的条目 ID（ISO8601 时间戳）。
#   文件不存在则创建 # 决策日志 头。
# ----------------------------------------------------------------------------
ledger_add() {
    local mem_dir="$1"
    local type="$2"
    local text="$3"
    local actor="${4:-user}"
    local context="${5:-}"
    local refs="${6:-}"
    local resolves="${7:-}"

    local ledger_file
    ledger_file=$(ledger_path "$mem_dir")

    # 若文件不存在，创建头部
    if [ ! -f "$ledger_file" ]; then
        {
            echo "# 决策日志"
            echo ""
        } > "$ledger_file"
    fi

    # 生成 ISO8601 时间戳；冲突则 _2/_3
    local ts id
    ts=$(date '+%Y-%m-%dT%H:%M:%S')
    id="$ts"
    local i=2
    while grep -qF "## [$id]" "$ledger_file" 2>/dev/null; do
        id="${ts}_${i}"
        i=$((i + 1))
    done

    # 默认 status：todo/blocker 为 open，其余不设
    local status_line=""
    case "$type" in
        todo|blocker) status_line="status: open" ;;
    esac

    {
        echo "## [$id] $type ($actor)"
        echo "$text"
        [ -n "$context" ] && { echo "context: $context"; }
        [ -n "$status_line" ] && echo "$status_line"
        [ -n "$refs" ] && echo "refs: $refs"
        [ -n "$resolves" ] && echo "resolves: $resolves"
        echo ""
    } >> "$ledger_file"

    echo "$id"
}

# ----------------------------------------------------------------------------
# ledger_parse <ledger_file>
#   Python 解析 ledger.md → JSON 数组
#   每个元素: {id, type, actor, summary, status, context, refs, resolves, ts_raw}
# ----------------------------------------------------------------------------
ledger_parse() {
    local ledger_file="$1"
    if [ ! -f "$ledger_file" ] || [ ! -s "$ledger_file" ]; then
        echo "[]"
        return
    fi

    $PYTHON - "$ledger_file" <<'PY' 2>/dev/null
import re, sys, json

ledger_file = sys.argv[1]
header_re = re.compile(r'^## \[(.+?)\]\s+(\w+)\s+\((\w+)\)\s*$')

entries = []
with open(ledger_file, 'r', errors='replace') as f:
    cur = None
    for raw in f:
        line = raw.rstrip('\n')
        m = header_re.match(line)
        if m:
            if cur:
                entries.append(cur)
            cur = {
                'id': m.group(1),
                'type': m.group(2),
                'actor': m.group(3),
                'summary': '',
                'status': '',
                'context': '',
                'refs': '',
                'resolves': '',
                'ts_raw': m.group(1),
            }
            # 下一行是摘要（正文第一行）
            nxt = f.readline()
            if nxt:
                cur['summary'] = nxt.rstrip('\n').strip()
            continue

        if cur is None:
            continue

        if line.startswith('status:'):
            cur['status'] = line.split(':', 1)[1].strip()
        elif line.startswith('context:'):
            # context 可跟多行缩进（直到空行或下一字段）
            ctx = line.split(':', 1)[1].strip()
            # 读后续缩进行
            while True:
                pos = f.tell()
                nxt = f.readline()
                if not nxt:
                    break
                nxt = nxt.rstrip('\n')
                if nxt.startswith('  ') or nxt.startswith('\t'):
                    ctx += '\n' + nxt.strip()
                elif nxt == '':
                    break
                else:
                    # 回退
                    f.seek(pos)
                    break
            cur['context'] = ctx
        elif line.startswith('refs:'):
            cur['refs'] = line.split(':', 1)[1].strip()
        elif line.startswith('resolves:'):
            cur['resolves'] = line.split(':', 1)[1].strip()

    if cur:
        entries.append(cur)

print(json.dumps(entries, ensure_ascii=False))
PY
}

# ----------------------------------------------------------------------------
# ledger_open_entries <ledger_file>
#   event-sourcing 计算 open 集合：
#   open = (type=todo|blocker 且 status=open 的条目) − (被 resolves 引用的条目)
#   输出 JSON 数组（仅含 id/type/actor/summary/status/ts_raw）
# ----------------------------------------------------------------------------
ledger_open_entries() {
    local ledger_file="$1"
    if [ ! -f "$ledger_file" ] || [ ! -s "$ledger_file" ]; then
        echo "[]"
        return
    fi

    $PYTHON - "$ledger_file" <<'PY' 2>/dev/null
import re, sys, json

ledger_file = sys.argv[1]
header_re = re.compile(r'^## \[(.+?)\]\s+(\w+)\s+\((\w+)\)\s*$')

entries = []
resolved_ids = set()
with open(ledger_file, 'r', errors='replace') as f:
    cur = None
    for raw in f:
        line = raw.rstrip('\n')
        m = header_re.match(line)
        if m:
            if cur:
                entries.append(cur)
            cur = {
                'id': m.group(1),
                'type': m.group(2),
                'actor': m.group(3),
                'summary': '',
                'status': '',
                'resolves': '',
                'ts_raw': m.group(1),
            }
            nxt = f.readline()
            if nxt:
                cur['summary'] = nxt.rstrip('\n').strip()
            continue

        if cur is None:
            continue

        if line.startswith('status:'):
            cur['status'] = line.split(':', 1)[1].strip()
        elif line.startswith('resolves:'):
            cur['resolves'] = line.split(':', 1)[1].strip()
            resolved_ids.add(cur['resolves'])

    if cur:
        entries.append(cur)

# open 集合：todo/blocker 且 status=open 且未被 resolves 引用
open_entries = []
for e in entries:
    if e['type'] in ('todo', 'blocker') and e['status'] == 'open' and e['id'] not in resolved_ids:
        open_entries.append({
            'id': e['id'],
            'type': e['type'],
            'actor': e['actor'],
            'summary': e['summary'],
            'status': e['status'],
            'ts_raw': e['ts_raw'],
        })

print(json.dumps(open_entries, ensure_ascii=False))
PY
}

# ----------------------------------------------------------------------------
# ledger_list <ledger_file> [opts...]
#   opts 通过环境变量传递：
#     LEDGER_FILTER_TYPE   — 逗号分隔 type
#     LEDGER_FILTER_STATUS — open / resolved / superseded
#     LEDGER_FILTER_SINCE  — N 天前整数
#     LEDGER_FILTER_LIMIT  — 最多返回 N 条
#     LEDGER_FORMAT_JSON   — 1 则输出 JSON，否则表格
# ----------------------------------------------------------------------------
ledger_list() {
    local ledger_file="$1"

    local filter_type="${LEDGER_FILTER_TYPE:-}"
    local filter_status="${LEDGER_FILTER_STATUS:-}"
    local filter_since="${LEDGER_FILTER_SINCE:-}"
    local filter_limit="${LEDGER_FILTER_LIMIT:-}"
    local format_json="${LEDGER_FORMAT_JSON:-0}"

    local raw_json
    raw_json=$(ledger_parse "$ledger_file")

    # 计算 open 集合（用于 --status open）
    local open_json
    open_json=$(ledger_open_entries "$ledger_file")

    # Python 过滤 + 格式化
    $PYTHON - "$raw_json" "$open_json" "$filter_type" "$filter_status" "$filter_since" "$filter_limit" "$format_json" <<'PY' 2>/dev/null
import json, sys, re
from datetime import datetime, timedelta

entries = json.loads(sys.argv[1])
open_entries = json.loads(sys.argv[2])
filter_type = sys.argv[3]
filter_status = sys.argv[4]
filter_since = sys.argv[5]
filter_limit = sys.argv[6]
format_json = sys.argv[7] == '1'

open_ids = {e['id'] for e in open_entries}

# 构建 type 白名单
type_set = set()
if filter_type:
    type_set = {t.strip() for t in filter_type.split(',') if t.strip()}

# 过滤
result = []
for e in entries:
    if type_set and e['type'] not in type_set:
        continue
    if filter_status:
        # --status open 用 event-sourcing 计算（而非 status 字段字面）
        if filter_status == 'open':
            if e['id'] not in open_ids:
                continue
        else:
            if e.get('status') != filter_status:
                continue
    if filter_since:
        try:
            days = int(filter_since)
            # 从 id（时间戳）解析日期
            ts_str = e['id'].split('_')[0]  # 去掉可能的 _2 后缀
            cutoff = datetime.now() - timedelta(days=days)
            # 尝试 ISO8601 解析
            try:
                dt = datetime.strptime(ts_str, '%Y-%m-%dT%H:%M:%S')
            except ValueError:
                try:
                    dt = datetime.strptime(ts_str[:10], '%Y-%m-%d')
                except ValueError:
                    continue
            if dt < cutoff:
                continue
        except Exception:
            pass
    result.append(e)

# limit（取最近 N 条，列表已是时间序=追加序）
if filter_limit:
    try:
        limit = int(filter_limit)
        result = result[-limit:]
    except Exception:
        pass

if format_json:
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)

# 文本表格
count_open = len(open_ids)
mem_name = ''  # 调用方在输出前打印记忆名
total = len(entries)
print(f"## ledger: {total} 条, {count_open} open")
print("")
print("| 时间 | 类型 | 状态 | 摘要 |")
print("|------|------|------|------|")
for e in result:
    ts_disp = e['id'][:16]  # YYYY-MM-DDTHH:MM
    st = e.get('status', '')
    if e['id'] in open_ids:
        st = 'open'
    elif e['type'] == 'done':
        st = '—'
    elif not st:
        st = '—'
    summary = e.get('summary', '')
    if len(summary) > 60:
        summary = summary[:57] + '...'
    print(f"| {ts_disp} | {e['type']} | {st} | {summary} |")
PY
}

# ----------------------------------------------------------------------------
# ledger_resolve <ledger_file> <id> [note]
#   追加 done 条目，带 resolves: <id>
#   echo 新条目 ID
# ----------------------------------------------------------------------------
ledger_resolve() {
    local mem_dir="$1"
    local target_id="$2"
    local note="${3:-已完成}"
    local actor="${4:-user}"

    local ledger_file
    ledger_file=$(ledger_path "$mem_dir")

    # 校验 id 存在
    if [ ! -f "$ledger_file" ] || ! grep -qF "## [$target_id]" "$ledger_file"; then
        echo "错误: 未找到条目 ID: $target_id" >&2
        return 1
    fi

    local new_id
    new_id=$(ledger_add "$mem_dir" "done" "$note" "$actor" "" "" "$target_id")
    echo "$new_id"
}

# ----------------------------------------------------------------------------
# ledger_show <ledger_file> <id>
#   打印单条目全文
# ----------------------------------------------------------------------------
ledger_show() {
    local ledger_file="$1"
    local target_id="$2"

    if [ ! -f "$ledger_file" ]; then
        echo "（无决策日志）"
        return 0
    fi

    $PYTHON - "$ledger_file" "$target_id" <<'PY' 2>/dev/null
import re, sys

ledger_file = sys.argv[1]
target_id = sys.argv[2]
header_re = re.compile(r'^## \[(.+?)\]\s+(\w+)\s+\((\w+)\)\s*$')

with open(ledger_file, 'r', errors='replace') as f:
    lines = f.readlines()

found = False
out = []
for raw in lines:
    line = raw.rstrip('\n')
    m = header_re.match(line)
    if m:
        if found:
            break
        if m.group(1) == target_id:
            found = True
            out.append(line)
            continue
    if found:
        out.append(line)

if found:
    print('\n'.join(out).strip())
else:
    print(f'错误: 未找到条目 ID: {target_id}')
    sys.exit(1)
PY
}

# ----------------------------------------------------------------------------
# ledger_entries_for_inject <memory_dir>
#   SessionStart 注入用：读取 MCM_LEDGER_INJECT_* 配置，
#   返回格式化的 open 条目列表（markdown 引用块）
# ----------------------------------------------------------------------------
ledger_entries_for_inject() {
    local mem_dir="$1"
    local ledger_file
    ledger_file=$(ledger_path "$mem_dir")

    if [ ! -f "$ledger_file" ]; then
        return
    fi

    local count="${MCM_LEDGER_INJECT_COUNT:-5}"
    local types="${MCM_LEDGER_INJECT_TYPES:-todo,blocker}"
    local since_days="${MCM_LEDGER_INJECT_SINCE_DAYS:-14}"

    local open_json
    open_json=$(ledger_open_entries "$ledger_file")

    $PYTHON - "$open_json" "$count" "$types" "$since_days" <<'PY' 2>/dev/null
import json, sys
from datetime import datetime, timedelta

entries = json.loads(sys.argv[1])
count = int(sys.argv[2])
types = [t.strip() for t in sys.argv[3].split(',') if t.strip()]
since_days = int(sys.argv[4])

cutoff = datetime.now() - timedelta(days=since_days)

filtered = []
for e in entries:
    if types and e['type'] not in types:
        continue
    ts_str = e['id'].split('_')[0]
    try:
        dt = datetime.strptime(ts_str, '%Y-%m-%dT%H:%M:%S')
    except ValueError:
        continue
    if dt < cutoff:
        continue
    filtered.append(e)

# 按时间倒序（最近优先），截前 count
filtered = list(reversed(filtered))[:count]

if not filtered:
    sys.exit(0)

print("<!-- mcMemory ledger: open items -->")
print(f"> **未竟事项**（{len(filtered)} open, 最近 {since_days} 天）:")
for e in filtered:
    ts_disp = e['id'][:10]  # YYYY-MM-DD
    print(f"> - [{e['type']}] {ts_disp} {e['summary']}")
print("<!-- /mcMemory ledger -->")
PY
}

# ----------------------------------------------------------------------------
# _ledger_inject_block <memory_dir>
#   供 inject.sh session_start_inject 调用，返回字符串或空
# ----------------------------------------------------------------------------
_ledger_inject_block() {
    local mem_dir="$1"
    local out
    out=$(ledger_entries_for_inject "$mem_dir")
    [ -n "$out" ] && printf '%s\n' "$out"
}
