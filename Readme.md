# Haul

**Haul** (`haul.sh`) is a safe, verifiable file-haul tool for Linux/macOS. It recursively copies all files and folders (including hidden ones) from a source directory to a destination directory, verifies the result with SHA-256 checksums, skips files that haven't changed, and writes a detailed, timestamped log file for every run.

---

## Features

- **Deep copy** — recursively copies the entire directory tree, including hidden files (dotfiles) and symlinks, preserving permissions and timestamps (`cp -a`).
- **Smart skip** — by default, files whose source and destination checksums are identical are *not* overwritten. Re-running the script only transfers what changed (incremental behavior).
- **Force overwrite** — `--overwrite` copies everything unconditionally.
- **Checksum verification** — after copying, every file is verified by comparing SHA-256 checksums of source vs destination (enabled by default). Results are shown as a table and saved to the log. Any mismatch exits with code 1.
- **Dry-run mode** — `--dry-run` copies nothing; instead it prints (and logs) a "source vs destination" table of everything that *would* be copied.
- **Per-run logging** — every run creates its own uniquely named log file containing every decision (MKDIR / COPY / SKIP), the verification table, and the final result.
- **Live progress bar** — when stderr is a terminal, a `[=====>   ] N/TOTAL` bar is shown in-place during the copy and verify phases. It is never written to the log file and is automatically suppressed in scripts, CI, and redirected output.
- **Quiet / verbose output** — `--quiet` (`-q`) suppresses all console output except errors (log file is always written in full); `--verbose` (`-v`) prints every COPY / SKIP / MKDIR decision to the console as it happens.
- **Parallel workers** — `--workers <n>` copies files using N concurrent workers. Checksum verification is always sequential. Useful for high-latency or high-throughput storage.
- **Exclude patterns** — `--exclude <pattern>` (repeatable) skips matching files and directories. Glob patterns (e.g. `*.tmp`) match by filename; plain names (e.g. `.git`) exclude the item and its entire subtree.

---

## Requirements

- `bash` 4+ (uses `mapfile`)
- Standard GNU/Linux core utilities: `cp`, `find`, `sha256sum`, `tee`, `awk`, `sed`
  - On macOS, install coreutils (`brew install coreutils`) or replace `sha256sum` with `shasum -a 256`.

## Configuration

### Making the script executable

```bash
chmod +x haul.sh
```

### Adding to PATH (optional)

```bash
# System-wide (requires sudo):
sudo cp haul.sh /usr/local/bin/haul

# User-only (no sudo needed):
mkdir -p ~/.local/bin
cp haul.sh ~/.local/bin/haul
# Make sure ~/.local/bin is in your PATH (add to ~/.bashrc or ~/.zshrc if not):
# export PATH="$HOME/.local/bin:$PATH"
```

### Creating a shell alias (optional)

Add to `~/.bashrc` or `~/.zshrc` to bake in your preferred defaults:

```bash
# Example: always store logs in ~/logs/, always skip .git and node_modules
alias bkp='haul.sh --log ~/logs/bkp.log --exclude .git --exclude node_modules'
```

### Setting a dedicated log directory

The `--log` option accepts any path. Create the directory once and point every run at it:

```bash
mkdir -p ~/logs
haul.sh -s /data/src -d /data/dst --log ~/logs/backup.log
# Each run creates: ~/logs/backup_20260612_143501_8421.log
```

### macOS note

macOS ships `shasum` instead of `sha256sum`. Install GNU coreutils once:

```bash
brew install coreutils
```

After that, `sha256sum` is available as a separate command and the script works without modification.

---

## Usage

```
haul --source <dir> --destination <dir> [options]
```

Source and destination are passed as **named options** (in any order), not positional arguments.

| Option | Description |
|---|---|
| `-s, --source <dir>` | **Required.** Directory to copy from (must exist) |
| `-d, --destination <dir>` | **Required.** Directory to copy into (created automatically if missing). Alias: `--dest` |
| `-l, --log <file>` | Base log file path. A per-run timestamp is inserted into the name, e.g. `backup.log` → `backup_20260612_123702_525.log`. Default base: `./haul.log` |
| `-n, --dry-run` | Copy nothing; show a table of everything that would be copied (also saved to the log) |
| `-o, --overwrite` | Force overwrite of every destination file, even identical ones |
| `-c, --checksum` | Verify the copy with SHA-256 checksums afterwards (**default: on**) |
| `--no-checksum` | Skip the post-copy checksum verification (faster for huge trees) |
| `-q, --quiet` | Suppress all console output except errors and the progress bar. Log file still written in full. |
| `-v, --verbose` | Print every COPY / SKIP / MKDIR decision to the console as it happens. Progress bar suppressed. |
| `-e, --exclude <pattern>` | Skip files/dirs matching pattern. Repeatable. Globs (e.g. `*.tmp`) match by name; plain names (e.g. `.git`) exclude the item and its whole subtree. |
| `-w, --workers <n>` | Number of parallel copy workers (default: `1`). Verification is always sequential. |
| `-h, --help` | Show built-in help |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (copy completed, verification passed or skipped) |
| `1` | Error: bad arguments, missing source, unwritable log, or checksum mismatch |

