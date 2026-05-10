import fs from "node:fs";
import path from "node:path";
import os from "node:os";

/**
 * TUI-local "archive" store. Lets the user hide a wallet (or one of its
 * derived sub-accounts) from the WalletsHub list without deleting it
 * daemon-side — the slot is intact, the keystore is untouched, only the
 * UI filters it out by default. Archive state lives in
 * `$XDG_STATE_HOME/leankohaku/tui-archive.json` (falling back to
 * `~/.local/state/leankohaku/...`); it's plain JSON so users can edit
 * by hand if they need to. We never block the UX on read/write errors —
 * a corrupted file just silently empties the archive set.
 */

const STATE_DIR = (() => {
  const xdg = process.env.XDG_STATE_HOME;
  if (xdg && xdg.length > 0) return path.join(xdg, "leankohaku");
  return path.join(os.homedir(), ".local", "state", "leankohaku");
})();

const FILE = path.join(STATE_DIR, "tui-archive.json");

/** Compound key used by both the archive set and the WalletsHub balance
 *  map. Always include the account index so primaries and sub-accounts
 *  archive independently. */
export function archiveKey(
  kind: string,
  name: string,
  accountIndex?: number,
): string {
  return `${kind}:${name}:${accountIndex ?? 0}`;
}

export function readArchive(): Set<string> {
  try {
    const raw = fs.readFileSync(FILE, "utf8");
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return new Set();
    const arr = (parsed as { archived?: unknown }).archived;
    if (!Array.isArray(arr)) return new Set();
    return new Set(arr.filter((k): k is string => typeof k === "string"));
  } catch {
    return new Set();
  }
}

export function writeArchive(set: Set<string>): void {
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(
      FILE,
      JSON.stringify({ archived: Array.from(set).sort() }, null, 2),
    );
  } catch {
    // best-effort persistence; intentionally no fallback path
  }
}

export function toggleArchive(key: string): Set<string> {
  const set = readArchive();
  if (set.has(key)) set.delete(key);
  else set.add(key);
  writeArchive(set);
  return set;
}
