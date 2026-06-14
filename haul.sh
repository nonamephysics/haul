#!/usr/bin/env bash
#
# haul.sh — recursively haul all files and folders from SOURCE to DESTINATION,
#            with per-run logging, dry-run mode, smart skip of identical files,
#            parallel workers, forced overwrite, and SHA-256 verification.
#
# Usage:
#   ./haul.sh --source <dir> --destination <dir> [options]
#

set -euo pipefail

RUN_STAMP="$(date '+%Y%m%d_%H%M%S')_$$"   # timestamp + PID -> unique per run
LOG_FILE=""                               # resolved after parsing args
LOG_ARG=""                                # user-provided base (-l/--log)
DRY_RUN=false
CHECKSUM=true                             # post-copy verification; --no-checksum to skip
OVERWRITE=false                           # force overwrite; default = skip identical files
VERBOSITY=1                               # 0=quiet  1=normal  2=verbose
EXCLUDE_PATTERNS=()                       # patterns from --exclude (repeatable)
WORKERS=1                                 # parallel copy workers; 1 = sequential

# --- Help --------------------------------------------------------------------
show_help() {
    cat <<'HELP'
haul.sh — recursively (deep) copy all files and folders from SOURCE to DESTINATION

Usage:
  haul.sh --source <dir> --destination <dir> [options]
  haul.sh -h | --help

Required options:
  -s, --source <dir>        Directory to copy from (must exist)
  -d, --destination <dir>   Directory to copy into (created automatically
                            if missing). Alias: --dest

Options:
  -l, --log <file>        Base log file path. A per-run timestamp is inserted
                          into the name, e.g. 'backup.log' ->
                          'backup_20260612_121530_123.log'
                          (default base: ./haul.log)
  -n, --dry-run           Do NOT copy anything. Instead, collect every element
                          that would be copied and show it in a table (printed
                          to console and saved to the log file)
  -o, --overwrite         FORCE overwrite of every destination file. Without
                          this flag, files whose source and destination
                          checksums are EQUAL are skipped.
  -c, --checksum          Verify the copy afterwards by comparing SHA-256
                          checksums of every source file vs its destination
                          copy (DEFAULT: enabled). Mismatch -> exit 1.
      --no-checksum       Skip the post-copy checksum verification
  -q, --quiet             Suppress all console output except errors. Log file
                          is still written in full.
  -v, --verbose           Print each COPY / SKIP / MKDIR decision to the
                          console as it happens (in addition to the log file).
                          Progress bar is suppressed in this mode.
  -e, --exclude <pattern> Skip files/directories matching pattern. Can be
                          specified multiple times. Glob patterns (e.g.
                          '*.tmp') match by name; plain names (e.g. '.git')
                          exclude the item and everything inside it.
  -w, --workers <n>       Number of parallel copy workers (default: 1).
                          Workers copy files concurrently; checksum
                          verification is always sequential. In parallel
                          mode COPY/SKIP log entries are written after all
                          workers finish, sorted by original file order.
  -h, --help              Show this help and exit

Behavior:
  * Copies ALL contents recursively, including hidden files (dotfiles)
  * Preserves permissions, timestamps, and symlinks (cp -a per element)
  * Identical files (same checksum) are skipped unless --overwrite is given
  * EVERY RUN writes its own separate log file (unique timestamped name)
  * When stderr is a terminal (and not quiet/verbose), a live progress bar
    is shown during copy and verification (never written to the log file)

Examples:
  haul.sh -s ~/projects/myapp -d /backup/myapp
  haul.sh --dry-run --source ~/projects/myapp --destination /backup/myapp
  haul.sh --overwrite --log /var/log/mybackup.log -s /var/www/site -d /tmp/site-copy
  haul.sh -s /data/src -d /data/dst --exclude .git --exclude '*.tmp'
  haul.sh --quiet -s /data/src -d /data/dst && echo OK
  haul.sh --verbose -s /data/src -d /data/dst
HELP
}

