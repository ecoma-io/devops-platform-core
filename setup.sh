#!/usr/bin/env sh
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-dev}"

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



if [ "$MODE" = "staging" ]; then
    group "Installing toolings for tester nodes..."
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
    endgroup
fi


if [ "$MODE" = "staging" ] || [ "$MODE" = "static-analysis" ]; then
    group "Setting up BATS testing framework..."
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

if [ "$MODE" = "dev" ]; then
   group "Setting up k3d cluster for development..."
   k3d cluster delete devops-platform-core || true 
   k3d cluster create --config "$ROOT_DIR/k3d.yaml" --wait    
fi

if [ "$MODE" = "dev" ] ||  [ "$MODE" = "staging" ] || [ "$MODE" = "production" ]; then
    group "1️⃣ Boostraping cluster"
    kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm  "$ROOT_DIR"/bootstrap/base | kubectl apply --server-side  -f -
    kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm  "$ROOT_DIR"/bootstrap/"$MODE" | kubectl apply --server-side  -f -
    endgroup

    group "2️⃣ Waiting CNI stable..."
    kubectl wait --for=condition=ready --timeout=120s pod -l k8s-app=flannel -n kube-system
    endgroup

    group "3️⃣ Deploying CoreDNS & Local DNS Cache..."
    kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm  "$ROOT_DIR"/deploy/kube-system/coredns/"$MODE" | kubectl apply --server-side  -f -
    kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm  "$ROOT_DIR"/deploy/kube-system/node-local-dns/"$MODE" | kubectl apply --server-side  -f -
    endgroup

    group "4️⃣ Waiting DNS stable..."
    kubectl wait --for=condition=ready --timeout=120s pod -l k8s-app=coredns -n kube-system
    kubectl wait --for=condition=ready --timeout=120s pod -l k8s-app=node-local-dns -n kube-system
    endgroup

    group "5️⃣ Deploying metrics-server..."
    kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm  "$ROOT_DIR"/deploy/kube-system/metrics-server/"$MODE" | kubectl apply --server-side  -f -
    endgroup
fi