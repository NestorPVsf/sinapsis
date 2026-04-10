# Security Policy

## Supported Versions

| Version | Supported          | Notes |
|---------|-------------------|-------|
| 4.4.x   | Yes               | Current stable release |
| 4.3.x   | Security fixes only | Upgrade recommended |
| < 4.3   | No                | Known vulnerabilities — upgrade immediately |

## Reporting a Vulnerability

**Please do NOT open a public GitHub issue for security vulnerabilities.**

Instead, report them confidentially:

- **Email**: luis@salgadoia.com
- **Subject**: `[Sinapsis] Security: <brief description>`
- **Include**: steps to reproduce, affected version, potential impact

### Response Timeline

| Stage | Timeline |
|-------|----------|
| Acknowledgment | Within 48 hours |
| Initial assessment | Within 5 business days |
| Fix or mitigation | Within 14 business days |
| Public disclosure | After fix is released |

We follow responsible disclosure. If you report a vulnerability, we will credit you in the CHANGELOG and release notes (unless you prefer anonymity).

## Vulnerability Scope

The following areas are in scope for security reports:

| Category | Description |
|----------|-------------|
| **Command injection** | Unsafe use of shell commands in hook scripts |
| **Secret exposure** | API keys, tokens, or credentials leaking through observations or logs |
| **Path traversal** | File access outside intended directories |
| **ReDoS** | Regular expression denial of service in trigger patterns |
| **Race conditions** | Concurrent file writes corrupting data files |
| **Prompt injection** | Malicious content in instincts or observations reaching Claude's context |
| **Permission escalation** | Hooks or scripts running with unintended privileges |
| **Data loss on upgrade** | Installer destroying user data (instincts, rules, settings) |

### Out of Scope

- **Claude Code platform vulnerabilities** — report these to [Anthropic](https://www.anthropic.com/responsible-disclosure)
- **Vulnerabilities requiring physical access** to the machine
- **Social engineering attacks** against users
- **Issues in third-party dependencies** (Node.js, Python, bash) — report upstream

## Current Security Protections (v4.4)

### Command Execution Safety
- `execFileSync` / `spawnSync` used instead of `execSync` with string concatenation (prevents command injection — [Bug #4, v4.3.1])
- No user-controlled strings passed directly to shell commands
- Inject sanitization: 500-character limit + blocked patterns on instinct injection

### Secret Detection
- 12-category secret scrubbing in observation pipeline:
  - GitHub tokens (`ghp_`, `gho_`, `ghs_`, `ghu_`)
  - JWT tokens (`eyJ...`)
  - AWS keys (`AKIA...`)
  - Stripe keys (`sk_live_`, `sk_test_`, `pk_live_`, `pk_test_`)
  - Generic API keys, passwords, connection strings
  - Base64-encoded credentials
- Secrets are redacted before writing to `observations.jsonl`

### Regex Safety
- Trigger patterns validated against ReDoS before compilation ([Bug #12, v4.3.1])
- Patterns with nested quantifiers or catastrophic backtracking are rejected
- Maximum pattern length enforced

### File Safety
- Atomic writes: temporary file + rename pattern on all JSON/JSONL data files
- File locking via `fcntl.flock` (Unix) with graceful fallback on Windows
- Lock files with 1-hour stale detection (dream cycle)
- Restrictive permissions (`chmod 600`) on all data files containing learned patterns

### Upgrade Safety
- Installer detects existing installation and creates timestamped backup
- User data files (`_instincts-index.json`, `_passive-rules.json`, `_projects.json`, `_operator-state.json`) are preserved on upgrade — never overwritten
- `--force-update` flag required to explicitly reset data files
- `CLAUDE.md` is never overwritten if it exists
- `settings.json` hooks are never overwritten (manual merge documented)

### Input Validation
- Observation text sanitized before storage
- Instinct injection limited to 500 characters with blocked shell patterns
- Unicode support in Jaccard similarity (dream cycle duplicate detection)
- Contradiction detection uses 7 opposing keyword pairs (EN+ES) to prevent conflicting instincts

## Running Security Tests

Sinapsis includes 52+ automated tests across 4 test suites. To run security-specific tests:

```bash
# Security tests (command injection, ReDoS, secret scrubbing)
bash tests/test-security.sh

# Installation and upgrade safety tests
bash tests/test-install-upgrade.sh

# Dream cycle tests (index integrity, lock files, atomic writes)
bash tests/test-dream.sh

# End-to-end integration tests
bash tests/test-e2e-dream.sh

# Reflection orchestrator tests
bash tests/test-reflection-orchestrator.sh

# Run ALL tests
for f in tests/test-*.sh; do bash "$f"; done
```

### Test Coverage by Security Area

| Area | Test Suite | Tests |
|------|-----------|-------|
| Command injection prevention | `test-security.sh` | 3 tests |
| ReDoS protection | `test-security.sh` | 3 tests |
| Secret scrubbing | `test-security.sh` | 5 tests |
| Upgrade data preservation | `test-install-upgrade.sh` | 14 tests |
| File locking & atomic writes | `test-dream.sh` | 4 tests |
| Index integrity | `test-e2e-dream.sh` | 15 tests |
| Orchestrator logic | `test-reflection-orchestrator.sh` | 16 tests |

## Security Audit History

| Date | Auditor | Version | Findings | Status |
|------|---------|---------|----------|--------|
| 2026-04-08 | Fersora (Fernando Montero) | v4.3.0 | 22 bugs + 6 vulnerabilities | All resolved in v4.3.1 |

Full audit details in [CHANGELOG.md](CHANGELOG.md) under v4.3.1.

## Hardening Recommendations for Users

1. **Keep Sinapsis updated** — run `git pull` and re-run the installer regularly
2. **Review instinct proposals** before accepting — use `/analyze-session` to inspect what the learning engine proposes
3. **Don't store secrets in project files** — Sinapsis scans for them, but prevention is better than detection
4. **Run `/cso-audit`** periodically on your projects — it checks OWASP Top 10, STRIDE, and supply chain risks
5. **Use `/dream`** to maintain index hygiene — removes duplicates, contradictions, and stale patterns
