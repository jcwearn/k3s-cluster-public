#!/usr/bin/env bash
#
# Structural checks on the encrypted secrets. Runs in CI, so it must work
# WITHOUT the age private key -- which rules out `sops -d`, because the MAC is
# itself encrypted and verifying it requires decryption.
#
# What it can do instead is catch the specific mistake that produced a broken
# file here: two *.sops.yaml sharing a `mac` value. The MAC covers the file's
# values including the plaintext ones, so two Secrets in different namespaces
# cannot legitimately share one. An identical MAC means one file was copied from
# the other rather than encrypted -- which yields valid ciphertext, an invalid
# MAC, and a file Flux accepts while the sops CLI refuses it. That combination
# hid for sixteen months.
#
# For a real MAC verification you need the key, so that stays a local command:
#
#   for f in $(git ls-files '*.sops.yaml'); do sops -d "$f" >/dev/null || echo "BAD: $f"; done
#
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
fail=0

# The pathspec exclusion is load-bearing: git's '*' matches the empty string, so
# '*.sops.yaml' also matches the repo-root .sops.yaml, which is the sops CONFIG
# file rather than an encrypted secret. Without this the check reports its own
# configuration as a broken secret.
files=$(git ls-files '*.sops.yaml' ':!:.sops.yaml')
[ -n "$files" ] || { echo "no *.sops.yaml files found"; exit 0; }

echo "Checking $(echo "$files" | wc -l | tr -d ' ') encrypted files..."

# 1. Duplicate MACs -- the copied-file signature.
dupes=$(for f in $files; do
          mac=$(grep -m1 -E '^\s+mac: ' "$f" 2>/dev/null | sed 's/.*mac: //')
          [ -n "$mac" ] && printf '%s\t%s\n' "$(printf %s "$mac" | shasum | cut -c1-16)" "$f"
        done | sort | awk -F'\t' '{c[$1]=c[$1]" "$2} END {for (m in c) {n=split(c[m],a," "); if (n>1) print c[m]}}')

if [ -n "$dupes" ]; then
  echo "::error::Two or more encrypted files share a MAC. That means one was copied"
  echo "         from another rather than encrypted, so its MAC does not match its"
  echo "         contents. Flux will accept it; \`sops -d\` will not."
  echo "$dupes" | sed 's/^/  shared MAC:/'
  fail=1
fi

# 2. Every file actually carries sops metadata. A file named *.sops.yaml that is
#    plaintext is the other way this goes wrong, and it is worse.
for f in $files; do
  if ! grep -q '^sops:' "$f"; then
    echo "::error::$f is named as encrypted but has no sops metadata."
    fail=1
  fi
  if ! grep -q 'ENC\[AES256_GCM' "$f"; then
    echo "::error::$f contains no encrypted values."
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "All encrypted files look structurally sound."
exit "$fail"
