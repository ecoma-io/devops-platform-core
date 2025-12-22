#!/usr/bin/env bats
# System component readiness checks
setup() {
  load '/bats/bats-support/load.bash'
  load '/bats/bats-assert/load.bash'
  load '/bats/detik/detik.bash'
  ROOT_DIR="$(dirname "$BATS_TEST_FILENAME")/.."
  DETIK_CLIENT_NAME="kubectl"
  DETIK_CLIENT_NAMESPACE="kube-system"  
}

@test "Kubernetes API server is accessible" {
  run kubectl cluster-info
  assert_success
  assert_output --partial "Kubernetes control plane"
}

@test "Should have 3 nodes in the cluster" {
  run bash -c "kubectl get nodes --no-headers | wc -l | tr -d '[:space:]'"
  assert_success
  assert_equal "3" "$output"
}

@test "All nodes are in Ready state" {
  run bash -c "kubectl get nodes --no-headers | awk '{print \$2}' | grep -v 'Ready' | wc -l | tr -d '[:space:]'"
  assert_success
  assert_equal "0" "$output"
}