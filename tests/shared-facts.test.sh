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
  local loader="$TMP/ccc-secrets-env.sh" secrets="$TMP/secrets"
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
  mkdir -p "$secrets/adir.env"                    # a directory named in the map
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
adir.env TOKEN CF_DIR

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
    for bad in CF_TRAVERSAL CF_ABS CF_HIDDEN CF_BADKEY CF_METAKEY 1CF_BADNAME CF_INJECT CF_MISSING CF_DIR; do
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

  # a directory named in the map is skipped, and must not abort a strict bash
  # shell (sed fails on a directory; set -eo pipefail would exit the shell)
  strict="$(env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" bash -c \
    'set -euo pipefail; . "$1"; printf "%s|%s" "${CF_DIR-unset}" "${CF_DEFAULT-unset}"' _ "$loader")" \
    || fail "a directory in env.map aborted a strict bash shell"
  assert_eq "$strict" "unset|fake-five" "directory target not exported, other exports still happen under bash strict mode"

  # unreadable file: silent, other exports still happen
  if [[ "$(id -u)" -ne 0 ]]; then
    chmod 000 "$secrets/five.env"
    out="$(env -i PATH="$PATH" CCC_SECRETS_DIR="$secrets" sh -c '. "$1"; printenv CF_PLLX' _ "$loader" 2>&1)"
    assert_eq "$out" "fake-pllx" "unreadable file is silent and does not stop other exports"
    chmod 600 "$secrets/five.env"
  fi
}

# ── ssh shared known_hosts ────────────────────────────────────────────────────
test_ssh_conf() {
  command -v ssh >/dev/null || { echo "skip: ssh not installed"; return 0; }
  extract_heredoc SSHCCCCONF "$TMP/ccc.conf"
  local effective
  effective="$(ssh -G -F "$TMP/ccc.conf" example.invalid | grep -i '^globalknownhostsfile ')"
  [[ "$effective" == *"/etc/ccc/known_hosts"* ]] \
    || fail "ssh does not consult /etc/ccc/known_hosts: $effective"
  [[ "$effective" == *"/etc/ssh/ssh_known_hosts"* ]] \
    || fail "ssh dropped the default system known_hosts: $effective"
}

