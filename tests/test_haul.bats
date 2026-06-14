#!/usr/bin/env bats
# tests/test_haul.bats — bats-core tests for haul.sh

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/haul.sh"

setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/src/sub"
    printf 'hello\n'  > "$TMP/src/a.txt"
    printf 'nested\n' > "$TMP/src/sub/b.txt"
    printf 'hidden\n' > "$TMP/src/.hidden"
}

teardown() {
    rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "missing --source: error message and exit 1" {
    run bash "$SCRIPT" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"-s/--source"* ]]
}

@test "missing --destination: error message and exit 1" {
    run bash "$SCRIPT" -s "$TMP/src" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"-d/--destination"* ]]
}

@test "positional arguments rejected with helpful error" {
    run bash "$SCRIPT" "$TMP/src" "$TMP/dst" 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"unexpected argument"* ]]
}

@test "nonexistent source directory exits 1" {
    run bash "$SCRIPT" -s "$TMP/no_such_dir" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Fresh copy
# ---------------------------------------------------------------------------

@test "fresh copy: 3 elements copied, 0 skipped, exit 0" {
    run bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 element(s) copied, 0 skipped"* ]]
}

@test "fresh copy: destination directory is created" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    [ -d "$TMP/dst" ]
}

@test "fresh copy: all files present in destination" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    [ -f "$TMP/dst/a.txt" ]
    [ -f "$TMP/dst/sub/b.txt" ]
    [ -f "$TMP/dst/.hidden" ]
}

@test "fresh copy: checksum verification passes" {
    run bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASSED"* ]]
}

# ---------------------------------------------------------------------------
# Smart skip (re-run)
# ---------------------------------------------------------------------------

@test "re-run: 0 copied, 3 skipped as identical" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    run bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 element(s) copied, 3 skipped"* ]]
}

@test "corrupted destination file is re-copied: 1 copied, 2 skipped" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    printf 'corrupted\n' > "$TMP/dst/a.txt"
    run bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 element(s) copied, 2 skipped"* ]]
}

# ---------------------------------------------------------------------------
# --overwrite
# ---------------------------------------------------------------------------

@test "--overwrite: re-copies all files even when identical" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    run bash "$SCRIPT" --overwrite -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 element(s) copied, 0 skipped"* ]]
}

# ---------------------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------------------

@test "--dry-run: exit 0, destination not created" {
    run bash "$SCRIPT" --dry-run -s "$TMP/src" -d "$TMP/dryrun_dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [ ! -d "$TMP/dryrun_dst" ]
}

@test "--dry-run: SOURCE / DESTINATION / TYPE table printed" {
    run bash "$SCRIPT" --dry-run -s "$TMP/src" -d "$TMP/dryrun_dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"SOURCE"* ]]
    [[ "$output" == *"DESTINATION"* ]]
    [[ "$output" == *"TYPE"* ]]
}

# ---------------------------------------------------------------------------
# --no-checksum
# ---------------------------------------------------------------------------

@test "--no-checksum: verification skipped, exit 0" {
    run bash "$SCRIPT" --no-checksum -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped (--no-checksum)"* ]]
    [[ "$output" != *"PASSED"* ]]
}

# ---------------------------------------------------------------------------
# --quiet
# ---------------------------------------------------------------------------

@test "--quiet: no INFO output on stderr, exit 0" {
    run bash "$SCRIPT" --quiet -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" != *"[INFO]"* ]]
}

@test "--quiet: log file still written in full" {
    bash "$SCRIPT" --quiet -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    log_file="$(find "$TMP" -maxdepth 1 -name 'run_*.log' | head -1)"
    grep -q '\[COPY\]' "$log_file"
    grep -q '\[INFO\]' "$log_file"
}

# ---------------------------------------------------------------------------
# --verbose
# ---------------------------------------------------------------------------

@test "--verbose: COPY lines printed to console" {
    run bash "$SCRIPT" --verbose -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"[COPY]"* ]]
}

@test "--verbose: SKIP lines printed to console on re-run" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    run bash "$SCRIPT" --verbose -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP]"* ]]
}

# ---------------------------------------------------------------------------
# --exclude
# ---------------------------------------------------------------------------

@test "--exclude by name: file is not copied" {
    run bash "$SCRIPT" --exclude a.txt -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [ ! -f "$TMP/dst/a.txt" ]
    [ -f "$TMP/dst/sub/b.txt" ]
}

@test "--exclude glob pattern: matching files are not copied" {
    printf 'temp\n' > "$TMP/src/build.tmp"
    run bash "$SCRIPT" --exclude '*.tmp' -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [ ! -f "$TMP/dst/build.tmp" ]
    [ -f "$TMP/dst/a.txt" ]
}

@test "--exclude directory: dir and contents are not copied" {
    run bash "$SCRIPT" --exclude sub -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [ ! -d "$TMP/dst/sub" ]
    [ -f "$TMP/dst/a.txt" ]
}

@test "--exclude repeatable: multiple patterns all respected" {
    run bash "$SCRIPT" --exclude a.txt --exclude .hidden \
        -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [ ! -f "$TMP/dst/a.txt" ]
    [ ! -f "$TMP/dst/.hidden" ]
    [ -f "$TMP/dst/sub/b.txt" ]
}

# ---------------------------------------------------------------------------
# --workers (parallel copy)
# ---------------------------------------------------------------------------

@test "--workers 2: all files copied correctly" {
    run bash "$SCRIPT" --workers 2 -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [ -f "$TMP/dst/a.txt" ]
    [ -f "$TMP/dst/sub/b.txt" ]
    [ -f "$TMP/dst/.hidden" ]
    [[ "$output" == *"3 element(s) copied"* ]]
}

@test "--workers 2 re-run: all files skipped" {
    bash "$SCRIPT" --workers 2 -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    run bash "$SCRIPT" --workers 2 -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 element(s) copied, 3 skipped"* ]]
}

@test "--workers requires a positive integer" {
    run bash "$SCRIPT" --workers 0 -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

# ---------------------------------------------------------------------------
# Log files
# ---------------------------------------------------------------------------

@test "each run produces a separate log file" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    [ "$(find "$TMP" -maxdepth 1 -name 'run_*.log' | wc -l)" -eq 2 ]
}

@test "log file contains [COPY] lines" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    log_file="$(find "$TMP" -maxdepth 1 -name 'run_*.log' | head -1)"
    grep -q '\[COPY\]' "$log_file"
}

@test "re-run log file contains [SKIP] lines" {
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    bash "$SCRIPT" -s "$TMP/src" -d "$TMP/dst" -l "$TMP/run.log" 2>/dev/null
    log_file="$(find "$TMP" -maxdepth 1 -name 'run_*.log' | sort | tail -1)"
    grep -q '\[SKIP\]' "$log_file"
}

@test "dry-run log file contains the table" {
    bash "$SCRIPT" --dry-run -s "$TMP/src" -d "$TMP/dryrun_dst" -l "$TMP/run.log" 2>/dev/null
    log_file="$(find "$TMP" -maxdepth 1 -name 'run_*.log' | head -1)"
    grep -q 'SOURCE' "$log_file"
}
