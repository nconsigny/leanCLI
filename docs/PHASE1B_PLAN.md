# Phase 1b — Skills system + protocol knowledge

This plan covers `Agent/Skills.lean`, two new agent tools, the eleven
skill directories, packaging, and the smoke test. Read this together
with `docs/PHASE0_PLAN.md` (forbidden-import list, trust model) and
`docs/PHASE1A_PLAN.md` (persistent agent daemon wire shape).

## Pre-existing state and divergences from the spec

When the Phase 1b workstream began the codebase already had a working
skills system at a different layer:

* `LeanKohaku/Daemon/SkillsStore.lean` reads `skills/<verb>/SKILL.md`
  from the repo (action-oriented, verb-named: `send-native`,
  `approve-erc20`, `swap-uniswap-v3`, etc.). It is exposed to outside
  callers via the daemon RPCs `skills.list` and `skills.get` in
  `LeanKohaku/Daemon/Server.lean`.
* Frontmatter fields in that system are `name / description /
  category / risk`, plus a `requires.daemonRpcs` body convention.
* Loading is on-demand by RPC, not by trigger-keyword.

Phase 1b adds a parallel **agent-side** skills layer rather than
mutating the daemon's action-skill API. The two live side by side:

| Layer       | Owner                              | Trigger      | Surface                  |
|-------------|------------------------------------|--------------|--------------------------|
| Action skill| `LeanKohaku/Daemon/SkillsStore`    | RPC call     | TUI / daemon callers     |
| Protocol/meta skill | `LeanKohaku/Agent/Skills` | LLM context  | `kohaku-agentd` system prompt |

Concrete divergences from the original Phase 1b spec, all kept here so
nothing is silently inherited:

1. **Directory location**. Spec said "repo-root `skills/`". The repo
   already uses `skills/` for action-skills. Protocol and meta skills
   live at the *same* root (flat layout: `skills/<protocol>/...`,
   `skills/<meta>/...`). Daemon `skills.list` will start surfacing
   them too; their frontmatter is a superset of what the daemon parser
   needs (it ignores `triggers` / `alwaysOn` / `ofacFlagged`). The
   `category` field is added to the new skills with the value
   `protocol` or `meta` so the daemon's category-keyed grouping stays
   useful.
2. **Module path**. Spec said `LeanKohaku/Agent/Skills.lean`. Confirmed
   — we do *not* reuse `Daemon/SkillsStore.lean` from the agent layer
   because that would pull a Daemon import into the Agent tree and
   violate the import-graph gate.
3. **JSON module**. Spec said "project uses `Lean.Json`". The
   codebase uses `LeanKohaku.Encoding.Json`. Codebase wins.
4. **Skill renderer**. Spec asked for ~500–1500 tokens of compact
   rendering per skill. We approximate via character budget (≈ 4 chars
   per token) — the prompt is recomputed each turn anyway so token
   accounting is the LLM's job; the renderer just truncates `overview`
   to ~6 KiB and lists at most three function summaries inline.
5. **SIGHUP handler**. Lean 4 v4.29.1 does not expose POSIX signal
   APIs. `Agent/Skills.reload` is wired and callable, and the smoke
   test exercises it via a dedicated `reload` op on the daemon
   socket rather than an actual SIGHUP signal. Documented under
   `Acceptance criteria #8` how the manual test exercises it.
6. **Skill at `/mnt/skills/user/web3-security/`** is not present in
   this sandbox. We write the v1 `web3-security` skill from first
   principles per the spec's fallback.
7. **Action-skill `skills/swap-uniswap-v3/`** already exists and is
   verb-named; the new protocol-skill `skills/uniswap/` is additive,
   not a replacement. Both ship.

## Eleven skills, addresses, sources, and triggers

All addresses below are **checksummed (EIP-55)** in `contracts.json`.
Triggers in `SKILL.md` use lowercased forms for hex matching.

Chain IDs in scope: **1 = mainnet**, **11155111 = Sepolia**. No L2.

### Meta skills (real content; `alwaysOn: true`)

1. `kohaku-wallet` — wallet operating model: pre-sign pipeline,
   signer/path separation, ConfirmGate, nonce monotonicity. No
   addresses. Cross-references `INVARIANTS.md`.
