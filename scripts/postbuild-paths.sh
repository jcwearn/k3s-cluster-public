#!/usr/bin/env bash
#
# Prints the path of every Flux Kustomization that has postBuild substitution
# enabled, one per line, relative to the repo root and without the leading "./".
#
# Derived from clusters/prod/ rather than hand-maintained, so a path is covered
# from the moment postBuild is enabled on it and the list never drifts. Both CI
# and the git hooks use this to decide which overlays must render through
# `flux envsubst --strict`.
#
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# -N suppresses the "---" separators yq emits once more than one document
# matches, which would otherwise be read back as a path.
yq -N 'select(.spec.postBuild.substituteFrom != null) | .spec.path' clusters/prod/*.yaml \
  | grep -v '^---$' \
  | sed 's#^\./##' \
  | grep -v '^$' \
  | sort -u
