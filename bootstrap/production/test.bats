#!/usr/bin/env bats

setup() {
  load '/bats/bats-support/load.bash'
  load '/bats/bats-assert/load.bash'
  DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
}

@test "kustomize build succeeds in bootstrap/production" {
  run kustomize build --helm-debug --enable-helm --load-restrictor LoadRestrictionsNone ${DIR}
  assert_success
}
