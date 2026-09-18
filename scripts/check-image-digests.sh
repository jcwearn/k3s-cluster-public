#!/usr/bin/env bash
#
# Fails on any container image in the rendered overlays that is not pinned by
# digest, unless the image is listed in .ci/image-pin-allowlist.
#
#   scripts/check-image-digests.sh <rendered-dir>
#
# Renovate keeps every `tag@sha256:...` reference current, so a digest is what
# makes a manifest describe one exact image rather than whatever the registry
# serves today. kube-linter's latest-tag check only catches an untagged or
# :latest image; a plain tag slips past it. This closes that gap for the three
# places an image reference lives: containers, initContainers, and the
# volumes[].image.reference form the ansible CronJobs use.
#
# The allowlist exists so that this can be turned on before every image is
# pinned. Each line is one exact image reference. Emptying the file is a goal
# of docs/plans/cluster-hardening, not a permanent state.
#
set -euo pipefail

dir="${1:?usage: check-image-digests.sh <rendered-dir>}"

root="$(git rev-parse --show-toplevel)"
cd "$root"

allowlist="$root/.ci/image-pin-allowlist"
allowed=()
if [ -f "$allowlist" ]; then
  while read -r line; do
    line="${line%%#*}"
    line="${line// /}"
    [ -n "$line" ] && allowed+=("$line")
  done < "$allowlist"
fi

fail=0
found=0
while read -r ref; do
  [ -n "$ref" ] || continue
  found=$((found + 1))
  case "$ref" in
    *@sha256:*) continue ;;
  esac
  for a in "${allowed[@]:-}"; do
    [ "$ref" = "$a" ] && continue 2
  done
  echo "unpinned image: $ref" >&2
  fail=1
done < <(
  yq -N '
    .. | select(has("image") and (.image | tag == "!!str")) | .image,
    .. | select(has("image") and (.image | tag == "!!map") and (.image | has("reference"))) | .image.reference
  ' "$dir"/*.yaml 2>/dev/null | grep -v '^---$' | sort -u
)

if [ "$found" -eq 0 ]; then
  echo "no image references found in $dir -- refusing to pass an empty run" >&2
  exit 1
fi

echo "Checked $found image references."
exit "$fail"
