#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
runtime_tests="$ROOT/tests/script-runtime"
runtime_script_market="$ROOT/Resources/script-market-sources"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$runtime_tests/node_modules/.playwright-browsers}"
if [[ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}" ]]; then
  for candidate in \
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
    '/Applications/Chromium.app/Contents/MacOS/Chromium' \
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'; do
    if [[ -x "$candidate" ]]; then
      export PLAYWRIGHT_CHROMIUM_EXECUTABLE="$candidate"
      break
    fi
  done
fi

# The production monitor smoke test imports Playwright even when the upstream
# script-market sources are intentionally absent from the public repository.
# Keep downloaded test browsers inside the ignored dependency tree rather than
# mutating the user's global Playwright cache.
if [[ ! -x "$runtime_tests/node_modules/.bin/playwright" ]]; then
  (cd "$runtime_tests" && npm ci --ignore-scripts)
fi
if [[ -z "${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-}" ]] && ! (
  cd "$runtime_tests"
  node --input-type=module -e 'import { existsSync } from "node:fs"; import { chromium } from "playwright"; process.exit(existsSync(chromium.executablePath()) ? 0 : 1)'
); then
  (cd "$runtime_tests" && ./node_modules/.bin/playwright install chromium)
fi

tests=(
  open-source-compliance-tests.sh
  codex-plus-compatibility-tests.sh
  codex-plus-payload-build-tests.sh
  installer-domain-tests.sh
  configuration-tests.sh
  provider-catalog-tests.sh
  installer-core-tests.sh
  installer-transaction-tests.sh
  plugin-package-tests.sh
  script-market-tests.sh
  openai-authorization-tests.sh
  appkit-ui-tests.sh
  payload-refresh-tests.sh
  app-icon-tests.sh
  production-smoke-tests.sh
  installer-package-tests.sh
)
for test_script in "${tests[@]}"; do
  bash "$ROOT/tests/$test_script"
done
if [[ -d "$runtime_script_market" ]]; then
  (cd "$runtime_tests" && npm test)
else
  printf '%s\n' 'run-all-tests: SKIP unlicensed upstream monitor runtime sources are not mirrored'
fi
printf '%s\n' 'run-all-tests: PASS'