# --- Logging -----------------------------------------------------------------
# log LEVEL MESSAGE  -> always writes to log file; prints to console unless --quiet
log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    echo "$line" >> "$LOG_FILE"
    if [[ "$level" == "ERROR" ]] || (( VERBOSITY > 0 )); then
        echo "$line" >&2
    fi
}

# log_only LEVEL MESSAGE -> always writes to log file; also console when --verbose
log_only() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    echo "$line" >> "$LOG_FILE"
    if (( VERBOSITY >= 2 )); then
        echo "$line" >&2
    fi
}

# _show_progress CURRENT TOTAL PHASE — inline TTY-only progress bar (never logged)
# Shown only in normal mode; suppressed in --quiet and --verbose.
_show_progress() {
    [[ -t 2 ]] || return 0
    (( VERBOSITY == 2 )) && return 0
    local current=$1 total=$2 phase=$3
    local width=25 filled=0 bar='' i
    (( total > 0 )) && filled=$(( width * current / total ))
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then bar+='='; else bar+=' '; fi
    done
    local pct=0
    (( total > 0 )) && pct=$(( 100 * current / total ))
    printf '\r  %-10s [%s] %d/%d (%d%%)  ' "$phase" "$bar" "$current" "$total" "$pct" >&2
}

# _clear_progress — erase the progress line (TTY + normal mode only)
_clear_progress() {
    [[ -t 2 ]] || return 0
    (( VERBOSITY == 2 )) && return 0
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    printf '\r%*s\r' "$cols" '' >&2
}

# _copy_one IDX REL — parallel-copy worker; writes result to $_WORK_DIR/IDX
# Inherits SRC, DEST, OVERWRITE, _WORK_DIR from the parent subshell.
_copy_one() {
    local idx=$1 rel=$2
    local s="$SRC/$rel" d="$DEST/$rel"
    local out
    out="$_WORK_DIR/$(printf '%09d' "$idx")"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ "$OVERWRITE" == false && ! -L "$s" && -f "$d" && ! -L "$d" ]]; then
        local src_sum dest_sum
        src_sum=$(sha256sum "$s" | awk '{print $1}')
        dest_sum=$(sha256sum "$d" | awk '{print $1}')
        if [[ "$src_sum" == "$dest_sum" ]]; then
            echo "SKIP"  > "$out"
            echo "$ts [SKIP] '$s' == '$d' (identical checksum, not overwritten)" >> "$out"
            return 0
        fi
    fi

    cp -a -f "$s" "$d"
    echo "COPY"  > "$out"
    echo "$ts [COPY] '$s' -> '$d'" >> "$out"
}

# _xfind FIND-ARGS... — runs find with FIND_EXCL exclusions appended
_xfind() {
    if (( ${#FIND_EXCL[@]} > 0 )); then
        find "$@" "${FIND_EXCL[@]}"
    else
        find "$@"
    fi
}

# --- Parse arguments ----------------------------------------------------------
SRC=""
DEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--source)
            if [[ -z "${2:-}" ]]; then
                echo "Error: $1 requires a directory path argument." >&2
                exit 1
            fi
            SRC="$2"
            shift 2
            ;;
        -d|--dest|--destination)
            if [[ -z "${2:-}" ]]; then
                echo "Error: $1 requires a directory path argument." >&2
                exit 1
            fi
            DEST="$2"
            shift 2
            ;;
        -l|--log)
            if [[ -z "${2:-}" ]]; then
                echo "Error: $1 requires a file path argument." >&2
                exit 1
            fi
            LOG_ARG="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -o|--overwrite)
            OVERWRITE=true
            shift
            ;;
        -c|--checksum)
            CHECKSUM=true
            shift
            ;;
        --no-checksum)
            CHECKSUM=false
            shift
            ;;
        -q|--quiet)
            VERBOSITY=0
            shift
            ;;
        -v|--verbose)
            VERBOSITY=2
            shift
            ;;
        -e|--exclude)
            if [[ -z "${2:-}" ]]; then
                echo "Error: $1 requires a pattern argument." >&2
                exit 1
            fi
            IFS=',' read -ra _excl_list <<< "$2"
            EXCLUDE_PATTERNS+=("${_excl_list[@]}")
            shift 2
            ;;
        -w|--workers)
            if [[ -z "${2:-}" ]]; then
                echo "Error: $1 requires a number argument." >&2
                exit 1
            fi
            if ! [[ "${2}" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --workers requires a positive integer, got '${2}'." >&2
                exit 1
            fi
            WORKERS="$2"
            shift 2
            ;;
        -*)
            echo "Error: unknown option '$1'." >&2
            echo "Try '$0 --help' for more information." >&2
            exit 1
            ;;
        *)
            echo "Error: unexpected argument '$1'. Source and destination must be passed via -s/--source and -d/--destination." >&2
            echo "Try '$0 --help' for more information." >&2
            exit 1
            ;;
    esac