# ── ccc-doctor shared facts ───────────────────────────────────────────────────
test_doctor_shared_facts() {
  extract_function ccc_check_shared_facts
  local homes="$TMP/dhomes" out="$TMP/doctor.out" grp
  grp="$(id -gn)"
  mkdir -p "$homes/alice/.claude" "$homes/alice/.codex" "$homes/alice/.gemini" \
           "$homes/bob/.claude" "$homes/bob/.codex" "$homes/bob/.gemini" \
           "$homes/dave" "$TMP/dsecrets"
  for rel in .claude/CLAUDE.md .codex/AGENTS.md .gemini/GEMINI.md; do
    echo "see Meridian-VPS/docs/access-map.md" > "$homes/alice/$rel"
    echo "see Meridian-VPS/docs/access-map.md" > "$homes/bob/$rel"
  done
  echo "no pointer here" > "$homes/bob/.codex/AGENTS.md"      # drifted file
  # dave: home exists but is empty and unreadable files -> warn, not crash
  # erin: in the group but has no home at all
  : > "$TMP/known_hosts"; echo "host ssh-ed25519 AAAA" > "$TMP/known_hosts"
  : > "$TMP/ccc.conf"
  : > "$out"
  (
    ok() { echo "OK $*" >> "$out"; }
    fail() { echo "FAIL $*" >> "$out"; }
    warn() { echo "WARN $*" >> "$out"; }
    getent() { echo "ccc:x:1001:alice,bob,dave,erin"; }
    CCC_SHARED_GROUP="$grp" CCC_HOMES_ROOT="$homes" CCC_SECRETS_DIR="$TMP/dsecrets" \
      CCC_KNOWN_HOSTS="$TMP/known_hosts" CCC_SSH_CONF_FILE="$TMP/ccc.conf"
    source "$TMP/ccc_check_shared_facts.sh"
    ccc_check_shared_facts
  )
  grep -Fq "OK alice: .codex/AGENTS.md points at the registry" "$out" || fail "alice pointer not reported ok"
  grep -Fq "FAIL bob: .codex/AGENTS.md lacks the registry pointer" "$out" || fail "bob drift not reported"
  grep -Fq "WARN dave: cannot read .claude/CLAUDE.md" "$out" || fail "dave unreadable file not a warning"
  grep -Fq "WARN erin: home" "$out" || fail "missing home not a warning"
  grep -Fq "OK alice: home group $grp" "$out" || fail "home group ok not reported"
  grep -Fq "OK secrets dir readable" "$out" || fail "secrets dir not reported ok"
  grep -Fq "OK shared known_hosts present" "$out" || fail "known_hosts not reported ok"
  grep -Fq "OK ssh shared-hosts config installed" "$out" || fail "ssh conf not reported ok"

  # wrong group is a failure that names the fix
  : > "$out"
  (
    ok() { echo "OK $*" >> "$out"; }; fail() { echo "FAIL $*" >> "$out"; }; warn() { echo "WARN $*" >> "$out"; }
    getent() { echo "ccc:x:1001:alice"; }
    CCC_SHARED_GROUP=definitely-not-a-group CCC_HOMES_ROOT="$homes" CCC_SECRETS_DIR="$TMP/nope" \
      CCC_KNOWN_HOSTS="$TMP/none" CCC_SSH_CONF_FILE="$TMP/none"
    source "$TMP/ccc_check_shared_facts.sh"
    ccc_check_shared_facts
  )
  grep -Fq "FAIL alice: home group is" "$out" || fail "wrong home group not a failure"
  grep -Fq "FAIL secrets dir not readable" "$out" || fail "unreadable secrets dir not a failure"
  grep -Fq "WARN shared known_hosts empty, missing or unreadable by $(id -un): $TMP/none" "$out" \
    || fail "missing known_hosts not a warning"
  grep -Fq "FAIL ssh config missing" "$out" || fail "missing ssh config not a failure"

  # a known_hosts with content the invoking user cannot read is a warning, not ok
  if [[ "$(id -u)" -ne 0 ]]; then
    local locked="$TMP/known_hosts.locked"
    echo "host ssh-ed25519 AAAA" > "$locked"
    chmod 000 "$locked"
    : > "$out"
    (
      ok() { echo "OK $*" >> "$out"; }; fail() { echo "FAIL $*" >> "$out"; }; warn() { echo "WARN $*" >> "$out"; }
      getent() { echo "ccc:x:1001:alice"; }
      CCC_SHARED_GROUP="$grp" CCC_HOMES_ROOT="$homes" CCC_SECRETS_DIR="$TMP/dsecrets" \
        CCC_KNOWN_HOSTS="$locked" CCC_SSH_CONF_FILE="$TMP/ccc.conf"
      source "$TMP/ccc_check_shared_facts.sh"
      ccc_check_shared_facts
    )
    chmod 600 "$locked"
    grep -Fq "WARN shared known_hosts empty, missing or unreadable by $(id -un): $locked" "$out" \
      || fail "unreadable known_hosts not a warning"
    ! grep -Fq "OK shared known_hosts present" "$out" || fail "unreadable known_hosts reported ok"
  fi
}

# ── BASH_ENV for non-interactive shells (AI agent Bash tools) ─────────────────
test_set_bash_env() {
  extract_function ccc_set_bash_env
  local envfile="$TMP/environment" loader="$TMP/bashenv-loader.sh"
  printf 'PATH="/usr/bin:/bin"\n' > "$envfile"
  (
    CCC_ENV_FILE="$envfile"
    source "$TMP/ccc_set_bash_env.sh"
    ccc_set_bash_env >/dev/null
    ccc_set_bash_env >/dev/null   # idempotent
  )
  assert_eq "$(grep -c '^BASH_ENV=' "$envfile")" "1" "BASH_ENV added exactly once"
  grep -Fxq 'BASH_ENV=/etc/profile.d/ccc-secrets-env.sh' "$envfile" || fail "BASH_ENV points at the loader"
  grep -Fxq 'PATH="/usr/bin:/bin"' "$envfile" || fail "existing /etc/environment lines kept"

  # an owner-set BASH_ENV is left alone, with a warning
  printf 'BASH_ENV=/opt/other.sh\n' > "$envfile"
  (
    CCC_ENV_FILE="$envfile"
    source "$TMP/ccc_set_bash_env.sh"
    ccc_set_bash_env >/dev/null 2>&1
  )
  assert_eq "$(cat "$envfile")" "BASH_ENV=/opt/other.sh" "existing BASH_ENV not overwritten"

  # the loader actually reaches a non-login, non-interactive bash via BASH_ENV
  extract_heredoc CCCENVLOADER "$loader"
  mkdir -p "$TMP/bsecrets"
  printf 'TOKEN=fake-pllx\n' > "$TMP/bsecrets/pllx.env"
  printf 'pllx.env TOKEN CF_PLLX\n' > "$TMP/bsecrets/env.map"
  assert_eq "$(env -i PATH="$PATH" BASH_ENV="$loader" CCC_SECRETS_DIR="$TMP/bsecrets" bash -c 'printenv CF_PLLX')" \
    "fake-pllx" "non-interactive bash gets secrets through BASH_ENV"
}

