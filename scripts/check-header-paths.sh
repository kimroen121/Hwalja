#!/bin/bash
set -euo pipefail
# Reject absolute Unix/Windows paths without matching C comment delimiters.
if LC_ALL=C grep -Eq '(^|[[:space:]"=:])/[[:alnum:]_.~-]|[[:alpha:]]:[\\/]'; then
  echo 'Generated ABI header contains an absolute path' >&2
  exit 1
fi
