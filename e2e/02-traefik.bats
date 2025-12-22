#!/usr/bin/env bats
# Traefik ingress health tests

load '/bats/bats-support/load.bash'
load '/bats/bats-assert/load.bash'
load '/bats/detik/detik.bash'

@test "Traefik namespace exists" {
  run kubectl get namespace ingress-system
  assert_success
}

@test "Traefik pods are ready" {
  run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n ingress-system --timeout=30s
  assert_success
}

@test "Traefik service exists" {
  run kubectl get service traefik -n ingress-system
  assert_success
}
