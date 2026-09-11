#!/usr/bin/env bash
set -euo pipefail

# Trusted system candidate paths for the ai-usagebar executable.
# Ambient PATH lookup is intentionally prohibited to prevent execution
# of untrusted shadow binaries.
readonly CANDIDATES=(
  "/usr/bin/ai-usagebar"
  "/usr/local/bin/ai-usagebar"
)

RESOLVED=""
for candidate in "${CANDIDATES[@]}"; do
  # Verify file exists and is executable
  if [[ ! -f "$candidate" || ! -x "$candidate" ]]; then
    continue
  fi

  # Reject symlinks to ensure execution is not redirected to an untrusted path
  if [[ -L "$candidate" ]]; then
    echo "Warning: rejecting symlinked executable at $candidate" >&2
    continue
  fi

  # Reject untrusted ownership: must be owned by root (UID 0) or current user ($EUID)
  owner_uid=$(stat -c '%u' "$candidate" 2>/dev/null || echo "-1")
  if [[ "$owner_uid" != "0" && "$owner_uid" != "$EUID" ]]; then
    echo "Warning: rejecting executable with untrusted owner (UID $owner_uid) at $candidate" >&2
    continue
  fi

  # Reject world-writable executables (other write bit: octal 002)
  perm=$(stat -c '%a' "$candidate" 2>/dev/null || echo "777")
  if (( (8#$perm & 8#002) != 0 )); then
    echo "Warning: rejecting world-writable executable at $candidate" >&2
    continue
  fi

  RESOLVED="$candidate"
  break
done

if [[ -z "$RESOLVED" ]]; then
  echo "Error: ai-usagebar executable not found in trusted system paths (/usr/bin, /usr/local/bin) or failed security checks." >&2
  exit 127
fi

exec "$RESOLVED" "$@"
