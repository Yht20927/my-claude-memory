#!/bin/bash
# ============================================================================
# mcMemory 全量测试入口（unit + integration）
# ============================================================================
# 用法: bash tests/run_all.sh
# 退出码: 任一测试套件失败则非 0
# ============================================================================

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

declare -i TOTAL_FAILED=0

run_suite() {
    local name="$1"
    local script="$2"
    echo ""
    echo -e "${BLUE}>>> $name${NC}"
    if bash "$script"; then
        :
    else
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        echo -e "${RED}!!! 套件失败: $name${NC}"
    fi
}

run_suite "Unit tests"              "$TEST_DIR/test_core.sh"
run_suite "Integration: hook e2e"   "$TEST_DIR/integration/test_hook_e2e.sh"
run_suite "Integration: sync"       "$TEST_DIR/integration/test_sync_idempotent.sh"
run_suite "Integration: concurrent" "$TEST_DIR/integration/test_concurrent.sh"
run_suite "Integration: export/import" "$TEST_DIR/integration/test_export_import.sh"
run_suite "Integration: phase2 observability" "$TEST_DIR/integration/test_phase2.sh"
run_suite "Integration: phase3 scoring+evidence" "$TEST_DIR/integration/test_phase3.sh"

echo ""
echo "=========================================="
if [ "$TOTAL_FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ 全部测试通过${NC}"
    exit 0
else
    echo -e "${RED}✗ $TOTAL_FAILED 个测试套件失败${NC}"
    exit 1
fi
