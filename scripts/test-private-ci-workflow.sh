#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_dir="$root_dir/.github/workflows"
dispatcher="$workflow_dir/speak-private-ci.yml"
source_root="${1:-}"

if [[ ! -f "$dispatcher" ]]; then
  echo "Private CI dispatcher not found: $dispatcher" >&2
  exit 1
fi
if grep -Eq '^  pull_request:' "$dispatcher" || grep -Fq 'github.head_ref' "$dispatcher"; then
  echo "Private CI must not map speak-ci pull-request refs into panda-lingo/speak" >&2
  exit 1
fi

reusable_workflows=(
  private-ci-api.yml
  private-ci-standalone.yml
  private-ci-web-browser.yml
  private-ci-web-live.yml
  private-ci-web-e2e.yml
  private-ci-build.yml
)
for workflow_name in "${reusable_workflows[@]}"; do
  if [[ ! -f "$workflow_dir/$workflow_name" ]]; then
    echo "Required reusable workflow is missing: $workflow_name" >&2
    exit 1
  fi
done

# Dispatcher job, reusable workflow, and selected job form one declarative map.
test_job_contracts=(
  'test-api|private-ci-api.yml|test-api'
  'test-api-ai-text-live|private-ci-api.yml|test-api-ai-text-live'
  'test-api-mm-gateway-e2e|private-ci-api.yml|test-api-mm-gateway-e2e'
  'test-api-omni-audio-e2e|private-ci-api.yml|test-api-omni-audio-e2e'
  'test-proxy|private-ci-standalone.yml|test-proxy'
  'test-standalone-mm-gateway|private-ci-standalone.yml|test-standalone-mm-gateway'
  'test-standalone-operations|private-ci-standalone.yml|test-standalone-operations'
  'test-local-compose-security|private-ci-standalone.yml|test-local-compose-security'
  'test-web|private-ci-web-browser.yml|test-web'
  'test-web-sites|private-ci-web-browser.yml|test-web-sites'
  'test-web-base-path|private-ci-web-browser.yml|test-web-base-path'
  'test-web-ai-text-live|private-ci-web-live.yml|test-web-ai-text-live'
  'test-web-live-talk-live|private-ci-web-live.yml|test-web-live-talk-live'
  'test-web-e2e|private-ci-web-e2e.yml|test-web-e2e'
  'test-web-e2e-redroid-mobile|private-ci-web-e2e.yml|test-web-e2e-redroid-mobile'
)
build_job_contracts=(
  'build-api|build-api'
  'build-web|build-web'
)

workflow_job() {
  local workflow="$1"
  local target="$2"
  awk -v target="$target" '
    $0 == "  " target ":" { in_job = 1; print; next }
    in_job && /^  [a-z0-9][a-z0-9-]*:[[:space:]]*$/ { exit }
    in_job { print }
  ' "$workflow"
}

workflow_step() {
  local block="$1"
  local target="$2"
  awk -v target="$target" '
    $0 == "      - name: " target { in_step = 1; print; next }
    in_step && /^      - / { exit }
    in_step { print }
  ' <<< "$block"
}

require() {
  local subject="$1"
  local expected="$2"
  local block="$3"
  if ! grep -Fq "$expected" <<< "$block"; then
    echo "$subject is missing required workflow content: $expected" >&2
    exit 1
  fi
}

require_timeout() {
  local subject="$1"
  local block="$2"
  if ! grep -Eq '^    timeout-minutes:[[:space:]]*[1-9][[:space:]]*$' <<< "$block"; then
    echo "$subject must declare timeout-minutes from 1 through 9" >&2
    exit 1
  fi
}

require_private_checkout() {
  local subject="$1"
  local block="$2"
  for mapping in \
    'repository: ${{ env.CHECKOUT_REPOSITORY }}' \
    'ref: ${{ env.CHECKOUT_REF }}' \
    'token: ${{ secrets.SPEAK_REPO_TOKEN }}'; do
    require "$subject private-source checkout" "$mapping" "$block"
  done
}

