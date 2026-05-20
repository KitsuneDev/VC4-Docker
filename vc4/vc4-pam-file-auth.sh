#!/usr/bin/env bash
set -Eeuo pipefail

credentials_file="${1:-}"
username="${PAM_USER:-}"
password=""

IFS= read -r password || true

if [[ -z "$credentials_file" || -z "$username" || ! -f "$credentials_file" ]]; then
  exit 1
fi

while IFS=$'\t' read -r expected_user expected_password _; do
  [[ -z "${expected_user:-}" || "${expected_user:0:1}" == "#" ]] && continue
  if [[ "$username" == "$expected_user" && "$password" == "${expected_password:-}" ]]; then
    exit 0
  fi
done < "$credentials_file"

exit 1
