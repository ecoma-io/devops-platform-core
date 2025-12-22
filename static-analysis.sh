#!/usr/bin/env sh
# Lint tracked Markdown and shell scripts in parallel.
# - Uses `git ls-files` to only include tracked files (respecting .gitignore)
# - Runs `npx markdownlint` on `**/*.md`
# - Runs `shellcheck` on `**/*.sh`
# - Executes both linters in parallel and reports a concise summary

set -eu

md_count=$(git ls-files --cached --others --exclude-standard -- '*.md' ':(exclude)CHANGELOG.md' | wc -l | tr -d '[:space:]' || true)
sh_count=$(git ls-files --cached --others --exclude-standard -- '*.sh' | wc -l | tr -d '[:space:]' || true)
kustomize_count=0

# Create temp dir for buffering outputs
TMPDIR=$(mktemp -d 2> /dev/null || mktemp -d -t lintsh)
md_out="$TMPDIR/markdown.out"
sh_out="$TMPDIR/shell.out"
kustomize_failures="$TMPDIR/kustomize.failures"
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
  # Build a list of directories that contain a kustomization file if not already prepared.
  dirs_file="$TMPDIR/kustomize.dirs"
  if [ ! -s "$dirs_file" ]; then
    for root in bootstrap deploy; do
      if [ -d "$root" ]; then
        find "$root" -type f \( -iname 'kustomization.yaml' -o -iname 'kustomization.yml' -o -iname 'Kustomization' \) -print0 \
          | xargs -0 -n1 dirname >> "$dirs_file" 2>/dev/null || true
      fi
    done
    if [ -s "$dirs_file" ]; then
      sort -u "$dirs_file" -o "$dirs_file" || true
    fi
  else
      :
  fi
  kustomize_count=$(wc -l < "$dirs_file" | tr -d '[:space:]' || true)
  if [ "${kustomize_count:-0}" -eq 0 ]; then
    : > "$kustomize_failures"
    return 0
  fi
  : > "$kustomize_failures"
  # Determine concurrency limit: 50% of CPU threads (ceil), min 2, max 8
  cpu_count=0
  if command -v nproc >/dev/null 2>&1; then
    cpu_count=$(nproc)
  elif [ -r /proc/cpuinfo ]; then
    cpu_count=$(grep -c '^processor' /proc/cpuinfo || true)
  fi
  if [ -z "${cpu_count}" ] || [ "$cpu_count" -lt 1 ]; then
    cpu_count=2
  fi
  half=$(( (cpu_count + 1) / 2 ))
  limit=$half
  if [ "$limit" -lt 2 ]; then
    limit=2
  fi
  if [ "$limit" -gt 8 ]; then
    limit=8
  fi

  # Split directories: build `base` directories first, then the rest.
  base_dirs_file="$TMPDIR/kustomize.base.dirs"
  other_dirs_file="$TMPDIR/kustomize.other.dirs"
  : > "$base_dirs_file"
  : > "$other_dirs_file"
  while IFS= read -r d; do
    if [ "$(basename "$d")" = "base" ]; then
      printf '%s\n' "$d" >> "$base_dirs_file"
    else
      printf '%s\n' "$d" >> "$other_dirs_file"
    fi
  done < "$dirs_file"

  # Create a temporary worker script to avoid complex quoting and be POSIX compatible.
  worker_script_file="$TMPDIR/kustomize_worker.sh"
  cat > "$worker_script_file" <<'EOF'
#!/usr/bin/env sh
tmpdir="$1"
failures="$2"
d="$3"
name=$(printf "%s" "$d" | tr "/" "_")
build_file="$tmpdir/build_$name.yaml"
err_file="$tmpdir/build_$name.err"

# Determine a lock target so overlays that share the same ../base are serialized.
lock_target=""
if [ -d "$d/../base" ]; then
  lock_target=$(cd "$d/../base" 2>/dev/null && pwd -P || true)
fi
if [ -z "$lock_target" ]; then
  lock_target=$(cd "$d" 2>/dev/null && pwd -P || printf "%s" "$d")
fi

# Derive a short deterministic lock name (sha1sum/md5sum fallback)
if command -v sha1sum >/dev/null 2>&1; then
  h=$(printf "%s" "$lock_target" | sha1sum | cut -d" " -f1)
