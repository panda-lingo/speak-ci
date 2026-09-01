# speak-ci

This repository runs GitHub Actions for the private `panda-lingo/speak` repository while keeping the CI repository public.

## Workflow

The workflow dispatcher at `.github/workflows/speak-private-ci.yml` is pinned to
this organization mapping:

| Concern | Value |
| --- | --- |
| Source repository | `panda-lingo/speak` |
| CI repository | `panda-lingo/speak-ci` |
| Published API image | `ghcr.io/panda-lingo/speak` |
| Published web image | `ghcr.io/panda-lingo/speak:web-*` |
| Package publish credentials | `GITHUB_TOKEN` from `panda-lingo/speak-ci` with `packages: write` |

The dispatcher preserves the source workflow's individual test-job names. It
selects a focused reusable workflow through a declarative `target` input, then
the dispatcher quality gate requires every selected test job to succeed before
either image build can begin. The reusable workflow layout is:

| Dispatcher job group | Reusable workflow | Coverage |
| --- | --- | --- |
| API | `private-ci-api.yml` | Go, live AI text, direct mm-gateway, and OMNI audio checks |
| Standalone | `private-ci-standalone.yml` | proxy, mm-gateway, recovery, and local Compose-boundary checks |
| Web browser | `private-ci-web-browser.yml` | unit, mock-site, and runtime-prefix checks |
| Web live | `private-ci-web-live.yml` | live AI text and Live Talk journeys |
| Web full-stack | `private-ci-web-e2e.yml` | desktop and Redroid browser checks |
| Builds | `private-ci-build.yml` | API and web image build/publish jobs |

Each reusable workflow receives the same `panda-lingo/speak` repository and ref
mapping as explicit inputs. The called jobs set `CHECKOUT_REPOSITORY` and
`CHECKOUT_REF` from those inputs and retain `SPEAK_REPO_TOKEN`; this makes the
private-source boundary visible even though the jobs live in focused files.

The workflow contains the copied `panda-lingo/speak` test, build, and publish jobs and asks them to:

- validate its own job timeout and quality-gate contract in a fast
  `test-private-ci-workflow` job
- check out `panda-lingo/speak` with `SPEAK_REPO_TOKEN`
- run the test matrix
- run both the direct provider-backed mm-gateway e2e and the complete `/music`
  browser journey when their mirrored settings are configured; the browser
  enters style and lyric direction, composes final inputs, starts asynchronous
  generation, waits for `completed`, and validates recognizable audio bytes
- pin the supervisor-capable mm-gateway revision whose status reads return
  cached snapshots; provider logs containing prompts or signed media URLs are
  excluded from uploaded artifacts
- exercise the source repository's standalone PostgreSQL, VictoriaMetrics, and
  rclone recovery smoke before images can be built or published
- exercise the local Compose network-boundary contract and upload its
  non-secret postflight evidence on every result
- run the source repository's uncached OMNI audio-practice, pinned music-analysis,
  and voice-memo e2e contract when the mirrored `OMNI_*` settings are present
- run the source repository's real Live Talk browser journey when the mirrored
  `LIVE_TALK_*` settings are present; the journey configures the Free plan
  through the Admin Portal UI before it starts a learner conversation
- bootstrap Redroid without an APT index refresh: use the hosted runner's
  tool baseline, download the official Android Platform-Tools archive only when
  `adb` is absent, make only a bounded no-index repair attempt for a missing
  matching binder module, then validate and re-export the logged tool directory
  for the later browser step
- build the API and web images
- optionally publish the images back to `ghcr.io/panda-lingo/speak`

Automatic behavior:

- pull requests, pushes to `main`, and tags that start with `v` run tests and image builds against the matching source ref in `panda-lingo/speak`
- pushes to `main` and tags that start with `v` also publish images
- manual runs can choose any `source_ref` from `panda-lingo/speak` and can force publishing with the `publish_image` input

## Runtime-prefix verification contract

The fallback workflow must build the source repository's web image without
`NEXT_PUBLIC_API_URL` or `NEXT_PUBLIC_BASE_PATH` build overrides. The source
image contains validated runtime tokens; its `test-web-base-path` job runs the
source `npm run test:e2e:base-path` contract, which starts fresh containers
from one image at both `/speak` and `/academy`. This keeps fallback CI aligned
with the deploy-without-rebuild guarantee instead of testing a separately
prefix-built image.

