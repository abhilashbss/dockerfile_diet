# Dockerfile Autoresearch — Operating Protocol

A Karpathy-style ratcheting loop for shrinking a project's Docker image. The
framework is stack-agnostic; candidate Dockerfiles are stack-specific and live
in `candidates/`. The mutable artifact during a run is one file: `Dockerfile`.
Everything else (`smoke_test.sh`, `score.sh`, `loop.sh`, `program.md`,
`config.env`, `.dockerignore.repo`) is frozen.

The loop is driven by `loop.sh`, which walks `candidates/queue.tsv` and
applies, scores, and judges each candidate Dockerfile autonomously. Run
`./loop.sh` once and it iterates until a stop condition fires.

Per-project knobs (`APP_NAME`, `MASTER_BRANCH`, `HOST_PORT`, `CONTAINER_PORT`,
`READY_TIMEOUT`, stop thresholds) live in `config.env`, sourced by both
`score.sh` and `loop.sh` on every run. Inline env vars override.

## The artifact under test

`./Dockerfile` — built with the **repo root** (the parent directory) as the build context:

```
docker build -f dockerfile_autoresearch/Dockerfile -t guidezy:<tag> .
```

This is enforced by `score.sh`. The `.dockerignore` at the repo root keeps
`node_modules/`, `.next/`, `dockerfile_autoresearch/`, and other host-only junk
out of the build context.

## The contract

`smoke_test.sh` is the frozen acceptance test. The container PASSES iff:

1. It starts and stays up for the duration of the test.
2. It listens on `0.0.0.0:3000` (or whatever `PORT` is exported in the harness).
3. `GET /` returns HTTP 200 within the readiness window (default 60s).

The smoke test does not care **how** the container achieves this. Distroless,
scratch, static-linked Node, custom builds — all on the table, as long as
the contract holds.

## Score harness

`./score.sh` does the full loop:

1. `docker build -f Dockerfile -t guidezy:autoresearch ..` (context = repo root)
2. `docker run -d -p HOST_PORT:3000 guidezy:autoresearch`
3. Wait for readiness, run `smoke_test.sh`
4. Measure final image size via `docker image inspect`
5. Print exactly one final line:

   ```
   RESULT=PASS SIZE=123456789 BUILD_S=183 TOTAL_S=205 STARTED=2026-05-01T07:53:21Z
   ```

   - `RESULT` is one of `PASS`, `FAIL_BUILD`, `FAIL_BOOT`, `FAIL_SMOKE`.
   - `SIZE` is the image size in bytes (or `0` if no image was produced).
   - `BUILD_S` is wall-clock build duration in seconds.
   - `TOTAL_S` is wall-clock total script duration in seconds (build + boot + smoke + cleanup).
   - `STARTED` is the script's start time, ISO 8601 UTC.

   On `FAIL_*`, the script also dumps the last ~200 lines of container logs
   above the result line so we can diagnose without re-running.

Parse the final `RESULT=...` line — earlier lines are diagnostics.

The harness also writes the same fields to `dockerfile_autoresearch/last_run.env`
as `KEY=value` pairs, so the loop driver can `source last_run.env` instead of
parsing stdout. `last_run.env` is gitignored — it's per-run scratch, not
part of the audit trail.

## The driver: loop.sh

`loop.sh` is the autonomous orchestrator. Per queue row:

1. If `autoresearch/<tag>` already has a row in `results.csv`, skip (idempotent).
2. `git checkout main`, restore `Dockerfile` to current best, create
   `autoresearch/<tag>`, copy `candidates/<tag>.Dockerfile` over `Dockerfile`.
3. Wipe `last_run.env`, run `./score.sh`.
4. `source last_run.env`. Compute `size_mb` and `delta_vs_best_mb`.
5. Decide:
   - **PASS and `SIZE` < current best:** commit Dockerfile on the experiment
     branch, `git merge --no-ff` to `main`. Update current best. `kept=yes`.
   - **PASS but `SIZE` ≥ best:** delete branch, restore Dockerfile. `kept=no`.
   - **FAIL_\*:** delete branch, restore Dockerfile. `kept=no`.
