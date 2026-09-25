#!/usr/bin/env bash
# Behavior tests for the shared-workstation-facts pieces of the provisioner.
# Each piece is extracted from install/ccc-provision-workstation.sh and run
# against stubs, so nothing here touches /etc or real accounts.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROV="$REPO_ROOT/install/ccc-provision-workstation.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2] got [$1]"; }

# Body of `cat > FILE << 'TERMINATOR'` ... `TERMINATOR`.
extract_heredoc() {
  awk -v t="$1" 'index($0, t) { f = !f; next } f' "$PROV" > "$2"
  [[ -s "$2" ]] || fail "heredoc $1 not found in provisioner"
}

# A top-level `name() { ... }` function, closing brace in column 0.
extract_function() {
  sed -n "/^$1() {/,/^}/p" "$PROV" > "$TMP/$1.sh"
  [[ -s "$TMP/$1.sh" ]] || fail "function $1 not found in provisioner"
}

# ── ccc_share_home_groups ─────────────────────────────────────────────────────
test_share_home_groups() {
  extract_function ccc_share_home_groups
  local homes="$TMP/homes" calls="$TMP/chgrp.calls"
  mkdir -p "$homes/alice" "$homes/bob"   # carol has no home directory
  : > "$calls"
  (
    getent() { echo "ccc:x:1001:alice,bob,carol"; }
    stat() { case "$*" in *alice) echo ccc ;; *bob) echo bob ;; esac; }
    chgrp() { echo "chgrp $*" >> "$calls"; }
    CCC_SHARED_GROUP=ccc CCC_HOMES_ROOT="$homes"
    # shellcheck source=/dev/null
    source "$TMP/ccc_share_home_groups.sh"
    ccc_share_home_groups >/dev/null
  )
  assert_eq "$(cat "$calls")" "chgrp ccc $homes/bob" \
    "only the home whose group differs is changed; missing homes are skipped"

  # chgrp failing must not abort the caller (the provisioner runs under set -e).
  (
    getent() { echo "ccc:x:1001:bob"; }
    stat() { echo bob; }
    chgrp() { return 1; }
    CCC_SHARED_GROUP=ccc CCC_HOMES_ROOT="$homes"
    source "$TMP/ccc_share_home_groups.sh"
    set -e
    ccc_share_home_groups >/dev/null 2>&1
  ) || fail "a failing chgrp aborted the caller"
}

# ── env loader ────────────────────────────────────────────────────────────────
test_env_loader() {
  local loader="$TMP/ccc-env.sh" secrets="$TMP/secrets"
  extract_heredoc CCCENVLOADER "$loader"
  mkdir -p "$secrets"

  # getvar SHELL NAME [DIR] -> value of NAME after sourcing the loader in a clean env
  getvar() {
    env -i PATH="$PATH" CCC_SECRETS_DIR="${3:-$secrets}" "$1" -c '. "$1"; printenv "$2" || true' _ "$loader" "$2"
  }

  # missing map: no output, exit 0
  env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" sh -c '. "$1"' _ "$loader" \
    || fail "loader failed with no env.map"

  # Every hostile map line below has a REAL target holding a FAKE value, so it
  # would be exported if its validation were missing.
  printf 'TOKEN=fake-five\n' > "$secrets/five.env"
  printf 'export TOKEN="fake-pllx"\n' > "$secrets/pllx.env"
  printf 'TOKEN=a$b`c d"e\x27f\n' > "$secrets/odd.env"
  printf 'TOKEN=fake-traversal\n' > "$TMP/etc.env"      # reached by ../etc.env
  printf 'TOKEN=fake-abs\n' > "$secrets/abs.env"        # reached by /abs.env ("$dir//abs.env")
  printf 'TOKEN=fake-hidden\n' > "$secrets/.hidden.env"
  printf 'BAD-KEY=fake-badkey\n' > "$secrets/badkey.env"
  {
    cat <<'MAP'
# comment
five.env TOKEN CF_DEFAULT
pllx.env TOKEN CF_PLLX
odd.env  TOKEN CF_ODD
../etc.env TOKEN CF_TRAVERSAL
/abs.env TOKEN CF_ABS
.hidden.env TOKEN CF_HIDDEN
badkey.env BAD-KEY CF_BADKEY
five.env .* CF_METAKEY
five.env TOKEN 1CF_BADNAME
five.env TOKEN CF_INJECT=evil
missing.env TOKEN CF_MISSING

MAP
    # CRLF variant of a valid line must be rejected, not half-applied
    printf 'five.env TOKEN CF_CRLF2\r\n'
    # a valid line after the hostile ones: the loader must keep going
    printf 'five.env TOKEN CF_LAST\n'
  } > "$secrets/env.map"

  for sh in sh bash; do
    assert_eq "$(getvar "$sh" CF_DEFAULT)" "fake-five" "$sh: plain KEY=value"
    assert_eq "$(getvar "$sh" CF_PLLX)" "fake-pllx" "$sh: export prefix and quotes stripped"
    assert_eq "$(getvar "$sh" CF_ODD)" 'a$b`c d"e'"'"'f' "$sh: metacharacters kept literally"
    assert_eq "$(getvar "$sh" CF_LAST)" "fake-five" "$sh: loader continues past hostile lines"
    for bad in CF_TRAVERSAL CF_ABS CF_HIDDEN CF_BADKEY CF_METAKEY 1CF_BADNAME CF_INJECT CF_MISSING; do
      assert_eq "$(getvar "$sh" "$bad")" "" "$sh: hostile/malformed line $bad ignored"
    done
    # nothing named CF_CRLF2 (with or without a stray \r) may reach the environment
    crlf="$(env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" "$sh" -c '. "$1"; env' _ "$loader" | grep -c '^CF_CRLF2' || true)"
    assert_eq "$crlf" "0" "$sh: CRLF map line rejected"
  done

  # a hand-edited map often lacks the final newline: the last entry must still apply
  local secrets2="$TMP/secrets2"
  mkdir -p "$secrets2"
  printf 'TOKEN=fake-first\n' > "$secrets2/a.env"
  printf 'TOKEN=fake-last\n' > "$secrets2/b.env"
  printf 'a.env TOKEN A1\nb.env TOKEN B1' > "$secrets2/env.map"
  for sh in sh bash; do
    assert_eq "$(getvar "$sh" A1 "$secrets2")" "fake-first" "$sh: terminated line"
    assert_eq "$(getvar "$sh" B1 "$secrets2")" "fake-last" "$sh: final line without newline"
    # a caller's non-default IFS must not break map parsing
    assert_eq "$(env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" "$sh" -c 'IFS=:; . "$1"; printenv CF_DEFAULT' _ "$loader")" \
      "fake-five" "$sh: caller IFS does not affect parsing"
  done

  # never aborts a strict shell
  for sh in sh bash; do
    env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" "$sh" -eu -c '. "$1"' _ "$loader" \
      || fail "loader aborted a $sh -eu shell"
  done

  # unreadable file: silent, other exports still happen
  if [[ "$(id -u)" -ne 0 ]]; then
    chmod 000 "$secrets/five.env"
    out="$(env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" sh -c '. "$1"; printenv CF_PLLX' _ "$loader" 2>&1)"
    assert_eq "$out" "fake-pllx" "unreadable file is silent and does not stop other exports"
    chmod 600 "$secrets/five.env"
  fi
}

# ── calls (add new test definitions above this line) ──────────────────────────
test_share_home_groups
test_env_loader
echo "shared-facts tests passed"
