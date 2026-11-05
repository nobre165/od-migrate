#!/usr/bin/env bats
# Tests for od-migrate.sh — plan / mkdirs / copy / verify.
# free / status call powershell.exe and are only testable on Windows + WSL;
# here we only assert they fail cleanly when powershell.exe is absent.
#
# Run: bats tests/

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../od-migrate.sh"

setup() {
    TMP="$(mktemp -d)"
    SRC="$TMP/src"; DST="$TMP/dst"; PLAN="$TMP/plan"
    mkdir -p "$SRC/dir a/sub" "$SRC/dir b" "$DST"
    head -c 3M /dev/urandom > "$SRC/dir a/f1 with space.bin"
    head -c 2M /dev/urandom > "$SRC/dir a/sub/f2.bin"
    head -c 5M /dev/urandom > "$SRC/dir b/big.bin"
    head -c 1M /dev/urandom > "$SRC/dir b/bad:name.bin"
    head -c 100K /dev/urandom > "$SRC/dir b/CON.txt"
    echo hi > "$SRC/root.txt"
}

teardown() { rm -rf "$TMP"; }

@test "no args prints usage and exits 1" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Subcommands:"* ]]
}

@test "--help prints usage to stdout and exits 0" {
    run --separate-stderr "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"*"Subcommands:"* ]]
    [[ "$output" == *"plan "*"mkdirs "*"copy "*"verify "*"free "*"status "* ]]
    [ -z "$stderr" ]
}

@test "subcommand with missing args prints usage to stderr and exits 1" {
    run --separate-stderr "$SCRIPT" copy
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Usage:"* ]]
}

@test "unknown subcommand fails" {
    run "$SCRIPT" bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown subcommand"* ]]
}

@test "plan packs files by size and skips invalid OneDrive names" {
    run "$SCRIPT" plan "$SRC" 4M "$PLAN"
    [ "$status" -eq 0 ]
    [ -f "$PLAN/plan.conf" ]
    [ -f "$PLAN/plan-summary.txt" ]
    # 4 valid files, 2 invalid, 1 oversize (big.bin > 4M)
    [[ "$output" == *"4 planned, 2 skipped"*"1 oversize"* ]]
    # invalid report names both offending files with a reason
    grep -q $'reserved-name;\t' "$PLAN/invalid-names.tsv"
    grep -q $'forbidden-char;\t' "$PLAN/invalid-names.tsv"
    grep -q 'CON.txt' "$PLAN/invalid-names.tsv"
    grep -q 'bad:name.bin' "$PLAN/invalid-names.tsv"
    # every batch has a .bytes sidecar and no batch exceeds the limit
    for b in "$PLAN"/batch-*.txt; do
        [ -f "${b%.txt}.bytes" ]
        bytes="$(<"${b%.txt}.bytes")"
        # oversize file is allowed to exceed, but only when alone in its batch
        if (( bytes > 4194304 )); then
            [ "$(tr -cd '\0' < "$b" | wc -c)" -eq 1 ]
        fi
    done
    # batch lists are NUL-separated and relative to source
    tr '\0' '\n' < "$PLAN/batch-0001.txt" | grep -q '^dir a/f1 with space.bin$'
}

@test "plan records absolute source in plan.conf" {
    "$SCRIPT" plan "$SRC" 10M "$PLAN"
    # shellcheck disable=SC1090
    source "$PLAN/plan.conf"
    [ "$SOURCE" = "$(readlink -f "$SRC")" ]
}

@test "plan rejects unparsable size" {
    run "$SCRIPT" plan "$SRC" lots "$PLAN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot parse size"* ]]
}

@test "mkdirs replicates directory tree without files" {
    run "$SCRIPT" mkdirs "$SRC" "$DST"
    [ "$status" -eq 0 ]
    [ -d "$DST/dir a/sub" ]
    [ -d "$DST/dir b" ]
    [ "$(find "$DST" -type f | wc -l)" -eq 0 ]
}

@test "copy transfers one batch and is idempotent" {
    "$SCRIPT" plan "$SRC" 4M "$PLAN"
    run "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST"
    [ "$status" -eq 0 ]
    [ -f "$DST/dir a/f1 with space.bin" ]
    cmp -s "$SRC/dir a/f1 with space.bin" "$DST/dir a/f1 with space.bin"
    [ -f "$PLAN/batch-0001.log" ]
    # files from other batches are not copied
    [ ! -e "$DST/dir b/big.bin" ]
    # second run transfers (almost) nothing: rsync reports a large speedup
    run "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST"
    [ "$status" -eq 0 ]
    [[ "$output" == *"speedup is "* ]]
    speedup="$(printf '%s' "$output" | sed -n 's/.*speedup is \([0-9,]*\).*/\1/p' | tr -d , | tail -1)"
    [ "$speedup" -gt 100 ]
}

@test "copy accepts --source override when plan.conf is absent" {
    "$SCRIPT" plan "$SRC" 1T "$PLAN"   # everything in one batch
    rm "$PLAN/plan.conf"
    run "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plan.conf not found"* ]]
    run "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST" --source "$SRC"
    [ "$status" -eq 0 ]
    [ -f "$DST/root.txt" ]
}

@test "copy accepts --source before the positional arguments" {
    "$SCRIPT" plan "$SRC" 1T "$PLAN"
    rm "$PLAN/plan.conf"
    run "$SCRIPT" copy --source "$SRC" "$PLAN/batch-0001.txt" "$DST"
    [ "$status" -eq 0 ]
    [ -f "$DST/root.txt" ]
}

@test "copy rejects --source without a value and unknown options" {
    "$SCRIPT" plan "$SRC" 1T "$PLAN"
    run --separate-stderr "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST" --source
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"requires an argument"*"Usage:"* ]]
    run --separate-stderr "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST" --bogus
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"unrecognized option"*"Usage:"* ]]
    run "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST" extra
    [ "$status" -eq 1 ]
}

@test "unknown global option prints usage and exits 1" {
    run --separate-stderr "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"unrecognized option"*"Usage:"* ]]
    run "$SCRIPT" -h
    [ "$status" -eq 0 ]
    run "$SCRIPT" help
    [ "$status" -eq 0 ]
}

@test "verify reports pending files and clean batches" {
    "$SCRIPT" plan "$SRC" 4M "$PLAN"
    run "$SCRIPT" verify "$PLAN/batch-0001.txt" "$DST"
    [ "$status" -eq 0 ]
    [[ "$output" == *">f+++++++++ dir a/f1 with space.bin"* ]]
    "$SCRIPT" copy "$PLAN/batch-0001.txt" "$DST"
    run "$SCRIPT" verify "$PLAN/batch-0001.txt" "$DST"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing pending"* ]]
}

@test "all batches together reproduce every valid file" {
    "$SCRIPT" plan "$SRC" 4M "$PLAN"
    "$SCRIPT" mkdirs "$SRC" "$DST"
    for b in "$PLAN"/batch-*.txt; do "$SCRIPT" copy "$b" "$DST"; done
    expected="$(cd "$SRC" && find . -type f | grep -v 'bad:name\|CON.txt' | sort)"
    actual="$(cd "$DST" && find . -type f | sort)"
    [ "$expected" = "$actual" ]
}

@test "free and status fail cleanly without powershell.exe" {
    if command -v powershell.exe >/dev/null 2>&1; then skip "running under WSL"; fi
    run "$SCRIPT" free "$DST"
    [ "$status" -eq 1 ]
    [[ "$output" == *"powershell.exe"* ]]
    run "$SCRIPT" status "$DST"
    [ "$status" -eq 1 ]
}
