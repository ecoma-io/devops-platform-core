<!-- markdownlint-disable MD013 MD041 MD029 MD024 -->

## Shell scripting best practices and conventions

````instructions
---
applyTo: "**/*.sh"
description: "Shell scripting best practices and conventions for bash, sh, zsh, and other shells"
---

This file defines workspace-wide shell scripting conventions. It follows
the same structural style as other instruction files in this repository
(for example, `ts.instructions.md` and `ts-jest.instructions.md`): a
short scope header, mandatory rules, examples, and CI/lint guidance.

Keep this file focused on shell-specific best practices and avoid
repeating general repository policies that live elsewhere (for example,
commit or CI rules). Use this guidance for automation scripts, dev
tools, and small helpers included in the repository.

## Scope

- Applies to: all shell scripts (`**/*.sh`) and small shell snippets
  intended to be executable in the repo (CI helpers, tooling scripts,
  dev containers).
- Goal: make shell scripts safe, readable, robust, and maintainable
  across Bourne-compatible shells (bash, zsh, sh) while allowing
  project-level portability choices.

## Mandatory Rules (concise)

1. Shebang & shell selection

  - Add an explicit shebang at the top of every script. Prefer
     `#!/usr/bin/env bash` for scripts that rely on Bash features. Use
     `#!/bin/sh` for strict POSIX-compatible scripts.
   - Document the shell requirement in the header comment (for example,
  `# Requires: bash >= 4.0`).

2. Fail-fast, safety flags
   - Always enable safe flags unless there is a documented reason not to:
     set -euo pipefail
   - Explain any deviation from the above in the file header (for portability or CI reasons).

3. Quotations and expansions

  - Double-quote variable expansions: `"$var"`.
  - Use `${var}` for clarity in complex expansions.
  - Avoid `eval` and untrusted command substitution.

4. Input validation & usage
  - Validate required parameters and provide a `usage()` function.
  - Exit with non-zero status and helpful error messages on invalid usage.

5. Temporary resources & cleanup
  - Use `mktemp` (or `mktemp -d`) to create temp files/dirs and remove them in a `trap 'cleanup' EXIT` handler.
  - Ensure cleanup runs for both success and failure paths.

6. Functions & structure
  - Organize scripts into small functions; keep `main` as the orchestration entry point.
  - Prefer local variables in functions (`local` where supported).
  - Keep the main linear flow readable and short.

7. Error messages & logging

  - Print concise, contextual error messages to stderr (use `>&2`).
  - Provide a `log()` helper to centralize verbose/debug logging.

8. Portability & compatibility
  - If the script targets POSIX `sh`, avoid Bash-specific features. If using Bash features, declare them clearly in the header.
  - When portability is required across different shells/platforms, prefer POSIX constructs and document required runtime environments.

9. Security & secrets
  - Do not hard-code secrets or credentials. Read secrets from environment variables or credential stores.
  - Mask or avoid printing secrets. If scripts accept secrets via args, document safer alternatives (stdin, files with restricted perms).

10. External tools & dependencies
- Document required external programs (e.g., `jq`, `yq`, `docker`, `curl`) at the top of the script and fail fast if missing.
- Prefer `command -v tool >/dev/null` checks.

11. JSON/YAML handling
- Prefer `jq` for JSON and `yq` (or `jq`+`yq`) for YAML. Quote jq/yq filters and use `--raw-output` when appropriate.
- Treat parser failures as fatal: check exit codes or rely on `set -e`.

12. Tests & linting
- Use `shellcheck` to lint scripts; enable CI linting for changed scripts where practical.
- Add minimal unit/integration checks (in CI) for scripts that perform critical repo automation.

13. Comments & header metadata
- Add a short header comment block describing purpose, required environment, example usage, and a brief changelog or author if appropriate.

## Recommended file layout (template)

