#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

failed=0

pass() {
  printf '[ OK ] %s\n' "$1"
}

skip() {
  printf '[SKIP] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  failed=1
}

mapfile -d '' markdown_files < <(
  find docs/containers docs/openshift-platform -type f -name '*.md' -print0 | sort -z
)

if ((${#markdown_files[@]} == 0)); then
  fail "No Markdown files found in the documentation audit paths"
else
  fence_report="$(mktemp)"
  if awk '
    function left_trim(value) {
      sub(/^[[:space:]]*/, "", value)
      return value
    }

    function fence_line(value) {
      value = left_trim(value)
      if (quoted_fence) {
        sub(/^>[[:space:]]?/, "", value)
      }
      return value
    }

    FNR == 1 {
      if (NR != 1 && in_fence) {
        printf "%s:%d: fenced block is not closed\n", previous_file, opening_line
        bad = 1
      }
      in_fence = 0
      previous_file = FILENAME
    }

    function report(message) {
      printf "%s:%d: %s\n", FILENAME, FNR, message
      bad = 1
    }

    {
      candidate = left_trim($0)
      opening_is_quoted = 0
      if (!in_fence && candidate ~ /^>[[:space:]]*```/) {
        sub(/^>[[:space:]]*/, "", candidate)
        opening_is_quoted = 1
      } else if (in_fence) {
        candidate = fence_line($0)
      }

      if (candidate !~ /^```/) {
        next
      }

      if (!in_fence) {
        if (candidate !~ /^```[[:alnum:]_+-]+[[:space:]]*$/) {
          report("fenced block has no language identifier")
        }
        in_fence = 1
        quoted_fence = opening_is_quoted
        opening_line = FNR
      } else {
        if (candidate !~ /^```[[:space:]]*$/) {
          report("closing fence contains unexpected text")
        }
        in_fence = 0
        quoted_fence = 0
      }
    }

    END {
      if (in_fence) {
        printf "%s:%d: fenced block is not closed\n", previous_file, opening_line
        bad = 1
      }
      exit bad
    }
  ' "${markdown_files[@]}" >"$fence_report"; then
    pass "Markdown fences are closed and have language identifiers"
  else
    fail "Markdown fence validation"
    cat "$fence_report"
  fi
  rm -f "$fence_report"

  block_report="$(mktemp)"
  if awk '
    function left_trim(value) {
      sub(/^[[:space:]]*/, "", value)
      return value
    }

    function report(message) {
      printf "%s:%d: %s\n", FILENAME, FNR, message
      bad = 1
    }

    {
      content = $0
      candidate = left_trim($0)
      opening_is_quoted = 0

      if (!in_fence && candidate ~ /^>[[:space:]]*```/) {
        sub(/^>[[:space:]]*/, "", candidate)
        opening_is_quoted = 1
      } else if (in_fence && quoted_fence) {
        content = left_trim(content)
        sub(/^>[[:space:]]?/, "", content)
        candidate = content
      }
    }

    !in_fence && candidate ~ /^```[[:alnum:]_+-]+[[:space:]]*$/ {
      language = candidate
      sub(/^```/, "", language)
      sub(/[[:space:]]*$/, "", language)
      in_fence = 1
      quoted_fence = opening_is_quoted
      expect_continuation = 0
      next
    }

    in_fence && candidate ~ /^```[[:space:]]*$/ {
      if (expect_continuation) {
        report("shell continuation reaches the closing fence")
      }
      in_fence = 0
      quoted_fence = 0
      expect_continuation = 0
      language = ""
      next
    }

    !in_fence { next }

    language != "powershell" && content ~ /[^`]`[[:space:]]*$/ {
      report("stray trailing backtick inside a fenced block")
    }

    (language == "ini" || language == "systemd" || language == "quadlet") && \
      content ~ /(^|[[:space:]])(Description|Image|ContainerName|PublishPort|Volume|EnvironmentFile|ExecStart|ExecStop|Restart|RestartSec|WantedBy|RequiredBy|After|Requires)=.*[[:space:]](Description|Image|ContainerName|PublishPort|Volume|EnvironmentFile|ExecStart|ExecStop|Restart|RestartSec|WantedBy|RequiredBy|After|Requires)=/ {
      report("multiple Quadlet or systemd directives appear on one line")
    }

    language == "bash" || language == "sh" {
      if (expect_continuation) {
        if (content ~ /^[[:space:]]*$/) {
          report("shell continuation is followed by a blank line")
        } else if (content !~ /^[[:space:]]+/) {
          report("shell continuation line is not indented")
        }
        expect_continuation = 0
      }

      if (content ~ /\\[[:space:]]*$/) {
        expect_continuation = 1
      }

      if (content ~ /^[[:space:]]*(sudo[[:space:]]+)?(apt|apt-get|dnf|yum)[[:space:]]+install[[:space:]]+(-y|--yes)[[:space:]]*$/) {
        report("package installation ends before any package names")
      }
    }

    END { exit bad }
  ' "${markdown_files[@]}" >"$block_report"; then
    pass "Fenced blocks contain no known trailing-backtick or continuation defects"
    pass "Quadlet and systemd examples keep directives on separate lines"
  else
    fail "Known fenced-block defect checks"
    cat "$block_report"
  fi
  rm -f "$block_report"
fi

mapfile -d '' shell_scripts < <(find scripts -type f -name '*.sh' -print0 | sort -z)

shell_syntax_failed=0
for script in "${shell_scripts[@]}"; do
  if ! bash -n "$script"; then
    shell_syntax_failed=1
  fi
done
if ((shell_syntax_failed)); then
  fail "bash -n found invalid repository shell scripts"
else
  pass "bash -n passed for ${#shell_scripts[@]} repository shell scripts"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "${shell_scripts[@]}"; then
    pass "shellcheck passed for repository shell scripts"
  else
    fail "shellcheck found issues in repository shell scripts"
  fi
else
  skip "shellcheck is not installed"
fi

mapfile -d '' yaml_files < <(
  find . -path './.git' -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z
)

if ((${#yaml_files[@]} == 0)); then
  skip "No standalone YAML files found for yamllint"
elif command -v yamllint >/dev/null 2>&1; then
  if yamllint "${yaml_files[@]}"; then
    pass "yamllint passed for ${#yaml_files[@]} standalone YAML files"
  else
    fail "yamllint found issues in standalone YAML files"
  fi
else
  skip "yamllint is not installed (${#yaml_files[@]} YAML files not linted)"
fi

if ((failed)); then
  printf '\nDocumentation validation failed.\n'
  exit 1
fi

printf '\nDocumentation validation passed.\n'
