#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failed=0

check() {
  local description="$1"
  local pattern="$2"
  if grep -RInE --exclude-dir=.git --exclude='preflight.sh' "$pattern" . >/tmp/portfolio-preflight.out 2>/dev/null; then
    echo "[FAIL] $description"
    cat /tmp/portfolio-preflight.out
    failed=1
  else
    echo "[ OK ] $description"
  fi
}

check "No private-key blocks" 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
check "No obvious GitHub tokens" 'gh[pousr]_[A-Za-z0-9_]{20,}'
check "No obvious GitLab tokens" 'glpat-[A-Za-z0-9_-]{20,}'
check "No JWT bearer tokens" 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
check "No embedded kubeconfig tokens" '^[[:space:]]*token:[[:space:]]+[A-Za-z0-9._-]{20,}'
check "No literal password assignments" "(password|passwd)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/=_-]{12,}"

rm -f /tmp/portfolio-preflight.out

if [[ "$failed" -ne 0 ]]; then
  echo
  echo "Preflight failed. Remove or replace the flagged values before committing."
  exit 1
fi

echo
echo "Preflight passed. Review the staged diff manually before pushing."
