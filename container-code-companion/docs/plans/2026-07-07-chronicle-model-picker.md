# Chronicle Model Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick the extract-stage and synthesize-stage Claude model per run from the CCC dashboard, passed through to `chronicle run` as new `--extract-model` / `--synthesize-model` flags.

**Architecture:** Three layers across two repos. (1) Chronicle CLI gains two optional flags that override the resolved per-stage model. (2) CCC Go backend validates the browser-supplied model against a four-value allowlist and appends `shellQuote`'d flags to the detached run command. (3) The Chronicle dashboard page gains two `<select>` dropdowns whose values ride the existing run POST. "Default" means omit the flag (Chronicle keeps its own per-provider default).

**Tech Stack:** Python (Chronicle CLI, pytest), Go (CCC backend, `go test`), vanilla JS (CCC `web/app.js`).

**Repos & working dirs:**
- Chronicle repo: `/srv/ccc/projects/Chronicle` — Tasks 1–2. Tests: `.venv/bin/python -m pytest`.
- CCC repo: `/srv/ccc/projects/CCC/container-code-companion` — Tasks 3–6. Tests: `go test ./...`.

**Allowlist (single source of truth, re-declared per language):** `claude-sonnet-5`, `claude-fable-5`, `claude-opus-4-8`, `claude-haiku-4-5`. Empty string = "Default" = flag omitted.

**Spec:** `docs/specs/2026-07-07-chronicle-model-picker-design.md`

---

## Task 1: Chronicle `resolve_cfg` — per-stage model overrides

**Files:**
- Modify: `/srv/ccc/projects/Chronicle/chronicle/cli.py:114-120` (`resolve_cfg`)
- Test: `/srv/ccc/projects/Chronicle/tests/test_cli.py` (near existing `test_resolve_cfg_*`, ~line 401)

- [ ] **Step 1: Write the failing tests**

Add after `test_resolve_cfg_provider_override_beats_env` in `tests/test_cli.py`:

```python
def test_resolve_cfg_extract_model_flag_overrides_default():
    cfg = resolve_cfg({}, None, extract_model="claude-opus-4-8")
    assert cfg.extract_model == "claude-opus-4-8"
    assert cfg.synthesize_model == "claude-fable-5"  # other stage untouched


def test_resolve_cfg_synthesize_model_flag_overrides_default():
    cfg = resolve_cfg({}, None, synthesize_model="claude-sonnet-5")
    assert cfg.synthesize_model == "claude-sonnet-5"
    assert cfg.extract_model == "claude-sonnet-5"  # default, unchanged


def test_resolve_cfg_model_flag_beats_env():
    cfg = resolve_cfg({"EXTRACT_MODEL": "env-model"}, None,
                      extract_model="claude-opus-4-8")
    assert cfg.extract_model == "claude-opus-4-8"


def test_resolve_cfg_no_model_flags_unchanged():
    cfg = resolve_cfg({})
    assert cfg.extract_model == "claude-sonnet-5"
    assert cfg.synthesize_model == "claude-fable-5"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /srv/ccc/projects/Chronicle && .venv/bin/python -m pytest tests/test_cli.py -k resolve_cfg -v`
Expected: the three new flag tests FAIL with `TypeError: resolve_cfg() got an unexpected keyword argument 'extract_model'`.

- [ ] **Step 3: Implement the override**

Replace `resolve_cfg` in `chronicle/cli.py` (currently lines 114-120) with:

```python
def resolve_cfg(env, provider_override: str | None = None,
                extract_model: str | None = None,
                synthesize_model: str | None = None) -> Config:
    cfg = load_config(env)
    if provider_override:
        cfg = replace(cfg, llm_provider=provider_override)
    # An explicit --extract-model/--synthesize-model wins over env before
    # resolve_models fills any per-provider default for a still-unset stage.
    if extract_model:
        cfg = replace(cfg, extract_model=extract_model)
    if synthesize_model:
        cfg = replace(cfg, synthesize_model=synthesize_model)
    resolved_extract, resolved_synthesize = resolve_models(cfg)
    return replace(cfg, extract_model=resolved_extract,
                   synthesize_model=resolved_synthesize)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /srv/ccc/projects/Chronicle && .venv/bin/python -m pytest tests/test_cli.py -k resolve_cfg -v`
