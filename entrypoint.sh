#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo "[entrypoint] $*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  log "ERROR: entrypoint must run as root. Do not use --user or compose 'user:'."
  exit 1
fi

USER_NAME="dev"
HOME_DIR="/home/${USER_NAME}"

USER_ID="${USER_ID:-1000}"
GROUP_ID="${GROUP_ID:-1000}"

PERSIST_DIR="${PERSIST_DIR:-/persist}"
PASSWORD_STORE_DIR="${PASSWORD_STORE_DIR:-${PERSIST_DIR}/password-store}"
READY_FILE="${PERSIST_DIR}/state/devbox_ready"

GPG_NAME="${GPG_NAME:-Dev User}"
GPG_EMAIL="${GPG_EMAIL:-dev@example.com}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"

GERRIT_HOST="${GERRIT_HOST:-}"
GERRIT_USERNAME="${GERRIT_USERNAME:-}"
GERRIT_PAT="${GERRIT_PAT:-}"

find_free_uid() {
  local uid=2000
  while getent passwd | awk -F: -v u="$uid" '$3==u {found=1} END{exit !found}'; do
    uid=$((uid+1))
  done
  echo "$uid"
}

fix_owner_if_needed() {
  local path="$1"
  local want="${USER_ID}:${GROUP_ID}"
  [[ -e "$path" ]] || return 0
  local cur
  cur="$(stat -c '%u:%g' "$path" 2>/dev/null || echo '')"
  if [[ "$cur" != "$want" ]]; then
    log "Fixing ownership on $path (was $cur, want $want)"
    chown -R "$want" "$path" || true
  fi
}

mkdir -p "${PERSIST_DIR}/gnupg" "${PERSIST_DIR}/password-store" "${PERSIST_DIR}/state"
rm -f "${READY_FILE}" 2>/dev/null || true

if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  log "ERROR: user '${USER_NAME}' does not exist in image. Fix Dockerfile."
  exit 1
fi

if getent group "${GROUP_ID}" >/dev/null 2>&1; then
  usermod -g "${GROUP_ID}" "${USER_NAME}" || true
else
  if getent group "${USER_NAME}" >/dev/null 2>&1; then
    groupmod -g "${GROUP_ID}" "${USER_NAME}" || true
  else
    groupadd -g "${GROUP_ID}" "${USER_NAME}"
  fi
  usermod -g "${GROUP_ID}" "${USER_NAME}" || true
fi

OWNER_OF_UID="$(getent passwd "${USER_ID}" | cut -d: -f1 || true)"
if [[ -n "${OWNER_OF_UID}" && "${OWNER_OF_UID}" != "${USER_NAME}" ]]; then
  NEW_UID="$(find_free_uid)"
  log "UID ${USER_ID} is taken by '${OWNER_OF_UID}'. Moving '${OWNER_OF_UID}' -> UID ${NEW_UID}"
  usermod -u "${NEW_UID}" "${OWNER_OF_UID}" || true
fi

CURRENT_UID="$(id -u "${USER_NAME}")"
CURRENT_GID="$(id -g "${USER_NAME}")"

if [[ "${CURRENT_UID}" != "${USER_ID}" ]]; then
  log "Changing ${USER_NAME} UID ${CURRENT_UID} -> ${USER_ID}"
  usermod -u "${USER_ID}" "${USER_NAME}" || true
fi

if [[ "${CURRENT_GID}" != "${GROUP_ID}" ]]; then
  log "Changing ${USER_NAME} GID ${CURRENT_GID} -> ${GROUP_ID}"
  usermod -g "${GROUP_ID}" "${USER_NAME}" || true
fi

fix_owner_if_needed "${PERSIST_DIR}/gnupg"
fix_owner_if_needed "${PERSIST_DIR}/password-store"
fix_owner_if_needed "${PERSIST_DIR}/state"
fix_owner_if_needed "${HOME_DIR}"

rm -rf "${HOME_DIR}/.gnupg"
ln -s "${PERSIST_DIR}/gnupg" "${HOME_DIR}/.gnupg"
chown -h "${USER_ID}:${GROUP_ID}" "${HOME_DIR}/.gnupg" || true

rm -rf "${HOME_DIR}/.password-store"
ln -s "${PERSIST_DIR}/password-store" "${HOME_DIR}/.password-store"
chown -h "${USER_ID}:${GROUP_ID}" "${HOME_DIR}/.password-store" || true

