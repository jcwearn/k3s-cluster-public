#!/usr/bin/env bash
#
# Renders every kustomize overlay in the repo into one directory, one file per
# overlay, named after its path with "/" replaced by "__":
#
#   scripts/render-all.sh <outdir>
#
# This is the single step the CI checks hang off. kubeconform, kube-linter and
# the rendered diff all read <outdir> rather than re-running kustomize, so they
# see exactly what Flux applies -- post-substitution -- and agree with each
# other about what that is.
#
# clusters/ is skipped: those are the Flux Kustomization objects themselves,
# not overlays, and Flux generates the kustomization for ./apps at runtime.
#
# Exits non-zero if any overlay fails to render, after trying all of them, and
# emits a GitHub error annotation per failure when running under Actions. An
# empty run is an error rather than a pass: a guard that silently checks
# nothing is the failure mode this script exists to catch.
#
set -euo pipefail

outdir="${1:?usage: render-all.sh <outdir>}"

root="$(git rev-parse --show-toplevel)"
cd "$root"
mkdir -p "$outdir"

fail=0
count=0
while read -r f; do
  d=$(dirname "$f")
  count=$((count + 1))
  if ! err=$("$root/scripts/render.sh" "$d" "$outdir/${d//\//__}.yaml" 2>&1); then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error file=$f::render failed for $d: $err"
    else
      echo "FAIL $d: $err" >&2
    fi
    fail=1
  fi
done < <(git ls-files '*kustomization.yaml' | grep -v '^clusters/')

if [ "$count" -eq 0 ]; then
  echo "no overlays found -- refusing to pass an empty run" >&2
  exit 1
fi

echo "Rendered $count overlays into $outdir."
exit "$fail"