Expected: all `resolve_cfg` tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/Chronicle
git add chronicle/cli.py tests/test_cli.py
git commit -m "feat: resolve_cfg accepts per-stage model overrides

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Chronicle `run` — CLI flags wired to `resolve_cfg`

**Files:**
- Modify: `/srv/ccc/projects/Chronicle/chronicle/cli.py` — `main()` argparse (~line 129-135) and the `resolve_cfg` call (~line 157)

`main()` is `# pragma: no cover` (argparse plumbing); verify by invoking the CLI.

- [ ] **Step 1: Add the argparse flags**

In `main()`, immediately after the existing `run_p.add_argument("--provider", ...)` block, add:

```python
    run_p.add_argument("--extract-model", default=None,
                       help="model for the extract stage (overrides EXTRACT_MODEL)")
    run_p.add_argument("--synthesize-model", default=None,
                       help="model for the synthesize stage "
                            "(overrides SYNTHESIZE_MODEL)")
```

- [ ] **Step 2: Pass the flags into `resolve_cfg`**

Replace the existing call (currently `cfg = resolve_cfg(os.environ, args.provider)`, ~line 157) with:

```python
    cfg = resolve_cfg(os.environ, args.provider,
                      extract_model=args.extract_model,
                      synthesize_model=args.synthesize_model)
```

- [ ] **Step 3: Verify the flags parse and are accepted**

Run: `cd /srv/ccc/projects/Chronicle && .venv/bin/chronicle run --help`
Expected: help text lists `--extract-model` and `--synthesize-model`.

Run: `cd /srv/ccc/projects/Chronicle && .venv/bin/chronicle run --synthesize-only --synthesize-model claude-sonnet-5`
Expected: run proceeds (synthesizes from cache using sonnet; no argparse error). It may stage items or print "no candidates" — either is fine; the point is the flag is accepted end-to-end.

- [ ] **Step 4: Run the full suite (nothing regressed)**

Run: `cd /srv/ccc/projects/Chronicle && .venv/bin/python -m pytest -q`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/Chronicle
git add chronicle/cli.py
git commit -m "feat: chronicle run --extract-model/--synthesize-model flags

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: CCC `chronicleRunArgs` — allowlist + arg builder

**Files:**
- Modify: `/srv/ccc/projects/CCC/container-code-companion/internal/system/chronicle.go` (add helper + allowlist near `buildPublishArgs`, ~line 104)
- Test: `/srv/ccc/projects/CCC/container-code-companion/internal/system/chronicle_test.go` (after `TestBuildPublishArgs`, ~line 127)

- [ ] **Step 1: Write the failing table test**

Add to `internal/system/chronicle_test.go`:

```go
func TestChronicleRunArgs(t *testing.T) {
	cases := []struct {
		name             string
		extract, synth   string
		want             []string
		wantErr          bool
	}{
		{"both default", "", "", []string{"run"}, false},
		{"extract only", "claude-opus-4-8", "",
			[]string{"run", "--extract-model", "claude-opus-4-8"}, false},
		{"synth only", "", "claude-sonnet-5",
			[]string{"run", "--synthesize-model", "claude-sonnet-5"}, false},
		{"both set", "claude-haiku-4-5", "claude-sonnet-5",
			[]string{"run", "--extract-model", "claude-haiku-4-5",
				"--synthesize-model", "claude-sonnet-5"}, false},
		{"off-list extract", "gpt-4", "", nil, true},
		{"off-list synth", "", "sonnet", nil, true},
		{"metacharacter injection", "claude-sonnet-5; rm -rf /", "", nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := chronicleRunArgs(tc.extract, tc.synth)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got args %v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("got %v want %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("got %v want %v", got, tc.want)
				}
			}
		})
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run TestChronicleRunArgs`
Expected: FAIL — `undefined: chronicleRunArgs`.

- [ ] **Step 3: Implement the allowlist and builder**

Add to `internal/system/chronicle.go` just above `buildPublishArgs`:

```go
// chronicleModelAllowlist is the exact set of model values the dashboard may
// pass to `chronicle run`. It is the primary guard on the one piece of
// browser-supplied input that reaches a shell command (shellQuote is the
// backstop). Empty string is not in the set: it means "Default" (flag omitted).
var chronicleModelAllowlist = map[string]bool{
	"claude-sonnet-5":  true,
	"claude-fable-5":   true,
	"claude-opus-4-8":  true,
	"claude-haiku-4-5": true,
}

// chronicleRunArgs builds the `chronicle run` argument list, appending
// --extract-model/--synthesize-model only for a non-empty, allowlisted model.
// An empty model means Default: Chronicle applies its own per-provider default.
func chronicleRunArgs(extractModel, synthesizeModel string) ([]string, error) {
	args := []string{"run"}
	for _, m := range []struct{ flag, value string }{
		{"--extract-model", extractModel},
		{"--synthesize-model", synthesizeModel},
	} {
		if m.value == "" {
			continue
		}
		if !chronicleModelAllowlist[m.value] {
			return nil, fmt.Errorf("model %q is not an allowed Chronicle model", m.value)
		}
		args = append(args, m.flag, m.value)
	}
	return args, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run TestChronicleRunArgs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add internal/system/chronicle.go internal/system/chronicle_test.go
git commit -m "feat: chronicleRunArgs builds allowlisted run flags

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: CCC `StartChronicleRun` — accept & splice model args

**Files:**
- Modify: `/srv/ccc/projects/CCC/container-code-companion/internal/system/chronicle.go` — `StartChronicleRun` (~line 181)
- Modify: `/srv/ccc/projects/CCC/container-code-companion/internal/system/chronicle_test.go:217` — `TestStartChronicleRunMissingBinary` call site

- [ ] **Step 1: Update the missing-binary test to the new signature**

In `chronicle_test.go`, `TestStartChronicleRunMissingBinary` calls `StartChronicleRun()`. Change that call to:

```go
	result, err := StartChronicleRun("", "")
```

(Leave the rest of the test — it asserts missing-binary ExitCode/err — unchanged.)

- [ ] **Step 2: Run to verify it fails to compile**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/ -run TestStartChronicleRun`
Expected: FAIL — too many arguments to `StartChronicleRun` (signature still takes none).

- [ ] **Step 3: Change the signature and build the command from `chronicleRunArgs`**

In `chronicle.go`, change the signature:

```go
func StartChronicleRun(extractModel, synthesizeModel string) (CommandResult, error) {
```

After the `os.Stat(bin)` missing-binary check and before `logPath := chronicleRunLogPath()`, insert:

```go
	runArgs, err := chronicleRunArgs(extractModel, synthesizeModel)
	if err != nil {
		return CommandResult{
			Command:  "chronicle run",
			Output:   err.Error(),
			ExitCode: 1,
		}, err
	}
	quoted := make([]string, len(runArgs))
	for i, a := range runArgs {
		quoted[i] = shellQuote(a)
	}
	runInvocation := shellQuote(bin) + " " + strings.Join(quoted, " ")
```

Then replace the command string's run portion. The current line reads:

```go
		" && { setsid env NO_COLOR=1 " + shellQuote(bin) + " run >> " + shellQuote(logPath) +
```

Change it to:

```go
		" && { setsid env NO_COLOR=1 " + runInvocation + " >> " + shellQuote(logPath) +
```

(`runArgs` already begins with `run`, so `runInvocation` is e.g. `'…/chronicle' 'run' '--synthesize-model' 'claude-sonnet-5'`. Default → `'…/chronicle' 'run'`, identical to today.)

- [ ] **Step 4: Run to verify system tests pass**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/system/`
Expected: PASS (compiles; missing-binary test still green).

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add internal/system/chronicle.go internal/system/chronicle_test.go
git commit -m "feat: StartChronicleRun splices allowlisted model flags

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: CCC server — pass models through the run endpoint

**Files:**
- Modify: `/srv/ccc/projects/CCC/container-code-companion/internal/server/server.go` — `ChronicleRun` field (line 53), wiring (lines 134, 222), `handleChronicleRun` (~line 813)
- Modify: `/srv/ccc/projects/CCC/container-code-companion/internal/server/server_test.go:912` — test injection of `ChronicleRun`
- Test: add a handler test in `server_test.go`

- [ ] **Step 1: Update the test server injection and add a passthrough test**

In `server_test.go`, change the `ChronicleRun` field in the test config (line ~912) to capture its args:

```go
		ChronicleRun: func(extractModel, synthesizeModel string) (system.CommandResult, error) {
			return system.CommandResult{
				Command:  "chronicle run",
				Output:   "extract=" + extractModel + " synth=" + synthesizeModel,
				ExitCode: 0,
			}, nil
		},
