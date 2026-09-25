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

# ── calls (add new test definitions above this line) ──────────────────────────
test_share_home_groups
echo "shared-facts tests passed"
