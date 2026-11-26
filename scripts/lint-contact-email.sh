#!/usr/bin/env bash
# No contact email address in the repo (ADR 0054, docs/SUPPORT_SPEC.md).
# Support is the in-app Contact Support form and septena.app/support. A
# personal or company address in copy, code or docs is the bug this catches:
# agents kept adding mz's address to pages. A line that must hold one (a store
# form that requires an address, an access list) carries
# `septena-lint:allow contact-email` with the reason. History docs are listed
# below and never change.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

pattern='[A-Za-z0-9._%+-]+@(envisioning\.com|centaur-?labs\.[a-z]+)|(support|contact|hello|help|feedback|mz)@septena\.app'
history='^(docs/adr/0054-support-lands-in-starlings\.md|docs/SUPPORT_SPEC\.md|docs/feedback\.md|scripts/lint-contact-email\.sh|changelog/|.*\.lock$|.*lock\.(json|yaml)$):'

hits=$(git grep -nIE "$pattern" -- . 2>/dev/null \
  | grep -vE "$history" \
  | grep -v 'septena-lint:allow contact-email' \
  | grep -v 'Co-Authored-By' || true)

if [ -n "$hits" ]; then
  echo "✗ contact-email: no email address in copy, code or docs (ADR 0054)."
  echo "  Link to https://septena.app/support, or call Support.open() in an app."
  echo "  A store or reviewer form that requires an address: add"
  echo "  'septena-lint:allow contact-email' on that line, with the reason."
  printf '%s\n' "$hits" | sed 's/^/    /'
  exit 1
fi
