# ax fork — handoff, known gaps, and how to work on them

This file hands the repo to a fresh agent (or a future session) with no memory
of this fork's history. Read it top to bottom before touching code.

## 0. Repo state (read this first)

- Fork of [`vercel-labs/fx`](https://github.com/vercel-labs/fx) at upstream
  tag `v0.0.6` (merge `00e3f4f` over `04e0ae0`, v0.0.5), renamed to **ax**.
- `origin` = `https://github.com/doriangironde/ax.git`, `upstream` =
  `https://github.com/vercel-labs/fx.git`.
- Fork commits:
  - `0da89d9` — rebrand: user-facing identity + binary rename `fx` → `ax`.
  - `cbc8db6` — skills-menu filter-label collision fix + TUI/e2e expectation
    alignment.
  - `528321f` — G10 custom-provider feature (registry, presets, and the
    OpenAI-compatible transport; see G10 below).
  - `00e3f4f` — merge upstream `v0.0.6` with the fork identity, G10, and the
    picker hub re-applied (see "v0.0.6 sync notes" below).
  - `982143c` — merge latest upstream `main` (85 commits past `00e3f4f`) with
    the fork identity re-applied (see "Round 2 sync notes" in G7). On local
    branch `sync-upstream`; **not pushed or merged to `main` yet** — the fork's
    GitHub `main` now carries only the pre-sync history plus the 0.0.7 release
    prep (PR #1, branch `prepare-v0.0.7`).
- The binary is `./zig-out/bin/ax`. **Always use this binary for
  verification.** Never run a `PATH`-installed `fx`.

### What the rebrand changed vs. what it deliberately kept

Changed (user-facing): welcome header `𝒂x`, help/usage (`ax [flags]`,
`ax ask`...), error prefixes (`ax:`), system prompt (`You are ax`),
permission-mode guidance, approval copy, upgrade notices, trace filenames
(`ax-trace-*`), ACP `agentInfo`, herdr agent name, YOLO warning, gateway
`X-Title` header, README.

Kept (internal/compat, do not rename casually):
- Config dir `~/.fx`, env vars `FX_*`, session on-disk format (schema v3).
- WASM exports (`extern "fx"`, `fx-core.wasm`, `fx-term.wasm`).
- ACP `_meta` protocol key `{"fx": {...}}`.
- MCP wire identity: `io.modelcontextprotocol/clientInfo` name is `fx` in
  `mcp_runtime.zig` (3 sites) and `tool_subscription.zig` (listen metadata),
  and the recovery-continuation marker `_meta.fx.continueRecovery`. The e2e
  fixture `fixtures/mcp-modern-stdio.mjs` refuses every message whose
  `clientInfo.name !== "fx"` (conformance oracle, do not touch); the
  `<fx-turn-context>` prompt marker is asserted by tests. See G9.
- Provider attribution headers: `originator=fx` (OpenAI), 
  `x-grok-client-identifier=fx`, user-agent/`http-referer` =
  `https://github.com/vercel-labs/fx`. The OAuth authorize URLs built by
  `chatgpt_oauth.zig`/`grok_oauth.zig` also carry `originator=fx` /
  `referrer=fx` parameters — the PKCE URL unit tests assert them.
- Skills-menu filter label `"Fx"` (see gap G4 — do not "fix" the spelling).
- `fx.sh` documentation URLs (upstream docs serve the same feature set).

## 1. Environment setup (one-time)

```bash
# Zig 0.16.0 (matches CI pin) lives at ~/zig
export PATH="$HOME/zig:$PATH"        # add to shell rc
zig version                            # expect 0.16.0

# When shelled through the DSH file sandbox, redirect Zig's GLOBAL cache into
# the workspace: the sandbox denies writes to ~/.cache/zig, which fails every
# build with manifest_create PermissionDenied.
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"   # (gitignored)

# TUI tests need tmux (3.7c installed via brew on this machine)
tmux -V

# e2e deps
cd tests/e2e && bun install
cd ../evals && bun install            # only if running live evals
```

### Sandbox limitation: tmux cannot fork (affects every TUI test)

Since 2026-08-26 the DSH file sandbox denies `fork()` inside the tmux server:
every `tmux new-session` fails with `create window failed: fork failed:
Operation not permitted`. All tmux-based e2e suites (tui-*, mcp-* TUI cases,
prompt-history TUI cases) fail at session creation, not in app code. Run them
in an unsandboxed shell or on CI. The picker/layout changes were verified
instead by their unit tests (`auth_runtime` PickerView tests), the CLI suite,
and live `ax` drives.

### tmux hygiene (required on this machine)

The tmux default server wedges when its working directory is deleted (a test
fixture cleanup can do this between tests). A wedged server makes every pane
die instantly — panes look "empty" and tests time out at their first wait.
Symptoms: `Timed out waiting for pane predicate`, `Last pane:` empty, exit
status files written with `0` but no output.

**Always `tmux kill-server` before starting any TUI run and between files:**

```bash
cd tests/e2e && tmux kill-server; bun test tui-startup.test.ts; tmux kill-server
```

Exit-status artifacts land in bun's tmpdir:
`/var/folders/.../T/fx-test-*.exit-status` (useful forensics: a `0` with empty
pane = the process spawned and exited, i.e. wedge or early-exit, not a crash).

## 2. Verification matrix (measured on this machine, macOS arm64)

### Green on the fork

| Suite | Command | Result |
|---|---|---|
| Zig unit | `zig build test` | 8538/8541, 3 skipped; 3 fails + 1 leak = the sandbox-environment set only (PTY/Keychain/raw-mode denials + the pre-existing `terminal start` leak; byte-identical on pristine upstream code under the same sandbox). Includes the 25+ custom-provider tests and the v0.0.6 additions. Unsandboxed shell shows the historical counts below. |
| CLI e2e | `bun test cli.test.ts` | 110/117 pass, 5 skip (live-key evals); 2 fails = macOS Keychain sandbox denial only |
| e2e non-TUI | `bun test config-persistence.test.ts prompt-history.test.ts` | pass (their TUI-dependent cases need tmux, see below) |
| ACP + gateway | `bun test acp.test.ts ./gateway-stream-lifecycle.test.ts ./tmux-helpers.test.ts` | pass (last verified 298/0 across these + cli + persistence) |
| MCP e2e | `bun test ./mcp-stdio.test.ts ./mcp-http.test.ts ./mcp-legacy-remote.test.ts ./mcp-auth.test.ts ./session-recovery.test.ts` | non-TUI cases pass; TUI cases blocked by the sandbox tmux fork denial (below) |
| MCP conformance | `cd tests/e2e/conformance && npm ci && npm test` (needs `zig` on PATH) | PASSED |
| tui-startup | 10/10 | |
| tui-slash-menu | 38/38 | (was 37/38 until G4 fix) |
| tui-input-navigation | 37/37 | |
| tui-auth-source-selection | 50/50 | |

### Failing identically on upstream (pre-existing, environment — not fork bugs)

Proven by rebuilding upstream `04e0ae0` in a worktree and running the same
files. Do not chase these locally; they are tmux-3.7c/machine/parse-sensitive
and pass on CI runners:

| File | Failures |
|---|---|
| `tools.terminal.terminal` leak (zig) | `terminal start canonicalizes interactive command representations` leaks 5 allocations (fails on clean upstream too) |
| `tui-native-clear-recovery.test.ts` | 2/4: `direct native-clear recovery...` + `direct healthy screens retain...` |
| `tui-resume.test.ts` | 2 fails (`streamed document append preserves native scrollback without ONLCR`, `Ctrl-C closes the Ctrl-O viewer...`, `graceful exit prints an exact resume command`) + `upgrade ctrl-g ...` x2 (61 s timeouts) |
| `tui-gateway-stream-lifecycle.test.ts` | `launch-row release preserves complete history during a large table append` only (fails identically on pristine upstream; tmux command-parse interaction with the quoted pane command on this machine) |
| `tui-resize.test.ts` | 9 fails (set identical to upstream, names differ only by `fx`→`ax`) |

Note: `tui-resize.test.ts` takes ~2 min and its 9-fail set was byte-compared
against upstream — do not treat a new failure set there as a regression
without the upstream worktree comparison. Re-run `tui-resize` after the G3
harness fix landed; several `:0`-targeted failures may have been the
`base-index` config issue below.

## 3. Gap inventory (work items)

### G1 — CI on the fork repo is not configured (highest priority)

**Why:** GitHub repo exists but no Actions runs have been green; the shared
workflows were renamed in files but some paths still say `fx`.

**Status (2026-08-24): DONE — verified green.** The push matrix on `main`
(`ci.yml` + `Benchmarks` + `Release`) is green on the current commit; the
four-runner `full-ci.yml` matrix was verified on a `ci-verify` test branch
(see below) and passes. What was fixed along the way:

- `mcp_runtime`/`tool_subscription` wire identity + test/fixture alignment
  (G9) — this was the bulk of the E2E failures.
- SDK tests (`𝒇x` glyph, `Signed out of fx.`) and `ci.yml`
  `--test-name-pattern "fx ask …"` filter.
- `release.yml`/`dev-release.yml` packaged the `ax` binary under the `fx`
  tar member, failing the Package step on every push; PGSO control stage
  now adopts the product-named executable (`scripts/pgso/pipeline.py`
  `build_control`).
- `ci-shards`/tmux harness window/pane index resolution (G3).
- Terminal/upgrade sweep tail: `ax-trace-*.md` report filters, process
  discovery basename, `ax-terminal-` transport root, internal control-mode
  flag, upgrade tarball member (`ax`), graceful-exit resume symlink, and
  the render-replay fixture name.

Remaining known items:
1. PGSO self-named runner-temp paths (`fx-pgso-*`, `control/bin/fx` upload
   paths in `pgso-macos-arm64.yml`, `scripts/pgso/README.md` prose) are
   deliberate pipeline self-naming — the control path now exists thanks to
   the `build_control` shim; leave the names.
2. The `Release` workflow runs the full PGSO qualification on every push
   because the fork has no release tags (`check-version` reports needed).
   That is heavy and slow; either accept it or tag 0.0.5 once a release is
   wanted. `Dev Release` and `Publish libfx` lanes legitimately no-op/exit
   nonzero until a release tag exists.
3. Keep the PGSO/binary-size/bench gates: they enforce upstream's 7.8 MiB
   ceiling and 2 ms startup budget; both apply to ax.

**Verify:** full-ci green on all runners for the exact commit — recorded
green at commit `79f5cef` on branch `ci-verify` (24/24 jobs: 4 native
checks + 16 E2E shards), and the push `CI` + `Benchmarks` green on `main`. 

### G2 — Local TUI flakiness (mostly resolved; CI is the real gate)

**Why:** the largest share of local "pre-existing" TUI failures was the
machine's `~/.config/tmux/tmux.conf` setting `base-index 1` (see G3/G9:
harness hardcoded `:0` targets). The harness now resolves indexes at session
creation, so gated sessions and most TUI tests pass locally. Remaining local
fails are the section-2 table (proven identical on pristine upstream).

### G3 — tmux cwd-wedge hardening (DONE — see G9 for the deeper root cause)

`tmux-helpers.ts` now resolves the real window index and pane id at session
creation instead of hardcoding `:0` / `.0.0` targets. This fixed a whole class
of "pre-existing" TUI failures on this machine: `~/.config/tmux/tmux.conf`
sets `base-index 1` and `pane-base-index 1`, so every harness `-t name:0`
target died with `no such window`. tui-startup (no `:0` targets) always
passed; every gated/remain-on-exit session failed. CI runners write a bare
`.tmux.conf` (history-limit only), so CI never saw it — the failures were
local-only. Do not remove the per-session `windowIndex`/`paneId` resolution;
it is a correctness fix that also holds for default index 0.

Remaining machine fails that are NOT index-related: `launch-row release...`
(tmux chain-parse interaction with the quoted observed pane command), the
61 s `upgrade ctrl-g` timeouts, `tui-native-clear-recovery` x2, and the
`tui-resize` set. All byte-compared/proven identical on pristine upstream
`04e0ae0` on this machine. Do not chase them locally.

### G4 — Skills-menu filter label wart: `"Fx"` must stay (do not "fix")

**Root cause (bisected across 13 rebuilds):** `skillMenuFilterLabel(.fx)`
returns `"Fx"`. Changing the value to `"ax"` (or `"Ax"`) deterministically
breaks the `$`-inline-completion flow: the skills menu opens with a bogus
single-result state and `tui-slash-menu.test.ts` =>
`inline completions stay in the composer...` times out (9.5 s, pane shows
`Skills 1` + `managed-menu` + empty composer). The menu-matching machinery
collides with the lowercase 2-letter label value; capitalization does not
matter, length does not matter — only `"Fx"` works.

**Decision: leave the label as `"Fx"`.** It appears only in the skills-menu
source-tab header (`[Fx]`). Tests assert `"Fx"`:
- `src/ui/footer/skills_menu_presentation.zig:447`, 
- `tests/e2e/tui-slash-menu.test.ts:2339`,
- `tests/e2e/tui-resize.test.ts:652`.

**If you ever fix it properly:** first find which subsystem matches against
the visible tab row (fuzzy filter in `src/ui/input` or skills completion in
`src/core/skills`), make the matcher exclude rendered chrome, then restore
`"ax"` and update the three assertions above.

**Verify:** `bun test tui-slash-menu.test.ts` must stay 38/38.

### G10 — Custom providers (v1 complete; roadmap for v2)

**What:** ax can now run against any OpenAI-compatible endpoint registered in
`~/.fx/providers.json` (name, base_url, api_key or api_key_env, api_type,
models with context_window/max_output_tokens/reasoning/vision/file_input).
Wire: `POST <base_url>/chat/completions` with SSE parsing for content,
reasoning_content, tool calls, usage, and finish reasons. No Gateway traffic:
keys resolve from the registry (env ref wins, then inline), tracked as the
`custom_provider` credential source.

**User surfaces (v1):** `ax provider <name>` activates a registered provider
(no catalog fetch; the model list is static from the file), `ax models` lists
its models, `/model` and the model cache serve the static catalog, sessions
and subagents carry the selection (`custom_provider` in settings.json and the
session codec, optional keys, backward compatible), and resume/restore routes
back through the same registry. Interactive: `/login` opens the setup hub and
its **Model provider** stage lists every registered custom provider after the
three builtins (plus unregistered presets); selecting one activates it in
place and marks it `current`. A custom provider without a usable key opens a
masked inline key entry; Enter stores the key into `~/.fx/providers.json`
(removing `api_key_env` so the stored key is authoritative) and completes the
switch. Esc returns to the provider stage. Permissions: automatic review is
disabled for custom providers (the custom bundle carries no
`permission_reviewer`); sensitive actions surface the direct prompt instead.

**Inline key entry notes:** the typed key lives in the auth runtime's
`api_key_input` buffer, is masked in the picker, and is zeroed after the save;
`storeApiKey` (custom_providers.zig) rewrites providers.json atomically
(tmp + rename, mode 0600) with the inline `api_key` and no env reference.
The submit flow owns a copy of the provider name before stage teardown: the
runtime's `clearRetainingCapacity` scribbles 0xaa over its buffers in Debug
builds, so borrowed slices must not outlive it (the 2026-08-24 garbage-name
regression was exactly this). The catalog provider returned by
`App.customCatalogProviderForSelection` (and the ask context's twin) points
its context at the owning app field: the model cache fetches on a worker
thread, and a stack-local context segfaulted interactive startup
(2026-08-24 SIGSEGV regression, pinned by a pointer-identity regression test
in main.zig).

**Implementations that deliberately punt (v2):**
1. ACP sessions cannot route `.custom`; the server says
   `AgentStreamProviderUnavailable` (same treatment as codex/grok in WASM).
2. Only `openai-completions` api_type exists. `anthropic-messages` and
   `openai-responses` are future enum values; unknown api_types are skipped at
   registry load with the rest of the entry intact.
3. No automatic permission reviewer on the custom route, no auth header
   templating beyond `Bearer <key>` (or no header at all for keyless
   entries). The `/v1/models` fetch is DONE (v1): `ax provider refresh
   <name>` (see below).
4. WASM hosts never carry custom routes.
5. The `/login` stage refreshes the registry each time it opens, but
   the app's lazily loaded in-memory registry is only re-read on restart; a
   provider added to providers.json while ax runs appears in the picker
   immediately and is activatable (the switch flow reads the file fresh), while
   `/model` warmups for the new name start after the next launch. Preset
   registration while running is the one caller that reloads the in-memory
   registry immediately (`App.reloadCustomProviderRegistry`) so the freshly
   registered entry is routable in the same session. Since 2026-08-25 the
   `/login` root menu lists registered custom providers and unregistered
   presets directly (after the built-in sign-in ways, before Switch provider);
   the provider stage under Switch provider remains the full list with the
   built-ins included and the active row marked. The root menu marks the
   active provider row `current` (`openPickerWithActiveProvider`, fed by
   `/login` and `/setup` with the runtime selection) while preset rows carry
   no description; display rows use each preset's curated `label`
   (e.g. OpenCode Go) through `auth_runtime.customProviderLabel`, so
   registered names that match a preset are also shown under the label while
   hand-registered names keep their own identifier.
6. Preset model lists are static starting points, never live `/v1/models`
   fetches; users edit providers.json for catalog drift.

**Presets (2026-08-25):** `src/core/config/provider_presets.zig` ships 12
curated OpenAI-compatible endpoints (opencode-go, openrouter, groq, deepseek,
ollama, together, mistral, cerebras, xai, gemini, perplexity, moonshot) with
curated display labels (OpenCode Go, OpenRouter, Groq, DeepSeek, Ollama,
Together AI, Mistral, Cerebras, xAI, Gemini, Perplexity, Moonshot).
Registration (`ax provider <preset>`, or a `.custom_provider_preset` picker
row) merges the preset entry into providers.json inside one request arena,
preserving every other entry verbatim; an absent file starts a fresh document
and the parent `.fx` dir is created. `keyless: true` entries (only ollama in
the catalog; manual entries may set it too) need no key: the transport omits
the Authorization header (`Value.omit`) instead of failing with
`OpenAICompatibleCredentialRequired`, `resolveForProviderWithCustom` returns
an empty-token custom credential, the CLI activation check uses
`Entry.usableKey()`, and the interactive switch skips the inline key picker.
Keyless entries send no auth header and are only as safe as the endpoint
(localhost default). Verified live 2026-08-25: `ax provider ollama` registers
and selects with a fresh isolated HOME; `ax provider openrouter` registers
and correctly demands `OPENROUTER_API_KEY`; `ax provider` lists all three
classes; unit suite covers catalog invariants, merge, idempotence, malformed
documents, keyless parsing, and the transport guard.

**Registry details:** env override `FX_CUSTOM_PROVIDERS_PATH` (absolute path,
test/diagnostic use); default `~/.fx/providers.json`. Registry validation is
in `src/core/config/custom_providers.zig` (name charset `[a-z0-9-]`, no
slashes; entries with unknown api_type, bad URLs, or no models are skipped).
Transport in `src/gateway/openai_compatible.zig` mirrors
`openai_codex.zig`'s bounded HTTP + SSE discipline. Static catalog adapter
`staticCatalogProvider` feeds the model cache and picker.

**Sweep note:** provider names travel as strings (`custom_provider` keys in
settings/session JSON). Any future sweep that touches `"custom"` / the
`custom_provider` key must keep binary and tests in agreement, and the
`mcp-modern-stdio.mjs`-style conformance oracles do not involve this surface.

**Wire contract (2026-08-24):** the tools array must keep the standard
OpenAI nesting `{"type":"function","function":{"name",..., "parameters",...}}`.
Flattened tool objects pass permissive servers (the local mock) but OpenCode Go
rejects them with `tools[0]: missing field 'function'`; the transport unit test
pins the nested shape. Verified live against opencode.ai after the fix: plain
and tool-calling `ax ask` round trips (deepseek-v4-flash-vision-exp, stored
inline key) complete end to end.

**Model refresh (v1, 2026-08-26):** `ax provider refresh <name>` fetches
`<base_url>/models` and merges the catalog into providers.json atomically.
Merge policy: newly advertised models are added; models that already exist
keep their declared metadata (fetched metadata wins per field); models the
endpoint dropped are removed except one retained model — the provider's
currently selected model (`models.custom` in settings), or the previous first
model when nothing is selected — so the selection always survives. The merged
list is capped at `max_models_per_provider` (retained entry first, so
truncation never drops the selection). Files: `refreshModels` +
`ModelRefreshSummary` in `custom_providers.zig` (mutates the raw JSON document
in the parse arena, atomic tmp+rename write via the extracted `writeDocument`);
`fetchModelCatalog`/`parseModelsCatalog`/`modelsEndpoint` in
`openai_compatible.zig` (bounded GET via `runBoundedHttpOperation`, Bearer key
or none for keyless, tolerant parse that rejects empty catalogs);
`refreshCustomProviderModels` in `cli_surface.zig` (usage:
`ax provider <gateway|codex|grok|custom-name> | refresh <custom-name>`).
Caveats: no `--json` summary yet; a GET request must be finalized with
`sendBodilessUnflushed()` + `connection.flush()` before `receiveHead` — without
it the head never leaves and the CLI hangs (hit and fixed during the e2e).
Verified end to end against `scripts/local-mock-openai.py` (which now serves
GET /v1/models, shapeable via `MODELS_JSON`): phase 1 add/keep/remove,
phase 2 retention of the selected model with metadata and ordering, plus
unknown-provider, invalid-name, and bare-`refresh` usage errors. Zig unit
tests cover the merge policy, the tolerant parse, and the endpoint builder.

**E2E verification (2026-08-24, this machine, sandboxed shell):** a local
mock OpenAI-compatible server (`scripts/local-mock-openai.py`, run on
127.0.0.1) was registered as `mock`, then driven with the freshly built
`zig-out/bin/ax` under an isolated `HOME`:
1. `ax provider mock` -> `Provider set to mock (custom).`; settings written
   as `{"model":"helper","provider":"custom","custom_provider":"mock"}`.
2. `ax models` lists the registered models; no Gateway copy shown for the
   custom catalog.
3. `ax ask "Just say hi"` streams `hello from helper` through the custom
   SSE path and exits 0 after exactly one request.
4. `ax ask "list the files in this directory"` drives the mock tool call
   (`list_files`) through the real tool admission and execution path, then
   continues for a second plain request; exits 0.
5. `ax ask --resume last` continues the custom session on the same route.
6. Interactive (tmux): `/login` -> Switch provider lists registered custom
   names; selecting one with a key present persists
   `{"provider":"custom","custom_provider":"<name>"}` and shows
   `Switched to <name> (custom provider) with <model>.`; reopening the picker
   marks the active name `current`; a subsequent typed prompt streams through
   the custom transport inline.
7. The real OpenCode Go registry entry (30 models from the live catalog) was
   validated by `ax models` and by a dummy-key `ax ask` that reached
   `https://opencode.ai/zen/go/v1` and returned HTTP 401.
8. Interactive drives (tmux, isolated HOME, real registry): `/login` ->
   Switch provider lists `opencode-go` after the builtins; selecting with the
   missing key opens the masked key entry; typed key + Enter stores it inline
   (providers.json rewritten atomically, `api_key_env` removed) and completes
   the switch; reopening the picker marks the provider `current`.
9. Live against opencode.ai with the stored inline key (flat-rate
   subscription): `ax ask` plain and tool-calling round trips pass end to end
   on `deepseek-v4-flash-vision-exp` after the tools[0].function fix (item
   below). The user's real profile now selects the custom provider
   (`provider=custom`, `custom_provider=opencode-go`) with the inline key on
   this machine.
10. Suite runs after every fix: 8468/8476, only the sandbox-environment set
    failing (identical on pristine code); `zig fmt --check src/` clean;
    Debug + wasm + napi builds compile.
6. `zig build test`: all 23 new unit tests pass. The four failures that
   remain (PTY output drains, terminal start leak, Keychain round trip,
   enableRawMode queued input) reproduce identically on the pristine
   pre-change tree and are sandbox artifacts: the sandbox denies PTY,
   Keychain, and raw-mode termios access, and the Zig runner panic
   `error logs detected` aborts co-running tests with "failed without
   output". Run the suite in an unsandboxed shell to see the historical
   counts (8442/8444, 1 pre-existing leak).
7. `zig fmt --check src/` passes. The Debug binary, wasm-surface=core, and
   napi-surface=core builds all compile.

**Verify:** `zig build test` (unsandboxed shell), `ax provider <name>` with a
local OpenAI-compatible server, `ax models`, and an `ax ask` round trip through
the custom route.

### G9 — MCP/context wire identity must stay `fx` (regression fixed, keep)

The rebrand swept the binary's MCP `clientInfo` name to `ax`, which broke the
e2e conformance fixture oracle: `fixtures/mcp-modern-stdio.mjs` rejects every
message whose `_meta.clientInfo.name !== "fx"` (each rejected listen also
suppresses the fixture's `list_changed` notifications). Symptoms: `acp.test.ts`
18 fails, `mcp-stdio.test.ts` subscription/search fails, gateway lifecycle
fails — all deterministic, but only visible when a test drives the fixture
through a full session (the acp/CLI matrix in earlier runs did not cover it).

Fixed by reverting the clientInfo name to `fx` at all four emission sites:
- `src/core/mcp/mcp_runtime.zig:11651` (modern request metadata)
- `src/core/mcp/mcp_runtime.zig:12451` (legacy initialize)
- `src/core/mcp/mcp_runtime.zig:15861` (unit-test expectation)
- `src/core/mcp/tool_subscription.zig:1009` (subscriptions/listen — missed
  on the first pass; its wire showed `ax` while discover/list showed `fx`)

Plus test-side reversions to match kept wire tokens:
- `_meta: { fx: { continueRecovery: true } }` in `acp.test.ts` (binary parses
  `_meta.fx.continueRecovery`; the sweep renamed the client key to `ax`)
- `<fx-turn-context>` in `gateway-stream-lifecycle.test.ts` (binary emits
  `fx-turn-context`, G7's src protect list kept it, the tests sweep list was
  missing it)
- `tests/e2e/permission-mode-context.ts` was an unswept fixture of
  user-facing copy — sweep it forward (`fx`→`ax` in the copy) whenever the
  binary's permission-mode guidance text changes; it is not a wire surface.

Also fixed: tests/conformance still spawned `zig-out/{"bin","fx"}`
(rebranded binary is `ax`) — `mcp-stdio.test.ts` (13 sites),
`mcp-legacy-remote.test.ts`, `tests/e2e/conformance/{client,run}.ts`, and
two evals files. This was the "Classic sweep mistake" from G7: producer
renamed, consumer missed.

**Rules:** when sweeping `fx` anywhere, the MCP/context wire identity is
part of the protect list (`clientInfo` name, `_meta.fx`, `fx-turn-context`,
fixture oracle checks). The fixture and the binary must always agree; if you
ever rename the wire identity, rename fixture and binary together and bump
the conformance baseline check in sync.

### G5 — Deep rename roadmap (partially done, wire surfaces still deferred)

Since the v0.0.7 release (2026-08-27):
- `install.sh` (repo root) installs the latest release into `~/.ax/bin` with
  sha256 verification; the README one-liner is
  `curl -fsSL https://raw.githubusercontent.com/doriangironde/ax/main/install.sh | sh`.
- GitHub Release assets are `ax-<platform>-<arch>.tar.gz` (macos arm64 is
  `ax-macos-arm64.tar.gz`, linux arm64 is `ax-linux-aarch64.tar.gz`).
- The release job no longer mirrors to the upstream CDN (no R2 credentials).

What remains deferred (compatibility surfaces):
### G5 — Deep rename roadmap (deliberately deferred)

User-facing rename is done. A full rename of the internal identity is a
separate, risky project. Order of operations if attempted:

1. **Config dir:** `~/.fx` → `~/.ax` (then migration: read old dir if new is
   absent; write new). Sites: every `io_mod.openOrCreateVerifiedPrivateDir(
   &root, ".fx")` + hardcoded `~/.fx` strings; ~15 files, grep
   `grep -rn "\.fx" src/ --include='*.zig'`.
2. **Env vars** `FX_*` → `AX_*`: config_runtime, test helpers
   (`tests/evals/eval-helpers.ts`, `tests/e2e/tmux-helpers.ts` are full of
   FX_-prefixed keys), README. Keep `AI_GATEWAY_API_KEY` (provider-owned).
3. **Session format:** do not touch `schema_version` or field names — old
   sessions must keep loading. `session_codec.zig` has `repair_legacy_*`
   functions as the pattern to follow for any compat shim.
4. **WASM/ACP:** `extern "fx"`, `fx-core.wasm`/`fx-term.wasm`, ACP `_meta`
   key are wire/ABI contracts — only rename with a coordinated SDK release.
5. **Provider attribution:** `originator=fx`, `x-grok-client-identifier=fx`
   headers are what OpenAI/xAI dashboards attribute usage to; renaming is
   cosmetic and safe, but keep `user-agent`/`http-referer` pointing at the
   upstream repo for provenance.
6. Update the fork-notes section of README.md.

**Verify:** full zig suite + cli e2e + a real session resume across the
migration (old `~/.fx` dir → new dir).

### G6 — Live evals need credentials

**Why:** `tests/evals/*` (30 files) drive real model calls via
`ax ask --json` and skip without `AI_GATEWAY_API_KEY`.

**Fix:** run with the key exported. Matrix: `cd tests/evals && bun run
eval:matrix`. Note `tests/evals/eval-helpers.ts` already points at
`zig-out/bin/ax`.

### G7 — Upstream sync + branding re-sweep procedure

**Why:** upstream moves fast; merging pulls old `fx` strings back in.

**Procedure:**
```bash
git fetch upstream
git merge upstream/main            # expect conflicts in strings
# Re-apply branding with the safe sweep (see below), then:
zig fmt --check src/ && zig build test
bun test tests/e2e/cli.test.ts     # plus any TUI file you touched
```

**Safe sweep pattern** — word-boundary perl with an explicit protect list.
This exact list was used twice without collateral damage (identifiers like
`fx_login`, `workspace_fx`, `FX_*` are protected by `\b`; fixture names and
URLs by the list):

```bash
# src/ only
grep -rln '\bfx\b' src/ --include='*.zig' | \
  xargs perl -i -pe 's/\bfx\b/ax/g unless /FX_|fx\.sh|\/tmp\/fx|~\/\.fx|\.fx\/|\.fx\b|fx-test|fx-onboarding|fx-codex-auth|fx-turn-context|fx-command|fx-background|fx-term|fx-core|fx-wasm|"fx"|fx-pgso|fx-trace|fx\.log|fx-old|fx-new/'

# tests/e2e + tests/evals
perl -i -pe 's/\bfx\b/ax/g unless /FX_|fx\.sh|\.fx\b|\.fx\/|\/tmp\/fx|fx-test|fx-tui|fx-command|fx-background|fx-login|referrer.*\bfx\b|originator.*\bfx\b|fx-welcome|fx-e2e|fx-trace|fx-turn-context|"fx"/' tests/e2e/*.test.ts

# glyphs and capital-Fx (word boundary does not catch these)
perl -i -pe 's/𝒇x/𝒂x/g' $(grep -rln '𝒇x' src/ tests/e2e/)
perl -i -pe 's/Fx needs access/ax needs access/g; s/Fx could not read/ax could not read/g' $(grep -rln 'Fx needs\|Fx could' src/ tests/)
```

**After sweeping, rebuild and run the killer tests** (these catch sweep
mistakes): `zig build test`, `bun test cli.test.ts`, `bun test
tui-slash-menu.test.ts`. The two classic sweep mistakes: replacing code
identifiers (compile errors, or worse, silently) and replacing fixtures the
producer still emits as `fx` (tests fail as expected-vs-actual mismatches).

**v0.0.6 sync notes (2026-08-26, merge `00e3f4f`).** Besides re-running the
sweep, re-applying G10 onto v0.0.6 required:
- Upstream replaced the `model`/`codex_model`/`grok_model` settings slots with
  a per-provider `models` map (`model_preferences.zig`). The fork's
  `custom_provider` settings key survives; the custom model preference now
  lives at `models.custom` and `putModelPreference` removes the legacy `model`
  key for `.custom` too.
- Upstream centralized provider routing in `core/gateway/provider_set.zig`
  (`Set.select`). The fork adds a `custom: Bundle = .{}` slot (empty bundle =
  unavailable stream, no reviewer) and fills it per selection from the live
  registry entry: `builtins.providers.customBundle(entry, catalog_context)`.
  `generation_usage_provider.Set` got the same `.custom` slot. AskContext gets
  a `providerSet()` accessor that injects the bundle; `App.providerSet()` does
  the same from `selectionCustomEntry()` (needs `*App`, not `*const`).
- The `/login` picker is now the setup hub (`.connections` stage holds the
  sign-in ways). The fork's custom/preset rows live in the `.provider` stage
  after the three built-ins; `openPickerWithActiveProvider` still marks the
  active row. The old TUI index-math tests were re-derived for the hub; the
  e2e custom-provider test navigates `/login` → **Model provider**.
- `stream_provider.Provider` lost `build_fn`; transports build the payload
  inside `stream_fn` from `ModelRequest.data()` and emit through `EventSink`.
  `openai_compatible.zig` was ported to that shape (auth header from
  `credential.secret`, `Admission.admit()`, `.completed`/`.failed` results,
  `types.ModelCompletion`). `originator=/referrer=` URL params on OAuth
  authorize links stay `fx` at the binary and in the PKCE tests.
- Sweep asymmetries hit in this sync (fix by keeping BOTH sides identical):
  escaped-quote wire strings (`\"name\":\"fx\"`) defeat the `"fx"` protect
  rule — restore MCP `clientInfo` name manually at the emission sites
  (mcp_runtime.zig x3, tool_subscription.zig) and `_meta.fx.continueRecovery`
  (acp/prompt.zig parse + test input, acp.test.ts). Split-string producers
  (`"/tmp", "fx-recordings"`) defeat `\/tmp\/fx` — the tape dir must stay
  `fx-recordings`/`fx-record-*` (G8). Markdown-fixture and git-parser tests
  assert `fx` literals while the sweep changed inputs — the fixture and the
  assertion must agree. The `SkillMenuSourceFilter` enum member `fx` is
  protected at the `.fx` uses but not at the bare `fx,` declaration — restore
  the declaration. A test variable named `fx` (acp/prompt.zig meta parse) was
  renamed by the sweep; identifier renames must be reverted.
Also remember the auto-review classifier's SHA-256 check:
`auto_classifier.zig` "automatic review policy matches the tested XML v1
artifact" — any change to the template text requires recomputing the digest
(the test computes actual; copy the new digest into `expected_digest`).

**Round 2 sync notes (2026-08-26, merge `982143c`, from upstream `main`
`b8ebe21`).** The fork tracked latest upstream main (85 commits: provider
usage ledger, inline skill picker, natural-language capability discovery,
streamlined sign-in UI, prompt-submit latency, e2e hardening). What it took:

- **The only merge conflict** was `tests/e2e/tui-slash-menu.test.ts`: upstream
  now renders the skills menu INLINE (main screen stays visible; no new
  alternate-buffer enter). Fork's alternate-buffer assertions were replaced by
  upstream's inline assertions with the `𝒂x` glyph.
- **Sweep:** the G7 commands, with the test glob extended to
  `tests/e2e/*.ts` (helpers like `tmux-helpers.ts`, `ui-observer.ts`,
  `conditional-guidance-oracle.ts`, `permission-mode-context.ts` need it).
  Content sweep (user-facing copy) is wanted this round: browser-capability
  text, "questions about ax" prompt line, doctor `ax session`, skills help
  "ax workspace roots", oracle regex "subagent inside ax".
- **Restores (this round's sweep misses, all fixed by hand):**
  MCP `clientInfo` `"fx"` at all four emission sites (escaped-quote wire
  strings defeat the `"fx"` protect — mcp_runtime.zig x3, tool_subscription);
  `_meta.fx.continueRecovery` (acp/prompt.zig parse + test input +
  acp.test.ts — the escaped-quote `\"ax\"` form defeated the restore regex,
  recheck with `grep 'ax.*continueRecovery'`); G4 `[fx]` label
  (skills_menu_presentation + tui-slash-menu:2537) and the `fx,` enum member;
  `fx-recordings`/`fx-record-*` tape dirs; `originator=fx`/`referrer=fx`
  OAuth URL params; `id=fx-grok-auth` hyperlink; test-local identifier and
  fixture renames (`fx` dir vars in native_session/store fixtures, tool_args
  JSON input, assistant_presentation test inputs, skill_search `fx-review`);
  `vercel-labs/fx` git-URL fixtures in context.zig; sdk
  `test-term-workspace.mjs` copy switched to `ax` (matches the binary's
  browser-capabilities text); the `fx.sh` line in context.zig shielded the
  adjacent "questions about fx" — fixed to "questions about ax" by hand.
- **API adaptations:** `UsageOutcome` lost `.immediate`; the custom transport
  now sets `.unavailable = .possibly_billed` (mirrors the codex billing
  fallback). `session_usage.exactUsageOrigin` gained
  `.custom => "exact/custom"`. `TestAuth`/`TestApp` gained stubs for the
  fork's key-entry surface (`customProviderKeyEntryActive`,
  `customKeyEntryProviderName`, `takeApiKeyBuffer`, `exitApiKeyStage`,
  `adoptCredential`, `openProviderPicker`, `openCustomProviderKeyPicker`,
  `stream`/`worker`/`workspace_root` fields, `selected_model` is now an
  `ArrayList` with deinit). `ApiKeyExitReason` (auth_runtime.zig) needed
  `pub`. SHA-256 digests recomputed in `auto_classifier.zig` and
  `builtins/tools.zig` after the sweep changed the hashed text.
- **release.yml:** upstream's signed+notarized macos-x86_64 job hardcodes
  Vercel's Apple identity and needs Apple secrets the fork does not have; it
  was replaced by the fork's previous unsigned cross-compiled matrix entry
  (`macos-x86_64` back in `build-linux`, `needs` updated to
  `[check-version, build-linux, build-macos-arm64]`).
  `scripts/sign-and-notarize-macos.sh` stays on disk, unused.
- **Verification (this machine, sandboxed shell):** `zig build test`
  8647/8654 pass, 3 skipped; the 4 failures + leak are the documented
  sandbox-environment set (PTY drains, Keychain `USER unset`, enableRawMode
  x2 — upstream added a second raw-mode test) plus the pre-existing `terminal
  start` leak; `zig fmt --check` clean; `cli.test.ts` 110/117 (2 Keychain
  fails); custom-provider e2e green via `scripts/local-mock-openai.py`
  (provider select, models list, plain + tool-call `ax ask` roundtrips).
  TUI suites still need tmux (sandbox fork denial) — CI is the gate.
- **Sequence note:** the first release prep (`prepare-v0.0.7`, PR #1, v0.0.7)
  was created from pre-sync `main` and is independent of this merge. When
  both are on `main`, the CHANGELOG fork section merges trivially; the sync
  bullet and the release markers live in different sections.
- **Sweep trap found by CI (2026-08-26, commit `27bc8bb`):** the `"fx"`
  protect rule shields every quoted `"fx"` token, including `join(REPO_ROOT,
  "zig-out", "bin", "fx")` binary paths in `mcp-stdio.test.ts` (13 sites the
  v0.0.6 sync had already fixed). After any merge, grep tests for
  `zig-out/bin/fx` and `bin", "fx"` — the TUI mcp tests fail with 21 s pane
  timeouts when they launch a nonexistent `fx` binary. Also re-check the MCP
  `clientInfo` sites with the ESCAPED pattern
  (`grep -n 'clientInfo' src/core/mcp/*.zig | grep 'ax'`) — a plain
  `grep '"name":"ax"'` misses `\"name\":\"ax\"`.
- **Round-2 CI battle log (2026-08-26, commit `e3256a5` green):** Full CI +
  ci.yml + Benchmarks + Binary Size are green on `sync-upstream`; the macOS
  arm64 PGSO candidate training lane still flakes with 21 s tmux pane
  timeouts under the fork's concurrent-load conditions (the same scenarios
  pass in the Full CI matrix), re-run it alone before a release. Fixes that
  landed along the way and their traps:
  - MCP `clientInfo` wire sites: the escaped-quote form `\"name\":\"ax\"`
    defeats both the `"fx"` protect rule AND plain greps — check with
    `grep clientInfo src/core/mcp/*.zig | grep ax`.
  - The `"fx"` protect rule shields every quoted `fx` token: `zig-out/bin/fx`
    (13 sites in mcp-stdio), the `fx` upgrade-fixture symlink and tarball
    member (fork extracts member `ax`), `fx-trace-*` trace filename filters
    (fork writes `ax-trace-*`), the `fx-render-bug` replay fixture names.
  - The upgrade e2e's tarball must pack the product member: the fixture now
    tars `ax` and the resumed PATH symlink is named `ax`.
  - The G4 label decision was REVERSED for good: `skillMenuFilterLabel(.fx)`
    returns upstream's lowercase `fx` again (the fork's capital `Fx` was
    tuned to the deleted alternate-screen picker; on the merged inline
    picker it produces a bogus single-result skills panel). Unit and TUI
    assertions were reverted to the upstream shapes; the fork's
    `ax · Global` scope labels stay. The fork's `tui-slash-menu` count
    expectations follow upstream's.
  - tmux harness: sessions keyed by non-default `base-index`/`pane-base-index`
    still resolve explicit indexes (the fork's G3 fix), but default-index
    servers use upstream's `name:0.0` targets without queries; stale
    `$TMUX_TMPDIR/tmux-<pid>` socket dirs are swept by connect-probing
    (pid checks are fooled by recycled pids); graceful-exit e2e sessions
    are isolated (`-L` sockets).
- **Upstream signing machinery is fork-removed (2026-08-26):** upstream's
  sign-and-notarize steps hardcode Vercel's Apple identity and need secrets
  the fork does not have; they were removed from `release.yml` (see the
  round-2 notes) and from `pgso-macos-arm64.yml` (`sign-stable-release` now
  only packages, and packages the candidate under the `ax` tarball member).
  `scripts/sign-and-notarize-macos.sh` and `scripts/tests/test_macos_signing.py`
  stay on disk, unused by any fork workflow (the python test asserts the
  upstream pipeline shape and is not wired into CI).
- **Next planned feature:** G10 v2 item 3 — live `/v1/models` catalog refresh
  for custom providers (`ax provider refresh <name>`); the local mock server
  will need a `/v1/models` endpoint for the e2e.

### G8 — Known residual `fx` strings (inventory, all intentional)

Run `grep -rn 'fx'` with the protect list above to get the live list. Known
categories: `/tmp/fx-trace-*.log` (debug trace path), `/tmp/fx-recordings`
(tape dir), `fx-old`/`fx-new` upgrade-test fixtures, `fx_login` enum tags
(serialized in `status --json` as `"fx_login"` — a schema value, keep),
"fx Vercel App" inside the `ax login` OAuth error string (factual upstream
app name), skill fixtures (`fx-test-strategy`), test display names, and the
G9 wire identity: MCP `clientInfo` name `fx` in `mcp_runtime.zig` +
`tool_subscription.zig`, `_meta.fx` continueRecovery, `<fx-turn-context>`
marker, and the `mcp-modern-stdio.mjs` oracle checks. The threat surface is
any future sweep touching those files.

## 4. Commands cheat sheet

```bash
export PATH="$HOME/zig:$PATH"
zig build                       # Debug binary at zig-out/bin/ax
zig build -Doptimize=ReleaseSafe
zig build test                  # full zig suite (~4 min)
zig fmt src/                    # format; zig fmt --check src/ before commit

cd tests/e2e && tmux kill-server
bun test cli.test.ts            # 112 fast CLI tests (~40 s)
bun test tui-startup.test.ts    # TUI, needs tmux (~12 s)
bun test tui-slash-menu.test.ts # fork regression gate (~90 s)
bun test tui-resize.test.ts     # slow (~2 min), 9 known env-fails

cd tests/evals && bun test      # needs AI_GATEWAY_API_KEY
```

Manual smoke of the built binary (AGENTS.md requires driving the change
before declaring done):

```bash
./zig-out/bin/ax --version      # 0.0.5
./zig-out/bin/ax help           # 𝒂x banner, usage: ax ...
./zig-out/bin/ax badcmd         # "ax: unknown subcommand"
./zig-out/bin/ax ask "..."      # needs credentials
```

## 5. Guardrails for the next agent

- Work on `main` for now (single-person fork) or feature branches + PRs
  against `doriangironde/ax`. Do not mark anything ready without running
  `./zig-out/bin/ax` for the changed path (AGENTS.md rule; the TUI suites do
  not cover startup crashes).
- Every `tests/e2e/*.test.ts` needs a classification in
  `scripts/pgso/corpus.json` only when full PGSO qualification is used —
  the fork inherits upstream's classifications; do not add new e2e files
  without updating the corpus.
- `zig fmt --check src/` before committing.
- Do not rename `Fx` (G4), do not touch the wasm/ACP/attribution surfaces
  (section 0) without a plan.
- The e2e `FX_*` env names in tests are helper protocol, not branding —
  `--record`, `FX_TEST_PRODUCT_EXE`, `FX_UI_OBSERVE_DIR` stay.
- When merging upstream, apply section G7, not ad hoc greps.