private_contract_block="$(workflow_job "$dispatcher" test-private-ci-workflow)"
require_timeout 'test-private-ci-workflow' "$private_contract_block"
source_checkout_block="$(workflow_step "$private_contract_block" 'Checkout source workflow contract')"
require 'source workflow checkout' 'uses: actions/checkout@v7' "$source_checkout_block"
require 'source workflow checkout' 'repository: panda-lingo/speak' "$source_checkout_block"
require 'source workflow checkout' 'ref: ${{ github.event_name == '\''workflow_dispatch'\'' && inputs.source_ref || github.ref_name }}' "$source_checkout_block"
require 'source workflow checkout' 'token: ${{ secrets.SPEAK_REPO_TOKEN }}' "$source_checkout_block"
require 'source workflow checkout' 'path: .tmp/speak-source' "$source_checkout_block"
require 'source workflow checkout' 'sparse-checkout: .github/workflows/docker-ci-web-browser.yml' "$source_checkout_block"
require 'source workflow checkout' 'sparse-checkout-cone-mode: false' "$source_checkout_block"
require 'source workflow checkout' 'persist-credentials: false' "$source_checkout_block"
require 'test-private-ci-workflow' './scripts/test-private-ci-workflow.sh .tmp/speak-source' "$private_contract_block"

checkout_ref_mapping='checkout_ref: ${{ github.event_name == '\''workflow_dispatch'\'' && inputs.source_ref || github.ref_name }}'
test_jobs=(test-private-ci-workflow)
for contract in "${test_job_contracts[@]}"; do
  IFS='|' read -r dispatcher_job reusable_name selected_job <<< "$contract"
  dispatcher_block="$(workflow_job "$dispatcher" "$dispatcher_job")"
  reusable_block="$(workflow_job "$workflow_dir/$reusable_name" "$selected_job")"
  require "$dispatcher_job" "uses: ./.github/workflows/$reusable_name" "$dispatcher_block"
  require "$dispatcher_job" "target: $selected_job" "$dispatcher_block"
  require "$dispatcher_job" 'checkout_repository: panda-lingo/speak' "$dispatcher_block"
  require "$dispatcher_job" "$checkout_ref_mapping" "$dispatcher_block"
  require "$dispatcher_job" 'secrets: inherit' "$dispatcher_block"
  require "$selected_job" "if: inputs.target == '$selected_job'" "$reusable_block"
  case "$selected_job" in
    test-api-mm-gateway-e2e)
      require "$selected_job" 'timeout-minutes: 25' "$reusable_block"
      ;;
    test-web-ai-text-live)
      require "$selected_job" 'timeout-minutes: ${{ matrix.scenario == '\''music'\'' && 40 || 9 }}' "$reusable_block"
      ;;
    *)
      require_timeout "$selected_job" "$reusable_block"
      ;;
  esac
  require_private_checkout "$selected_job" "$reusable_block"
  test_jobs+=("$dispatcher_job")

  if [[ "$dispatcher_job" == 'test-web-ai-text-live' ]]; then
    require "$dispatcher_job" 'needs: [test-api-ai-text-live, test-api-mm-gateway-e2e]' "$dispatcher_block"
  elif grep -Eq '^    needs:' <<< "$dispatcher_block"; then
    echo "Required test dispatcher job $dispatcher_job must start without a needs dependency" >&2
    exit 1
  fi
done

quality_gate_block="$(workflow_job "$dispatcher" quality-gate)"
require_timeout 'quality-gate' "$quality_gate_block"
require 'quality-gate' 'if: always()' "$quality_gate_block"
require 'quality-gate' 'all(.[]; .result == "success")' "$quality_gate_block"
quality_gate_needs="$(awk '
  /^  quality-gate:[[:space:]]*$/ { in_quality_gate = 1; next }
  in_quality_gate && /^  [a-z0-9][a-z0-9-]*:[[:space:]]*$/ { exit }
  in_quality_gate && /^      - [a-z0-9][a-z0-9-]*[[:space:]]*$/ {
    job = $0
    sub(/^      - /, "", job)
    sub(/[[:space:]]*$/, "", job)
    print job
  }
