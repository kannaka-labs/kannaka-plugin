# kannaka-mcp

The Kannaka MCP server: a stdio MCP server, with zero dependencies, that drives the `kannaka` binary. It's the same server the [Kannaka Claude Code plugin](https://github.com/kannaka-labs/kannaka-plugin) runs, published on its own so any MCP client can use it.

| Tools | What they do |
|---|---|
| `kannaka_status` / `kannaka_recall` / `kannaka_remember` / `kannaka_dream` | HRM memory: metrics, search, store, consolidation |
| `swarm_status` / `swarm_send` / `swarm_tail` | NATS swarm: peers, messages, live constellation pulse |
| `compute_machines` / `compute_status` / `compute_events` / `compute_wake` / `compute_grant` | KAX Compute District: roster, events, Ed25519-signed wakes and credit grants |

## Requirements

- Node 20 or newer.
- The `kannaka` binary, in `~/.local/bin`, `~/.kannaka/bin`, on `PATH`, or at `KANNAKA_BIN`. Install it with the [Kannaka installer](https://github.com/kannaka-labs/kannaka-plugin#install).
- Authenticated swarm and KAX subjects need NATS credentials, from `NATS_USER`/`NATS_PASSWORD` or `~/.kannaka-nats.env` (override the path with `KANNAKA_NATS_ENV`).
- `compute_wake` and `compute_grant` sign with an operator key at `~/.kannaka/kax-operator.key` (`KAX_OPERATOR_KEY_FILE`).

## Use

Any MCP client that launches stdio servers:

```json
{ "mcpServers": { "kannaka": { "command": "npx", "args": ["-y", "kannaka-mcp"] } } }
```

DeepSeek Harness users can install [`dsh-plugin-kannaka`](https://github.com/flaukowski/dsh-plugin-kannaka), which depends on this package.

## Timeouts

Each HRM command has its own budget: status 150 s, recall 30 s, remember 60 s, dream 180 s, swarm status 30 s. Set `KANNAKA_MCP_TIMEOUT_MS` to override all of them. Give your MCP client a per-call timeout above these, because `kannaka status` takes 30-60 s on a store of about 1,300 memories.

If `kannaka_remember` times out, the memory may still have been stored. Check with `kannaka_recall` before retrying.

## License

Space Child License, Version 1.0. See [LICENSE](LICENSE).
