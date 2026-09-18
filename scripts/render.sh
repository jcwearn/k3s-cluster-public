#!/usr/bin/env bash
#
# Renders one kustomize overlay the way Flux will apply it.
#
#   scripts/render.sh <dir>            # rendered manifests on stdout
#   scripts/render.sh <dir> <outfile>  # ... written to <outfile>
#
# `kustomize build` is only half of what Flux does. For every path listed in
# clusters/prod/ with postBuild substitution enabled, Flux also replaces each
# ${VAR} from the cluster-vars Secret -- and replaces an unknown one with an
# EMPTY STRING while reporting success. `flux envsubst --strict` is the only
# thing that turns that into a failure, so this pipes through it whenever the
# overlay sits under a substituted path.
#
# The placeholder values are exported here rather than in each caller. Only
# the NAMES have to match the keys in the cluster-vars Secret; the values are
# irrelevant, since this checks resolution rather than correctness. Adding a
# key to the Secret means adding it here too. Values already present in the
# environment are left alone.
#
set -euo pipefail

dir="${1:?usage: render.sh <dir> [outfile]}"
out="${2:-/dev/stdout}"

root="$(git rev-parse --show-toplevel)"
cd "$root"
dir="${dir#./}"
dir="${dir%/}"

export DOMAIN="${DOMAIN:-example.test}"
export TAILNET="${TAILNET:-example-tailnet.ts.net}"
export LAN_PREFIX="${LAN_PREFIX:-10.255.255}"
export MGMT_PREFIX="${MGMT_PREFIX:-10.255.254}"
export R2_ENDPOINT="${R2_ENDPOINT:-https://example.r2.cloudflarestorage.com}"

substituted=false
while read -r p; do
  [ -n "$p" ] || continue
  if [ "$dir" = "$p" ] || [[ "$dir" == "$p"/* ]]; then
    substituted=true
    break
  fi
done < <("$root/scripts/postbuild-paths.sh")

if [ "$substituted" = true ]; then
  kustomize build "$dir" | flux envsubst --strict > "$out"
else
  kustomize build "$dir" > "$out"
fi
