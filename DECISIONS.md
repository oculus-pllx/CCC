# CCC Architecture Decisions

Durable decisions and the reasoning behind them. Append; don't rewrite history.
Session-local state belongs in `.claude/HANDOFF.md` (untracked), not here.

---

## 2026-07-29 — Agent config drift is fixed at the provisioner, never by hand

**Context.** Four managed accounts (`oculus`, `prime`, `terminus`, `ollama`) had
diverged: a plugin explicitly disabled on one, `model` missing on two,
`autoCompactWindow` missing or stale everywhere. Hand-repairing the four files
would have left the cause in place.

**Decision.** Every agent-config value is owned by
`install/ccc-provision-workstation.sh`. Hand edits to a managed file are a bug
report about the provisioner, not a fix.

**Consequence.** Repairs land via commit → push → `sudo ccc-self-update`, which
applies them to all four accounts at once. Nothing is patched in place.

---

## 2026-07-29 — A write guarded on *missing* cannot repair anything

**Context.** Three unrelated defects turned out to share one shape:

| Site | Guard | Why it never healed |
|---|---|---|
| `enabledPlugins` merge | `ep.setdefault(k, True)` | `setdefault` never overwrites, so a stray `false` survived every run |
| statusline script | `if [[ ! -f … ]]` | file existed, so a stale 200000 context fallback was permanent |
| superpowers clone | `[[ ! -d "$cache/superpowers" ]]` | parent existed, so a bumped version pin never re-cloned |

**Decision.** Distinguish the two categories explicitly, and say which in a
comment at each site:

- **Managed content** — assignment, rewritten every run. Anything whose correct
  value the provisioner defines: the statusline script, the terse output style,
  plugin enablement.
- **Preference** — `setdefault`, written once. Anything a user may legitimately
  change and keep: `outputStyle`, `model`.

When a guard tests existence, it must test the *exact* thing whose absence
implies work is needed — the versioned directory, not its parent.

---

## 2026-07-29 — `autoCompactWindow` is a window size, not a trigger point

**Context.** Set to 150000 fleet-wide, which fired compaction at 11.7% of the
context window. The name reads like a trigger, so a "raise it" request has no
obvious correct number.

**Decision.** Value is **833000**. Semantics were read out of the Claude Code
2.1.220 binary, not guessed: the trigger is `window − 20000 (output reserve) −
13000 (headroom)`. 833000 therefore fires at 800000 = 80% of Opus 5's 1M window.

**Consequence.** The merge is **raise-only** — a machine tuned higher keeps its
value, while stale low ones get repaired. Any future model-family change to the
context size makes this number wrong; it is derived, not arbitrary, so re-derive
rather than scale it.

---

## 2026-07-29 — Python tooling installs through `uv`, never `pip install --user`

**Context.** Aider could not install for any account. Root cause was PEP 668:
Ubuntu 24.04 ships `/usr/lib/python3.12/EXTERNALLY-MANAGED`, so pip refuses to
touch the system interpreter and fails unconditionally.

**Decision.** Python-based tools in the catalog install via `uv tool install`,
which builds an isolated venv per tool and puts the launcher in `~/.local/bin`.
Aider additionally needs `--with pip` because it shells out to pip at runtime.

**Consequence.** `~/.local/bin` is a legitimate path for non-npm tools. The
`TestProviderNPMToolsUseSharedPrefix` sweep is scoped to npm specs so it does not
false-positive on them.

---

## 2026-07-29 — Response shaping goes in an output style, not `CLAUDE.md`

**Context.** Request was for terser, more direct responses, and separately for
whether superpowers could be reimplemented as `.md` directives to save context.

**Measurement.** Superpowers costs ~1.9K tokens/session resident (a ~3KB
SessionStart primer plus 14 skill descriptions); the 114KB of skill bodies load
lazily on invocation. `CLAUDE.md` loads **in full, every session**.

**Decision.** Keep superpowers as a plugin. Put response-shaping instructions in
`~/.claude/output-styles/terse.md` and point `outputStyle` at it.

**Rationale.** An output style *replaces* the response-shaping layer rather than
adding resident tokens, so it is roughly free. Moving even one skill into
`CLAUDE.md` would cost more than the whole plugin does now.

**Trap.** `keep-coding-instructions: true` is mandatory. Without it Claude Code
treats an output style as a replacement for the software-engineering system
prompt, not an addition to it.

---

## 2026-07-30 — One superpowers version on disk, pinned by explicit edit

