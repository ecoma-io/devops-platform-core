#!/usr/bin/env bats
# Basic cluster health tests

load '/bats/bats-support/load.bash'
load '/bats/bats-assert/load.bash'
load '/bats/detik/detik.bash'

@test "Kubernetes API server is accessible" {
  run kubectl cluster-info
  assert_success
  assert_output --partial "Kubernetes control plane"
}

@test "All nodes are Ready" {
  run kubectl get nodes
  assert_success
  refute_output --partial "NotReady"
}

@test "All system pods are running" {
  run kubectl get pods -A
  assert_success
  refute_output --partial "Error"
  refute_output --partial "CrashLoopBackOff"
}
