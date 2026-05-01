# dockerfile-autoresearch

A Karpathy-style ratcheting loop that autonomously shrinks a project's Docker
image. You drop the framework next to any repo, queue a few candidate
Dockerfiles, and run `./loop.sh`. The loop tests each candidate, keeps only
strict size wins, ratchets `main` forward on every win, and records every
experiment — passes, fails, and rejected wins — in an append-only audit trail.

The result on one Next.js app: **2,072 MB → 237 MB in 7 min of compute**, every
candidate landed, full git history of every hypothesis. See
[`results.example.csv`](./results.example.csv) for the actual run log.

## What's in the box

```
dockerfile_autoresearch/
├── program.md                # protocol: contract, ratchet rules, schema, stop conditions
├── README.md                 # this file
├── config.env                # per-project knobs (APP_NAME, MASTER_BRANCH, ports, timeouts)
├── loop.sh                   # autonomous driver — walks the queue, ratchets MASTER_BRANCH
├── score.sh                  # build + run + smoke + measure harness
├── smoke_test.sh             # frozen acceptance contract (HTTP 200 on /)
├── Dockerfile                # mutable artifact under test (== current best on MASTER_BRANCH)
├── .dockerignore.repo        # installed at repo root by score.sh on first run
├── results.csv               # audit log — empty until you run loop.sh; appended on each experiment
├── results.example.csv       # one real run from a Next.js app (2,072 MB → 237 MB) — receipts
├── last_run.env              # scratch — last score.sh result (gitignored)
└── candidates/
    ├── queue.tsv             # ordered list: tag <TAB> hypothesis
    └── *.Dockerfile          # one per row in queue.tsv (Next.js examples ship by default)
```

The framework — `loop.sh`, `score.sh`, `smoke_test.sh`, `program.md`,
`config.env`, the queue mechanic — is **stack-agnostic**. The candidate
Dockerfiles in `candidates/` are **Next.js-specific examples** that ship with
the repo as a working starting point. For another stack, replace them.

## Quickstart

```bash
# 1. Drop this directory next to your repo's source tree.
#    Build context is the parent dir (your repo root).
cp -r dockerfile_autoresearch /path/to/your/repo/

# 2. Edit config.env: set APP_NAME, MASTER_BRANCH if it isn't `main`,
#    and HOST_PORT/CONTAINER_PORT if your app doesn't listen on 3000.

# 3. Make sure Docker Desktop is running.

# 4. Run the loop.
cd /path/to/your/repo/dockerfile_autoresearch
chmod +x loop.sh score.sh smoke_test.sh
./loop.sh
```

That's it. Walk away. The loop:

- Auto-commits the autoresearch scaffolding to `MASTER_BRANCH`.
- For each row in `candidates/queue.tsv`: branches off `MASTER_BRANCH`, swaps
  in `candidates/<tag>.Dockerfile`, runs `score.sh`, decides.
- **PASS + size strictly beats current best:** commits on the experiment
  branch, `git merge --no-ff` to `MASTER_BRANCH`, updates current best.
- **PASS but no improvement, or any FAIL_*:** deletes the experiment branch,
  restores `Dockerfile` to current best.
- Appends a row to `results.csv` and commits it on `MASTER_BRANCH` (audit trail).
- Halts on stop conditions (see `program.md`) and prints a summary.

To halt mid-run: `touch STOP` in this dir from another shell.

To resume after halt or crash: re-run `./loop.sh`. Already-recorded experiments
are skipped; the loop picks up where it stopped.

## Adapting to your stack

The candidates in `candidates/` assume a Node.js / Next.js project that builds
with `npm run build` and serves with `next start`. To use this framework on a
different stack:

1. **Define your contract in `smoke_test.sh`.** Default is `GET / → 200` within
   60s. If your app needs a JWT, a database, or a different ready endpoint,
   that goes here. This file is otherwise frozen during a run.
2. **Write candidates.** Each one is a `<tag>.Dockerfile` in `candidates/` that
   builds and runs your app. Build context is the repo root.
3. **List them in `candidates/queue.tsv`** — one row per candidate, ordered
   cheap-wins-first. Format: `<tag><TAB><one-line hypothesis>`.
4. **Set `APP_NAME` in `config.env`** so image tags and container names don't
   collide with other projects on your machine.

That's the entire adaptation surface. Everything else is generic.

## What gets logged

Every experiment appends one row to `results.csv`:

```
exp_id, branch, started_at_utc, hypothesis, result, size_mb, size_bytes,
build_seconds, total_seconds, delta_vs_best_mb, kept, notes
```

`kept=yes` rows form the master ratchet timeline. `result` is one of `PASS`,
`FAIL_BUILD`, `FAIL_BOOT`, `FAIL_SMOKE`, `BLOCKED`. `score.sh` also writes
`last_run.env` (machine-readable `KEY=value`) for any helper script that
needs the last result without parsing stdout.

## Hypothesis backlog (Next.js examples)

| order | tag                    | hypothesis                                                                 |
| ----- | ---------------------- | -------------------------------------------------------------------------- |
| 1     | slim-base              | `node:22` → `node:22-slim` (slim Debian, ~250 MB base vs ~1.1 GB)          |
| 2     | alpine-base            | `node:22-alpine` (musl) + `libc6-compat` for native modules                |
| 3     | multistage-slim        | multi-stage on slim — runtime carries only prod deps + `.next` + `public`  |
| 4     | multistage-alpine      | multi-stage on alpine                                                      |
| 5     | standalone-slim        | Next.js `output: 'standalone'` — runtime drops `node_modules` entirely     |
| 6     | standalone-alpine      | standalone bundle on alpine                                                |
| 7     | distroless-standalone  | `gcr.io/distroless/nodejs22-debian12:nonroot` over standalone bundle       |

Replace these with candidates for your stack and the loop runs the same way.

## Stop conditions

From `config.env` (overridable inline):

- 5 consecutive `FAIL_*` of the same kind → halt
- 10 consecutive non-improvements → halt
- Current best below 30 MB → halt
- `STOP` file present → halt at next iteration boundary
- All queue rows recorded → halt

On halt, the loop prints a summary: total experiments, kept wins,
baseline → final size, top wins by delta.

## License & origin

The pattern is from Karpathy's "autoresearch" framing — pick one mutable
artifact, freeze a binary contract, ratchet the artifact only on strict wins,
log everything. This repo is a generic, runnable instance of that pattern
specialized for Docker images.