**Context.** The registry pinned 5.1.0 on all four accounts while newer trees sat
beside it unused, because the registry generator picked `vdirs[0]` —
lexicographically first, not newest. That sort is wrong in general: it ranks
`10.0.0` below `5.1.0`.

**Decision.** Pin an explicit version (`sp_version`, currently 6.2.0) so a bump
is a deliberate edit that lands everywhere at once. The registry selects the
newest directory by numeric component. Superseded trees are pruned.

**Safety.** Pruning is gated on the pinned tree having a readable
`.claude-plugin/plugin.json`, so a failed or half-finished clone prunes nothing
and never leaves an account without a working plugin.

---

## 2026-08-10 — Agent instruction *content* lives in `oculus-configs`, not this repo

**Context.** This repo owns the provisioner; the global `CLAUDE.md`, `rules/*.md`,
and `mcp.json` it distributes live in `oculus-pllx/oculus-configs`, cloned to
`/opt/oculus-configs`. The provisioner runs `git reset --hard origin/$REF` on every
pull, so an edit made in place there is destroyed on the next update.

**Decision.** Instruction content changes are committed to `oculus-configs` and
deployed with `sudo ccc-sync-agent-configs --all-users`. Provisioner *mechanism*
changes are committed here and deployed with `sudo ccc-self-update`.

**Trap (fixed 2026-08-10, `7ec40b2`).** `ccc-sync-agent-configs` used to default
to a **single** account, so a bare run silently left three of four on stale
content — while every doc and MOTD line told users to run the bare form. The
default is now every managed account; `--user` narrows and `--all-users` is an
accepted no-op alias.

---

## 2026-08-10 — A shared UI baseline is accessibility, not a design system

*Superseded the same-week decision to make Material Design 3 the global default
(`64b5ecf`); corrected in `ba1fc40`.*

**Context.** Request was for a shared UI baseline usable from project or global
instructions. It named "Google Layout", which is not a system Google ships. I
mapped that to Material Design 3 and shipped all of M3 as the global default.

**Why that was wrong.** M3 is Google's *house style* — tonal palettes, surface-tint
elevation, FAB/nav-rail component vocabulary — not a neutral summary of best
practices. `@`-included on every account, it nudged every project toward looking
like a Google product without anyone having chosen that, including projects with
their own design language. The applicability gate limited *when* it applied, but
not *what* it imposed once it did.

**Decision.** Split by what is universal versus what is a house style:

| | File | Loaded |
|---|---|---|
| Universal | `rules/ui-baseline.md` — WCAG AA contrast, focus indicators, target size, reduced motion, labels, keyboard reachability, tokens-not-hardcoded, break on container width | `@`-included, always |
| House style | `rules/ui-material3.md` — the full M3 spec | synced, read on request only |

The baseline explicitly declares **no default design system** and says to ask
before adopting one, because that is a product decision visible to every user.

**Test for anything added to global instructions.** Would a competent engineer on
a project that never heard of this call it *wrong*, or merely *different*? Only
the first belongs in a default. Accessibility fails that test as wrong; a type
scale is merely different. Resident cost fell 5,063 B → 2,432 B as a side effect,
which is the usual sign the line was drawn in the right place.

---

## 2026-08-10 — The safe default is the widest one, for a fleet-wide sync tool

**Context.** Three defects in `ccc-sync-agent-configs` shared a root: the tool's
default was narrower than its documented purpose. A bare run synced one account;
the docs, MOTD, and every runbook said to run it bare.

**Decision.** A tool whose job is "keep the fleet consistent" defaults to the
whole fleet. Narrowing is the flag, not the default. Where that widens blast
radius, tighten *enumeration* instead of falling back to a narrow default — this
one now enumerates members of `$CCC_SHARED_GROUP` rather than every UID ≥ 1000.

**Corollary — `set -euo pipefail` turns `getent` into a silent killer.** `getent`
exits non-zero on a missing key. Inside `x="$(getent … | cut …)"` that fails the
pipeline, and `set -e` aborts *before* the next line can report why. Two paths
were dead because of it: the missing-group fallback, and the `Unknown user`
message (`--user nosuchuser` exited 2 with no output). Every such capture takes
its own `|| x=""`. Same hazard with `ls` in a prune pipeline when nothing matches
— hence `|| true`.

**Corollary — never fan out inside a pipeline.** The old loop was
`getent … | while read user; do …; done`, so a failed account vanished into the
pipeline's exit status and a partial sync looked clean. Collect failures in an
array, name them, exit non-zero.

