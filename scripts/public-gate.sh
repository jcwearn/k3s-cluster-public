#!/usr/bin/env bash
#
# Pre-publication gate for the public mirror.
#
# Renders the tree that .github/workflows/publish.yaml would push, then checks it for the
# literal values held in the cluster-vars Secret.
#
# It greps for the actual values rather than for hand-written patterns. A pattern is either
# too broad -- '\.ts\.net' matches the deliberate placeholders in validate.yaml and the
# flux-operator docs -- or too narrow, missing a value nobody thought to write down. The
# Secret is the authority on what must not appear.
#
# Every check carries a positive control: the same grep is run against the private tree and
# must find something there. Without that, a zero result cannot distinguish "absent" from
# "my pattern is broken".
#
# Requires cluster access to read the Secret. Values are never printed.
#
# Usage:  ./scripts/public-gate.sh
# Exit:   0 clean, 1 a value leaked or a control failed.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

rsync -a --exclude=.git/ --exclude-from=.publicignore ./ "$out/"
echo "Rendered $(find "$out" -type f | wc -l | tr -d ' ') files."
echo

vars=$(kubectl -n flux-system get secret cluster-vars -o json | python3 -c 'import json,sys,base64
d = json.load(sys.stdin)["data"]
for k, v in sorted(d.items()):
    print("%s\t%s" % (k, base64.b64decode(v).decode()))')

if [ -z "$vars" ]; then
  echo "Could not read cluster-vars. Is kubectl pointed at the cluster?" >&2
  exit 1
fi

fail=0
printf '%-24s %8s %8s  %s\n' VALUE PUBLIC PRIVATE VERDICT

check() {
  local label="$1" needle="$2" want_control="$3"
  local pub priv verdict
  pub=$(grep -rlF -- "$needle" "$out" 2>/dev/null | wc -l | tr -d ' ')
  priv=$(git grep -lIF -- "$needle" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$pub" != "0" ]; then
    verdict="*** LEAK ***"; fail=1
    grep -rlF -- "$needle" "$out" 2>/dev/null | sed "s|$out/|      |"
  elif [ "$want_control" = "yes" ] && [ "$priv" = "0" ]; then
    verdict="NO POSITIVE CONTROL"; fail=1
  else
    verdict="clean"
  fi
  printf '%-24s %8s %8s  %s\n' "$label" "$pub" "$priv" "$verdict"
}

while IFS=$'\t' read -r k v; do
  [ -n "${v:-}" ] || continue
  check "$k" "$v" yes
done <<< "$vars"

# Additional needles that are not in cluster-vars -- historical values, personal identifiers,
# anything else that should never appear. One per line, blank lines and # comments ignored.
#
# They live in .publicgate-extra rather than in this file, and that file is excluded from the
# mirror: a gate that spells out the values it is looking for would publish them itself. This
# script found exactly that bug in its own first draft.
#
# No positive control is required for these. They should be absent from the private tree too,
# so 0/0 is the expected healthy result.
if [ -f .publicgate-extra ]; then
  while IFS= read -r needle; do
    case "$needle" in ''|'#'*) continue ;; esac
    check "extra: ${needle:0:6}..." "$needle" no
  done < .publicgate-extra
else
  echo "(no .publicgate-extra file -- checking cluster-vars values only)"
fi

echo
if [ "$fail" = "0" ]; then
  echo "Gate clean."
else
  echo "Gate FAILED. Do not publish."
fi
exit "$fail"
