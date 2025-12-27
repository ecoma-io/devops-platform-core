#!/usr/bin/env bats
# System component readiness checks

# Copied debug helpers (adapted from setup.sh) so tests can collect logs
# and other cluster state when `wait` fails. The user asked to copy them
# directly into the test rather than source the original file.

TEST_ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/.."

debug_collect() {
  ns="$1"
  selector="$2"
  outdir="$TEST_ROOT_DIR/debug-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$outdir"
  echo "Collecting debug info into $outdir"
  kubectl version --client=true > "$outdir/kubectl-client.txt" 2>&1 || true
  kubectl cluster-info dump --output-directory="$outdir/cluster-dump" 2>/dev/null || true
  if [ -n "$ns" ]; then
    kubectl get pods -n "$ns" -o wide > "$outdir/pods.txt" 2>&1 || true
    kubectl get events -n "$ns" --sort-by='.metadata.creationTimestamp' > "$outdir/events.txt" 2>&1 || true
    kubectl describe pods -n "$ns" > "$outdir/describe-pods.txt" 2>&1 || true
  else
    kubectl get pods --all-namespaces -o wide > "$outdir/pods-all-ns.txt" 2>&1 || true
    kubectl get events --all-namespaces --sort-by='.metadata.creationTimestamp' > "$outdir/events-all-ns.txt" 2>&1 || true
  fi

  if [ -n "$selector" ] && [ -n "$ns" ]; then
    if echo "$selector" | grep -q '/'; then
      pname="${selector#pod/}"
      kubectl logs -n "$ns" "$pname" --all-containers=true > "$outdir/log-$pname.txt" 2>&1 || true
    else
      for p in $(kubectl get pods -n "$ns" -l "$selector" -o name 2>/dev/null); do
        pname="${p#pod/}"
        kubectl logs -n "$ns" "$pname" --all-containers=true > "$outdir/log-$pname.txt" 2>&1 || true
      done
    fi
  fi

  echo "Debug data saved to $outdir"
}

wait_or_debug() {
  ns="$1"
  selector="$2"
  timeout="${3:-300s}"
  if echo "$selector" | grep -q '/'; then
    target="$selector"
    if ! kubectl wait --for=condition=ready --timeout="$timeout" "$target" -n "$ns"; then
      echo "kubectl wait failed for target=$target ns=$ns"
      debug_collect "$ns" "$selector"
      return 1
    fi
  else
    if ! kubectl wait --for=condition=ready --timeout="$timeout" pod -l "$selector" -n "$ns"; then
      echo "kubectl wait failed for selector=$selector ns=$ns"
      debug_collect "$ns" "$selector"
      return 1
    fi
  fi
}

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

@test "lpv-provisioner dynamic provisioning works" {

  # Generate unique resource names
  PVC_NAME="test-lpv-pvc-$RUN_ID"
  POD_NAME="test-lpv-pod-$RUN_ID"

  # Check if there is 1 pod with label app=localpv-provisioner in storage-system and it is Running
  run kubectl get pod -n storage-system -l app=localpv-provisioner -o jsonpath='{.items[0].status.phase}'
  assert_success
  [ "$output" = "Running" ]

  # Create a test PVC manifest

  cat <<EOF > /tmp/test-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: storage-system
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 16Mi
  storageClassName: localpv-hot
EOF

  # Create a test Pod manifest

  cat <<EOF > /tmp/test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: storage-system
spec:
  containers:
  - name: busybox
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: test-vol
      mountPath: /mnt
  volumes:
  - name: test-vol
    persistentVolumeClaim:
      claimName: ${PVC_NAME}
EOF

  # Cleanup any old resources with same name (if exist)
  kubectl delete pod ${POD_NAME} -n storage-system --ignore-not-found
  kubectl delete pvc ${PVC_NAME} -n storage-system --ignore-not-found

  # Apply PVC và Pod trước
  kubectl apply -f /tmp/test-pvc.yaml
  kubectl apply -f /tmp/test-pod.yaml

  # Wait for Pod to be Ready
  run wait_or_debug storage-system "pod/${POD_NAME}" 150s
  assert_success

  # Confirm PVC is Bound (optional, for clearer debugging)
  run kubectl get pvc ${PVC_NAME} -n storage-system -o jsonpath='{.status.phase}'
  assert_success
  [ "$output" = "Bound" ]

  # Cleanup
  kubectl delete pod ${POD_NAME} -n storage-system --ignore-not-found
  kubectl delete pvc ${PVC_NAME} -n storage-system --ignore-not-found
  rm -f /tmp/test-pvc.yaml /tmp/test-pod.yaml
}

