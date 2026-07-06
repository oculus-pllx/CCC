# Claude Chronicle — CCC Dashboard Page

**Date:** 2026-07-06
**Status:** Approved pending user review

## Goal

Add a "Claude Chronicle" page to Container Code Companion that drives Chronicle's
two-stage flow from the browser: run the harvester, review the synthesized config
delta items as a checklist, and publish a chosen subset (or discard). Today this is
a two-command terminal workflow (`chronicle run`, then `chronicle publish --items …`);
this page makes it a point-and-click operation alongside the existing `oculus-configs`
view it feeds.

Chronicle is the standalone Python CLI at `<projects-root>/Chronicle`. It already
exposes exactly the interface this page needs: `chronicle run` stages synthesized
items to `data/pending-items.json` (no git), and `chronicle publish --items/--all/--discard`
publishes a selection to `oculus-configs/proposals/`. CCC only invokes the CLI and
reads its pending file — it never reimplements publish logic.

## Scope

**v1 (this spec): Core flow** — Run (default `claude-cli` provider, no options UI) →
poll live log → review item checklist → Publish selected / Publish all / Discard.

**Deferred (documented, not built):** provider dropdown and `--limit` field wired
through to `chronicle run`. This is a purely additive change (two form controls plus
passing `--provider`/`--limit` as extra CLI args); the Core backend and frontend do
not need to anticipate it beyond leaving the run-launch arg list easy to extend.

## Locating Chronicle

Chronicle's paths are **derived** from CCC's existing `sharedProjectsRoot()` — which
already resolves `/srv/ccc/projects` and honors the `CCC_SHARED_PROJECTS` env override.
No hardcoded absolute path, no config UI, no new environment variable.

| Purpose | Path |
|---|---|
| Binary | `<projects-root>/Chronicle/.venv/bin/chronicle` |
| Working directory | `<projects-root>/Chronicle` |
| Pending file | `<projects-root>/Chronicle/data/pending-items.json` |
| Run log | `<projects-root>/Chronicle/data/chronicle-run.log` |

The run log lives under Chronicle's own git-ignored `data/` dir (not `/var/log`): a
chronicle run does not restart the CCC service, so it needs no restart-surviving,
sudo-writable log location the way `ccc-self-update` does.

## Flow

1. **Run.** User clicks **Run Chronicle**. CCC launches `chronicle run` as a detached
   background process (`setsid`, `NO_COLOR=1`) that appends stdout+stderr to the run
   log and returns immediately. This mirrors the existing self-update launch, and is
   required because `chronicle run` makes LLM calls that routinely exceed CCC's 45s
   synchronous-command timeout.
2. **Poll.** The browser polls a status endpoint every ~2s, streaming the run log into
   a live `<pre>` console and reading a `running` flag. This mirrors the existing
   self-update-log polling.
3. **Review.** When `running` becomes false, the browser fetches the pending items and
   renders them as a checklist: one row per item with a checkbox, the rule (one line),
   and the target file. A header shows `synthesized_at` and `session_count`. All items
   start checked.
4. **Publish / Discard.** **Publish selected** sends the checked indices; **Publish all**
   sends every item; **Discard** clears the pending set. CCC runs the corresponding
   `chronicle publish` invocation synchronously (publish is render + git push, well
   under 45s) and shows the CLI output. On success, the browser refreshes the
   `oculus-configs` section data so the new proposal commit is visible.

## Backend

New module `internal/system/chronicle.go`, following the `notes.go` / `ssh_keys.go`
pattern (typed structs, pure file I/O where possible, `exec.Command` for CLI calls).

```go
// Typed view of data/pending-items.json (fields verbatim from Chronicle's DeltaItem).
type ChroniclePendingItem struct {
    Rule       string   `json:"rule"`
    Why        string   `json:"why"`
    Citations  []string `json:"citations"`
    TargetFile string   `json:"target_file"`
    Placement  string   `json:"placement"`
}

type ChroniclePending struct {
    Available     bool                   `json:"available"`     // pending file exists & parsed
    SynthesizedAt string                 `json:"synthesizedAt"`
    SessionCount  int                    `json:"sessionCount"`
    Items         []ChroniclePendingItem `json:"items"`
}

// StartChronicleRun launches `chronicle run` detached, appending to the run log,
// and returns immediately. Preflight-checks that the binary exists.
func StartChronicleRun() (CommandResult, error)

// ChronicleRunStatus returns the run log contents and whether a chronicle run
// process is still alive (pgrep on the run command / binary path).
func ChronicleRunStatus() (log string, running bool)

// ReadChroniclePending parses the pending file. Absent or empty file => a
// ChroniclePending with Available:false and no items (not an error).
func ReadChroniclePending() (ChroniclePending, error)

// PublishChronicle validates the selection and runs the matching
// `chronicle publish` invocation synchronously, returning the CLI result.
func PublishChronicle(op ChroniclePublishOperation) (CommandResult, error)

type ChroniclePublishOperation struct {
    Mode  string `json:"mode"`  // "items" | "all" | "discard"
    Items []int  `json:"items"` // 1-based indices, required when Mode=="items"
}
```

