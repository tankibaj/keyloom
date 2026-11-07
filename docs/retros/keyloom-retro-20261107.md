# Keyloom MVP session retro
**Date:** 2026-11-07 | **Repo:** keyloom | **Source:** current session (harnex run started 2026-11-07 00:48) | **Status:** Proposals only, nothing applied

Repo guardrails found: no CLAUDE.md, no AGENTS.md, no `.claude/rules/`, no pre-commit hook, no CI config. `~/.harnex/metrics.jsonl` has no record for this run yet. All candidates below are therefore new.

## Candidates (most severe first)

### 1. [automated check] Dev builds default to the real library
- **Evidence:** a stray second app instance (macOS "Quit & Reopen" after the permission grant) opened `~/Library/Application Support/Keyloom/`, which holds the user's snippet `hello ::he`, and migrated it to schema v5. `Keyloom/UI/DataLocation.swift:16` avoids the default directory only when `--keyloom-data-dir` is passed.
- **Cost:** risk to real data; one backup written to the library's `Snapshots/`.
- **Change:** `DataLocation.resolve()` uses a separate `Keyloom-Dev` directory for any build that is not Developer-ID signed, with a unit test in `KeyloomTests/UI`.
- **Effort:** S

### 2. [review rule / automated check] "Implemented but not wired" escaped every worker's loop
- **Evidence:** the gate review's 5 MUST-FIX were all integration gaps: `localChangesCommitted` and `accountMayHaveChanged` had no callers, launch awaited the network, a single-consumer change stream, a stale editor overwrote remote edits, `AssistanceService` was unreachable from the UI.
- **Cost:** one fix round, about 60 min, 3 workers.
- **Change:** (a) a mechanical `scripts/orphans.sh` that lists `Keyloom/` symbols whose only callers are in `KeyloomTests/`, run by the gate; (b) a plan rule that each WP's done check includes a test through `AppEnvironment` (the composition root).
- **Effort:** M

### 3. [automated check / navigation] No single check command and no CLAUDE.md
- **Evidence:** two build breaks at merge seams (`SyncStatus` and `UnavailableReason` name clashes; `recordUsage` calling a removed continuation), found only by a manual suite run. Workers rediscovered the same quirks repeatedly: the `TEST_RUNNER_` prefix for test env vars, BSD sed lacking `\b`, UI tests needing `-scheme KeyloomUITests` and exactly one Keyloom process, a separate `-derivedDataPath` per worker.
- **Cost:** about 10 min per break, plus a worker rediscovering each quirk.
- **Change:** `scripts/check.sh` (build plus unit suite with the grep filter) and a short repo `CLAUDE.md` holding the commands and these quirks. Optionally a pre-merge hook.
- **Effort:** S

### 4. [tool economy] The full suite ran about 15 times
- **Evidence:** the orchestrator ran it after each of about 9 merges, the validator ran it 3 times, and each worker ran its own. Naim objected twice.
- **Cost:** about 30 s per run plus agent minutes; mostly user trust.
- **Change:** a rule in the repo `CLAUDE.md` and the delegation template: one full suite at the end, `-only-testing:<Class>` while working. `scripts/check.sh` takes a class argument.
- **Effort:** S

### 5. [harnex issue] Tool preflight is missing
- **Evidence:** the plan promised Claude computer use; it was found unavailable only after a UI reviewer run, forcing a replan to scripted XCUITest.
- **Cost:** about 20 min and one agent run.
- **Change:** the harnex flow checks the tools it needs (computer use, Automation permission, Screen Recording) at brief time and asks up front.
- **Effort:** M (harnex, propose only)

### 6. [harnex issue] Big-context workers were resumed for new tasks
- **Evidence:** the WP4 worker (about 540k tokens, 54% context) was resumed for the integration pass, the fix rounds and the XCUITest task; the last one was killed and replaced.
- **Cost:** slow turns and the extra spend Naim flagged.
- **Change:** the orchestrator starts a fresh implementer for each new task and resumes a worker only for a fix round on its own WP.
- **Effort:** S (harnex)

### 7. [harnex issue] UI reviewed before the UI was frozen
- **Evidence:** the icon picker changed after the screenshot journeys started, so J1 and J10 screenshots went stale; the library window clipped at narrow widths only once Writing Assistance was enabled.
- **Cost:** re-shoots, about 30 min.
- **Change:** a UI-freeze step before the UI/UX review, and the review config states the minimum, default and large window sizes up front.
- **Effort:** S (harnex)

## Not checked
- CI (none configured).
- The transcript file was not read; this retro comes from the live session.
