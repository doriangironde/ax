```
⠀⠀⠀⠀⠀⠀⢠⣿⣧⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⣾⡟⣿⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⣸⡿⠀⢻⣧⠀⠀⠀⠀⠀⠀⣴⣶⣶⠆
⠀⠀⠀⠀⢠⣿⠃⠀⠘⣿⡜⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
⠀⠀⠀⠀⣾⡏⠀⠀⠀⢻⣧⠀⠻⣿⣿⣿⠟⠀⠀⠀
⠀⠀⠀⣸⡿⠀⠀⠀⠀⠘⣿⣤⣦⠘⢿⣿⣷⡀⠀⠀
⠀⠀⢠⣿⠿⠿⠿⠿⠿⠇⣻⣿⣿⠗⠀⠻⣿⣿⣄⠀
⠀⠀⣾⡏⠀⠀⠀⠀⠀⠾⠿⣿⡏⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
⠀⣸⡿⠀⠀⠀⠀⠀⠀⠀⠀⢻⣧⠀⠀⠀⠀⠀⠀⠀
⢠⣿⠃⠀⠀⠀⠀⠀⠀⠀⠀⠘⣿⡄⠀⠀⠀⠀⠀⠀
```

ax is a fork of [fx](https://github.com/vercel-labs/fx), a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and compact native binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Install ax

One line, no dependencies beyond curl and tar:

```bash
curl -fsSL https://raw.githubusercontent.com/doriangironde/ax/main/install.sh | sh
```

The installer detects your platform, downloads the latest release from the
GitHub Releases page, verifies its sha256 checksum, installs the `ax` binary
into `~/.ax/bin`, and adds it to your PATH. Pin a version with `AX_VERSION`
(for example `AX_VERSION=v0.0.7`) or choose an install directory with
`AX_INSTALL_DIR`.

## Run ax

Sign in with Vercel AI Gateway:

```bash
ax login
```

Or use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
ax login codex
ax
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
ax login grok
ax
```

`ax login codex` and `ax login grok` select that provider and a model from its authenticated catalog. Inside ax, open `/setup` and choose **Model provider** to move between Gateway, Codex, and Grok. `/model` lists the active provider's fetched models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Use `/logout codex` or `/logout grok` to remove that subscription session without affecting other providers; choosing it again from **Model provider** starts sign-in.

The OpenAI Codex route uses ChatGPT subscription access directly and never sends its OAuth token to Vercel AI Gateway. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

To use an AI Gateway API key instead:

```bash
ax setup
```

Run ax from a project:

```bash
cd your_project
ax
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands.

### Custom providers

ax can run against any OpenAI-compatible endpoint. Register providers in `~/.fx/providers.json`:

```json
{
  "providers": [
    {
      "name": "opencode-go",
      "base_url": "https://opencode.ai/zen/go/v1",
      "api_key_env": "OPENCODE_GO_API_KEY",
      "api_type": "openai-completions",
      "models": [
        {
          "id": "glm-4.6",
          "context_window": 200000,
          "reasoning": true,
          "vision": true,
          "max_output_tokens": 32768
        }
      ]
    }
  ]
}
```

`base_url` is the API root; ax requests `<base_url>/chat/completions`. Keys resolve from `api_key_env` (recommended) or inline `api_key`. Each model entry may declare `context_window`, `max_output_tokens`, `reasoning`, `vision`, and `file_input`. Endpoints without a key or with no models cannot be selected.

Select a registered provider with `ax provider <name>` (for example `ax provider opencode-go`). Inside ax, run `/login`: the setup hub lists Connections, Model provider, Vercel team, and Credential source; **Model provider** opens the provider stage with the built-in routes followed by every registered custom provider and unregistered preset, so a direct pickup needs no extra step — choosing a preset registers it first, and a provider without a key asks for one inline. List its models with `ax models`, and switch back to the built-in providers with `ax provider gateway|codex|grok`.

### Built-in presets

ax ships a curated catalog of well-known OpenAI-compatible endpoints. A preset that is not yet registered is copied into `~/.fx/providers.json` on first use, so there is no JSON to hand-write:

```bash
ax provider openrouter        # registers openrouter, then asks for its key
ax provider deepseek          # registers deepseek
ax provider ollama            # keyless local server; selected directly
```

Run `ax provider` with no arguments to list the built-ins, registered custom providers, and available presets; `ax provider <preset>` registers and activates. Presets also appear in the `/login` **Model provider** stage (no description until picked, then join the registered list). Display names such as OpenCode Go, OpenRouter, or Ollama come from the catalog; registered names that are not presets keep their own identifier. Available presets: `opencode-go`, `openrouter`, `groq`, `deepseek`, `ollama`, `together`, `mistral`, `cerebras`, `xai`, `gemini`, `perplexity`, and `moonshot`.

Each preset registers a default `api_key_env` (for example `OPENROUTER_API_KEY`); export that variable or paste a key inline when prompted. Keyless presets such as `ollama` send no `Authorization` header at all. A registered preset is an ordinary entry in `providers.json` and stays editable there; presets are starting points, never hidden state.

When a selected custom provider has no usable key, ax asks for one inline: the picker opens a masked entry field, and Enter saves the key into `~/.fx/providers.json` (removing any configured `api_key_env` so the stored key is authoritative) and completes the switch. Custom providers never touch the AI Gateway: the key goes directly to your endpoint, Fast mode is unavailable, and sensitive actions surface the direct permission prompt instead of an automatic review.

This unlocks flat-rate subscriptions such as OpenCode Go, plus local and self-hosted servers (Ollama, vLLM, LM Studio) and aggregators (OpenRouter) that speak OpenAI Chat Completions.

Registered custom providers list their models from `providers.json`. To sync the list with the endpoint, run `ax provider refresh <name>`: ax fetches the provider's `/models` catalog, adds newly advertised models, keeps existing models (with their declared metadata), and removes models the endpoint no longer advertises — except the provider's currently selected model, which is kept so open sessions stay selectable. The saved selection always survives a refresh.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `ax sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
ax session resume last
ax session resume --id <id>
```

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. Renaming or resuming a session updates the tab, and exiting clears the ax-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the upstream feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, ax copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `ax ask` for a single request:

```bash
ax ask "explain the changes in this repository"
```

Foreground terminal commands run with an explicit finite deadline. ax uses durable terminal sessions for services, watchers, GUI applications, and other long-lived work, and keeps captured foreground output available through an opaque bounded-read handle for the active session or `--no-save` process.

ax starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow safety review based on the current user request and the exact pending action. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow configured approval prompts when stdin is a TTY. Automatic safety review never opens that prompt. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed ax

ax builds as a native binary or WebAssembly. Applications embedding ax can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `ax acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend ax

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Inside ax, `/mcp add <name> <command> [args...]` saves a local server and `/mcp add --transport http <name> <url>` saves a remote Streamable HTTP server. Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `ax status` and `ax doctor` report an invalid trusted MCP profile without starting its servers.

## Documentation

Read the upstream [fx documentation](https://fx.sh/docs). Behavior changed in this fork is documented in the [changelog](CHANGELOG.md).

## Build from source

Building ax requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/doriangironde/ax.git
cd ax
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ax
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Fork notes

- Product identity, welcome header, help text, and terminal title say `ax`; the binary is `ax`.
- `~/.fx` config dir, `FX_*` environment variables, session format, WASM exports, and ACP `_meta` keys keep the upstream fx names for compatibility. A future deep rename can move them.
- MCP/context wire identity stays `fx` by design: the `io.modelcontextprotocol/clientInfo` name, the `_meta.fx.continueRecovery` marker, and the `<fx-turn-context>` prompt section are asserted by the conformance fixtures, which reject any other value. Do not sweep them (see FORK_GAPS.md G9).
- Upstream release machinery (`release.yml`, `dev-release.yml`, `pgso-macos-arm64.yml`) is rebrand-consistent: the release tarballs and GitHub Release assets are `ax-<platform>-<arch>.tar.gz` with the `ax` binary inside, `install.sh` (the one-liner above) fetches them, and the PGSO pipeline tolerates the renamed product executable (control stage adopts the installed binary). `fx-pgso-*` runner-temp names remain as pipeline self-naming. The mirror upload to the upstream CDN is intentionally not attempted (the fork has no Vercel R2 credentials); GitHub Releases is the download source.
- CI status: the push `CI` and `Benchmarks` workflows are green on `main`, and the four-runner `Full CI` (native checks + 16 E2E shards) passes on the `ci-verify` branch. The `Release` lane runs the full PGSO qualification on every push until the fork gets its first release tag; `Dev Release` and `Publish libfx` no-op until a tag exists.
- Upstream tracking: the fork tracks upstream releases; v0.0.6 was merged as the current base (custom providers, presets, and the fork identity are re-applied on top). The `/login` picker follows the upstream setup-hub layout: Connections for sign-in ways, and the Model provider stage carries the built-in, custom, and preset routes.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Upstream: [vercel-labs/fx](https://github.com/vercel-labs/fx).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
