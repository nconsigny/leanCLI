/**
 * TS mirrors of the daemon's JSON-RPC response shapes that the TUI consumes.
 * Keep these handwritten and minimal — only the fields the TUI actually
 * reads. The daemon is the source of truth; if a field is missing here it
 * just isn't displayed.
 */

export type SlotKind = "eoa" | "tpm";

export type EoaListEntry = {
  name: string;
  address: string;
  unlocked?: boolean;
  derivationPath?: string;
};

export type TpmListEntry = {
  name: string;
  address: string;
};

export type ChainBalance = {
  /** Hex-encoded wei, e.g. "0x16345785d8a0000". */
  balance: string;
  /** Chain name the balance was fetched on; daemon echoes it back. */
  chain?: string;
};

export type Wallet = {
  kind: SlotKind;
  name: string;
  address: string;
  /** wei as bigint, undefined while loading. */
  balanceWei?: bigint;
  /** Chain the balance was fetched on — used by the wallet list to render
   *  e.g. `0.05 ETH (sepolia)` so EOAs (mainnet) and TPMs (sepolia) don't
   *  look like they share one number. */
  balanceChain?: string;
  /** present for EOAs; absent for TPM. */
  unlocked?: boolean;
  /** Slot-local account index. Undefined or 0 = primary account; >0 =
   *  sub-account derived via `eoa.account.add` (BIP-32 hardened branch).
   *  Daemon RPCs that take an `account` parameter use this. */
  accountIndex?: number;
  /** Optional human label for sub-accounts (set at creation time). */
  accountLabel?: string;
  /** Derivation path for sub-accounts. */
  accountPath?: string;
};