## Job timeout contract

The workflow uses a declarative timeout budget for every job:

| Job group | `timeout-minutes` | Constraint |
| --- | ---: | --- |
| ordinary `test-*` and `build-*` jobs | 9 | Must remain strictly below 10 minutes |
| `test-api-mm-gateway-e2e` | 25 | Covers the source build and full asynchronous provider deadline |
| `test-web-ai-text-live (music)` | 40 | Covers setup, composition, generation, terminal polling, and audio validation |
| `quality-gate` | 5 | Must remain strictly below 10 minutes |

Every ordinary job must declare an integer timeout from 1 through 9; only the
two data-driven music exceptions above may exceed it. The `quality-gate` must
list every dispatcher `test-*` job in `needs`, including the direct and
standalone `mm-gateway` checks, the stateful recovery smoke, and the local
Compose-boundary contract. The live browser job depends on both the text and
direct gateway prerequisites, and its matrix remains serial so provider calls
cannot overlap. The contract script checks the dispatcher-to-reusable mapping,
timeouts, topology, and result gate so new work cannot bypass coverage.

## Required Setup

1. In this repository, add an Actions secret named `SPEAK_REPO_TOKEN`.
2. Use a token that can read the private `panda-lingo/speak` repository.
3. Mirror `IMAGE_PROVIDER`, `IMAGE_BASE_URL`, `IMAGE_MODEL`, `MUSIC_PROVIDER`,
   and `MUSIC_MODEL` as repository variables, plus `IMAGE_API_KEY` as a
   repository secret. For a non-Vertex music backend, also configure
   `MUSIC_BASE_URL` and `MUSIC_API_KEY`. For Vertex Lyria, set
   `MUSIC_PROVIDER=vertex`, an explicit Vertex Lyria `MUSIC_MODEL` pin (for
   example `lyria-3-pro-preview`), and the raw service-account JSON in
   `VERTEX_CREDENTIALS_JSON`; `MUSIC_API_KEY` and `MUSIC_BASE_URL` are
   deliberately not required. To verify the production incident path, set the
   repository overrides `MUSIC_PROVIDER=minimax`, the regional API host that
   issued the inherited key, and a model currently accepted by that public
   endpoint. The China-region CI credential uses
   `MUSIC_BASE_URL=https://api.minimaxi.com`; the September 2026 contract pins
   `MUSIC_MODEL=music-2.6-free`, which is available to every MiniMax API key;
   the inherited `MUSIC_API_KEY` must be a MiniMax key. The direct e2e derives
   the project from the service account and defaults Lyria to the global
   endpoint; deployment-only
   `VERTEX_PROJECT` and `VERTEX_LOCATION` overrides are not injected into this
   check. The direct mm-gateway e2e is an explicit successful no-op until its
   selected provider configuration is complete.
4. Mirror `OMNI_API_FORMAT`, `OMNI_BASE_URL`, and `OMNI_MODEL` as repository
   variables and `OMNI_API_KEY` as a repository secret. Repository-level
   values take precedence over inherited organization values and keep all four
   settings bound to the same provider.
5. Mirror `LIVE_TALK_API_FORMAT`, `LIVE_TALK_BASE_URL`, and `LIVE_TALK_MODEL`
   as repository variables and `LIVE_TALK_API_KEY` as a repository secret. The
   format must be `gemini` or `openai`, and all four values must describe the
   same realtime provider endpoint. The workflow passes them only to the
   Live Talk job, whose browser setup writes them through `/admin/plans` rather
   than pre-seeding provider settings through an API shortcut.
6. Keep the workflow job permissions at `packages: write` so the repository `GITHUB_TOKEN` can publish `ghcr.io/panda-lingo/speak`.

Without `SPEAK_REPO_TOKEN`, the workflow can start in this public repo, but every job that checks out the private source tree will fail.
If the resolved `OMNI_*` configuration is incomplete, the live OMNI job is an
explicit successful no-op. Configure all four values at repository scope before
dispatching a live run; GitHub otherwise resolves any organization defaults.
The Live Talk job follows the same explicit-no-op rule only when its entire
`LIVE_TALK_*` configuration is absent or incomplete; a non-empty unsupported
format fails as a configuration error.