' "$dispatcher")"
expected_quality_gate_needs="$(printf '%s\n' "${test_jobs[@]}" | sort)"
actual_quality_gate_needs="$(printf '%s\n' "$quality_gate_needs" | sed '/^$/d' | sort)"
if [[ "$actual_quality_gate_needs" != "$expected_quality_gate_needs" ]]; then
  echo "quality-gate needs must exactly match the required test dispatcher jobs" >&2
  diff -u <(printf '%s\n' "$expected_quality_gate_needs") <(printf '%s\n' "$actual_quality_gate_needs") >&2 || true
  exit 1
fi

for contract in "${build_job_contracts[@]}"; do
  IFS='|' read -r dispatcher_job selected_job <<< "$contract"
  dispatcher_block="$(workflow_job "$dispatcher" "$dispatcher_job")"
  reusable_block="$(workflow_job "$workflow_dir/private-ci-build.yml" "$selected_job")"
  require "$dispatcher_job" 'needs: quality-gate' "$dispatcher_block"
  require "$dispatcher_job" 'uses: ./.github/workflows/private-ci-build.yml' "$dispatcher_block"
  require "$dispatcher_job" "target: $selected_job" "$dispatcher_block"
  require "$dispatcher_job" 'checkout_repository: panda-lingo/speak' "$dispatcher_block"
  require "$dispatcher_job" "$checkout_ref_mapping" "$dispatcher_block"
  require "$dispatcher_job" 'secrets: inherit' "$dispatcher_block"
  require "$selected_job" "if: inputs.target == '$selected_job'" "$reusable_block"
  require_timeout "$selected_job" "$reusable_block"
  require_private_checkout "$selected_job" "$reusable_block"
done

api_workflow="$workflow_dir/private-ci-api.yml"
standalone_workflow="$workflow_dir/private-ci-standalone.yml"
browser_workflow="$workflow_dir/private-ci-web-browser.yml"
live_workflow="$workflow_dir/private-ci-web-live.yml"
e2e_workflow="$workflow_dir/private-ci-web-e2e.yml"

desktop_evidence_job="$(workflow_job "$e2e_workflow" test-web-e2e)"
desktop_evidence_step="$(workflow_step "$desktop_evidence_job" 'Upload full-stack browser failure artifacts')"
require 'desktop cancellation evidence' 'if: failure() || cancelled()' "$desktop_evidence_step"
require 'desktop cancellation evidence' 'path: web/test-results' "$desktop_evidence_step"

