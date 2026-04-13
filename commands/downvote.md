---
name: downvote
description: Reduce confidence or archive an instinct that gave bad advice
command: true
---

# /downvote [instinct-id]

> Demote or archive an instinct that is incorrect or unhelpful.
> Inspired by Cortex cx-downvote — closes the feedback loop.

## Trigger

Run with `/downvote <id>`, "downvote instinct", "this instinct is wrong", "bad advice from instinct".

## Process

### Step 1: Identify the instinct

If user provides an ID directly: use it.
If not: read `~/.claude/skills/_instinct.log`, show the last 10 activations, ask which one.

### Step 2: Read current state

Read `~/.claude/skills/_instincts-index.json`. Find the instinct by ID. Show:
- Current level (draft/confirmed/permanent)
- Domain
- Occurrences
- Inject text (what it says)

### Step 3: Ask what to do

```
This instinct has been activated {N} times.

[1] Demote (confirmed → draft, permanent → confirmed)
[2] Archive (remove from active index, keep in archived array)
[3] Delete (remove completely)
[4] Cancel
```

### Step 4: Apply the action

**Demote:**
- `permanent` → `confirmed`
- `confirmed` → `draft`
- `draft` → archived (can't go lower)
- Add `"downvoted": true` and `"downvoted_at": "{ISO date}"` to the instinct

**Archive:**
- Move from `instincts` array to `archived` array
- Add `"archived_reason": "downvoted"` and `"archived_at": "{ISO date}"`

**Delete:**
- Remove from both arrays entirely

### Step 5: Write and confirm

Write back to `_instincts-index.json` using atomic tmp+rename.
Log the action to `_instinct.log`:
```
{ISO date} | DOWNVOTE | {id} | {action} (was {old_level})
```

Output confirmation:
```
Instinct "{id}" {action}ed.
- Was: {old_level}
- Now: {new_level or "archived" or "deleted"}
```

## Important Rules

1. **Never auto-downvote** — always confirm with the user first
2. **Permanent instincts require double confirmation** — they were explicitly promoted
3. **Archived instincts are recoverable** — they stay in the archived array
4. **Log everything** — the audit trail is essential for understanding instinct quality over time
