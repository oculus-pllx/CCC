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

  # getvar SHELL NAME -> value of NAME after sourcing the loader in a clean env
  getvar() {
    env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" "$1" -c '. "$1"; printenv "$2" || true' _ "$loader" "$2"
  }

  # missing map: no output, exit 0
  env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" sh -c '. "$1"' _ "$loader" \
    || fail "loader failed with no env.map"

  printf 'TOKEN=fake-five\n' > "$secrets/five.env"
  printf 'export TOKEN="fake-pllx"\n' > "$secrets/pllx.env"
  printf 'TOKEN=a$b`c d"e\x27f\n' > "$secrets/odd.env"
  cat > "$secrets/env.map" <<'MAP'
# comment
five.env TOKEN CF_DEFAULT
pllx.env TOKEN CF_PLLX
odd.env  TOKEN CF_ODD
../etc.env TOKEN CF_TRAVERSAL
/abs.env TOKEN CF_ABS
.hidden.env TOKEN CF_HIDDEN
five.env BAD-KEY CF_BADKEY
five.env TOKEN 1CF_BADNAME
missing.env TOKEN CF_MISSING

MAP
  # CRLF variant of one line must be rejected, not half-applied
  printf 'five.env TOKEN CF_CRLF2\r\n' >> "$secrets/env.map"

  for sh in sh bash; do
    assert_eq "$(getvar "$sh" CF_DEFAULT)" "fake-five" "$sh: plain KEY=value"
    assert_eq "$(getvar "$sh" CF_PLLX)" "fake-pllx" "$sh: export prefix and quotes stripped"
    assert_eq "$(getvar "$sh" CF_ODD)" 'a$b`c d"e'"'"'f' "$sh: metacharacters kept literally"
    for bad in CF_TRAVERSAL CF_ABS CF_HIDDEN CF_BADKEY 1CF_BADNAME CF_MISSING CF_CRLF2; do
      assert_eq "$(getvar "$sh" "$bad")" "" "$sh: hostile/malformed line $bad ignored"
    done
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