content_contracts=(
  "$api_workflow|test-api-ai-text-live|AI_HTTP_TRACE: \"1\""
  "$api_workflow|test-api-ai-text-live|./scripts/validate-live-ai-text-config.sh"
  "$api_workflow|test-api-ai-text-live|./scripts/run-live-ai-text-tests.sh"
  "$api_workflow|test-api-mm-gateway-e2e|repository: sloth-os/mm-gateway"
  "$api_workflow|test-api-mm-gateway-e2e|ref: afd0557a32c96189320bce3a4583a84f1847684d"
  "$api_workflow|test-api-mm-gateway-e2e|environment: music-e2e"
  "$api_workflow|test-api-mm-gateway-e2e|IMAGE_API_KEY: \${{ secrets.IMAGE_API_KEY }}"
  "$api_workflow|test-api-mm-gateway-e2e|IMAGE_BASE_URL: \${{ vars.IMAGE_BASE_URL }}"
  "$api_workflow|test-api-mm-gateway-e2e|IMAGE_MODEL: \${{ vars.IMAGE_MODEL }}"
  "$api_workflow|test-api-mm-gateway-e2e|IMAGE_PROVIDER: \${{ vars.IMAGE_PROVIDER }}"
  "$api_workflow|test-api-mm-gateway-e2e|MUSIC_API_KEY: \${{ secrets.MUSIC_API_KEY }}"
  "$api_workflow|test-api-mm-gateway-e2e|MUSIC_BASE_URL: \${{ vars.MUSIC_BASE_URL }}"
  "$api_workflow|test-api-mm-gateway-e2e|MUSIC_MODEL: \${{ vars.MUSIC_MODEL }}"
  "$api_workflow|test-api-mm-gateway-e2e|MUSIC_PROVIDER: \${{ vars.MUSIC_PROVIDER }}"
  "$api_workflow|test-api-mm-gateway-e2e|VERTEX_CREDENTIALS_JSON: \${{ secrets.VERTEX_CREDENTIALS_JSON }}"
  "$api_workflow|test-api-mm-gateway-e2e|if [[ \"\$MUSIC_PROVIDER\" == \"vertex\" ]]; then"
  "$api_workflow|test-api-mm-gateway-e2e|required_names+=(VERTEX_CREDENTIALS_JSON)"
  "$api_workflow|test-api-mm-gateway-e2e|required_names+=(MUSIC_API_KEY MUSIC_BASE_URL)"
  "$api_workflow|test-api-mm-gateway-e2e|MUSIC_AUTH=vertex_service_account_json"
  "$api_workflow|test-api-mm-gateway-e2e|env -u IMAGE_API_KEY -u MUSIC_API_KEY -u VERTEX_CREDENTIALS_JSON go test"
  "$api_workflow|test-api-mm-gateway-e2e|./scripts/run-mm-gateway-e2e.sh"
  "$api_workflow|test-api-omni-audio-e2e|./scripts/run-live-omni-audio-tests.sh"
  "$api_workflow|test-api-omni-audio-e2e|timeout 240s curl --fail --location --retry 2 --retry-all-errors"
  "$api_workflow|test-api-omni-audio-e2e|ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffmpeg-6.1-linux-64.zip"
  "$api_workflow|test-api-omni-audio-e2e|8bb4a27f5fd02f3dd9a5e75c9eddf6ace1d50a08929ee0d20bbf17eb467fb711"
  "$api_workflow|test-api-omni-audio-e2e|sha256sum --check --status"
  "$api_workflow|test-api-omni-audio-e2e|unzip -q"
  "$standalone_workflow|test-standalone-mm-gateway|./scripts/test-standalone-mm-gateway.sh"
  "$standalone_workflow|test-standalone-operations|./scripts/test-standalone-operations.sh"
  "$standalone_workflow|test-local-compose-security|./scripts/test-local-compose-security.sh"
  "$browser_workflow|test-web-sites|tests/admin-plan-mm-gateway.e2e.spec.ts"
  "$browser_workflow|test-web-base-path|npm run test:e2e:base-path"
  "$live_workflow|test-web-ai-text-live|max-parallel: 1"
  "$live_workflow|test-web-ai-text-live|name: \${{ matrix.environment }}"
  "$live_workflow|test-web-ai-text-live|environment: music-e2e"
  "$live_workflow|test-web-ai-text-live|environment: ci-unprivileged"
  "$live_workflow|test-web-ai-text-live|Checkout mm-gateway for real browser music"
  "$live_workflow|test-web-ai-text-live|ref: afd0557a32c96189320bce3a4583a84f1847684d"
  "$live_workflow|test-web-ai-text-live|MUSIC_API_KEY: \${{ matrix.scenario == 'music' && secrets.MUSIC_API_KEY || '' }}"
  "$live_workflow|test-web-ai-text-live|MUSIC_PROVIDER: \${{ matrix.scenario == 'music' && vars.MUSIC_PROVIDER || '' }}"
  "$live_workflow|test-web-ai-text-live|MUSIC_MODEL: \${{ matrix.scenario == 'music' && vars.MUSIC_MODEL || '' }}"
  "$live_workflow|test-web-ai-text-live|VERTEX_CREDENTIALS_JSON: \${{ matrix.scenario == 'music' && secrets.VERTEX_CREDENTIALS_JSON || '' }}"
  "$live_workflow|test-web-ai-text-live|E2E_MM_GATEWAY_SOURCE_DIR: \${{ github.workspace }}/.tmp/mm-gateway"
  "$live_workflow|test-web-ai-text-live|Selected music-provider GitHub configuration is incomplete; skipping real browser music e2e."
  "$live_workflow|test-web-ai-text-live|if [[ \"\$MUSIC_PROVIDER\" == \"vertex\" ]]; then"
  "$live_workflow|test-web-ai-text-live|required_music_names+=(VERTEX_CREDENTIALS_JSON)"
  "$live_workflow|test-web-ai-text-live|required_music_names+=(MUSIC_API_KEY MUSIC_BASE_URL)"
  "$live_workflow|test-web-ai-text-live|../scripts/validate-live-ai-text-config.sh"
  "$live_workflow|test-web-live-talk-live|LIVE_TALK_API_KEY: \${{ secrets.LIVE_TALK_API_KEY }}"
  "$live_workflow|test-web-live-talk-live|../scripts/validate-live-talk-config.sh"
  "$live_workflow|test-web-live-talk-live|npm run test:e2e:ci:live-talk-live"
  "$e2e_workflow|test-web-e2e-redroid-mobile|nohup bash -c"
  "$e2e_workflow|test-web-e2e-redroid-mobile|redroid-start.status"
  "$e2e_workflow|test-web-e2e-redroid-mobile|REDROID_BROWSER_PACKAGE=\$redroid_browser_package"
  "$e2e_workflow|test-web-e2e-redroid-mobile|GITHUB_PATH"
)
for contract in "${content_contracts[@]}"; do
  IFS='|' read -r workflow job expected <<< "$contract"
  require "$job" "$expected" "$(workflow_job "$workflow" "$job")"
