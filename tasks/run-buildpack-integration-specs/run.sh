#!/bin/bash -l
set -o errexit
set -o nounset
set -o pipefail

"./cf-space/login"

 if [[ -d "uncached-buildpack" ]]; then
   export UNCACHED_BUILDPACK_FILE=$(realpath $(find ./uncached-buildpack -name "*.zip"))
 fi

if [[ -d "cached-buildpack" ]]; then
  export CACHED_BUILDPACK_FILE=$(realpath $(find ./cached-buildpack -name "*.zip"))
  echo "BUILDPACK FILE!!!!!!!!!: $CACHED_BUILDPACK_FILE"
fi

cd buildpack

if [[ -z ${SKIP_DOCKER_START:-} ]]; then
  echo "Start Docker"
  ../buildpacks-ci/scripts/start-docker >/dev/null
fi

./scripts/integration.sh
