#!/usr/bin/env bash
# Tests/run_tests.sh — Integration test suite for the `versions` CLI
#
# Usage:
#   bash Tests/run_tests.sh
#
# The binary is located automatically. If not found, versions.swift is compiled.
# Each test is deterministic: temp files are isolated and cleaned up on exit.

set -uo pipefail
# NOTE: -e is intentionally absent — we capture non-zero exits as test results.

# ─── Color output ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; BOLD=''; NC=''
fi

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0

# ─── Scratch space ────────────────────────────────────────────────────────────
SCRATCH=$(mktemp -d)

# Indexed array of registered temp files (bash 3.2 compatible)
REGISTERED_FILE_COUNT=0

# ─── Binary detection ─────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_binary() {
    if [[ -x "$PROJECT_DIR/versions" ]]; then
        echo "$PROJECT_DIR/versions"; return
    fi
    if [[ -x "./versions" ]]; then
        echo "./versions"; return
    fi
    if command -v versions &>/dev/null; then
        command -v versions; return
    fi
    if [[ -f "$PROJECT_DIR/versions.swift" ]]; then
        echo "versions binary not found — compiling versions.swift..." >&2
        swiftc "$PROJECT_DIR/versions.swift" -O -o "$PROJECT_DIR/versions" >&2
        echo "$PROJECT_DIR/versions"; return
    fi
    echo "Error: cannot find 'versions' binary. Compile with: swiftc versions.swift -O -o versions" >&2
    exit 1
}

VERSIONS=$(find_binary)
echo -e "${BOLD}Binary: $VERSIONS${NC}"
echo ""

# ─── Temp file management ─────────────────────────────────────────────────────
# Each test file is registered so cleanup() can nuke its NSFileVersion history.
# Calling --deleteAll on a fresh mktemp file (no versions) is always safe.

new_temp_file() {
    local f
    f=$(mktemp)
    # Clear any leftover NSFileVersion state from a previously crashed run
    "$VERSIONS" --deleteAll "$f" &>/dev/null || true
    # Store in indexed variables for bash 3.2 compat (avoids set -u + empty array issues)
    eval "REGISTERED_FILE_$REGISTERED_FILE_COUNT=\"\$f\""
    REGISTERED_FILE_COUNT=$((REGISTERED_FILE_COUNT + 1))
    echo "$f"
}

cleanup() {
    local i f
    for ((i = 0; i < REGISTERED_FILE_COUNT; i++)); do
        eval "f=\"\${REGISTERED_FILE_$i}\""
        if [[ -f "$f" ]]; then
            "$VERSIONS" --deleteAll "$f" &>/dev/null || true
            rm -f "$f"
        fi
    done
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# ─── Test helpers ─────────────────────────────────────────────────────────────

_record_result() {
    local desc="$1" passed="$2" reason="$3"
    if [[ "$passed" == "true" ]]; then
        echo -e "  ${GREEN}PASS${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $desc"
        [[ -n "$reason" ]] && echo "       └─ $reason"
        FAIL=$((FAIL + 1))
    fi
}

# run_test DESC EXPECTED_EXIT STDOUT_PATTERN STDERR_PATTERN [versions args...]
#
# STDOUT_PATTERN / STDERR_PATTERN: ERE regex for `grep -qE`, or "" to skip check.
# Stdout and stderr are captured separately; exit code is checked independently.
run_test() {
    local desc="$1" expected_exit="$2" stdout_pat="$3" stderr_pat="$4"
    shift 4

    local actual_stdout actual_exit actual_stderr
    local passed=true reason="" preview

    actual_stdout=$("$VERSIONS" "$@" 2>"$SCRATCH/stderr")
    actual_exit=$?
    actual_stderr=$(<"$SCRATCH/stderr")

    if [[ "$actual_exit" != "$expected_exit" ]]; then
        passed=false
        reason="exit: got $actual_exit, want $expected_exit"
    fi

    if [[ -n "$stdout_pat" ]] && ! printf '%s' "$actual_stdout" | grep -qE -e "$stdout_pat"; then
        passed=false
        preview=$(printf '%s' "$actual_stdout" | head -3 | tr '\n' '|')
        reason="${reason:+$reason | }stdout «${preview:-<empty>}» ∌ /$stdout_pat/"
    fi

    if [[ -n "$stderr_pat" ]] && ! printf '%s' "$actual_stderr" | grep -qE -e "$stderr_pat"; then
        passed=false
        preview=$(printf '%s' "$actual_stderr" | head -3 | tr '\n' '|')
        reason="${reason:+$reason | }stderr «${preview:-<empty>}» ∌ /$stderr_pat/"
    fi

    _record_result "$desc" "$passed" "$reason"
}

# run_hook_test DESC EXPECTED_EXIT STDOUT_PATTERN STDERR_PATTERN STDIN_CONTENT
#
# Pipes STDIN_CONTENT to `versions --hook` and checks results.
run_hook_test() {
    local desc="$1" expected_exit="$2" stdout_pat="$3" stderr_pat="$4" stdin_content="$5"

    local actual_stdout actual_exit actual_stderr
    local passed=true reason="" preview

    actual_stdout=$(printf '%s' "$stdin_content" | "$VERSIONS" --hook 2>"$SCRATCH/stderr")
    actual_exit=$?
    actual_stderr=$(<"$SCRATCH/stderr")

    if [[ "$actual_exit" != "$expected_exit" ]]; then
        passed=false
        reason="exit: got $actual_exit, want $expected_exit"
    fi

    if [[ -n "$stdout_pat" ]] && ! printf '%s' "$actual_stdout" | grep -qE -e "$stdout_pat"; then
        passed=false
        preview=$(printf '%s' "$actual_stdout" | head -3 | tr '\n' '|')
        reason="${reason:+$reason | }stdout «${preview:-<empty>}» ∌ /$stdout_pat/"
    fi

    if [[ -n "$stderr_pat" ]] && ! printf '%s' "$actual_stderr" | grep -qE -e "$stderr_pat"; then
        passed=false
        preview=$(printf '%s' "$actual_stderr" | head -3 | tr '\n' '|')
        reason="${reason:+$reason | }stderr «${preview:-<empty>}» ∌ /$stderr_pat/"
    fi

    _record_result "$desc" "$passed" "$reason"
}

# ─────────────────────────────────────────────────────────────────────────────
# Group 1: Usage / help
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}Group 1: Usage / help${NC}"