done

# Retired web-session credentials and SSH sidecar wiring must not return through
# either provider entry point. Vertex and generic API-key paths above remain
# positive contracts, so removing obsolete coverage cannot remove live coverage.
for provider_workflow in "$api_workflow" "$live_workflow"; do
  if grep -Eiq 'MINIMAX_|minimax[-_]music|MUSIC_AUTH=minimax|== "minimax"' "$provider_workflow"; then
    echo "Provider workflows must not retain MiniMax session/SSH sidecar wiring" >&2
    exit 1
  fi
done

live_browser_block="$(workflow_job "$live_workflow" test-web-ai-text-live)"
for scenario in practice reader-text reader-image music rss pet; do
  require 'live browser coverage' "- scenario: $scenario" "$live_browser_block"
done

for browser_contract in \
  "$browser_workflow|test-web-sites" \
  "$browser_workflow|test-web-base-path" \
  "$live_workflow|test-web-ai-text-live" \
  "$live_workflow|test-web-live-talk-live" \
  "$e2e_workflow|test-web-e2e"; do
  IFS='|' read -r workflow job <<< "$browser_contract"
  browser_block="$(workflow_job "$workflow" "$job")"
  require "$job" 'install-dependencies: false' "$browser_block"
  require "$job" 'Verify Chrome browser' "$browser_block"
done

# The private checkout adapter may differ from the source workflow, but its
# mock-site ownership map must remain an exact copy. Exact comparison catches
# both missing coverage and accidental duplicate/aggregate execution.
web_site_matrix() {
  workflow_job "$1" test-web-sites | awk '
  /^          - name: / {
    name = $0
    sub(/^          - name: /, "", name)
    next
  }
  /^            specs: / && name != "" {
    specs = $0
    sub(/^            specs: /, "", specs)
    print name "|" specs
    name = ""
  }
'
}

actual_web_site_matrix="$(web_site_matrix "$browser_workflow")"
expected_web_site_matrix="$(cat <<'EOF'
suite-quota|tests/standalone-sites-quota.e2e.spec.ts
suite-pet|tests/standalone-sites-pet.e2e.spec.ts
suite-availability|tests/standalone-sites-availability.e2e.spec.ts
language|tests/dictionary-page.e2e.spec.ts tests/speech-grammar-results.e2e.spec.ts
language-switching|tests/learning-language.e2e.spec.ts
language-curriculum|tests/learner-language.e2e.spec.ts
language-study|tests/study-language.e2e.spec.ts
language-games|tests/games-language.e2e.spec.ts
language-practice|tests/practice-language.e2e.spec.ts
language-pet|tests/pet-language.e2e.spec.ts
language-exam|tests/exam-language.e2e.spec.ts
language-music|tests/music-language.e2e.spec.ts
language-community|tests/community-language.e2e.spec.ts
language-memory|tests/memory-language.e2e.spec.ts tests/memos-language.e2e.spec.ts
language-feeds|tests/feeds-language.e2e.spec.ts
language-agent|tests/agent-language.e2e.spec.ts
language-setup|tests/setup-language.e2e.spec.ts
language-admin-overview|tests/admin-overview-language.e2e.spec.ts
language-admin-settings|tests/admin-settings-language.e2e.spec.ts
language-graphics|tests/graphic-books-language.e2e.spec.ts
voice-agent|tests/voice-agent-page.e2e.spec.ts
creative|tests/music-page.e2e.spec.ts tests/graphic-book-workspace.e2e.spec.ts tests/admin-plan-mm-gateway.e2e.spec.ts
reader-selection|tests/reader-selection-visual-explanation.e2e.spec.ts
memory|tests/memory-workspace.e2e.spec.ts
memos|tests/memos-page.e2e.spec.ts
EOF
)"
if [[ "$actual_web_site_matrix" != "$expected_web_site_matrix" ]]; then
  echo "test-web-sites matrix must exactly mirror the Speak source workflow" >&2
  diff -u <(printf '%s\n' "$expected_web_site_matrix") <(printf '%s\n' "$actual_web_site_matrix") >&2 || true
  exit 1
