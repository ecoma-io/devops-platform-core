#!/usr/bin/env bats

setup() {
  KUSTOMIZE_DIR="$(dirname "$BATS_TEST_FILENAME")"
}

@test "kustomize build succeeds in argocd/base" {
  cd "$KUSTOMIZE_DIR"
  run kustomize build --helm-debug --enable-helm --load-restrictor LoadRestrictionsNone .
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q "apiVersion\|kind" || { echo "$output" >&2; false; }
}
