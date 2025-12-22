#!/usr/bin/env sh
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

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


# If running in CI, install dependencies
if [ -n "$CI" ]; then
    group "Installing dependencies..."
    # Install k3d
    if ! command -v k3d > /dev/null 2>&1; then
        printf "⏱️ Installing k3d...\n"
        wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    fi

    # Install BATS && supporting libraries
    if ! command -v bats > /dev/null 2>&1; then
        printf "⏱️ Installing BATS...\n"
        git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
        sudo /tmp/bats-core/install.sh /usr/local
        rm -rf /tmp/bats-core

        sudo git clone https://github.com/bats-core/bats-assert.git /bats/bats-assert --depth 1
        sudo git clone https://github.com/bats-core/bats-support.git /bats/bats-support --depth 1
        sudo git clone https://github.com/jasonkarns/bats-mock.git /bats/bats-mock --depth 1
        sudo git clone https://github.com/ztombol/bats-file.git /bats/bats-file --depth 1
        sudo chmod -R 755 /bats

        git clone https://github.com/bats-core/bats-detik.git /tmp/bats-detik
        sudo cp -r /tmp/bats-detik/lib/ /bats/detik
        rm -rf /tmp/bats-detik

        printf "⏱️ Installing dx-kit...\n"
        FILE_NAME="devops-utils.tar.gz"
        DOWNLOAD_URL=$(curl -s https://api.github.com/repos/ecoma-io/devops-tool-dx-kit/releases/latest \
        | jq -r ".assets[] | select(.name == \"$FILE_NAME\") | .browser_download_url")
        if [ -n "${DOWNLOAD_URL:-}" ]; then
          curl -fL -o "$FILE_NAME" "$DOWNLOAD_URL"
          sudo tar --no-same-owner -xzf "$FILE_NAME" -C /usr/local/bin
          sudo chmod -R 755 /usr/local/bin
          rm -f "$FILE_NAME"
        else
          printf "⚠️ Could not find %s in latest release assets\n" "$FILE_NAME" >&2
        fi

        NEED_INSTALL_SYSTEM_PACKAGES="${NEED_INSTALL_SYSTEM_PACKAGES:-} parallel"
    fi

    # Install system packages if needed (safe when variable may be unset)
    if [ -n "${NEED_INSTALL_SYSTEM_PACKAGES:-}" ]; then
      printf "⏱️ Installing required packages: %s\n" "$NEED_INSTALL_SYSTEM_PACKAGES"
      sudo apt-get update
      printf "%s\n" "$NEED_INSTALL_SYSTEM_PACKAGES" | xargs -r sudo apt-get install -y --
    fi


    
    # Install ArgoCD CLI
    if ! command -v argocd > /dev/null 2>&1; then
        curl -sSL -o /tmp/argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
        sudo install -m 555 /tmp/argocd-linux-amd64 /usr/local/bin/argocd
        sudo chmod +x /usr/local/bin/argocd
        rm /tmp/argocd-linux-amd64
    fi


    if ! command -v kubectl >/dev/null 2>&1; then
        printf "⏱️ Installing kubectl...\n"
        KUBECTL_URL="https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        tmp="$(mktemp)"
        curl -fsSL -o "$tmp" "$KUBECTL_URL"
        sudo install -o root -g root -m 0755 "$tmp" /usr/local/bin/kubectl
    fi

    # Install Helm 3.x
    if ! command -v helm > /dev/null 2>&1; then
        printf "⏱️ Installing Helm...\n"
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    # Install kustomize
    if ! command -v kustomize > /dev/null 2>&1; then
        curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
        sudo mv kustomize /usr/local/bin/kustomize
    fi


    # Install kubeseal
    if ! command -v kubeseal > /dev/null 2>&1; then
        printf "⏱️ Installing kubeseal...\n"
        KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/tags | jq -r '.[0].name' | cut -c 2-)
        KUBESEAL_TGZ="/tmp/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
        KUBESEAL_URL="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"

        # Download to /tmp, follow redirects, and wtmprite to the specified file
        curl -L -o "$KUBESEAL_TGZ" "$KUBESEAL_URL"

        # Extract the kubeseal binary from the archive into /tmp, install and cleanup
        (cd /tmp && tar -xvzf "$KUBESEAL_TGZ" kubeseal && sudo install -m 755 kubeseal /usr/local/bin/kubeseal)
        rm -f "$KUBESEAL_TGZ" /tmp/kubeseal || true
    fi

    # Install hey for load testing
    if ! command -v hey > /dev/null 2>&1; then
        printf "⏱️ Installing hey...\n"    
        sudo curl -L -o /usr/local/bin/hey https://ease.s3.us-east-2.amazonaws.com/hey_linux_amd64
        sudo chmod +x /usr/local/bin/hey
    fi
    
    endgroup
else   
    k3d cluster delete devops-platform-core || true 
    k3d cluster create --config "$ROOT_DIR/k3d.yaml" --wait    
    echo "Cluster is created."
    export BASE_HOST="localhost"
fi

group "Deploying bootstrap base..."
kust "$ROOT_DIR/deploy/bootstrap/base" | kubectl apply --server-side -f -
kubectl wait --for=condition=established crd alertmanagerconfigs.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=established crd alertmanagers.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=established crd podmonitors.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=established crd probes.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=established crd prometheuses.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=established crd prometheusrules.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=established crd servicemonitors.monitoring.coreos.com --timeout=60s
endgroup

group "Deploying bootstrap components..."
if [ -n "$CI" ]; then
    kust "$ROOT_DIR/deploy/bootstrap/production" | kubectl apply --server-side -f -
else    
    kust "$ROOT_DIR/deploy/bootstrap/dev" | kubectl apply --server-side -f -
fi

# Wait for ArgoCD CRDs to be established before continuing
kubectl wait --for=condition=established crd applications.argoproj.io --timeout=60s || true
kubectl wait --for=condition=established crd applicationsets.argoproj.io --timeout=60s || true
kubectl wait --for=condition=established crd appprojects.argoproj.io --timeout=60s || true

# Re-apply in case some resources failed due to CRD timing
if [ -n "$CI" ]; then
    kust "$ROOT_DIR/deploy/bootstrap/production" | kubectl apply --server-side -f -
else    
    kust "$ROOT_DIR/deploy/bootstrap/dev" | kubectl apply --server-side -f -
fi
endgroup


group "Waitting for cluster stability..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=coredns -n kube-system --timeout=300s
kubectl wait --for=condition=ready pod -l k8s-app=node-local-dns -n kube-system --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=metrics-server -n kube-system --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n ingress-system --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n gitops-system --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-applicationset-controller -n gitops-system --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n gitops-system --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n gitops-system --timeout=300s



group "Running end-to-end tests..."
bats "$(dirname "$0")/e2e" -r --pretty --trace --verbose-run --print-output-on-failure
endgroup
