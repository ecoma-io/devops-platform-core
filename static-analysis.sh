#!/usr/bin/env sh
# Lint tracked Markdown and shell scripts in parallel.
# - Uses `git ls-files` to only include tracked files (respecting .gitignore)
# - Runs `npx markdownlint` on `**/*.md`
# - Runs `shellcheck` on `**/*.sh`
# - Executes both linters in parallel and reports a concise summary

set -eu

md_count=$(git ls-files --cached --others --exclude-standard -- '*.md' ':(exclude)CHANGELOG.md' | wc -l | tr -d '[:space:]' || true)
sh_count=$(git ls-files --cached --others --exclude-standard -- '*.sh' | wc -l | tr -d '[:space:]' || true)
kustomize_count=$(for p in bootstrap/*; do [ -d "$p" ] && echo "$p"; done | wc -l | tr -d '[:space:]' || true)

# Create temp dir for buffering outputs
TMPDIR=$(mktemp -d 2> /dev/null || mktemp -d -t lintsh)
md_out="$TMPDIR/markdown.out"
sh_out="$TMPDIR/shell.out"
kustomize_failures="$TMPDIR/kustomize.failures"
checkov_failures="$TMPDIR/checkov.failures"
trap 'rm -rf "$TMPDIR"' EXIT

run_md() {
  if [ "${md_count:-0}" -eq 0 ]; then
    # ensure an empty file so reports can cat it safely
    : > "$md_out"
    return 0
  fi
  # collect output (stdout+stderr) into buffer
  git ls-files -z --cached --others --exclude-standard -- '*.md' ':(exclude)CHANGELOG.md' | xargs -0 npx markdownlint --config .markdownlint.json >> "$md_out" 2>&1
}

run_sh() {
  if [ "${sh_count:-0}" -eq 0 ]; then
    : > "$sh_out"
    return 0
  fi
  git ls-files -z --cached --others --exclude-standard -- '*.sh' | xargs -0 shellcheck >> "$sh_out" 2>&1
}

run_infra_checks() {
  if [ "${kustomize_count:-0}" -eq 0 ]; then
    : > "$kustomize_failures"
    : > "$checkov_failures"
    return 0
  fi
  : > "$kustomize_failures"
  : > "$checkov_failures"
  # For each immediate subdirectory of bootstrap/, run `kustomize build` and then `checkov`.
  for d in bootstrap/*; do
    if [ -d "$d" ]; then
      build_file="$TMPDIR/build_$(basename "$d").yaml"
      # Run kustomize build and capture to a temp file (suppress output)
      if ! kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm "$d" > "$build_file" 2>/dev/null; then
        echo "$d" >> "$kustomize_failures"
        # don't run checkov if build failed
        continue
      fi
      # Run checkov: prefer local binary, otherwise try Docker image
      if command -v checkov >/dev/null 2>&1; then
        if ! checkov -f "$build_file" >/dev/null 2>&1; then
          echo "$d" >> "$checkov_failures"
        fi
      elif command -v docker >/dev/null 2>&1; then
        # use bridgecrew/checkov docker image, mount file and run checkov silently
        if ! docker run --rm -v "$build_file":/tmp/manifest.yaml bridgecrew/checkov:latest -f /tmp/manifest.yaml >/dev/null 2>&1; then
          echo "$d" >> "$checkov_failures"
        fi
      fi
    fi
  done
  # return non-zero if any failures recorded
  if [ -s "$kustomize_failures" ] || [ -s "$checkov_failures" ]; then
    return 1
  fi
  return 0
}

# Run both linters in background (parallel)
run_md &
md_pid=$!
run_sh &
sh_pid=$!
run_infra_checks &
infra_pid=$!

md_status=0
sh_status=0
kustomize_status=0
checkov_status=0
checkov_missing=0

wait "$md_pid" || md_status=$?
wait "$sh_pid" || sh_status=$?
wait "$infra_pid" || true

# derive kustomize/checkov statuses from failure files (and detect missing checkov)
if [ -s "$kustomize_failures" ]; then
  kustomize_status=1
else
  kustomize_status=0
fi
if command -v checkov >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
  if [ -s "$checkov_failures" ]; then
    checkov_status=1
  else
    checkov_status=0
  fi
else
  checkov_missing=1
  checkov_status=0
fi

# Report Markdown results first, then shellcheck, using buffered outputs
if [ "${md_count:-0}" -gt 0 ]; then
  if [ "$md_status" -eq 0 ]; then
    echo "Markdownlint: OK"
  else
    echo "Markdownlint: FAILED (exit $md_status)"
    cat "$md_out"
  fi
else
  echo "Markdownlint: No files to check, SKIPPED"
fi
printf '\n\n'

if [ "${sh_count:-0}" -gt 0 ]; then
  if [ "$sh_status" -eq 0 ]; then
    echo "Shellcheck: OK"
  else
    echo "Shellcheck: FAILED (exit $sh_status)"
    cat "$sh_out"
  fi
else
  echo "Shellcheck: No files to check, SKIPPED"
fi
printf '\n\n'

# Report infra (kustomize + checkov) results
if [ "${kustomize_count:-0}" -gt 0 ]; then
  if [ "$kustomize_status" -eq 0 ]; then
    echo "Kustomize build: OK"
  else
    echo "Kustomize build: FAILED"
    echo "Failed directories:"
    while IFS= read -r line; do
      echo "- $line"
    done < "$kustomize_failures"
  fi
else
  echo "Kustomize build: No bootstrap directories to check, SKIPPED"
fi
printf '\n'

if [ "$checkov_missing" -eq 1 ]; then
  echo "Checkov: SKIPPED (not installed)"
elif [ "${kustomize_count:-0}" -gt 0 ]; then
  if [ "$checkov_status" -eq 0 ]; then
    echo "Checkov: OK"
  else
    echo "Checkov: FAILED"
    echo "Failed directories:"
    while IFS= read -r line; do
      echo "- $line"
    done < "$checkov_failures"
  fi
else
  echo "Checkov: No bootstrap directories to check, SKIPPED"
fi
printf '\n\n'

# Exit non-zero if any linter failed
if [ "$md_status" -ne 0 ] || [ "$sh_status" -ne 0 ] || [ "$kustomize_status" -ne 0 ]; then
  exit 1
fi

exit 0