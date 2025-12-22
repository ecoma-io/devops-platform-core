#!/usr/bin/env sh
# Lint tracked Markdown and shell scripts in parallel.
# - Uses `git ls-files` to only include tracked files (respecting .gitignore)
# - Runs `npx markdownlint` on `**/*.md`
# - Runs `shellcheck` on `**/*.sh`
# - Executes both linters in parallel and reports a concise summary

set -eu

group(){
    if [ -n "${CI:-}" ]; then
        printf "%s\n" "::group::$1"
    else
        echo "$1"
    fi
}

endgroup(){
    if [ -n "${CI:-}" ]; then
        printf "%s\n" "::endgroup::"
    else
        printf "%s\n" "-------------------"
    fi
}

# If running in CI, install dependencies
if [ -n "${CI:-}" ]; then
    group "Installing dependencies..."

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

    # Install markdownlint
    if ! command -v markdownlint > /dev/null 2>&1; then
        NEED_INSTALL_NPM_PACKAGES="${NEED_INSTALL_NPM_PACKAGES:-} markdownlint-cli"
    fi

    if [ -n "${NEED_INSTALL_NPM_PACKAGES:-}" ]; then
      printf "⏱️ Installing required npm packages: %s\n" "$NEED_INSTALL_NPM_PACKAGES"
      printf "%s\n" "$NEED_INSTALL_NPM_PACKAGES" | xargs -r sudo npm install -g --
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


    endgroup
fi


group "Running linters..."
md_count=$(git ls-files -- '*.md' | wc -l | tr -d '[:space:]' || true)
sh_count=$(git ls-files -- '*.sh' | wc -l | tr -d '[:space:]' || true)


run_md() {
  if [ "${md_count:-0}" -eq 0 ]; then
    echo "No Markdown files to lint."
    return 0
  fi
  echo "Running npx markdownlint on tracked .md files..."
  # Use null-separated list to safely handle filenames
  git ls-files -z -- '*.md' | xargs -0 npx markdownlint
}

run_sh() {
  if [ "${sh_count:-0}" -eq 0 ]; then
    echo "No shell scripts to lint."
    return 0
  fi
  echo "Running shellcheck on tracked .sh files..."
  git ls-files -z -- '*.sh' | xargs -0 shellcheck
}

# Run both linters in background (parallel)
run_md &
md_pid=$!
run_sh &
sh_pid=$!

md_status=0
sh_status=0

wait "$md_pid" || md_status=$?
wait "$sh_pid" || sh_status=$?
endgroup

group "Lint Summary"
echo "Found ${md_count:-0} Markdown files and ${sh_count:-0} shell scripts (tracked)."
if [ "${md_count:-0}" -gt 0 ]; then
  if [ "$md_status" -eq 0 ]; then
    echo "Markdownlint: OK"
  else
    echo "Markdownlint: FAILED (exit $md_status)"
  fi
else
  echo "Markdownlint: SKIPPED"
fi

if [ "${sh_count:-0}" -gt 0 ]; then
  if [ "$sh_status" -eq 0 ]; then
    echo "Shellcheck: OK"
  else
    echo "Shellcheck: FAILED (exit $sh_status)"
  fi
else
  echo "Shellcheck: SKIPPED"
fi

endgroup

# Exit non-zero if any linter failed
if [ "$md_status" -ne 0 ] || [ "$sh_status" -ne 0 ]; then
  exit 1
fi

exit 0
