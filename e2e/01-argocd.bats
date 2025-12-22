#!/usr/bin/env bats
# ArgoCD health tests

load '/bats/bats-support/load.bash'
load '/bats/bats-assert/load.bash'
load '/bats/detik/detik.bash'

DETIK_CLIENT_NAME="kubectl"

@test "ArgoCD namespace exists" {
  run kubectl get namespace gitops-system
  assert_success
}

@test "ArgoCD application controller is ready" {
  run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n gitops-system --timeout=30s
  assert_success
}

@test "ArgoCD repo server is ready" {
  run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n gitops-system --timeout=30s
  assert_success
}

@test "ArgoCD server is ready" {
  run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n gitops-system --timeout=30s
  assert_success
}

@test "ArgoCD applicationset controller is ready" {
  run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-applicationset-controller -n gitops-system --timeout=30s
  assert_success
}
