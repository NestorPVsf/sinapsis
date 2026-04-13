---
name: cleanup
description: Clean homunculus directory — remove legacy files, orphan projects, old archives
command: true
---

# /cleanup

> Clean the homunculus observation directory and remove legacy files.
> Shows what will be removed and asks for confirmation before deleting.

## Trigger

`/cleanup`, "clean homunculus", "clean observations", "free space sinapsis"

## Process

### Step 1: Scan homunculus

Read `~/.claude/homunculus/` and report:

```bash
# Total size
du -sh ~/.claude/homunculus/

# List all project directories with name (from context.md) and obs size
for d in ~/.claude/homunculus/projects/*/; do
  hash=$(basename "$d")
  name=""
  [ -f "$d/context.md" ] && name=$(head -1 "$d/context.md" | sed 's/## Proyecto: //')
  obs_size=$(du -sh "$d/observations.jsonl" 2>/dev/null | cut -f1)
  last_modified=$(stat -c '%Y' "$d/observations.jsonl" 2>/dev/null || stat -f '%m' "$d/observations.jsonl" 2>/dev/null)
  echo "$hash | $name | $obs_size | last: $last_modified"
done
```

### Step 2: Identify cleanup targets

**Legacy v1 files** (always safe to remove):
- `~/.claude/homunculus/config.json` — v1 config, replaced by operator-state
- `~/.claude/homunculus/identity.json` — v1 identity, replaced by operator-state
- `~/.claude/homunculus/instincts/` — v1 YAML instincts, migrated to _instincts-index.json
- `~/.claude/homunculus/evolved/` — v1 evolved skills
- `~/.claude/homunculus/exports/` — v1 export artifacts
- `~/.claude/homunculus/observations.jsonl` — root-level obs from v1 (projects have their own)
- `~/.claude/homunculus/observations.archive/` — root-level archive from v1
- `~/.claude/homunculus/observations.jsonl.lock` — stale lock

**Orphan project directories** (no context.md AND no observations in 30+ days):
- Projects where `observations.jsonl` hasn't been modified in 30+ days AND no `context.md` exists

**Old observation archives** (>60 days):
- `projects/*/observations.archive/*.jsonl` older than 60 days

**Empty/tiny projects** (<1KB observations, no context.md):
- Projects with essentially no data

### Step 3: Show cleanup plan

```
CLEANUP PLAN
============

Legacy v1 files (safe to remove):
  - config.json (912 bytes)
  - identity.json (1.5 KB)
  - instincts/ (v1 YAML, migrated)
  - evolved/ (v1 artifacts)
  - exports/ (v1 artifacts)
  - observations.jsonl (3.5 MB — root level, not per-project)
  - observations.archive/ (11 MB)
  Total: ~15 MB

Orphan projects (no activity in 30+ days, no name):
  - 04d1de17222e (12K, last: 45 days ago)
  - 07ce90c43121 (8K, last: 38 days ago)
  [... list all ...]
  Total: ~X MB

Old archives (>60 days):
  [list if any]

TOTAL SPACE TO RECOVER: ~X MB

Proceed? [y/n]
```

### Step 4: Execute cleanup (only after confirmation)

```bash
# Remove legacy
rm -f ~/.claude/homunculus/config.json
rm -f ~/.claude/homunculus/identity.json
rm -rf ~/.claude/homunculus/instincts/
rm -rf ~/.claude/homunculus/evolved/
rm -rf ~/.claude/homunculus/exports/
rm -f ~/.claude/homunculus/observations.jsonl
rm -rf ~/.claude/homunculus/observations.archive/
rm -f ~/.claude/homunculus/observations.jsonl.lock

# Remove orphan projects
rm -rf ~/.claude/homunculus/projects/{hash}/

# Remove old archives
find ~/.claude/homunculus/projects/*/observations.archive/ -name "*.jsonl" -mtime +60 -delete
```

### Step 5: Report

```
Cleanup complete:
  - Removed {N} legacy files ({X} MB)
  - Removed {M} orphan projects ({Y} MB)
  - Removed {K} old archives ({Z} MB)
  - Total recovered: {TOTAL} MB
  - Projects remaining: {R} (with active observations)
```

## Important Rules

1. **NEVER delete observations.jsonl for active projects** — only orphans and root-level legacy
2. **NEVER delete _instincts-index.json or _passive-rules.json** — those are in skills/, not homunculus
3. **Always ask confirmation** before deleting anything
4. **Log the cleanup** to `_instinct.log`