---

## 2026-08-10 — Cleanup must not be gated behind the change it cleans up after

**Context.** `backup_file` skips when content is identical (added 2026-07-29 to
stop backup accumulation), then prunes to the 3 newest. The prune sat *after* the
skip's early return, so it ran only when a snapshot was taken. Files that had
stopped changing kept their entire pre-fix backlog permanently — 368 backups
across four accounts, none reachable by any later run.

**Decision.** Make the *action* conditional and the *cleanup* unconditional. A
retention policy that only runs on write is not a retention policy.

**Consequence.** 368 → 40 (3 each for `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, plus
`settings.json`). This is the same shape as the 2026-07-29 entry above: a guard
placed so that the broken state is exactly the state that prevents repair.

---

## 2026-08-11 — Never mock the contract you are trying to verify

**Context.** The statusline read `.context.used` / `.context.max` from Claude
Code's payload. Those keys have never existed; the real ones are
`.context_window.used_percentage`, `.total_input_tokens`, and
`.context_window_size`. Every account displayed `ctx:0%` for as long as the
feature has existed.

**Why no test caught it.** There *was* a behavioural test — and it stubbed `jq`
with a fake that answered `.context.used` and `.context.max`. The mock was
written from the same wrong assumption as the code, so the two agreed and the
suite stayed green. A mock of an external contract can only ever confirm what
its author already believed.

**Decision.** For an external payload, test against a **recorded real sample**,
not a hand-written mock. The statusline test now runs actual `jq` over a payload
captured from a live 2.1.227 session (temporarily teeing the statusline's stdin),
and covers the derive path, an unparseable payload, and a host without `jq`.
Mocks stay legitimate for things we own; for a schema someone else defines, the
sample is the only honest source.

**Corollary — `set -euo pipefail` again.** `jq` exits non-zero on unparseable
input, which killed the script before its `echo`, so the statusline vanished
instead of degrading. Same shape as the `getent` entry above. Any capture from an
external parser takes its own `|| x=` fallback, and numeric fields are
range-checked before arithmetic — `[[ $x -le 0 ]]` on a non-numeric string is
itself fatal under `set -e`.

**Consequence.** Fixed across `1ad7ace` (schema) and `c2f99f0` (robustness +
honest test). `1ad7ace` was pushed with the suite red, which is how the two stale
assertions surfaced.

---

## 2026-08-11 — A managed directory is a mirror, not a merge

**Context.** `ui-material3.md` was deleted from `oculus-configs`. It stayed on all
four accounts anyway. `copy_optional_dir` is `cp -a "$src"/. "$dest"/` — purely
additive, so a file retired upstream is never removed. It remained readable and
`@`-includable while being invisible to anyone reviewing the source repo. Every
rule ever shipped was still resident.

**Decision.** A directory the provisioner *owns* is mirrored: `mirror_managed_dir`
deletes top-level destination files with no counterpart in the source. Applied to
`claude/rules` only. `copy_optional_dir` stays for everything else, because
`~/.claude/plugins` holds the cloned plugin cache alongside the synced files and a
mirror would delete it as retired. Which helper a call site uses is the statement
of whether the provisioner owns that directory outright.

**Guards, both against the same failure — emptying every account at once.** A
missing source dir skips, as before. An *empty* source dir also skips: git does not
track empty directories, so that state means a partial checkout or a bad ref, never
a mass retirement. Deletion is `-maxdepth 1 -type f`, so subdirectories are never
touched.

**Consequence.** `f8ffcad`. Verified against a real-shaped tree before shipping,
per the destructive-logic convention below: retired file gone, current file kept,
subdirectory untouched, missing and empty sources both no-ops.

---

## Testing conventions

- `tests/container-code-companion-static.sh` asserts on provisioner source text.
  Helpers use `grep -F` — **fixed strings, not regex**. Escaping a pattern breaks
  the assertion silently.
- Both helpers pass `--` to grep. Without it a pattern starting with a dash is
  parsed as an option, and the resulting usage error makes
  `require_file_not_contains` pass vacuously.
- Go code under `internal/system` has full `go test` infrastructure — use TDD.
  `web/app.js` has none; verify browser behavior with Playwright instead and
  record it as a deliberate exception.
- Destructive logic (anything looping `rm -rf` across home directories) gets a
  dry run against a fake tree, including the failure cases, before it ships.