2. `web3-security` — port. Source `/mnt/skills/user/web3-security/`
   not present in this sandbox; v1 written from first principles
   covering: key separation; fee/gas verification; signature
   semantics (EIP-191 vs EIP-712); EIP-712 risks (open-ended
   `permit`); approval anti-patterns (`unlimited`, sweep stalkers);
   address poisoning and zero-value transfers; phishing UX.

### Protocol skills

3. `uniswap` — **fully worked example**. Mainnet primary entrypoints:
   * `UniversalRouter` `0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD` (Uniswap deployment 2024-09 release)
   * `SwapRouter02` (V3) `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45`
   * `UniswapV2Router02` `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`
   * `Permit2` `0x000000000022D473030F116dDEE9F6B43aC78BA3` (ERC-7730
     descriptor already in `bridge/clearsign/registry/permit2.json` —
     reference, do not duplicate).

   Sepolia:
   * `UniversalRouter` `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b`
   * `SwapRouter02` `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`
   * `UniswapV2Router02` `0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3`

   Source: <https://docs.uniswap.org/contracts/v3/reference/deployments>
   and <https://docs.uniswap.org/contracts/v2/reference/smart-contracts/v2-deployments>.
   ABI provenance: fetched from official Uniswap GitHub
   (`Uniswap/v3-periphery`, `Uniswap/universal-router`, `Uniswap/v2-periphery`)
   where reachable; otherwise marked `TODO(curator):` with the source URL.

   Triggers: `uniswap`, `uni`, `swap`, `swapExactTokensForTokens`,
   `exactInputSingle`, plus the lowercased addresses above.

### Protocol skills (scaffold only — content is `TODO(curator):`)

4. `railgun` — Mainnet RAILGUN Smart Wallet 2.0 logic:
   `0x4d2A481a31D7d4F2937A20a309c4D71FdfD498B6` (RailgunLogic) and the
   proxy `0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9` per
   <https://docs.railgun.org/developer-guide/contract/contract-addresses>.
   Privacy plugin. Triggers: `railgun`, `0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9`,
   `0x4d2a481a31d7d4f2937a20a309c4d71fdfd498b6`.
5. `privacy-pool` — Privacy Pools v1 (0xbow): mainnet
   `Entrypoint` `0x6818809EefCe719E480a7526D76bD3e561526b46` plus
   per-asset pools. Sepolia: Entrypoint at
   `0x9D8D4cdfeD605293DC8826BC2D2A2c7Fb867Edd0` per the 0xbow
   deployment registry <https://docs.privacypools.com>. Triggers:
   `privacy pool`, `privacy-pool`, `privacypool`, addresses
   lowercased.
6. `tornado-cash` — **OFAC-sanctioned**, `ofacFlagged: true`. ETH
   pools on mainnet at:
   * `0.1 ETH` `0x12D66f87A04A9E220743712cE6d9bB1B5616B8Fc`
   * `1 ETH`   `0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936`
   * `10 ETH`  `0x910Cbd523D972eb0a6f4cAe4618aD62622b39DbF`
   * `100 ETH` `0xA160cdAB225685dA1d56aa342Ad8841c3b53f291`
   Source: <https://github.com/tornadocash/tornado-core>.
   Triggers: `tornado cash`, `tornado`, `mixer`, addresses lowercased.
7. `morpho` — Morpho Blue mainnet `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` plus
   MetaMorpho Factory `0xA9c3D3a366466Fa809d1Ae982Fb2c46E5fC41101`.
   Source: <https://docs.morpho.org/contracts/morpho-blue/addresses>.
   Triggers: `morpho`, `morpho blue`, `metamorpho`, addresses lowercased.
8. `fxusd` — fxUSD mainnet only. Treasury / `fxUSD` token at
   `0x085780639CC2cACd35E474e71f4d000e2405d8f6` per
   <https://docs.aladdin.club/fx-protocol/fx-protocol-overview>.
   Sepolia: `{}` with comment "no Sepolia deployment". Triggers:
   `fxusd`, `fx.aladdin`, `aladdin dao`, address lowercased.
