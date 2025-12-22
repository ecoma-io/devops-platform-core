#!/usr/bin/env sh
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-dev}"

# Enable verbose tracing when DEBUG is set or when running in CI
if [ -n "$DEBUG" ] || [ -n "$CI" ]; then
    set -x
fi

# Helper: collect debug info when kubectl wait/apply fails
debug_collect() {
    ns="$1"
    selector="$2"
    outdir="$ROOT_DIR/debug-$(date +%Y%m%dT%H%M%S)"
    mkdir -p "$outdir"
    echo "Collecting debug info into $outdir"
    # Export some cluster state
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
        for p in $(kubectl get pods -n "$ns" -l "$selector" -o name 2>/dev/null); do
            pname="${p#pod/}"
            kubectl logs -n "$ns" "$pname" --all-containers=true > "$outdir/log-$pname.txt" 2>&1 || true
        done
    fi

    if [ -n "$CI" ]; then
       find "$outdir" -type f | while read -r f; do
           echo "===== $f ====="
           cat "$f" || true
           echo ""
       done
    else 
        echo "Debug data saved to $outdir"
    fi
}

# Helper: apply kustomize; when DEBUG set, persist manifests for inspection
apply_kustomize() {
    src="$1"
    if [ -n "$DEBUG" ] || [ -n "$CI" ]; then
        tmp="$(mktemp -t kustomize.XXXXXX).yaml"
        kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm "$src" > "$tmp" 2> /dev/null || true
        echo "Kustomize output saved to $tmp"
        if ! kubectl apply --server-side -f "$tmp"; then
            echo "kubectl apply failed for $src — collecting debug info"
            debug_collect kube-system ""
            return 1
        fi
        rm -f "$tmp"
    else
        kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm "$src" | kubectl apply --server-side -f -
    fi
}

# Helper: wait for pods with selector in namespace; on failure collect debug info
wait_or_debug() {
    ns="$1"
    selector="$2"
    timeout="${3:-300s}"
    if ! kubectl wait --for=condition=ready --timeout="$timeout" pod -l "$selector" -n "$ns"; then
        echo "kubectl wait failed for selector=$selector ns=$ns"
        debug_collect "$ns" "$selector"
        return 1
    fi
}

group(){
    if [ -n "$CI" ]; then
        printf "%s\n" "::group::$1"
    else
        echo "$1"
    fi
}

endgroup(){
    if [ -n "$CI" ]; then
        printf "%s\n" "::endgroup::"
    else
        printf "%s\n" "-------------------"
    fi
}


# Stop if MODE not one of allowed values
if [ "$MODE" != "static-analysis" ] && [ "$MODE" != "staging" ] && [ "$MODE" != "dev" ] && [ "$MODE" != "production" ]; then
    echo "Error: Invalid environment. Use 'static-analysis', 'dev', 'staging', or 'production'."
    exit 1
fi



if [ "$MODE" = "staging" ] || [ "$MODE" = "static-analysis" ]; then
    group "Installing toolings..."
    echo "⏱️ Installing kubectl..."
    tmp="$(mktemp -t setup.XXXXXX)"
    curl -fsSL -o "$tmp" "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 "$tmp" /usr/local/bin/kubectl

    echo "⏱️ Installing helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
    sudo chmod 755 /usr/local/bin/helm

    echo "⏱️ Installing kustomize..."
    curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | sudo bash
    sudo mv kustomize /usr/local/bin/
    sudo chmod 755 /usr/local/bin/kustomize
  
    sudo mkdir -p /bats
    echo "⏱️ Installing BATS..."
    git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
    sudo /tmp/bats-core/install.sh /usr/local
    sudo chmod 755 /usr/local/bin/bats
    echo "⏱️ Installing BATS libraries..."
    sudo git clone https://github.com/bats-core/bats-assert.git /bats/bats-assert --depth 1
    sudo git clone https://github.com/bats-core/bats-support.git /bats/bats-support --depth 1
    sudo git clone https://github.com/jasonkarns/bats-mock.git /bats/bats-mock --depth 1
    sudo git clone https://github.com/ztombol/bats-file.git /bats/bats-file --depth 1
    git clone https://github.com/bats-core/bats-detik.git /tmp/bats-detik
    sudo cp -r /tmp/bats-detik/lib/ /bats/detik
    sudo chmod -R 0755 /bats
    endgroup
fi

if [ "$MODE" = "static-analysis" ]; then
    group "Install static analysis extra tools..."
    npm install -g markdownlint-cli
    endgroup
fi

if [ "$MODE" = "dev" ]; then
   group "Setting up k3d cluster for development..."
   k3d cluster delete devops-platform-core || true 
   k3d cluster create --config "$ROOT_DIR/k3d.yaml" --wait    
fi

if [ "$MODE" = "dev" ] ||  [ "$MODE" = "staging" ] || [ "$MODE" = "production" ]; then

    group "1️⃣ Deploying CRDs & Flannel..."
    apply_kustomize "$ROOT_DIR"/bootstrap/base
    apply_kustomize "$ROOT_DIR"/bootstrap/"$MODE"
    wait_or_debug kube-system "k8s-app=flannel" 300s
    endgroup    

    group "2️⃣ Deploying CoreDNS..."
    apply_kustomize "$ROOT_DIR"/deploy/kube-system/coredns/"$MODE"
    wait_or_debug kube-system "k8s-app=coredns" 300s
    endgroup

    group "3️⃣ Deploying Node Local DNS Cache..."
    apply_kustomize "$ROOT_DIR"/deploy/kube-system/node-local-dns/"$MODE"
    wait_or_debug kube-system "k8s-app=node-local-dns" 300s
    endgroup

    group "4️⃣ Deploying Metrics server..."
    apply_kustomize "$ROOT_DIR"/deploy/kube-system/metrics-server/"$MODE"    
    wait_or_debug kube-system "app.kubernetes.io/instance=metrics-server" 300s   
    endgroup

    group "5️⃣ Deploying Storage System components..."
    apply_kustomize "$ROOT_DIR"/deploy/storage-system/openebs-lpv/"$MODE"    
    wait_or_debug storage-system "app=localpv-provisioner" 300s   
    endgroup

fi