---

## Examples

**1. Basic copy with verification (default behavior):**

```bash
haul -s ~/projects/myapp -d /backup/myapp
```

**2. Preview first, then copy:**

```bash
haul --dry-run -s ~/projects/myapp -d /backup/myapp   # nothing is copied
haul -s ~/projects/myapp -d /backup/myapp             # actual copy
```

**3. Force a full re-copy, custom log location:**

```bash
haul --overwrite --log /var/log/backups/site.log --source /var/www/site --destination /mnt/backup/site
```

**4. Fast copy without verification:**

```bash
haul --no-checksum -s /data/big -d /mnt/archive/big
```

**5. Safe in automation** — the exit code reflects verification, so you can chain commands:

```bash
haul -s /data/src -d /data/dst && echo "verified OK" || echo "FAILED — check the log"
```

**6. Quiet mode for cron / scripts:**

```bash
haul --quiet -s /data/src -d /data/dst --log /var/log/backup.log
```

**7. Verbose mode — see every file decision:**

```bash
haul --verbose -s ~/projects/myapp -d /backup/myapp
```

**8. Exclude patterns:**

```bash
# Exclude .git and all *.tmp files
haul -s ~/projects/myapp -d /backup/myapp --exclude .git --exclude '*.tmp'

# Exclude build output and logs
haul -s /var/www/site -d /mnt/backup/site -e node_modules -e '*.log'

# Mixed: folders, hidden files, globs — all in one --exclude
haul -s ~/work/projects -d /backup/projects \
  --exclude '.git,__pycache__,.pytest_cache,build,dist,.Rhistory,.RData,*.sas7bdat,*.xpt'
```

**9. Parallel workers — faster copy over high-latency storage:**

```bash
haul --workers 8 -s /mnt/nas/data -d /mnt/backup/data
```

---

## Sample output

**Dry-run table:**

```
+---------------+--------------------+--------+
| SOURCE        | DESTINATION        | TYPE   |
+---------------+--------------------+--------+
| src/.hidden   | dest/.hidden       | file   |
| src/a.txt     | dest/a.txt         | file   |
| src/sub       | dest/sub           | dir    |
| src/sub/b.txt | dest/sub/b.txt     | file   |
+---------------+--------------------+--------+
```

**Checksum verification table (after a copy):**

```
+-----------+--------------+--------------+----------+
| FILE      | SRC SHA-256  | DEST SHA-256 | STATUS   |
+-----------+--------------+--------------+----------+
| .hidden   | e084a3683ef7 | e084a3683ef7 | OK       |
| a.txt     | 98ea6e4f216f | 98ea6e4f216f | OK       |
| sub/b.txt | 370a8c04b8a6 | 370a8c04b8a6 | OK       |
+-----------+--------------+--------------+----------+
```

Checksums are shortened to 12 characters for display; full SHA-256 values are compared internally.

**Console summary:**

```
2026-06-12 12:37:04 [INFO] Copy done: 1 element(s) copied, 2 skipped as identical.
2026-06-12 12:37:04 [INFO] Checksum verification PASSED: all 3 file(s) match.
```

---

## Logging

Every run writes its **own** log file. The name is built from the base path (default `haul.log`, or whatever you pass with `--log`) plus a timestamp and process ID:

```
backup.log  →  backup_20260612_123702_525.log
```

The exact file name for the current run is printed at startup:

```
[INFO] Log file for this run: logs/backup_20260612_123702_525.log
```

Each log contains:

- the options used for the run (`overwrite=...`, `checksum-verify=...`)
- a `[MKDIR]` line for every directory created
- a `[COPY]` line for every file or symlink copied
- a `[SKIP]` line for every file left untouched because checksums matched
- the dry-run or checksum verification table
- `[ERROR]` lines for any failure, plus the final result

## Overwrite logic in detail

| Situation | Default | With `--overwrite` |
|---|---|---|
| File missing in destination | copied | copied |
| File exists, checksums **differ** | copied (overwrites) | copied |
| File exists, checksums **equal** | **skipped** | copied |

This means running the script twice in a row is cheap and safe: the second run transfers nothing and still verifies everything.

## Testing

Tests are written with [bats-core](https://github.com/bats-core/bats-core) and live in `tests/test_haul.bats`. CI runs shellcheck and the full test suite on every push via `.github/workflows/ci.yml`.

### Running tests locally

```bash
# Install bats-core (one-time)
git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
sudo /tmp/bats-core/install.sh /usr/local

# Run the suite
bats tests/
```

### Running shellcheck locally

```bash
# Install shellcheck (Debian/Ubuntu)
sudo apt-get install shellcheck

# macOS
brew install shellcheck

# Run
shellcheck --severity=warning haul.sh
```

---

## Notes & limitations

- Symlinks are copied as symlinks (not followed) and are not checksum-verified.
- Files that exist *only* in the destination are never deleted — this tool copies, it does not mirror/sync.
- Checksumming reads every file twice (skip check + verification), so for very large datasets consider `--no-checksum` or running verification only periodically.