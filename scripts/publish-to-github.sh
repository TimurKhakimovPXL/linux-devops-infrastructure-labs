#!/usr/bin/env bash
set -euo pipefail

repo_name="${1:-linux-devops-infrastructure-labs}"
visibility="${2:-public}"
owner="${GITHUB_OWNER:-TimurKhakimovPXL}"

case "$visibility" in
  public|private) ;;
  *)
    echo "Usage: $0 [repository-name] [public|private]"
    exit 2
    ;;
esac

for command in git gh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command"
    exit 1
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

./scripts/preflight.sh

gh auth status >/dev/null

if ! git config user.name >/dev/null; then
  echo 'Git user.name is not configured. Example:'
  echo '  git config --global user.name "Timur Khakimov"'
  exit 1
fi

if ! git config user.email >/dev/null; then
  echo 'Git user.email is not configured. Set your GitHub email or noreply address first.'
  exit 1
fi

if [[ ! -d .git ]]; then
  git init -b main
fi

git add .

if git diff --cached --quiet; then
  echo "Nothing new to commit."
else
  git commit -m "docs: publish Linux, DevOps and OpenShift infrastructure labs"
fi

if git remote get-url origin >/dev/null 2>&1; then
  echo "Remote origin already exists: $(git remote get-url origin)"
  git push -u origin main
else
  gh repo create "${owner}/${repo_name}" "--${visibility}" --source=. --remote=origin --push
fi

echo "Published: https://github.com/${owner}/${repo_name}"