touch "${PERSIST_DIR}/state/zsh_history"
rm -f "${HOME_DIR}/.zsh_history"
ln -s "${PERSIST_DIR}/state/zsh_history" "${HOME_DIR}/.zsh_history"
chown -h "${USER_ID}:${GROUP_ID}" "${HOME_DIR}/.zsh_history" || true

mkdir -p "${PERSIST_DIR}/gnupg"
chown -R "${USER_ID}:${GROUP_ID}" "${PERSIST_DIR}/gnupg" || true
chmod 700 "${PERSIST_DIR}/gnupg" || true
find "${PERSIST_DIR}/gnupg" -type d -exec chmod 700 {} \; 2>/dev/null || true
find "${PERSIST_DIR}/gnupg" -type f -exec chmod 600 {} \; 2>/dev/null || true

cat > "${PERSIST_DIR}/gnupg/gpg-agent.conf" <<'EOF'
allow-loopback-pinentry
EOF
chown "${USER_ID}:${GROUP_ID}" "${PERSIST_DIR}/gnupg/gpg-agent.conf" || true
chmod 600 "${PERSIST_DIR}/gnupg/gpg-agent.conf" || true

runuser -u "${USER_NAME}" -- env \
  GNUPGHOME="${HOME_DIR}/.gnupg" \
  PASSWORD_STORE_DIR="${PASSWORD_STORE_DIR}" \
  GPG_NAME="${GPG_NAME}" \
  GPG_EMAIL="${GPG_EMAIL}" \
  GPG_PASSPHRASE="${GPG_PASSPHRASE}" \
  bash -lc '
set -Eeuo pipefail
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME" || true
rm -f "$GNUPGHOME"/S.gpg-agent* 2>/dev/null || true
gpgconf --kill gpg-agent >/dev/null 2>&1 || true
gpgconf --launch gpg-agent >/dev/null 2>&1 || true
has_secret_key() { gpg --list-secret-keys --with-colons 2>/dev/null | grep -q "^sec:"; }

if ! has_secret_key; then
  echo "[entrypoint] No secret key found. Generating per-machine GPG key..."
  umask 077
  cat > /tmp/gpg-batch <<EOF
Key-Type: RSA
Key-Length: 4096
Name-Real: ${GPG_NAME}
Name-Email: ${GPG_EMAIL}
Expire-Date: 0
EOF
  if [[ -n "${GPG_PASSPHRASE}" ]]; then
    cat >> /tmp/gpg-batch <<EOF
Passphrase: ${GPG_PASSPHRASE}
%commit
EOF
  else
    cat >> /tmp/gpg-batch <<EOF
%no-protection
%commit
EOF
  fi
  gpg --batch --pinentry-mode loopback --generate-key /tmp/gpg-batch
  rm -f /tmp/gpg-batch >/dev/null 2>&1 || true
fi

FPR=$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: "
  \$1==\"sec\" {insec=1}
  insec && \$1==\"fpr\" {print \$10; exit}
")
if [[ -z "$FPR" ]]; then
  echo "[entrypoint] ERROR: Could not determine secret key fingerprint." >&2
  gpg -K --with-colons >&2 || true
  exit 1
fi

if [[ ! -f "${PASSWORD_STORE_DIR}/.gpg-id" ]]; then
  echo "[entrypoint] Initializing pass store..."
  pass init "$FPR"
fi
'

touch "${READY_FILE}" || true
chown "${USER_ID}:${GROUP_ID}" "${READY_FILE}" || true
log "Ready marker created: ${READY_FILE}"

if [[ -n "${GERRIT_HOST}" ]]; then
  runuser -u "${USER_NAME}" -- bash -lc "git config --global credential.https://${GERRIT_HOST}.useHttpPath true"
  log "Configured useHttpPath for https://${GERRIT_HOST}"
fi

if [[ -n "${GERRIT_HOST}" && -n "${GERRIT_USERNAME}" && -n "${GERRIT_PAT}" ]]; then
  log "Seeding Gerrit HTTPS credentials for ${GERRIT_HOST} (${GERRIT_USERNAME})"
  runuser -u "${USER_NAME}" -- bash -lc "
    printf 'protocol=https\nhost=${GERRIT_HOST}\nusername=${GERRIT_USERNAME}\npassword=${GERRIT_PAT}\n\n' | git credential approve
  "
fi

if [[ $# -eq 0 ]]; then
  exec runuser -u "${USER_NAME}" -- zsh -l
else
  exec runuser -u "${USER_NAME}" -- "$@"
fi