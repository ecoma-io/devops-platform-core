#!/usr/bin/env bats
# DNS and metrics tests

load '/bats/bats-support/load.bash'
load '/bats/bats-assert/load.bash'
load '/bats/detik/detik.bash'

@test "CoreDNS is running" {
  run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=coredns -n kube-system --timeout=30s
  assert_success
}

@test "Node Local DNS is running" {
  run kubectl wait --for=condition=ready pod -l k8s-app=node-local-dns -n kube-system --timeout=30s
  assert_success
}

@test "Metrics Server is running" {
  run kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=metrics-server -n kube-system --timeout=30s
  assert_success
}

@test "Metrics Server API is accessible" {
  # Retry up to 30 times with 5 second intervals (2.5 minutes total)
  # Metrics API can be flaky in CI due to resource constraints
  local max_attempts=30
  local attempt=1
  local success=false
  
  while [ $attempt -le $max_attempts ]; do
    run kubectl top nodes
    if [ "$status" -eq 0 ]; then
      success=true
      break
    fi
    echo "# Attempt $attempt/$max_attempts failed, retrying in 5s..." >&3
    sleep 5
    attempt=$((attempt + 1))
  done
  
  if [ "$success" != true ]; then
    echo "# === Metrics Server Debug Info ===" >&3
    echo "# Pod status:" >&3
    kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server -o wide >&3 2>&1 || true
    echo "# APIService status:" >&3
    kubectl get apiservice v1beta1.metrics.k8s.io -o yaml >&3 2>&1 || true
    echo "# Metrics Server logs (last 50 lines):" >&3
    kubectl logs -n kube-system -l app.kubernetes.io/name=metrics-server --tail=50 >&3 2>&1 || true
    echo "# === End Debug Info ===" >&3
  fi
  
  [ "$success" = true ]
  assert_success
}
