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

`ax login codex` and `ax login grok` select that provider and a model from its authenticated catalog. Inside ax, open `/setup` and choose **Switch provider** to move between Gateway, Codex, and Grok. `/model` lists the active provider's fetched models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Use `/logout codex` or `/logout grok` to remove that subscription session without affecting other providers; choosing it again from **Switch provider** starts sign-in.

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

Run `/feedback` to open the fx feedback form at `fx.sh/feedback` (upstream service). It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, ax copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `ax ask` for a single request:

```bash
ax ask "explain the changes in this repository"
```

ax starts in `auto` permission mode. Routine understood development actions run directly; unresolved sensitive actions receive one bounded automatic review. A blocked action may return an exact approval request that the agent can send to ax's real permission screen. Ordinary question text never grants permission. See the [fx permissions documentation](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow the existing Y/N approval prompt when stdin is a TTY. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

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

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `ax status` and `ax doctor` report an invalid trusted MCP profile without starting its servers.

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
- Upstream release machinery (`release.yml`, `pgso-macos-arm64.yml`) is
  rebrand-consistent: the release tarball ships the `ax` binary, and the PGSO
  pipeline tolerates the renamed product executable (control stage adopts the
  installed binary). `fx-pgso-*` runner-temp names remain as pipeline
  self-naming.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Upstream: [vercel-labs/fx](https://github.com/vercel-labs/fx).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