fi

if [[ -n "$source_root" ]]; then
  source_browser_workflow="$source_root/.github/workflows/docker-ci-web-browser.yml"
  if [[ ! -f "$source_browser_workflow" ]]; then
    echo "Speak source browser workflow not found: $source_browser_workflow" >&2
    exit 1
  fi
  source_web_site_matrix="$(web_site_matrix "$source_browser_workflow")"
  if [[ "$actual_web_site_matrix" != "$source_web_site_matrix" ]]; then
    echo "Private test-web-sites matrix has drifted from the requested Speak source ref" >&2
    diff -u <(printf '%s\n' "$source_web_site_matrix") <(printf '%s\n' "$actual_web_site_matrix") >&2 || true
    exit 1
  fi
fi

postflight_artifact_contracts=(
  "$standalone_workflow|test-proxy|e2e-observability-proxy-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability/proxy-*"
  "$standalone_workflow|test-standalone-mm-gateway|e2e-observability-standalone-mm-gateway-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability/standalone-mm-gateway"
  "$standalone_workflow|test-standalone-operations|e2e-observability-standalone-operations-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability/standalone-operations"
  "$standalone_workflow|test-local-compose-security|e2e-observability-local-compose-security-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability/local-compose-security"
  "$api_workflow|test-api-mm-gateway-e2e|e2e-observability-mm-gateway-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability/mm-gateway"
  "$browser_workflow|test-web-base-path|e2e-observability-base-path-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability/runtime-prefix"
  "$live_workflow|test-web-ai-text-live|e2e-observability-ai-text-\${{ matrix.scenario }}-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability"
  "$live_workflow|test-web-live-talk-live|e2e-observability-live-talk-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability"
  "$e2e_workflow|test-web-e2e|e2e-observability-desktop-\${{ matrix.database }}-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability"
  "$e2e_workflow|test-web-e2e-redroid-mobile|e2e-observability-redroid-\${{ matrix.database }}-attempt-\${{ github.run_attempt }}|.tmp/e2e/observability"
)
for contract in "${postflight_artifact_contracts[@]}"; do
  IFS='|' read -r workflow job artifact_name artifact_path <<< "$contract"
  job_block="$(workflow_job "$workflow" "$job")"
  require "$job" "name: $artifact_name" "$job_block"
  require "$job" 'if: always()' "$job_block"
  require "$job" 'uses: actions/upload-artifact@v7' "$job_block"
  require "$job" "path: $artifact_path" "$job_block"
done

if grep -R -Eq 'NEXT_PUBLIC_(API_URL|BASE_PATH)=' "$workflow_dir"; then
  echo "Private CI must not override tokenized web runtime configuration at build time" >&2
  exit 1
fi
if grep -Fq 'LIVE_TALK_API_KEY=$LIVE_TALK_API_KEY' "$live_workflow"; then
  echo "Live Talk browser job must not print its API key" >&2
  exit 1
fi

echo "Private CI workflow contract passed: ${#test_jobs[@]} dispatcher test jobs and ${#reusable_workflows[@]} reusable workflows are bounded and gated."
