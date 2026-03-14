# Agent CLI Integration (OpenClaw, Codex, Scripts, etc.)

Use Agent Context as a local memory endpoint by calling its CLI.
This is suitable for OpenClaw and any other agent runner that can execute shell commands.

## One command agents should call

```bash
agent-context query "<question>" --json
```

Example:

```bash
agent-context query "what did I work on today?" --json
```

Agent command template:

```bash
agent-context query "$QUESTION" --json
```

## Expected output

Machine-readable JSON on stdout with keys:
- `answer`
- `key_points`
- `supporting_events`
- `insufficient_evidence`
- `sources.mem0_semantic_count`
- `sources.bm25_store_count`
- `time_scope`

Non-payload logs are written to stderr.

## Setup

Install Agent Context once:

```bash
./scripts/install.sh
```

Installer creates a global CLI symlink at:
- `~/.local/bin/agent-context`

If command is not found, add to PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Scope

- Same computer as Agent Context data: supported.
- Different computer: requires a separate remote endpoint (MCP/API).
