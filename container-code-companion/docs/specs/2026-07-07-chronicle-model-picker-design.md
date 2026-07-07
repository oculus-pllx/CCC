# Claude Chronicle — Dashboard Model Picker

**Date:** 2026-07-07
**Status:** Approved pending user review

## Goal

Let the user choose which Claude model runs each of Chronicle's two LLM stages —
**extract** and **synthesize** — from the CCC dashboard, instead of editing
`.env` or being locked to the built-in defaults. This is the follow-on to the
deferred "provider dropdown + `--limit`" note in the
[chronicle-dashboard-page spec](./2026-07-06-chronicle-dashboard-page-design.md);
it builds the **model** controls only (provider and `--limit` stay deferred).

**Motivating failure.** The synthesize stage defaults to `claude-fable-5`, whose
account limit is easy to hit; a rate-limited run fails the whole harvest. The
picker lets the user switch the synthesize stage to e.g. `claude-sonnet-5` for
that run without touching config on disk. (Chronicle already surfaces the real
"You've reached your Fable 5 limit… switch models" message rather than a bare
`exit 1`, so the user knows why to switch.)

## Scope

**v1 (this spec):** two model dropdowns on the Chronicle page — one for the
extract stage, one for the synthesize stage — passed through to `chronicle run`
as new `--extract-model` / `--synthesize-model` flags. Each dropdown offers a
curated Claude list plus a **Default** choice.

