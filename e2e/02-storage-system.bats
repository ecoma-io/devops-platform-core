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

  # Đợi Pod Running (PVC sẽ tự động Bound nếu Pod lên lịch thành công)
  run kubectl wait --for=condition=Ready pod/${POD_NAME} -n storage-system --timeout=300s
  assert_success

  # Xác nhận PVC đã Bound (tùy chọn, để debug rõ hơn)
  run kubectl get pvc ${PVC_NAME} -n storage-system -o jsonpath='{.status.phase}'
  assert_success
  [ "$output" = "Bound" ]

  # Cleanup
  kubectl delete pod ${POD_NAME} -n storage-system --ignore-not-found
  kubectl delete pvc ${PVC_NAME} -n storage-system --ignore-not-found
  rm -f /tmp/test-pvc.yaml /tmp/test-pod.yaml
}

