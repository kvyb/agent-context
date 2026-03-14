# Claude Integration (Easy Setup)

This connects Claude Code to Agent Context on the same Mac.

After setup, Claude Code can use your Agent Context memory from any repository on that computer.

## One-Time Setup (60 seconds)

Run this once:

```bash
cd /Users/kvyb/Documents/Code/myapps/agent-context

mkdir -p ~/.local/bin
cp scripts/agent_context_query.sh ~/.local/bin/agent_context_query.sh
chmod +x ~/.local/bin/agent_context_query.sh

mkdir -p ~/.claude/skills/agent-context-memory
cat > ~/.claude/skills/agent-context-memory/SKILL.md <<'EOF'
---
name: agent-context-memory
description: Query local Agent Context memory (Mem0 + BM25) to answer what the user worked on, what changed, and what may be unfinished.
argument-hint: "<question>"
---

# Agent Context Memory

Run: ~/.local/bin/agent_context_query.sh "$ARGUMENTS"
EOF
```

## How To Use In Claude Code

In any repo, ask:

- `Use agent-context-memory: what did I work on today?`
- `Use agent-context-memory: what did I forget to finalize this week?`
- `Use agent-context-memory: summarize what changed in project X since yesterday`

## What Must Be Running

- Agent Context must be installed on this Mac.
- Agent Context should have data in `~/.agent-context`.
- Mem0 should be enabled in Agent Context settings for best semantic recall.

## Important Limitation

- Works on the same computer: yes.
- Works automatically from a different computer: no.

If Claude Code runs on another computer, you need a remote endpoint (MCP/API) to reach this Mac's Agent Context data.

## Quick Check

If you want to verify setup quickly, run:

```bash
~/.local/bin/agent_context_query.sh "what did I work on today?"
```

You should get JSON containing `answer`, `key_points`, and `supporting_events`.

## Troubleshooting

- No useful answer:
  - open Agent Context and confirm Mem0 is enabled.
  - confirm your OpenRouter/OpenAI-compatible key is set in Agent Context settings.
- Claude says skill not found:
  - check this file exists: `~/.claude/skills/agent-context-memory/SKILL.md`.
