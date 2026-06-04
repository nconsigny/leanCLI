# leanCLI TUI

Interactive terminal UI for the leanCLI wallet daemon, built with
[Ink](https://github.com/vadimdemedes/ink) (React-for-the-terminal).

## Trust boundary

The TUI is a **second JSON-RPC client** of the same daemon the CLI talks
to. It holds **no secrets**: every passphrase, biometric, or signing
operation continues to happen inside the daemon path. The TUI's role is
limited to:

1. Listing wallets and balances by calling daemon RPCs.
2. Letting the user navigate with arrow keys.
3. Rendering the equivalent `leancli` CLI command for the chosen action and
   exiting — the user runs that command in their shell, and prompts (EOA
   passphrase, fingerprint) happen there exactly as they do today.

This keeps a single trust boundary (the daemon) and avoids forking wallet
flow logic into TypeScript.

## Build

```bash
cd tui
npm install
npm run build      # → dist/index.mjs (single bundled file, ~MB)
```

## Run

```bash
node dist/index.mjs
# or after install:
leancli tui
```

## Develop

```bash
npm run dev        # tsx, no bundle step
npm run typecheck
```