6. Append row to `results.csv`, commit it on `main` (durable audit trail).
7. Check stop conditions; halt if any trigger.

Adding a new hypothesis is two file changes — drop
`candidates/<tag>.Dockerfile` and append to `candidates/queue.tsv`. Re-run
`./loop.sh`; old rows are skipped, the new one runs.

## Ratchet rules

1. **One coherent hypothesis per branch.** Branch name: `autoresearch/<short-tag>`.
   Tag is a kebab-case noun phrase, e.g. `slim-base`, `multi-stage`,
   `next-standalone`, `distroless-runner`.
2. **Edit only `Dockerfile`.** `score.sh`, `smoke_test.sh`, `.dockerignore`,
   `program.md`, and `results.csv` (header) are frozen. The repo's `app/`
   sources, `package.json`, and `package-lock.json` are also frozen — we are
   shrinking the runtime, not changing the application.
3. **After each edit, run `./score.sh`** and record the result.
4. **Append every experiment to `results.csv`** — passes, failures, and rejected
   wins. The CSV is the audit trail.
5. **Merge to master only when** `RESULT=PASS` **and** `SIZE` strictly beats
   the current best (lower is better). Master is sacred and only moves forward.
6. On reject (FAIL or no improvement), `git checkout master` and try a different
   hypothesis. Do not patch a failing branch into the next one — keep hypotheses
   isolated.
7. If a constraint genuinely blocks a real win (e.g. need to touch
   `next.config.ts`), log a `BLOCKED` row in `results.csv` with a one-line note
   explaining what would have been tried, and move on. Do not work around the
   constraint silently.

## results.csv schema

```
exp_id,branch,started_at_utc,hypothesis,result,size_mb,size_bytes,build_seconds,total_seconds,delta_vs_best_mb,kept,notes
```

- `exp_id`: zero-padded sequence, e.g. `exp_0007`.
- `branch`: `autoresearch/<tag>` or `master` for the baseline.
- `started_at_utc`: ISO 8601 UTC, copied from the harness's `STARTED=` field.
- `hypothesis`: one-line description of what this experiment changes vs. master.
- `result`: `PASS`, `FAIL_BUILD`, `FAIL_BOOT`, `FAIL_SMOKE`, `BLOCKED`.
- `size_mb`: human-readable, 2 decimals. Empty for non-PASS.
- `size_bytes`: raw integer from `docker image inspect`. Empty for non-PASS.
- `build_seconds`: wall-clock seconds from harness's `BUILD_S=` field.
- `total_seconds`: wall-clock seconds from harness's `TOTAL_S=` field.
- `delta_vs_best_mb`: signed delta against current master best. Negative = win.
- `kept`: `yes` if merged to master, `no` otherwise.
- `notes`: short free-text. For FAILs, the diagnosis from the logs.

## Stop conditions

Stop and summarize when any of:

- 5 consecutive FAILs with the same root cause.
- 10 consecutive experiments with no improvement over current best.
- Current best below 30 MB.
- The user says stop.

## Summary format on stop

```
Total experiments: N
Kept wins: K
Baseline -> final: A.AA MB -> B.BB MB (-X.XX MB, -Y.Y%)
Top 3 wins by size delta:
  1. <tag>  -A.AA MB  (<one-line hypothesis>)
  2. <tag>  -A.AA MB  (<one-line hypothesis>)
  3. <tag>  -A.AA MB  (<one-line hypothesis>)
```

## Commit message convention

```
<tag>: <one-line hypothesis>
```

Examples:

- `slim-base: switch FROM node:22 -> node:22-slim`
- `multi-stage: separate deps/build/runtime, drop dev deps in runtime`
- `next-standalone: enable Next.js standalone output, drop node_modules from runtime`
- `distroless-runner: gcr.io/distroless/nodejs22-debian12 as runtime stage`