run_test "no args prints usage"    0 "Usage:" ""
run_test "--help prints usage"     0 "Usage:" "" --help
run_test "-h prints usage"         0 "Usage:" "" -h

# ─────────────────────────────────────────────────────────────────────────────
# Group 2: Missing required argument errors
#
# Key source detail: --save and --deleteAll use hardcoded strings in
# exitWithError(), so "-s" still produces "Error: --save requires...".
# ID-requiring flags use the runtime `flag` variable, so "-v" → "-v requires...".
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 2: Missing argument errors${NC}"

run_test "--save no file → error"         1 "" "--save requires"         --save
run_test "-s no file → error"             1 "" "--save requires"         -s    # hardcoded msg
run_test "--deleteAll no file → error"    1 "" "--deleteAll requires"    --deleteAll
run_test "--view no id → error"           1 "" "--view requires"         --view
run_test "--view id, no file → error"     1 "" "--view requires a file"  --view 1
run_test "--restore no id → error"        1 "" "--restore requires"      --restore
# --restore with valid id + file but no dest: caught inside the switch,
# before cmdRestore() runs, so any path works (file-existence not checked yet).
run_test "--restore no dest → error"      1 "" "requires a destination"  --restore 1 /any/path
run_test "-l no file → error"             1 "" "--list requires"         -l    # hardcoded msg

# ─────────────────────────────────────────────────────────────────────────────
# Group 3: File not found
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 3: File not found${NC}"

NE="/tmp/nonexistent_versions_$$"
run_test "list nonexistent → error"        1 "" "File not found" "$NE"
run_test "--save nonexistent → error"      1 "" "File not found" --save "$NE"
run_test "--deleteAll nonexistent → error" 1 "" "File not found" --deleteAll "$NE"
run_test "--view 0 nonexistent → error"    1 "" "File not found" --view 0 "$NE"
run_test "--delete 1 nonexistent → error"  1 "" "File not found" --delete 1 "$NE"

# ─────────────────────────────────────────────────────────────────────────────
# Group 4: Bad ID format
#
# ID validation fires before file-existence checks, so any path works here.
# Int("-1") = -1, which fails the `id >= 0` guard → same error as non-integer.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 4: Bad ID format${NC}"

run_test "--view abc → error"     1 "" "requires a non-negative integer" --view abc /any
run_test "--view -1 → error"      1 "" "requires a non-negative integer" --view -1 /any
run_test "--delete foo → error"   1 "" "requires a non-negative integer" --delete foo /any
run_test "--restore bar → error"  1 "" "requires a non-negative integer" --restore bar /any
run_test "--replace baz → error"  1 "" "requires a non-negative integer" --replace baz /any

# ─────────────────────────────────────────────────────────────────────────────
# Groups 5–8: Stateful workflow (one shared file; state accumulates)
#
# Version ID scheme after two saves:
#   otherVersions() sorts oldest-first → others[0]=oldest, others[1]=newest
#   versionForID(id): index = others.count - id
#     id=1 → index=1 → newest save  ("version two content")
#     id=2 → index=0 → oldest save  ("version one content")
#     id=0 → reads current file directly (no NSFileVersion needed)
# ─────────────────────────────────────────────────────────────────────────────
WF_FILE=$(new_temp_file)
RESTORE_DEST=$(new_temp_file)

echo ""
echo -e "${BOLD}Group 5: Save + list${NC}"

printf 'version one content\n' > "$WF_FILE"
run_test "save v1 succeeds"               0 "Saved new version"  "" --save "$WF_FILE"
run_test "list after 1 save shows [  1]"  0 '\[  1\]'           "" "$WF_FILE"