**Out of scope (still deferred):** the provider dropdown and the `--limit` field.
Provider stays `claude-cli` (the dashboard's only supported login path); `--limit`
is an operator concern, not a per-run dashboard control. The run-launch arg list
stays easy to extend for them later.

## Curated model list

A single source-of-truth list, shared in spirit across the three layers (each
layer re-declares it in its own language — no cross-repo import):

| Dropdown label | Value passed |
|---|---|
| Default | *(none — flag omitted)* |
| Sonnet 5 | `claude-sonnet-5` |
| Fable 5 | `claude-fable-5` |
| Opus 4.8 | `claude-opus-4-8` |
| Haiku 4.5 | `claude-haiku-4-5` |

**Default semantics.** "Default" means *do not pass the flag*; Chronicle then
applies its own per-provider stage default (`resolve_models` →
`claude-sonnet-5` extract, `claude-fable-5` synthesize). Default is the
pre-selected option in both dropdowns, so the picker is purely additive: a user
who ignores it gets exactly today's behavior.

## Layer 1 — Chronicle CLI (`Chronicle` repo)

Add two optional flags to `chronicle run`:

```
--extract-model MODEL       model for the extract stage (overrides EXTRACT_MODEL)
--synthesize-model MODEL    model for the synthesize stage (overrides SYNTHESIZE_MODEL)
```

- `cli.py`: add the two `run_p.add_argument(...)` calls (default `None`).
- `resolve_cfg(env, provider_override, extract_model=None, synthesize_model=None)`:
  when a flag is given, `replace()` it onto the `Config` **before** calling
  `resolve_models`, so an explicit flag wins over env and over the built-in
  default. When `None`, behavior is unchanged.
- `main()` passes `args.extract_model` / `args.synthesize_model` into `resolve_cfg`.

No validation of the model string in Chronicle itself — an unknown model simply
fails the `claude -p` call and surfaces through the existing `ProviderError`
path. (The allowlist boundary that matters is in CCC; see Layer 2 / Security.)

**Tests (`tests/test_cli.py`):** a flag overrides the env/default for that stage;
omitting a flag leaves the resolved model unchanged; the other stage is
unaffected when only one flag is passed.

## Layer 2 — CCC Go backend (`CCC` repo)

`StartChronicleRun` gains two parameters and validates them against an allowlist
before they ever reach the shell:

```go
func StartChronicleRun(extractModel, synthesizeModel string) (CommandResult, error)
```

- `chronicleRunArgs(extractModel, synthesizeModel string) ([]string, error)` —
  a new pure helper (mirrors `buildPublishArgs`) that returns
  `["run", "--extract-model", X, "--synthesize-model", Y]`, omitting each flag
  when its value is empty (Default). It rejects any non-empty value not in the
  allowlist set (`claude-sonnet-5`, `claude-fable-5`, `claude-opus-4-8`,
  `claude-haiku-4-5`) with a clear error. This keeps the allowlist and the
  arg-building in one testable place.
- The detached-command string appends each `shellQuote`'d flag+value. Empty
  Default → nothing appended → identical to today's command.
- `server.go`: the `ChronicleRun` config field becomes
  `func(extractModel, synthesizeModel string) (system.CommandResult, error)`;
  `handleChronicleRun` decodes an optional JSON body
  `{ "extractModel": "...", "synthesizeModel": "..." }` (both default `""`) and
  passes them through. A validation error from `chronicleRunArgs` is returned as
  `ExitCode!=0 + Output` (same shape as the missing-binary case), so the browser
  shows it in the run console without a special path.

**Defense in depth.** Two independent guards: the allowlist (rejects anything
off-list) *and* `shellQuote` (neutralizes shell metacharacters even if the list
ever grows a funny value). Neither alone is trusted.

**Tests (`chronicle_test.go` / server test):** `chronicleRunArgs` — both Default →
bare `["run"]`; one/both set → correct flags; an off-list value → error; a value
containing shell metacharacters → error (never reaches quoting). Handler test:
posted models flow into the injected `chronicleRun` fn; invalid → non-zero result.

## Layer 3 — CCC web UI (`CCC` repo)

In `renderChronicle`, add two `<select>` controls in the existing `.action-row`
ahead of the **Run Chronicle** button:

```
[ Extract model ▾ ]  [ Synthesize model ▾ ]  [ Run Chronicle ]
```

- Each `<select>` lists the curated options with **Default** first/selected.
- `runChronicle` reads `.value` from both selects and includes them in the
  existing `postJSON('/api/chronicle-run', { extractModel, synthesizeModel })`
  body (today it posts `{}`).
- Selects are disabled alongside the Run button while a run is in flight
  (reuse the existing `runBtn.disabled` toggle points).

No new endpoint, no new poll — the review/publish flow downstream is untouched.

## Data flow

```
[web] two <select>.value ──POST /api/chronicle-run { extractModel, synthesizeModel }──▶
[server] handleChronicleRun decode ──▶ chronicleRun(extract, synth)
[system] chronicleRunArgs → allowlist check → shellQuote → detached `chronicle run [--extract-model X] [--synthesize-model Y]`
[chronicle] resolve_cfg(flags) → resolve_models → provider.complete(model, …)
```

## Error handling

- **Off-list / malicious model value:** rejected in `chronicleRunArgs` before any
  shell string is built; surfaced as a non-zero `CommandResult` shown in the run
  console. The run never launches.
- **Valid-but-rate-limited model (e.g. Fable 5):** run launches; Chronicle fails
  the stage and the run log shows Chronicle's real provider message. The user
  re-runs with a different model from the dropdown. (This is the primary UX the
  feature exists to serve.)
- **Unknown model that passes the allowlist but Claude rejects:** cannot happen
  for v1 — the allowlist *is* the set of accepted values.

## Testing summary

- **Chronicle:** unit tests on `resolve_cfg` flag precedence (per stage).
- **CCC system:** table tests on `chronicleRunArgs` (Default, one, both, off-list,
  metacharacter).
- **CCC server:** handler passes decoded models through; invalid → non-zero result.
- **Manual:** run with synthesize=Sonnet 5 while Fable 5 is limited → run
  completes and stages items; run with Default → unchanged from today.

## Security notes

The model string is the one piece of browser-supplied input that reaches a
`bash -lc` command. Two boundaries protect it: an **allowlist** in
`chronicleRunArgs` (only four exact values pass) and **`shellQuote`** on every
value appended to the command. The allowlist is the primary control; quoting is
the backstop. No secrets are involved; provider remains `claude-cli` (OAuth).