```

Add a new test (near `TestChronicleRunRejectsGet`, ~line 1034):

```go
func TestChronicleRunPassesModels(t *testing.T) {
	srv := newTestServer()
	body := `{"extractModel":"claude-opus-4-8","synthesizeModel":"claude-sonnet-5"}`
	req := httptest.NewRequest(http.MethodPost, "/api/chronicle-run", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	if !strings.Contains(res.Body.String(), "extract=claude-opus-4-8 synth=claude-sonnet-5") {
		t.Fatalf("models not passed through: %s", res.Body.String())
	}
}

func TestChronicleRunEmptyBodyDefaults(t *testing.T) {
	srv := newTestServer()
	req := httptest.NewRequest(http.MethodPost, "/api/chronicle-run", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "test-token"})
	res := httptest.NewRecorder()
	srv.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	if !strings.Contains(res.Body.String(), "extract= synth=") {
		t.Fatalf("empty body should yield empty models: %s", res.Body.String())
	}
}
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/server/ -run TestChronicleRun`
Expected: FAIL — `ChronicleRun` field type mismatch (still `func() (...)`).

- [ ] **Step 3: Change the field type, wiring, and handler**

In `server.go`, change the config field (line 53):

```go
	ChronicleRun        func(extractModel, synthesizeModel string) (system.CommandResult, error)
```

The two wiring lines need no textual change if they assign by name (`chronicleRun: config.ChronicleRun` at line 134, `s.chronicleRun = system.StartChronicleRun` at line 222) — both now carry the new signature automatically. Confirm the struct field `chronicleRun` (unexported, on `Server`) also has the new type; update its declaration to match:

```go
	chronicleRun func(extractModel, synthesizeModel string) (system.CommandResult, error)
