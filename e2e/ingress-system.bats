#!/usr/bin/env bats

load "/bats/bats-support/load.bash"
load "/bats/bats-assert/load.bash"
load "/bats/detik/detik.bash"
load "/bats/bats-file/load.bash"

DETIK_CLIENT_NAME="kubectl"

@test "Traefik pods are running in ingress-system" {
  run kubectl get pods -n ingress-system -l app.kubernetes.io/name=traefik
  assert_success
  assert_output --partial "Running"
}

@test "Traefik service is available" {
  run kubectl get svc -n ingress-system -l app.kubernetes.io/name=traefik
  assert_success
}
