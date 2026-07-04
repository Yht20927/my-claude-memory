#!/bin/bash
# ============================================================================
# 集成测试 4: mcmExport → mcmImport 往返（v3.1 / Phase 1 补盲区）
# ============================================================================
# 验证:
#   - export 生成合法 tar.gz
#   - import 在 imported/ tag 下还原记忆
#   - 往返后 summary.md / chunk 内容一致
#   - 搜索索引含导入的 chunk
# ============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$PROJECT_DIR/lib/core.sh"

# 准备 workspace + init 记忆 + 填充 chunk 实质内容（替换占位符）
_seed_and_fill_memory() {
    local ws="$INT_FIXTURE_DIR/roundtrip-ws"
    mkdir -p "$ws"
    ( cd "$ws" && git init -q && git config user.email t@x && git config user.name t )
    cat > "$ws/CLAUDE.md" <<'EOF'
# Roundtrip Project
## Architecture
Export then import this memory.
EOF
    bash "$PROJECT_DIR/commands/init.sh" \
        --name "roundtrip-proj" \
        --tags "tools" \
        --description "export/import roundtrip fixture" \
        --workspace "$ws" > /dev/null 2>&1

    # 填充 chunk 实质内容（替换占位符），让往返有可比对的内容
    local mem_dir="$PROJECTS_DIR/tools/roundtrip-proj"
    local chunk="$mem_dir/chunks/1_CLAUDE.md"
    if [ -f "$chunk" ]; then
        cat > "$chunk" <<'EOF'
---
source_file: CLAUDE.md
last_sync: 2026-07-04T00:00:00
hash: dummyroundtrip
---

# Roundtrip Project

Unique marker: ROUNDTRIP_MARKER_42
EOF
    fi
    # 刷新搜索索引让 marker 进索引
    update_search_index "roundtrip-proj" "$mem_dir" false > /dev/null 2>&1
}

# ----------------------------------------------------------------------------
it_export_then_import_roundtrip() {
    _seed_and_fill_memory

    local mem_dir="$PROJECTS_DIR/tools/roundtrip-proj"
    assert_file_exists "$mem_dir/summary.md" "init 建记忆"
    assert_file_exists "$mem_dir/chunks/1_CLAUDE.md" "init 建 chunk"

    # export
    local archive="$INT_FIXTURE_DIR/roundtrip.tar.gz"
    bash "$PROJECT_DIR/commands/export.sh" "roundtrip-proj" --output "$archive" > /dev/null 2>&1
    local exp_exit=$?
    assert_equal "0" "$exp_exit" "export 退出码 0"
    assert_file_exists "$archive" "export 生成 tar.gz"

    # import 到 imported/ tag（import 默认 tag）
    bash "$PROJECT_DIR/commands/import.sh" "$archive" > /tmp/imp.out 2>&1
    local imp_exit=$?
    assert_equal "0" "$imp_exit" "import 退出码 0"

    local imported_dir="$PROJECTS_DIR/imported/roundtrip-proj"
    assert_file_exists "$imported_dir/summary.md" "import 还原 summary.md"
    assert_file_exists "$imported_dir/chunks/1_CLAUDE.md" "import 还原 chunk"

    # 往返内容一致
    assert_contains "ROUNDTRIP_MARKER_42" "$(cat "$imported_dir/chunks/1_CLAUDE.md" 2>/dev/null)" \
        "往返后 chunk 内容保留"
    assert_contains "export/import roundtrip fixture" "$(cat "$imported_dir/summary.md" 2>/dev/null)" \
        "往返后 summary 内容保留"

    # 搜索索引含导入的 chunk（import 调 update_search_index）
    assert_contains "ROUNDTRIP_MARKER_42" "$(cat "$SEARCH_INDEX" 2>/dev/null)" \
        "搜索索引含导入 chunk 内容"
}

# ----------------------------------------------------------------------------
IT_LIST=(
    "export → import roundtrip preserves content + updates index"  it_export_then_import_roundtrip
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run_its "mcmExport → mcmImport 往返" "${IT_LIST[@]}"
fi