done

if [[ -z "$SRC" || -z "$DEST" ]]; then
    [[ -z "$SRC" ]]  && echo "Error: missing required option -s/--source." >&2
    [[ -z "$DEST" ]] && echo "Error: missing required option -d/--destination." >&2
    echo "Try '$0 --help' for more information." >&2
    exit 1
fi

# --- Build a per-run log file name ----------------------------------------------
# Base name (default ./haul.log or the user's --log value) gets the run
# stamp inserted before the extension, so every run has its OWN log file.
BASE="${LOG_ARG:-haul.log}"
dir=$(dirname "$BASE"); name=$(basename "$BASE")
if [[ "$name" == *.* ]]; then
    LOG_FILE="$dir/${name%.*}_${RUN_STAMP}.${name##*.}"
else
    LOG_FILE="$dir/${name}_${RUN_STAMP}.log"
fi

mkdir -p "$dir"
touch "$LOG_FILE" || { echo "Error: cannot write to log file '$LOG_FILE'." >&2; exit 1; }

# Log any unexpected failure before the script exits
trap 'log ERROR "Run failed (exit code $?)."' ERR

MODE_LABEL=$([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "COPY")
log INFO "=== haul started [$MODE_LABEL]: '$SRC' -> '$DEST' ==="
log INFO "Log file for this run: $LOG_FILE"
log INFO "Options: overwrite=$OVERWRITE, checksum-verify=$CHECKSUM, verbosity=$VERBOSITY, workers=$WORKERS"
if (( ${#EXCLUDE_PATTERNS[@]} > 0 )); then
    log INFO "Exclude patterns: ${EXCLUDE_PATTERNS[*]}"
fi

# Build find exclusion arguments from --exclude patterns.
# Glob patterns (containing * or ?) filter by name; plain names filter by path
# so that a directory and everything inside it is excluded.
# Zone.Identifier files are Windows NTFS alternate data streams that appear in
# WSL as separate files; they are never valid copy targets and always excluded.
FIND_EXCL=( -not -name '*:Zone.Identifier' )
if (( ${#EXCLUDE_PATTERNS[@]} > 0 )); then
    for _pat in "${EXCLUDE_PATTERNS[@]}"; do
        if [[ "$_pat" == *'*'* || "$_pat" == *'?'* ]]; then
            FIND_EXCL+=( -not -name "$_pat" )
        else
            FIND_EXCL+=( -not -path "*/$_pat" -not -path "*/$_pat/*" )
        fi
    done
fi

# --- Validate source -----------------------------------------------------------
if [[ ! -d "$SRC" ]]; then
    log ERROR "Source directory '$SRC' does not exist."
    exit 1
fi

# ================================ DRY-RUN MODE ===================================
if [[ "$DRY_RUN" == true ]]; then
    log INFO "Dry-run: nothing will be copied. Collecting elements..."

    mapfile -t ITEMS < <(cd "$SRC" && _xfind . -mindepth 1 | sort)

    if [[ ${#ITEMS[@]} -eq 0 ]]; then
        log INFO "Source '$SRC' is empty — nothing would be copied."
        exit 0
    fi

    SRC_W=${#SRC}; DEST_W=${#DEST}
    for rel in "${ITEMS[@]}"; do
        rel="${rel#./}"
        s="$SRC/$rel"; d="$DEST/$rel"
        (( ${#s} > SRC_W ))  && SRC_W=${#s}
        (( ${#d} > DEST_W )) && DEST_W=${#d}
    done
    (( SRC_W  < 6 )) && SRC_W=6
    (( DEST_W < 11 )) && DEST_W=11

    SEP="+$(printf '%*s' $((SRC_W+2)) '' | tr ' ' '-')+$(printf '%*s' $((DEST_W+2)) '' | tr ' ' '-')+--------+"

    {
        echo "$SEP"
        printf "| %-*s | %-*s | %-6s |\n" "$SRC_W" "SOURCE" "$DEST_W" "DESTINATION" "TYPE"
        echo "$SEP"
        for rel in "${ITEMS[@]}"; do
            rel="${rel#./}"
            s="$SRC/$rel"; d="$DEST/$rel"
            if   [[ -L "$s" ]]; then t="link"
            elif [[ -d "$s" ]]; then t="dir"
            else                     t="file"
            fi
            printf "| %-*s | %-*s | %-6s |\n" "$SRC_W" "$s" "$DEST_W" "$d" "$t"
        done
        echo "$SEP"
    } | tee -a "$LOG_FILE"

    log INFO "Dry-run complete: ${#ITEMS[@]} element(s) would be copied. Table saved to $LOG_FILE"
    log INFO "=== haul finished [DRY-RUN] ==="
    exit 0
fi

# ================================= COPY MODE =====================================
if [[ ! -d "$DEST" ]]; then
    log INFO "Destination '$DEST' does not exist — creating it."
    mkdir -p "$DEST"
fi

log INFO "Copying files (overwrite=$OVERWRITE)..."

# 1) Recreate the directory tree
while IFS= read -r rel; do
    rel="${rel#./}"
    [[ -d "$DEST/$rel" ]] || { mkdir -p "$DEST/$rel"; log_only MKDIR "$DEST/$rel"; }
done < <(cd "$SRC" && _xfind . -mindepth 1 -type d | sort)

# 2) Copy files and symlinks
mapfile -t _COPY_FILES < <(cd "$SRC" && _xfind . -mindepth 1 \( -type f -o -type l \) | sort)
COPIED=0; SKIPPED=0
_PROG_I=0

if (( WORKERS == 1 )); then
    # --- Sequential path ---
    for rel in "${_COPY_FILES[@]}"; do
        (( ++_PROG_I ))
        _show_progress "$_PROG_I" "${#_COPY_FILES[@]}" "Copying"
        rel="${rel#./}"
        s="$SRC/$rel"; d="$DEST/$rel"

        if [[ "$OVERWRITE" == false && ! -L "$s" && -f "$d" && ! -L "$d" ]]; then
            src_sum=$(sha256sum "$s" | awk '{print $1}')
            dest_sum=$(sha256sum "$d" | awk '{print $1}')
            if [[ "$src_sum" == "$dest_sum" ]]; then
                log_only SKIP "'$s' == '$d' (identical checksum, not overwritten)"
                (( ++SKIPPED ))
                continue
            fi
        fi

        cp -a -f "$s" "$d"
        log_only COPY "'$s' -> '$d'"
        (( ++COPIED ))
    done
else
    # --- Parallel path (WORKERS > 1) ---
    # Each worker writes a 2-line result file (type + log line).
    # Results are aggregated in job-submission order after all workers finish.
    _WORK_DIR=$(mktemp -d)
    _ACTIVE_PIDS=()
    for rel in "${_COPY_FILES[@]}"; do
        (( ++_PROG_I ))
        _show_progress "$_PROG_I" "${#_COPY_FILES[@]}" "Copying"
        rel="${rel#./}"
        _copy_one "$_PROG_I" "$rel" &
        _ACTIVE_PIDS+=($!)
        # Throttle: when pool is full wait for the oldest job before submitting more
        if (( ${#_ACTIVE_PIDS[@]} >= WORKERS )); then
            wait "${_ACTIVE_PIDS[0]}" || true
            _ACTIVE_PIDS=("${_ACTIVE_PIDS[@]:1}")
        fi
    done
    # Drain any remaining background jobs
    if (( ${#_ACTIVE_PIDS[@]} > 0 )); then
        for _pid in "${_ACTIVE_PIDS[@]}"; do
            wait "$_pid" || true
        done
    fi

    # Aggregate results in original file order and write to log
    while IFS= read -r _out; do
        [[ -f "$_out" ]] || continue
        _rtype=$(head -1 "$_out")
        _rline=$(tail -n +2 "$_out")
        echo "$_rline" >> "$LOG_FILE"
        if (( VERBOSITY >= 2 )); then echo "$_rline" >&2; fi
        case "$_rtype" in
            COPY) (( ++COPIED )) ;;
            SKIP) (( ++SKIPPED )) ;;
        esac
    done < <(find "$_WORK_DIR" -maxdepth 1 -name '[0-9]*' | sort)
    rm -rf "$_WORK_DIR"
fi
_clear_progress

log INFO "Copy done: $COPIED element(s) copied, $SKIPPED skipped as identical."

# ============================ CHECKSUM VERIFICATION ==============================
if [[ "$CHECKSUM" == true ]]; then
    mapfile -t FILES < <(cd "$SRC" && _xfind . -type f | sort)

    if [[ ${#FILES[@]} -eq 0 ]]; then
        log INFO "No regular files to verify."
    else
        log INFO "Checksum verification started: ${#FILES[@]} file(s) to verify (SHA-256)..."

        FILE_W=4
        for rel in "${FILES[@]}"; do
            rel="${rel#./}"
            (( ${#rel} > FILE_W )) && FILE_W=${#rel}
        done

        SEP="+$(printf '%*s' $((FILE_W+2)) '' | tr ' ' '-')+--------------+--------------+----------+"
        MISMATCHES=0
        TABLE_TMP=$(mktemp)

        echo "$SEP" >> "$TABLE_TMP"
        printf "| %-*s | %-12s | %-12s | %-8s |\n" "$FILE_W" "FILE" "SRC SHA-256" "DEST SHA-256" "STATUS" >> "$TABLE_TMP"
        echo "$SEP" >> "$TABLE_TMP"
        _PROG_I=0
        for rel in "${FILES[@]}"; do
            (( ++_PROG_I ))
            _show_progress "$_PROG_I" "${#FILES[@]}" "Verifying"
            rel="${rel#./}"
            s="$SRC/$rel"; d="$DEST/$rel"
            src_sum=$(sha256sum "$s" | awk '{print $1}')
            if [[ -f "$d" ]]; then
                dest_sum=$(sha256sum "$d" | awk '{print $1}')
            else
                dest_sum="(missing)"
            fi
            if [[ "$src_sum" == "$dest_sum" ]]; then
                status="OK"
            else
                status="MISMATCH"
                (( ++MISMATCHES ))
            fi
            log_only VERIFY "'$rel': $status"
            printf "| %-*s | %-12s | %-12s | %-8s |\n" \
                "$FILE_W" "$rel" "${src_sum:0:12}" "${dest_sum:0:12}" "$status" >> "$TABLE_TMP"
        done
        echo "$SEP" >> "$TABLE_TMP"
        _clear_progress

        tee -a "$LOG_FILE" < "$TABLE_TMP"
        rm -f "$TABLE_TMP"

        if (( MISMATCHES > 0 )); then
            log ERROR "Checksum verification FAILED: $MISMATCHES of ${#FILES[@]} file(s) do not match. See $LOG_FILE"
            exit 1
        fi
        log INFO "Checksum verification PASSED: all ${#FILES[@]} file(s) match. Table saved to $LOG_FILE"
    fi
else
    log INFO "Checksum verification skipped (--no-checksum)."
fi

log INFO "=== haul finished successfully ==="