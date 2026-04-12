# Tools

## Accessing the Codebase

You can run commands on the host machine via SSH. Use the `exec` tool to run:

```bash
ssh -i /home/openclaw/.ssh/id_ed25519 -o StrictHostKeyChecking=no ranjeet@host.docker.internal "<command>"
```

### Available Commands

| Command | Example |
|---------|---------|
| `service-status` | `ssh ... ranjeet@host.docker.internal "service-status"` |
| `git-status` | `ssh ... ranjeet@host.docker.internal "git-status"` |
| `git-pull` | `ssh ... ranjeet@host.docker.internal "git-pull"` |
| `run-tests` | `ssh ... ranjeet@host.docker.internal "run-tests"` |
| `run-claude <prompt>` | `ssh ... ranjeet@host.docker.internal "run-claude read the README and summarize"` |

### Quick Reference

For simple questions about the codebase, use `run-claude`:
```bash
ssh -i /home/openclaw/.ssh/id_ed25519 -o StrictHostKeyChecking=no ranjeet@host.docker.internal "run-claude give me a high level overview of this project"
```

For git status:
```bash
ssh -i /home/openclaw/.ssh/id_ed25519 -o StrictHostKeyChecking=no ranjeet@host.docker.internal "git-status"
```

### Important
- Always use the full SSH command shown above
- The workspace is configured in .env (currently: ai-travel-agent)
- `run-claude` delegates coding tasks to Claude Code on the host
- You have read/write access to the repo via these commands

## Slack

You are connected to Slack. You can:
- Read messages in channels you're invited to
- Respond to @mentions and conversations
- Send messages using the `message` tool
- React to messages

When someone asks about the project or codebase, use the SSH commands above
to get real information from the code, then respond in Slack with the answer.