printf 'version two content\n' > "$WF_FILE"
run_test "save v2 succeeds"               0 "Saved new version"  "" --save "$WF_FILE"
run_test "list after 2 saves shows [  2]" 0 '\[  2\]'           "" "$WF_FILE"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 6: View${NC}"

# id=0: reads WF_FILE directly from disk (current = "version two content")
run_test "view 0 (current file)"          0 "version two content" "" --view 0 "$WF_FILE"
# id=1: newest save = "version two content"
run_test "view 1 (newest save)"           0 "version two content" "" --view 1 "$WF_FILE"
# id=2: oldest save = "version one content"
run_test "view 2 (oldest save)"           0 "version one content" "" --view 2 "$WF_FILE"
run_test "view out-of-range id → error"   1 "" "No version with identifier 99" --view 99 "$WF_FILE"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 7: Restore${NC}"

# Restore id=2 (oldest: "version one content") to RESTORE_DEST; WF_FILE unchanged
run_test "restore v2 to dest"             0 "Successfully restored" "" --restore 2 "$WF_FILE" "$RESTORE_DEST"
# --view 0 reads RESTORE_DEST directly (no saved versions needed)
run_test "restored file has v1 content"   0 "version one content"  "" --view 0 "$RESTORE_DEST"
# WF_FILE history is still intact
run_test "history intact after restore"   0 '\[  2\]'              "" "$WF_FILE"
run_test "restore invalid id → error"     1 "" "No version with identifier 99" --restore 99 "$WF_FILE" "$RESTORE_DEST"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 8: Replace${NC}"

# Replace WF_FILE with id=2 (oldest: "version one content")
run_test "replace v2 succeeds"            0 "Successfully replaced"  "" --replace 2 "$WF_FILE"
# WF_FILE on disk now contains "version one content"
run_test "file content after replace"     0 "version one content"    "" --view 0 "$WF_FILE"
run_test "replace invalid id → error"     1 "" "No version with identifier 99" --replace 99 "$WF_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Group 9: Delete one version
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 9: Delete one version${NC}"

DEL_FILE=$(new_temp_file)
printf 'delete test\n' > "$DEL_FILE"
"$VERSIONS" --save "$DEL_FILE" > /dev/null   # save 1 (becomes id=2 after next save)
"$VERSIONS" --save "$DEL_FILE" > /dev/null   # save 2 → now id=1 (newest), id=2 (oldest)

run_test "delete id=1 (newest save)"      0 "Successfully deleted version 1" "" --delete 1 "$DEL_FILE"
# After deletion, the remaining version is renumbered to id=1
run_test "after delete, one version left" 0 '\[  1\]'  "" "$DEL_FILE"
run_test "delete invalid id → error"      1 "" "No version with identifier 99" --delete 99 "$DEL_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Group 10: Delete all versions
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 10: Delete all versions${NC}"

DA_FILE=$(new_temp_file)
printf 'deleteall test\n' > "$DA_FILE"
"$VERSIONS" --save "$DA_FILE" > /dev/null   # save 1
"$VERSIONS" --save "$DA_FILE" > /dev/null   # save 2

run_test "deleteAll succeeds"             0 "Successfully deleted all" "" --deleteAll "$DA_FILE"
run_test "after deleteAll, no versions"   0 "No saved versions found"  "" "$DA_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Group 11: Hook mode
#
# --hook reads Claude Code PreToolUse JSON from stdin. It always exits 0
# (never blocks Claude), printing only to stderr on success.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Group 11: Hook mode${NC}"

# Invalid JSON → exits 0 cleanly, no output
run_hook_test "hook: invalid JSON → exit 0 silently" \
    0 "" "" \
    "not json at all"

# Valid JSON but missing tool_input → exits 0 silently
run_hook_test "hook: no tool_input key → exit 0 silently" \
    0 "" "" \
    '{"tool_name": "Write"}'

# Valid JSON with tool_input but no file_path → exits 0 silently
run_hook_test "hook: no file_path → exit 0 silently" \
    0 "" "" \
    '{"tool_input": {"content": "hello"}}'

# Valid JSON with file_path pointing to non-existent file → exit 0 (new file, nothing to version)
run_hook_test "hook: nonexistent file_path → exit 0 silently" \
    0 "" "" \
    "{\"tool_input\": {\"file_path\": \"/tmp/nonexistent_hook_$$\"}}"

# Valid JSON with file_path for a real file → saves version, prints to stderr
HOOK_FILE=$(new_temp_file)
printf 'hook content\n' > "$HOOK_FILE"
run_hook_test "hook: real file → saves version (stderr)" \
    0 "" "Saved version of" \
    "{\"tool_input\": {\"file_path\": \"$HOOK_FILE\"}}"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $TOTAL tests passed.${NC}"
else
    echo -e "${RED}${BOLD}$FAIL of $TOTAL tests FAILED.${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit code reflects pass/fail for CI
[[ $FAIL -eq 0 ]]
