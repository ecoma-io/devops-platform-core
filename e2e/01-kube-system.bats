#!/usr/bin/env bats
# System component readiness checks

setup() {
  load '/bats/bats-support/load.bash'
  load '/bats/bats-assert/load.bash'
  load '/bats/detik/detik.bash'
  DETIK_CLIENT_NAME="kubectl"
  DETIK_CLIENT_NAMESPACE="kube-system"
  RUN_ID=$(head /dev/urandom | tr -dc a-z0-9 | head -c6)
  PODS_TO_CLEAN=()  
  ROOT_DIR="$(dirname "$BATS_TEST_FILENAME")/.."
}

teardown() {
  for pod in "${PODS_TO_CLEAN[@]}"; do
    kubectl delete pod "$pod" -n kube-system --ignore-not-found
  done
}

# Helper: create a pod on a specific node using a manifest piped to kubectl
create_pod_on_node() {
  local pod_name="$1"
  local node_name="$2"
  kubectl apply -n kube-system -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
spec:
  nodeName: ${node_name}
  containers:
  - name: net
    image: nicolaka/netshoot:latest
    command: ["sleep","24h"]
  restartPolicy: Never
EOF
}

@test "Flannel pods (3 pods) are Ready and working" {

  # keep original check for kube-flannel pods
  run verify "there are 3 pods named 'kube-flannel'"
  assert_success

  # Need at least 2 nodes to place pods on different nodes
  readarray -t NODE_NAMES < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [ "${#NODE_NAMES[@]}" -lt 2 ]; then
    skip "Requires at least 2 nodes to run cross-node connectivity test"
  fi

  NODE_A="${NODE_NAMES[0]}"
  NODE_B="${NODE_NAMES[1]}"

  POD_A1="flannel-test-a1-$RUN_ID"
  POD_A2="flannel-test-a2-$RUN_ID"
  POD_B="flannel-test-b-$RUN_ID"

  PODS_TO_CLEAN+=("$POD_A1" "$POD_A2" "$POD_B")

  # Create two pods on NODE_A and one pod on NODE_B using a small diagnostics image
  create_pod_on_node "${POD_A1}" "${NODE_A}"
  create_pod_on_node "${POD_A2}" "${NODE_A}"
  create_pod_on_node "${POD_B}" "${NODE_B}"

  # wait for all test pods to become Ready
  kubectl wait -n kube-system --for=condition=ready pod/${POD_A1} pod/${POD_A2} pod/${POD_B} --timeout=150s

  # ensure pods exist
  run kubectl get pod -n kube-system ${POD_A1} ${POD_A2} ${POD_B}
  assert_success

  # get pod IPs
  IP_A1=$(kubectl get pod -n kube-system ${POD_A1} -o jsonpath='{.status.podIP}')
  IP_A2=$(kubectl get pod -n kube-system ${POD_A2} -o jsonpath='{.status.podIP}')
  IP_B=$(kubectl get pod -n kube-system ${POD_B} -o jsonpath='{.status.podIP}')

  assert_not_equal "" "$IP_A1"
  assert_not_equal "" "$IP_A2"
  assert_not_equal "" "$IP_B"

  # ping same-node pod (A1 -> A2)
  run kubectl exec -n kube-system ${POD_A1} -- ping -c 3 ${IP_A2}
  assert_success

  # ping cross-node pod (A1 -> B)
  run kubectl exec -n kube-system ${POD_A1} -- ping -c 3 ${IP_B}
  assert_success
}

@test "CoreDNS & DNS cache pods (1 coredns & 3 dns-cache) are Ready and working" {  
  run verify "there are 1 pods named 'coredns'"
  assert_success

  run verify "there are 3 pods named 'dns-cache'"
  assert_success

  DNS_CHECK_POD_NAME="dns-check-$RUN_ID"
  PODS_TO_CLEAN+=("dns-check-$RUN_ID")
  # Create a temporary pod in kube-system and use it for testing DNS resolution
  kubectl run dns-check-$RUN_ID -n kube-system --restart=Never --image=nicolaka/netshoot:latest -- sleep 24h

  # Wait for the test pod to become Ready
  kubectl wait -n kube-system --for=condition=ready pod/dns-check-$RUN_ID --timeout=150s

  run kubectl exec -n kube-system dns-check-$RUN_ID -- nslookup kubernetes.default.svc.cluster.local
  assert_success

  run kubectl exec -n kube-system dns-check-$RUN_ID -- nslookup google.com
  assert_success
}

 
@test "Metrics-server Pod are Ready (1 pod) and working" {
  run verify "there are 1 pods named 'metrics-server'"
  assert_success

  run kubectl top nodes
  assert_success
}