```bash
#!/usr/bin/env bash
# ==========================================================================
# Purpose: Short description of what the script does.
# Requires: bash >= 4.0, jq, docker
# Usage: ./scripts/example.sh --name NAME
# ==========================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
TEMP_DIR=""

cleanup() {
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]
  -n --name NAME   Description of NAME (required)
  -h --help        Show this help
EOF
  exit 0
}

require() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: required command '$cmd' not found" >&2
      exit 2
    fi
  done
}

main() {
  # Validate args
  if [[ $# -eq 0 ]]; then
    usage
  fi

  require jq docker

  TEMP_DIR="$(mktemp -d)"

  echo "Running..."
  # Main logic here

  echo "Done"
}

# Argument parsing (simple example)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name) NAME="$2"; shift 2;;
  -h|--help) usage;;
  --) shift; break;;
  *) echo "Unknown option: $1" >&2; usage;;
  esac
done

main "$@"
````

## CI & maintenance tips

- Add `shellcheck --severity=error` runs in CI for changed `*.sh` files.
- Keep scripts small and single-purpose; if they grow, consider moving logic into a small, tested utility (e.g., Node/Python/Go) with an entrypoint wrapper.
- Use `--` for safely passing arguments that may start with `-` to downstream commands.

## Examples of common patterns

- Safe read from environment with default:

```bash
readonly DEFAULT_TIMEOUT=30
TIMEOUT="${TIMEOUT:-$DEFAULT_TIMEOUT}"
```

- Polling with timeout (prefer polling over blind sleeps):

```bash
wait_for() {
  local retries=30
  local delay=2
  local i=0
  until command -v some-service > /dev/null 2>&1 || [[ $i -ge $retries ]]; do
    sleep "$delay"
    i=$((i + 1))
  done
  if [[ $i -ge $retries ]]; then
    echo "Timeout waiting for some-service" >&2
    return 1
  fi
}
```

## Notes & rationale

- The file elevates safety (`set -euo pipefail`), explicit error handling, and use of stable parsers (`jq`/`yq`).
- Prefer small, focused scripts and add tests or CI linting for scripts that affect automated workflows.
- Document environment and dependencies at the top of each script so authors and CI can validate requirements quickly.

---

applyTo: "\*_/_.sh"
description: "Shell scripting best practices and conventions for bash, sh, zsh, and other shells"

---

This file defines workspace-wide shell scripting conventions. It follows the same structural style as other instruction files in this repository (for example `ts.instructions.md` and `ts-jest.instructions.md`): a short scope header, mandatory rules, examples, and CI/lint guidance.

Keep this file focused on shell-specific best practices and avoid repeating general repository policies that live elsewhere (e.g., commit/CI rules). Use this guidance for automation scripts, dev-tools, and small helpers included in the repository.

## Scope

- Applies to: all shell scripts (`**/*.sh`) and small shell snippets intended to be executable in the repo (CI helpers, tooling scripts, dev containers).
- Goal: make shell scripts safe, readable, robust, and maintainable across Bourne-compatible shells (bash/zsh/sh) while allowing project-level portability choices.

## Mandatory Rules (concise)

1. Shebang & shell selection
   - Add an explicit shebang at the top of every script. Prefer `#!/usr/bin/env bash` for scripts that rely on Bash features. Use `#!/bin/sh` for strict POSIX-compatible scripts.
   - Document the shell requirement in the header comment (e.g., `# Requires: bash >= 4.0`).

2. Fail-fast, safety flags
   - Always enable safe flags unless there is a documented reason not to:
     set -euo pipefail
   - Explain any deviation from the above in the file header (for portability or CI reasons).

3. Quotations and expansions
   - Double-quote variable expansions: `"$var"`.
   - Use `${var}` for clarity in complex expansions.
   - Avoid `eval` and untrusted command substitution.

4. Input validation & usage
   - Validate required parameters and provide a `usage()` function.
   - Exit with non-zero status and helpful error messages on invalid usage.

5. Temporary resources & cleanup
   - Use `mktemp` (or `mktemp -d`) to create temp files/dirs and remove them in a `trap 'cleanup' EXIT` handler.
   - Ensure cleanup runs for both success and failure paths.

6. Functions & structure
   - Organize scripts into small functions; keep `main` as the orchestration entry point.
   - Prefer local variables in functions (`local` where supported).
   - Keep the main linear flow readable and short.

7. Error messages & logging
   - Print concise, contextual error messages to stderr (use `>&2`).
   - Provide a `log()` helper to centralize verbose/debug logging.

8. Portability & compatibility
   - If the script targets POSIX `sh`, avoid Bash-specific features. If using Bash features, declare them clearly in the header.
   - When portability is required across different shells/platforms, prefer POSIX constructs and document required runtime environments.

9. Security & secrets
   - Do not hard-code secrets or credentials. Read secrets from environment variables or credential stores.
   - Mask or avoid printing secrets. If scripts accept secrets via args, document safer alternatives (stdin, files with restricted perms).

10. External tools & dependencies

- Document required external programs (e.g., `jq`, `yq`, `docker`, `curl`) at the top of the script and fail fast if missing.
- Prefer `command -v tool >/dev/null` checks.

11. JSON/YAML handling

- Prefer `jq` for JSON and `yq` (or `jq`+`yq`) for YAML. Quote jq/yq filters and use `--raw-output` when appropriate.
- Treat parser failures as fatal: check exit codes or rely on `set -e`.

12. Tests & linting

- Use `shellcheck` to lint scripts; enable CI linting for changed scripts where practical.
- Add minimal unit/integration checks (in CI) for scripts that perform critical repo automation.

13. Comments & header metadata

- Add a short header comment block describing purpose, required environment, example usage, and a brief changelog or author if appropriate.

## Recommended file layout (template)

```bash
#!/usr/bin/env bash
# ==========================================================================
# Purpose: Short description of what the script does.
# Requires: bash >= 4.0, jq, docker
# Usage: ./scripts/example.sh --name NAME
# ==========================================================================

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
TEMP_DIR=""

cleanup() {
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat << EOF
Usage: $SCRIPT_NAME [options]
  -n --name NAME   Description of NAME (required)
  -h --help        Show this help
EOF
  exit 0
}

require() {
  for cmd in "$@"; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      echo "Error: required command '$cmd' not found" >&2
      exit 2
    fi
  done
}

main() {
  # Validate args
  if [[ $# -eq 0 ]]; then
    usage
  fi

  require jq docker

  TEMP_DIR="$(mktemp -d)"

  echo "Running..."
  # Main logic here

  echo "Done"
}

# Argument parsing (simple example)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n | --name)
      NAME="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

main "$@"
```

## CI & maintenance tips

- Add `shellcheck --severity=error` runs in CI for changed `*.sh` files.
- Keep scripts small and single-purpose; if they grow, consider moving logic into a small, tested utility (e.g., Node/Python/Go) with an entrypoint wrapper.
- Use `--` for safely passing arguments that may start with `-` to downstream commands.

## Examples of common patterns

- Safe read from environment with default:

```bash
readonly DEFAULT_TIMEOUT=30
TIMEOUT="${TIMEOUT:-$DEFAULT_TIMEOUT}"
```

- Polling with timeout (prefer polling over blind sleeps):

```bash
wait_for() {
  local retries=30
  local delay=2
  local i=0
  until command -v some-service > /dev/null 2>&1 || [[ $i -ge $retries ]]; do
    sleep "$delay"
    i=$((i + 1))
  done
  if [[ $i -ge $retries ]]; then
    echo "Timeout waiting for some-service" >&2
    return 1
  fi
}
```

## Notes & rationale

- The file elevates safety (`set -euo pipefail`), explicit error handling, and use of stable parsers (`jq`/`yq`).
- Prefer small, focused scripts and add tests or CI linting for scripts that affect automated workflows.
- Document environment and dependencies at the top of each script so authors and CI can validate requirements quickly.

---

If you want, I can also:

- Add a small repository `scripts/.template.sh` containing the template above and wire a CI job to run `shellcheck` on changed scripts; or
- Run a quick scan to list `*.sh` files that violate the most critical rules (missing shebang, missing `set -euo pipefail`, or lacking `shellcheck`-friendly headers).