```

Replace `handleChronicleRun` body (keep the method-guard) so it decodes an optional JSON body and passes it through:

```go
func (s *Server) handleChronicleRun(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Body is optional: no body / empty body means both models Default ("").
	var body struct {
		ExtractModel    string `json:"extractModel"`
		SynthesizeModel string `json:"synthesizeModel"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body) // EOF on empty body is fine
	}
	// A missing binary or a rejected (off-allowlist) model is reported through
	// the result (ExitCode!=0 + Output); the browser inspects exitCode.
	result, _ := s.chronicleRun(body.ExtractModel, body.SynthesizeModel)
	writeJSON(w, http.StatusOK, result)
}
```

(`encoding/json` is already imported in `server.go`. If `go build` reports it unused-or-missing, add it to the import block.)

- [ ] **Step 4: Run to verify server tests pass**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go test ./internal/server/ -run TestChronicleRun`
Expected: PASS (both new tests + the existing reject-GET test).

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add internal/server/server.go internal/server/server_test.go
git commit -m "feat: chronicle-run endpoint forwards selected models

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: CCC web — two model dropdowns

**Files:**
- Modify: `/srv/ccc/projects/CCC/container-code-companion/web/app.js` — `renderChronicle` (~line 963) and `runChronicle` (POST body + disable toggles)

No unit test harness for `app.js`; verify by building and loading the page (Task 7).

- [ ] **Step 1: Add the two selects to `renderChronicle`**

In `renderChronicle`, replace the `.action-row` that holds only the run button:

```javascript
    <div class="action-row">
      <button id="chronicle-run-btn" class="small-button">Run Chronicle</button>
```

with (keep the rest of the row/template that follows unchanged):

```javascript
    <div class="action-row">
      <label class="chronicle-model-label">Extract model
        <select id="chronicle-extract-model" class="chronicle-model-select">
          <option value="" selected>Default</option>
          <option value="claude-sonnet-5">Sonnet 5</option>
          <option value="claude-fable-5">Fable 5</option>
          <option value="claude-opus-4-8">Opus 4.8</option>
          <option value="claude-haiku-4-5">Haiku 4.5</option>
        </select>
      </label>
      <label class="chronicle-model-label">Synthesize model
        <select id="chronicle-synthesize-model" class="chronicle-model-select">
          <option value="" selected>Default</option>
          <option value="claude-sonnet-5">Sonnet 5</option>
          <option value="claude-fable-5">Fable 5</option>
          <option value="claude-opus-4-8">Opus 4.8</option>
          <option value="claude-haiku-4-5">Haiku 4.5</option>
        </select>
      </label>
      <button id="chronicle-run-btn" class="small-button">Run Chronicle</button>
```

- [ ] **Step 2: Read the selects and send them in the run POST**

In `runChronicle`, replace the start POST call (currently `start = await postJSON('/api/chronicle-run', {});`) with:

```javascript
    const extractModel = (document.getElementById('chronicle-extract-model') || {}).value || '';
    const synthesizeModel = (document.getElementById('chronicle-synthesize-model') || {}).value || '';
    start = await postJSON('/api/chronicle-run', { extractModel, synthesizeModel });
```

- [ ] **Step 3: Disable the selects while a run is in flight**

In `runChronicle`, right after `if (runBtn) runBtn.disabled = true;`, add:

```javascript
  const extractSel = document.getElementById('chronicle-extract-model');
  const synthSel = document.getElementById('chronicle-synthesize-model');
  if (extractSel) extractSel.disabled = true;
  if (synthSel) synthSel.disabled = true;
```

In `finishChronicleRun`, wherever it re-enables `runBtn` (search for `runBtn.disabled = false`), re-enable the selects alongside it:

```javascript
  const extractSel = document.getElementById('chronicle-extract-model');
  const synthSel = document.getElementById('chronicle-synthesize-model');
  if (extractSel) extractSel.disabled = false;
  if (synthSel) synthSel.disabled = false;
```

- [ ] **Step 4: Add minimal styling**

Append to the Chronicle section styles in `web/app.js` (or the stylesheet it uses — match how `.chronicle-item` is styled). Add:

```css
.chronicle-model-label { display: inline-flex; flex-direction: column; font-size: 0.8rem; gap: 2px; margin-right: 8px; }
.chronicle-model-select { font-size: 0.85rem; }
```

(If styles live in a separate `.css` file rather than inline in `app.js`, add them there instead — follow the existing pattern for `.chronicle-*` rules.)

- [ ] **Step 5: Commit**

```bash
cd /srv/ccc/projects/CCC/container-code-companion
git add web/app.js
git commit -m "feat: extract/synthesize model dropdowns on Chronicle page

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Full build, test, and manual verification

**Files:** none (verification only)

- [ ] **Step 1: Chronicle suite green**

Run: `cd /srv/ccc/projects/Chronicle && .venv/bin/python -m pytest -q`
Expected: all PASS.

- [ ] **Step 2: CCC build + full test suite green**

Run: `cd /srv/ccc/projects/CCC/container-code-companion && go build ./... && go test ./...`
Expected: build succeeds; all packages PASS.

- [ ] **Step 3: Manual end-to-end (the motivating case)**

Load the Chronicle dashboard page. Set **Synthesize model → Sonnet 5**, leave Extract at Default, click **Run Chronicle**. Watch the live log.
Expected: run completes and stages items (does NOT fail with the Fable-5 limit). Confirms the picker resolves the rate-limit failure.

Then run once with both dropdowns at **Default**.
Expected: identical behavior to before this feature (Chronicle uses `claude-sonnet-5` extract / `claude-fable-5` synthesize).

- [ ] **Step 4: Push both repos**

```bash
cd /srv/ccc/projects/Chronicle && git push
cd /srv/ccc/projects/CCC/container-code-companion && git push
```

- [ ] **Step 5: Update HANDOFF (do not commit HANDOFF.md)**

Update `.claude/HANDOFF.md` in whichever repo is the working context to note the model picker shipped. Per repo policy, `HANDOFF.md` is not committed.

---

## Self-review notes

- **Spec coverage:** Layer 1 → Tasks 1–2; Layer 2 → Tasks 3–4; Layer 3 → Task 5 (server) + Task 6 (web); curated list + Default semantics → Tasks 3 & 6; allowlist+shellQuote security → Tasks 3–4; error handling (off-list → non-zero result) → Tasks 3 & 5; manual rate-limit case → Task 7 Step 3. Provider/`--limit` correctly absent (out of scope).
- **Type consistency:** `chronicleRunArgs(extractModel, synthesizeModel string) ([]string, error)` and `StartChronicleRun(extractModel, synthesizeModel string)` used consistently; server field, unexported `chronicleRun` field, and test injection all updated to the same two-arg signature; JSON body keys `extractModel`/`synthesizeModel` match between web POST (Task 6) and handler decode (Task 5).