else
  h=$(printf "%s" "$lock_target" | md5sum | cut -d" " -f1)
fi
# Ensure a dedicated locks directory exists under the tempdir and use it for locks
locks_parent="$tmpdir/locks"
mkdir -p "$locks_parent" 2>/dev/null || true
lock_dir="$locks_parent/lock_$h"

# Acquire lock: serialize builds that share the same base to avoid helm untar races
while ! mkdir "$lock_dir" 2>/dev/null; do sleep 0.1; done
trap 'rmdir "$lock_dir" >/dev/null 2>&1' EXIT

if ! kustomize build --load-restrictor LoadRestrictionsNone --helm-debug --enable-helm "$d" > "$build_file" 2> "$err_file"; then
  printf "%s\n" "$d" >> "$failures"
fi

# Release lock (trap will also attempt removal)
rmdir "$lock_dir" >/dev/null 2>&1 || true
EOF
  chmod +x "$worker_script_file"

  # Helper: run xargs worker over a newline-separated file of dirs
  run_xargs_for_file() {
    f="$1"
    if [ ! -s "$f" ]; then
      return 0
    fi
    # convert lines to NUL-separated stream and feed to xargs -0
    ( while IFS= read -r line; do [ -d "$line" ] && printf '%s\0' "$line"; done < "$f" ) | xargs -0 -n1 -P "$limit" "$worker_script_file" "$TMPDIR" "$kustomize_failures"
  }

  # Build base directories first
  run_xargs_for_file "$base_dirs_file"
  # Then build the remaining directories
  run_xargs_for_file "$other_dirs_file"

  # return non-zero if any failures recorded
  if [ -s "$kustomize_failures" ]; then
    return 1
  fi
  return 0
}

# Run both linters in background (parallel)
run_md &
md_pid=$!
run_sh &
sh_pid=$!
# Prepare dirs_file and kustomize_count in parent so the main process can read it
dirs_file="$TMPDIR/kustomize.dirs"
: > "$dirs_file"
for root in bootstrap deploy; do
  if [ -d "$root" ]; then
    find "$root" -type f \( -iname 'kustomization.yaml' -o -iname 'kustomization.yml' -o -iname 'Kustomization' \) -print0 \
      | xargs -0 -n1 dirname >> "$dirs_file" 2>/dev/null || true
  fi
done
if [ -s "$dirs_file" ]; then
  sort -u "$dirs_file" -o "$dirs_file" || true
fi
kustomize_count=$(wc -l < "$dirs_file" | tr -d '[:space:]' || true)
run_infra_checks &
infra_pid=$!



md_status=0
sh_status=0
kustomize_status=0

wait "$md_pid" || md_status=$?
wait "$sh_pid" || sh_status=$?
wait "$infra_pid" || true

# derive kustomize status from failure file
if [ -s "$kustomize_failures" ]; then
  kustomize_status=1
else
  kustomize_status=0
fi

printf '==============================\n'
printf 'Static Analysis Results:\n'
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

# Report infra (kustomize + checkov) results
if [ "${kustomize_count:-0}" -gt 0 ]; then
  if [ "$kustomize_status" -eq 0 ]; then
    echo "Kustomize build: OK"
  else
    echo "Kustomize build: FAILED"
    echo "Failed directories and logs:"
    while IFS= read -r line; do
        echo "- $line"
        name=$(printf "%s" "$line" | tr "/" "_")
        err_file="$TMPDIR/build_$name.err"
        out_file="$TMPDIR/build_$name.yaml"
        if [ -s "$err_file" ]; then
          echo "  Stderr:"
          sed 's/^/    /' "$err_file" || true
        elif [ -s "$out_file" ]; then
          echo "  Stdout:"
          sed 's/^/    /' "$out_file" || true
        else
          echo "  (no output captured)"
        fi
    done < "$kustomize_failures"
  fi
else
  echo "Kustomize build: No bootstrap directories to check, SKIPPED"
fi

# Exit non-zero if any linter failed
if [ "$md_status" -ne 0 ] || [ "$sh_status" -ne 0 ] || [ "$kustomize_status" -ne 0 ]; then
  exit 1
fi

exit 0