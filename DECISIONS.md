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