`PublishChronicle` builds the argv server-side — `--items <csv>` / `--all` / `--discard`
— from the validated `Mode`; it never interpolates client text into a shell string.
Invalid mode, or `mode:"items"` with an empty/out-of-range index list, is rejected
before exec with an actionable error. `running` detection uses `pgrep -f` against the
chronicle binary path (a run is single-instance in practice; concurrent runs are out
of scope).

## HTTP endpoints

Wired in `server.go` through the existing `Config` dependency-injection funcs so
handler tests can stub them, exactly like `listNotes` / `sshKeyOperation`.

| Method | Path | Backend func | Purpose |
|---|---|---|---|
| POST | `/api/chronicle-run` | `StartChronicleRun` | launch detached run |
| GET | `/api/chronicle-run-log` | `ChronicleRunStatus` | `{log, running}` for polling |
| GET | `/api/chronicle-pending` | `ReadChroniclePending` | current pending items |
| POST | `/api/chronicle-publish` | `PublishChronicle` | publish selection / discard |

All four sit behind `requireSession`, like every other data route.

## Frontend

`web/app.js` + `web/index.html`, following the established SPA pattern (no framework,
no build step, no new dependency):

- **Nav:** a `data-section="chronicle"` button labeled **"Claude Chronicle"** in the
  **Settings** nav group, next to `oculus-configs` (its downstream target).
- **Renderer:** `renderChronicle()` added to the `renderers` map in `renderSection`,
  plus a `section-title` entry. Layout: a Run button + live log `<pre>`, then (once a
  run finishes or pending items already exist on section load) the item checklist and
  the Publish selected / Publish all / Discard action row, then a result `<pre>`.
- **Binding:** a `bindSectionActions` case for `chronicle` wires Run (POST run, then
  start the poll loop), the poll loop (GET run-log every ~2s until `running:false`,
  then GET pending and re-render the checklist), and the three publish/discard buttons
  (POST publish, show result, refresh oculus snapshot).
- On entering the section, it fetches pending once so a checklist from an earlier run
  (or a run started in a terminal) shows immediately without requiring a fresh run.

## Error handling

- **Chronicle not installed** (binary missing at the derived path): both run and
  publish return a clear "Chronicle not found at `<path>`" message; the page shows it
  instead of a checklist.
- **Run failure:** the non-zero exit and stderr are already in the streamed run log;
  the poll loop simply stops when `running` clears, leaving the error visible.
- **Empty synthesis:** `ReadChroniclePending` returns `Available:false`; the page shows
  "No pending items — run Chronicle to synthesize." (`chronicle run` itself prints its
  own "nothing staged" line into the log.)
- **Publish push failure:** the CLI already keeps the pending file and exits 1 on push
  failure; CCC surfaces its output verbatim and leaves the checklist in place so the
  user can retry.
- **Corrupt pending JSON:** `ReadChroniclePending` returns an error naming the file;
  the page shows it rather than a blank checklist.

## Assumptions / dependencies

The CCC service user can already run `chronicle` end to end — it has the `~/.claude`
transcripts, the Claude CLI OAuth the default provider rides, and the git credentials
for Chronicle's oculus-configs push. This is the same standing assumption under which
that user already runs `git` and `ccc-self-update`. CCC invokes the CLI; publish
internals (rendering, path guard, commit message, push) stay entirely Chronicle's
concern.

## Out of scope

- Provider/limit controls (deferred; see Scope).
- Editing item text before publishing (Chronicle doesn't support it; items are
  published verbatim or discarded).
- Concurrent or queued runs; multiple pending sets.
- Any reimplementation of Chronicle's synthesis or publish logic in Go.
- Scheduling/cron (Chronicle is manual-run by design).

## Testing

- **Go:** handler tests stub the four `Config` funcs (as `notes`/`ssh_keys` tests do)
  and assert routing, method guards, and JSON shapes. `ReadChroniclePending` gets unit
  tests against temp files: valid file, absent file (`Available:false`), empty file,
  corrupt JSON. `PublishChronicle` argv-building and validation get unit tests
  (items → `--items 1,3`, all → `--all`, discard → `--discard`, empty/out-of-range
  items → error) with the actual exec stubbed or pointed at a fake binary.
- **Frontend:** follows the repo's existing convention (no JS test harness present);
  verified manually against a live Chronicle checkout.
- Existing CCC tests must continue to pass (`go test ./...`).