# ── group sudo rule ───────────────────────────────────────────────────────────
test_group_sudoers() {
  extract_function ccc_write_group_sudoers
  local dir="$TMP/sudoers.d" target
  mkdir -p "$dir"
  target="$dir/zz-ccc-group"

  # writes the group rule, validated, mode 0440
  (
    CCC_SHARED_GROUP=crew CCC_SUDOERS_FILE="$target" CCC_VISUDO=true
    source "$TMP/ccc_write_group_sudoers.sh"
    ccc_write_group_sudoers >/dev/null
  )
  grep -Fxq '%crew ALL=(ALL:ALL) NOPASSWD: ALL' "$target" || fail "group rule not written"
  grep -Fq 'Managed by Container Code Companion' "$target" || fail "managed header missing"
  assert_eq "$(stat -c %a "$target")" "440" "sudoers mode"
  assert_eq "$(find "$dir" -name '.*' | wc -l)" "0" "no temp file left behind"

  # real visudo, when present, accepts the generated file
  if command -v visudo >/dev/null 2>&1 && visudo -cqf "$target" >/dev/null 2>&1; then :
  elif command -v visudo >/dev/null 2>&1 && visudo -cqf /dev/null >/dev/null 2>&1; then
    fail "visudo rejects the generated rule"
  fi

  # a rule that fails validation never replaces the installed file, and does not abort set -e
  chmod 0644 "$target"; echo "previous" > "$target"
  (
    CCC_SHARED_GROUP=crew CCC_SUDOERS_FILE="$target" CCC_VISUDO=false
    source "$TMP/ccc_write_group_sudoers.sh"
    set -e
    ccc_write_group_sudoers >/dev/null 2>&1
  ) || fail "a failed validation aborted the caller"
  assert_eq "$(cat "$target")" "previous" "invalid rule left the old file in place"
  assert_eq "$(find "$dir" -name '.*' | wc -l)" "0" "no temp file left after a failed validation"
}

test_doctor_group_sudo() {
  extract_function ccc_check_group_sudo
  local out="$TMP/sudo.out" grp rule="$TMP/zz-ccc-group"
  grp="$(id -gn)"
  check() {  # check RULE_FILE SUDO_RESULT
    : > "$out"
    (
      ok() { echo "OK $*" >> "$out"; }; fail() { echo "FAIL $*" >> "$out"; }; warn() { echo "WARN $*" >> "$out"; }
      sudo() { return "$SUDO_RESULT"; }
      SUDO_RESULT="$2" CCC_SHARED_GROUP="$grp" CCC_SUDOERS_FILE="$1"
      source "$TMP/ccc_check_group_sudo.sh"
      ccc_check_group_sudo
    )
  }
  : > "$rule"
  check "$rule" 0
  grep -Fq "OK group sudo rule installed" "$out" || fail "installed rule not reported ok"
  grep -Fq "OK $(id -un): passwordless sudo works" "$out" || fail "working sudo not reported ok"

  check "$TMP/missing-rule" 1
  grep -Fq "FAIL group sudo rule missing: $TMP/missing-rule — sudo ccc-self-update" "$out" || fail "missing rule not a failure"
  grep -Fq "FAIL $(id -un): sudo still asks for a password" "$out" || fail "password prompt not a failure"
}

# ── calls (add new test definitions above this line) ──────────────────────────
test_share_home_groups
test_set_bash_env
test_env_loader
test_ssh_conf
test_doctor_shared_facts
test_group_sudoers
test_doctor_group_sudo
echo "shared-facts tests passed"
