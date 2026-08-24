# ax fork — handoff, known gaps, and how to work on them

This file hands the repo to a fresh agent (or a future session) with no memory
of this fork's history. Read it top to bottom before touching code.

## 0. Repo state (read this first)

- Fork of [`vercel-labs/fx`](https://github.com/vercel-labs/fx) at commit
  `04e0ae0` (v0.0.5), renamed to **ax**.
- `origin` = `https://github.com/doriangironde/ax.git`, `upstream` =
  `https://github.com/vercel-labs/fx.git`.
- Fork commits:
  - `0da89d9` — rebrand: user-facing identity + binary rename `fx` → `ax`.
  - `cbc8db6` — skills-menu filter-label collision fix + TUI/e2e expectation
    alignment.
- Working tree is clean. All subsequent work starts from here.
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
  `https://github.com/vercel-labs/fx`.
- Skills-menu filter label `"Fx"` (see gap G4 — do not "fix" the spelling).
- `fx.sh` documentation URLs (upstream docs serve the same feature set).

## 1. Environment setup (one-time)

```bash
# Zig 0.16.0 (matches CI pin) lives at ~/zig
export PATH="$HOME/zig:$PATH"        # add to shell rc
zig version                            # expect 0.16.0

# TUI tests need tmux (3.7c installed via brew on this machine)
tmux -V

# e2e deps
cd tests/e2e && bun install
cd ../evals && bun install            # only if running live evals
```

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
| Zig unit | `zig build test` | 8442/8444, 2 skipped; 1 fail = pre-existing leak (below) |
| CLI e2e | `bun test cli.test.ts` | 112/112 |
| e2e non-TUI | `bun test config-persistence.test.ts prompt-history.test.ts` | pass |
| ACP + gateway | `bun test acp.test.ts ./gateway-stream-lifecycle.test.ts ./tmux-helpers.test.ts` | pass (last verified 298/0 across these + cli + persistence) |
| MCP e2e | `bun test ./mcp-stdio.test.ts ./mcp-http.test.ts ./mcp-legacy-remote.test.ts ./mcp-auth.test.ts ./session-recovery.test.ts` | 208/208 |
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

**Status (2026-08-23): largely done.** The push matrix on `main`
(`ci.yml` + `Benchmarks` + `Release`) is green on the current commit; the
four-runner `full-ci.yml` matrix was verified on a `ci-verify` test branch
(see below) and passes. What was fixed along the way:

- `mcp_runtime`/`tool_subscription` wire identity + test/fixture alignment
  (G9) — this was the bulk of the E2E failures.
- SDK tests (`𝒇x` glyph, `Signed out of fx.`) and `ci.yml`
  `--test-name-pattern "fx ask …"` filter.
- `release.yml` packaged the `ax` binary under the `fx` tar member, failing
  the Package step on every push; PGSO control stage now adopts the
  product-named executable (`scripts/pgso/pipeline.py` `build_control`).
- `ci-shards`/tmux harness window/pane index resolution (G3).

Remaining known items:
1. Repo settings → Actions enabled already (runs execute).
2. PGSO self-named runner-temp paths (`fx-pgso-*`, `control/bin/fx` upload
   paths in `pgso-macos-arm64.yml`, `scripts/pgso/README.md` prose) are
   deliberate pipeline self-naming — the control path now exists thanks to
   the `build_control` shim; leave the names.
3. The `Release` workflow runs the full PGSO qualification on every push
   because the fork has no release tags (`check-version` reports needed).
   That is heavy; either accept it or tag 0.0.5 once a release is wanted.
4. Decide later whether the fork keeps the PGSO/binary-size/bench gates
   (they enforce upstream's 7.8 MiB ceiling and 2 ms startup budget; both
   still apply to ax and should be kept).

**Verify:** full-ci green on all runners for the exact commit (see the
branch-run record below).

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
Also remember the auto-review classifier's SHA-256 check:
`auto_classifier.zig` "automatic review policy matches the tested XML v1
artifact" — any change to the template text requires recomputing the digest
(the test computes actual; copy the new digest into `expected_digest`).

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