9. `bold-liquity` — Liquity V2 mainnet only.
   `BoldToken` `0xb01dd87B29d187F3E3a4Bf6cdAebfb97F3D9aB98` per
   <https://github.com/liquity/bold/blob/main/README.md> deployment
   table. Sepolia: `{}` with comment "no Sepolia deployment".
   Triggers: `bold`, `liquity v2`, `liquity bold`, address lowercased.
10. `cowswap` — `GPv2Settlement` mainnet
    `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` (same address on
    Sepolia per the CoW docs). Source:
    <https://docs.cow.fi/cow-protocol/reference/contracts/core>.
    ERC-7730 order EIP-712 descriptor already exists at
    `bridge/clearsign/registry/eip712-cowswap-order.json`; reference
    it from `interactions.md` rather than duplicating semantics.
    Triggers: `cowswap`, `cow swap`, `cow protocol`, address
    lowercased.
11. `aave` — Aave V3 Pool mainnet
    `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`,
    PoolAddressesProvider `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e`.
    Sepolia Pool `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951`,
    PoolAddressesProvider `0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A`.
    Source: <https://aave.com/docs/resources/addresses>. Triggers:
    `aave`, `aave v3`, `aave pool`, addresses lowercased.

### ABI provenance and fetch policy

For each protocol the ABI lives under `skills/<name>/abi/<Contract>.json`
and is fetched from the **official GitHub repository** by preference
and **Etherscan** as a fallback. The exact source URL is documented at
the top of each ABI file as a JSON `_source` comment. If neither source
is reachable in the sandbox the file is created with a single
`TODO(curator):` line pointing at the official URL and the human
curator fills it in a follow-up PR. **No ABI entry is fabricated.**

Network-isolated sandbox detection: when the build host has no network
access, every `curl` returns an error; the scaffolder records an
empty-body `TODO(curator):` ABI rather than guessing. The Lean side does
not parse the ABI yet — it only ships the file — so an empty `abi`
file is a curation-debt marker, not a build failure.

## Module layout

```
LeanKohaku/Agent/Skills.lean          -- registry, frontmatter parse, triggers, renderer
LeanKohaku/Agent/ToolDefs/Protocols.lean
                                       -- protocol_lookup, protocol_function_lookup
LeanKohaku/Agent/Registry.lean         -- (already exists) add the two new tools
LeanKohaku/Agent/Prompt.lean           -- (modified) inject alwaysOn + trigger skills
LeanKohaku/Agent/Loop.lean             -- (modified) recompute active skills per call
LeanKohaku/App/AgentDaemonMain.lean    -- (modified) open registry at startup; add reload op
```

No new `lean_exe`. No new `extern_lib`. No new daemon RPCs (the
existing `skills.list` / `skills.get` already surface
action-skills; the agent-side protocol skills are consumed by the
agent at prompt-assembly time, not over the daemon socket).

## Smoke test

Add `tests/agent_phase1b_smoke.sh`:

A. Skill-registry unit pass — parse fixtures under
   `tests/fixtures/skills/`. Smoke checks the parser handles a
   valid skill, a skill missing `SKILL.md`, and one with malformed
   frontmatter.

B. agent-daemon ping (re-using `tests/agent_phase1a_smoke.sh`'s
   harness pattern). Verifies the binary still builds.

C. `protocol_lookup` over a temp socket — the existing daemon's
   `skills.list` already enumerates skill dirs, but the agent's new
   tool reads from the in-process Agent Skills registry. We exercise
   the tool by piping a synthesized turn through `run_turn` with
   trace logging, then grepping the agentd log for
   `[skills] active: kohaku-wallet,web3-security`.

D. Reload op via socket: edit a skill, send `{"op":"reload"}` to
   the socket, run another turn, verify the change is picked up.

E. OFAC factual surfacing: trigger the `tornado-cash` skill, grep
   the rendered system prompt for "OFAC" — the agent must not
   refuse, only surface the legal status.

## Acceptance gate

The 14 acceptance criteria in the spec become the test plan for
review. The grep gate runs as documented in step 11 of the deliverable
section.
