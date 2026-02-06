#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------
# Pretty output helpers
# -----------------------------
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok()   { echo "${GREEN}✅ OK${NC}  - $*"; PASS_COUNT=$((PASS_COUNT+1)); }
warn() { echo "${YELLOW}⚠️ WARN${NC} - $*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { echo "${RED}❌ FAIL${NC} - $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

section() { echo; echo "${BLUE}== $* ==${NC}"; }

TMP_FILES=()
cleanup() {
  for f in "${TMP_FILES[@]:-}"; do
    [[ -e "$f" ]] && rm -f "$f" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# -----------------------------
# Basic environment checks
# -----------------------------
section "Identity / Environment"

USER_ACTUAL="$(whoami || true)"
if [[ "$USER_ACTUAL" == "dev" ]]; then ok "Running as user 'dev'"; else fail "Expected user 'dev', got '$USER_ACTUAL'"; fi

UID_ACTUAL="$(id -u || true)"
GID_ACTUAL="$(id -g || true)"
ok "uid=$UID_ACTUAL gid=$GID_ACTUAL groups=$(id -Gn 2>/dev/null | tr ' ' ',')"

if [[ -n "${USER_ID:-}" ]]; then
  if [[ "$UID_ACTUAL" == "${USER_ID}" ]]; then ok "USER_ID matches ($USER_ID)"; else fail "USER_ID mismatch: env=$USER_ID actual=$UID_ACTUAL"; fi
else
  warn "USER_ID not set in environment (skipping strict check)"
fi

if [[ -n "${GROUP_ID:-}" ]]; then
  if [[ "$GID_ACTUAL" == "${GROUP_ID}" ]]; then ok "GROUP_ID matches ($GROUP_ID)"; else fail "GROUP_ID mismatch: env=$GROUP_ID actual=$GID_ACTUAL"; fi
else
  warn "GROUP_ID not set in environment (skipping strict check)"
fi

PWD_ACTUAL="$(pwd || true)"
if [[ "$PWD_ACTUAL" == "/work" ]]; then ok "Working directory is /work"; else warn "Working directory is '$PWD_ACTUAL' (expected /work)"; fi

HOME_ACTUAL="${HOME:-}"
if [[ "$HOME_ACTUAL" == "/home/dev" ]]; then ok "HOME is /home/dev"; else warn "HOME is '$HOME_ACTUAL' (expected /home/dev)"; fi

if [[ -n "${SHELL:-}" ]]; then ok "SHELL env is '$SHELL'"; else warn "SHELL env is unset (not fatal)"; fi

section "PID 1 / tini"
PID1="$(ps -p 1 -o comm= 2>/dev/null || true)"
PID1_ARGS="$(ps -p 1 -o args= 2>/dev/null || true)"
if [[ "$PID1" == *tini* ]]; then ok "PID 1 is tini ($PID1_ARGS)"; else warn "PID 1 is '$PID1' (expected tini). args='$PID1_ARGS'"; fi

# -----------------------------
# Tooling checks
# -----------------------------
section "Tools present"

TOOLS=(
  git zsh tmux nvim rg fzf cargo pass gpg ssh curl
  exa starship zoxide bat fd delta
)

for t in "${TOOLS[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "Found $t at $(command -v "$t")"
  else
    fail "Missing tool: $t"
  fi
done

section "Tool versions (informational)"
for cmd in \
  "git --version" \
  "zsh --version" \
  "gpg --version | head -n 2" \
  "pass --version | head -n 1" \
  "starship --version" \
  "zoxide --version" \
  "exa --version | head -n 2" \
  "rg --version | head -n 1" \
  "fzf --version | head -n 1" \
  "delta --version | head -n 1" \
; do
  echo "• $cmd"
  (eval "$cmd" 2>/dev/null) || true
done

# -----------------------------
# Shell sanity
# -----------------------------
section "Shell wiring (zsh/starship/zoxide)"
if [[ -f "/home/dev/.zshrc" ]]; then ok ".zshrc exists"; else warn ".zshrc missing"; fi
if command -v starship >/dev/null 2>&1; then ok "starship available"; fi
if command -v zoxide >/dev/null 2>&1; then ok "zoxide available"; fi

# -----------------------------
# Persistence checks
# -----------------------------
section "Persistence wiring"

check_symlink() {
  local link="$1" target="$2"
  if [[ -L "$link" ]]; then
    local resolved
    resolved="$(readlink "$link" || true)"
    if [[ "$resolved" == "$target" ]]; then
      ok "$link -> $target"
    else
      warn "$link points to '$resolved' (expected '$target')"
    fi
  else
    fail "$link is not a symlink"
  fi
}

check_symlink "/home/dev/.gnupg" "/persist/gnupg"
check_symlink "/home/dev/.password-store" "/persist/password-store"
check_symlink "/home/dev/.zsh_history" "/persist/state/zsh_history"

# Permissions: gnupg should be strict
if [[ -d "/persist/gnupg" ]]; then
  PERM="$(stat -c '%a' /persist/gnupg 2>/dev/null || true)"
  OWNER_NUM="$(stat -c '%u:%g' /persist/gnupg 2>/dev/null || true)"
  if [[ "$PERM" == "700" ]]; then ok "/persist/gnupg perms are 700"; else warn "/persist/gnupg perms are $PERM (expected 700)"; fi
  if [[ "$OWNER_NUM" == "${UID_ACTUAL}:${GID_ACTUAL}" ]]; then
    ok "/persist/gnupg owned by ${UID_ACTUAL}:${GID_ACTUAL}"
  else
    warn "/persist/gnupg owned by $OWNER_NUM (expected ${UID_ACTUAL}:${GID_ACTUAL})"
  fi
else
  fail "/persist/gnupg directory missing"
fi

# -----------------------------
# Write tests
# -----------------------------
section "Write tests (/work + /persist)"

WORK_TEST="/work/.container_write_test.$RANDOM.$RANDOM"
PERSIST_TEST="/persist/state/.persist_write_test.$RANDOM.$RANDOM"
TMP_FILES+=("$WORK_TEST" "$PERSIST_TEST")

if touch "$WORK_TEST" 2>/dev/null; then
  ok "Write OK: $WORK_TEST"
else
  fail "Cannot write to /work (bind mount permissions?)"
fi

if touch "$PERSIST_TEST" 2>/dev/null; then
  ok "Write OK: $PERSIST_TEST"
else
  fail "Cannot write to /persist/state (volume permissions?)"
fi

# -----------------------------
# Timezone sanity (warn only)
# -----------------------------
section "Timezone sanity (warn-only)"
if [[ -e /etc/localtime ]]; then
  ok "/etc/localtime exists"
else
  warn "/etc/localtime missing (tzdata not installed?). Some tools may warn."
fi

if [[ -f /etc/timezone ]]; then
  ok "/etc/timezone exists: $(cat /etc/timezone 2>/dev/null || true)"
else
  warn "/etc/timezone missing (not fatal)"
fi

if [[ -n "${TZ:-}" ]]; then
  ok "TZ env set: $TZ"
else
  warn "TZ env not set (not fatal)"
fi

# -----------------------------
# GPG checks
# -----------------------------
section "GPG checks"

GNUPGHOME_ACTUAL="${GNUPGHOME:-/home/dev/.gnupg}"
ok "GNUPGHOME is '${GNUPGHOME_ACTUAL}' (effective)"

if gpg -K --with-colons 2>/dev/null | grep -q '^sec:'; then
  ok "GPG secret key exists"
else
  fail "No GPG secret key found (gpg -K returned no 'sec:' entries)"
fi

FPR="$(gpg -K --with-colons 2>/dev/null | awk -F: '
  $1=="sec"{insec=1}
  insec && $1=="fpr"{print $10; exit}
')"
if [[ -n "$FPR" ]]; then
  ok "Extracted secret key fingerprint: $FPR"
else
  fail "Could not extract secret key fingerprint from gpg -K --with-colons"
fi

# -----------------------------
# pass checks
# -----------------------------
section "pass checks"

STORE_DIR="${PASSWORD_STORE_DIR:-/persist/password-store}"
ok "PASSWORD_STORE_DIR is '${STORE_DIR}'"

if [[ -f "${STORE_DIR}/.gpg-id" ]]; then
  ok "pass initialized (.gpg-id exists)"
else
  fail ".gpg-id missing (pass store not initialized)"
fi

GPG_ID_CONTENT="$(cat "${STORE_DIR}/.gpg-id" 2>/dev/null || true)"
if [[ -n "$GPG_ID_CONTENT" ]]; then
  ok ".gpg-id content: $GPG_ID_CONTENT"
else
  fail ".gpg-id is empty"
fi

TEST_NAME="validate/roundtrip_$(date +%s)_$RANDOM"
TEST_VALUE="ok-$(date -Is)-$RANDOM"

if printf "%s\n" "$TEST_VALUE" | pass insert -m "$TEST_NAME" >/dev/null 2>&1; then
  ok "pass insert OK ($TEST_NAME)"
else
  fail "pass insert failed (cannot encrypt?)"
fi

READ_BACK="$(pass show "$TEST_NAME" 2>/dev/null || true)"
if [[ "$READ_BACK" == "$TEST_VALUE" ]]; then
  ok "pass decrypt OK (roundtrip matches)"
else
  fail "pass decrypt mismatch (expected '$TEST_VALUE', got '$READ_BACK')"
fi

pass rm -f "$TEST_NAME" >/dev/null 2>&1 || true

# -----------------------------
# Git + GCM checks
# -----------------------------
section "Git credential checks"

HELPER="$(git config --system --get credential.helper 2>/dev/null || true)"
STORE="$(git config --system --get credential.credentialStore 2>/dev/null || true)"

if [[ -n "$HELPER" ]]; then
  ok "git system credential.helper = $HELPER"
else
  warn "git system credential.helper not set"
fi

if [[ -n "$STORE" ]]; then
  ok "git system credential.credentialStore = $STORE"
else
  warn "git system credential.credentialStore not set"
fi

if [[ -x "/usr/local/bin/git-credential-manager" ]]; then
  ok "git-credential-manager binary exists"
else
  warn "git-credential-manager binary missing or not executable"
fi

# -----------------------------
# Ready marker check (healthcheck target)
# -----------------------------
section "Ready marker"
if [[ -f "/persist/state/devbox_ready" ]]; then
  ok "Ready marker exists (/persist/state/devbox_ready)"
else
  warn "Ready marker missing (container may still be initializing)"
fi

# -----------------------------
# Summary + exit code
# -----------------------------
section "Summary"
echo "Passed: ${PASS_COUNT} | Warnings: ${WARN_COUNT} | Failed: ${FAIL_COUNT}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "${RED}Validation FAILED${NC} (exit code 1)"
  exit 1
fi

echo "${GREEN}Validation PASSED${NC} (exit code 0)"
exit 0