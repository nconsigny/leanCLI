/**
 * <KohakuKoi /> — render the Kohaku logo as half-block characters in any
 * Ink-based TUI. Each terminal cell encodes two stacked pixels via ▀/▄/█,
 * giving 2× vertical resolution at the typical 1:2 cell aspect ratio.
 *
 *   import KohakuKoi from "./widgets/KohakuKoi.js";
 *   <KohakuKoi size="medium" />
 *
 * No image-decoding deps — the cell grid is baked in (kohaku.cells.json).
 * Falls back to plain ASCII when `mono` is set, for terminals without
 * 24-bit color.
 */
import React from "react";
import { Box, Text } from "ink";
import cellsData from "./kohaku.cells.json" with { type: "json" };

type Cell = { ch: string; fg: string | null; bg: string | null };
type Grid = { width: number; height: number; rows: Cell[][] };
type Size = "medium" | "compact" | "tiny";

const GRIDS = cellsData as Record<Size, Grid>;

export interface KohakuKoiProps {
  /**
   * Render size:
   * - "medium"  : 60 cols × 30 rows (default)
   * - "compact" : 40 cols × 20 rows
   * - "tiny"    : 24 cols × 12 rows (denoised + eye preserved at this scale)
   */
  size?: Size;
  /** Render in monochrome ASCII (for terminals without truecolor). */
  mono?: boolean;
  /** Override the navy color used for outline + dark accents. */
  navy?: string;
  /** Override the red used for koi markings. */
  red?: string;
  /** Override the cream body color. */
  cream?: string;
  /** Override colour for the eye cell. When unset the eye uses the
   *  baked navy. Intended for transient highlight (e.g. AnimatedKoi
   *  flashing an amber eye on arrow input). The eye position is
   *  hardcoded per size — `tiny` is mapped today; other sizes silently
   *  ignore this prop. */
  eyeColor?: string;
}

/** Eye cell coordinates, per render size. The koi cells use half-block
 *  characters (`▀`/`▄`); each terminal cell encodes two stacked source
 *  pixels — fg paints one half, bg the other. The eyeball IS the navy
 *  pixel the artist painted on the cheek (it just happens to share the
 *  hex of the body outline that runs alongside it), so we override `bg`
 *  instead of `fg`: at (5, 5) the cell is `▀ fg=cream bg=navy` and the
 *  bottom-half navy pixel is the eyeball — recolouring `bg` lights
 *  exactly that one source pixel and leaves the cream cheek above
 *  untouched. Adjust here if the source grid is regenerated. */
const EYE_POS: Partial<Record<Size, ReadonlyArray<readonly [number, number]>>> = {
  tiny: [[5, 5] as const],
};

const BRAND = {
  "#0f2a3f": "navy",
  "#c92a2a": "red",
  "#f5efe0": "cream",
} as const;

function recolor(
  hex: string | null,
  overrides: { navy?: string; red?: string; cream?: string },
): string | undefined {
  if (!hex) return undefined;
  const lower = hex.toLowerCase() as keyof typeof BRAND;
  const slot = BRAND[lower];
  if (slot && overrides[slot]) return overrides[slot];
  return hex;
}

// Group consecutive cells with the same (fg, bg) into single <Text> runs.
// One <Text> per cell still works but produces a much larger React tree
// and slower diffs; a 60-wide row typically collapses to ~10 runs.
function compactRow(row: Cell[]): { fg?: string; bg?: string; text: string }[] {
  const runs: { fg?: string; bg?: string; text: string }[] = [];
  let cur: { fg?: string; bg?: string; text: string } | null = null;
  for (const c of row) {
    const fg = c.fg ?? undefined;
    const bg = c.bg ?? undefined;
    if (cur && cur.fg === fg && cur.bg === bg) cur.text += c.ch;
    else {
      cur = { fg, bg, text: c.ch };
      runs.push(cur);
    }
  }
  return runs;
}

const KohakuKoi: React.FC<KohakuKoiProps> = ({
  size = "medium",
  mono = false,
  navy,
  red,
  cream,
  eyeColor,
}) => {
  const grid = GRIDS[size];
  const overrides = { navy, red, cream };

  // Apply the eye-cell override before colour-run compaction so the eye
  // becomes its own run and gets the amber colour without breaking the
  // navy/red/cream palette logic. We override `bg` at the cell whose
  // bottom-half navy pixel IS the eyeball (`(5, 5)` on tiny: ▀ fg=cream
  // bg=navy → top cream cheek, bottom navy eyeball). No allocation when
  // eyeColor is unset.
  const eyePositions = eyeColor ? EYE_POS[size] : undefined;
  const renderRows: Cell[][] = eyePositions
    ? grid.rows.map((row, y) =>
        row.map((cell, x) =>
          eyePositions.some(([r, c]) => r === y && c === x)
            ? { ...cell, bg: eyeColor! }
            : cell,
        ),
      )
    : grid.rows;

  if (mono) {
    // Brightness-mapped ASCII: navy=#, red=*, cream=., bg=space.
    const lines: string[] = renderRows.map((row) =>
      row
        .map((c) => {
          if (!c.fg && !c.bg) return " ";
          const color = (c.fg ?? c.bg)?.toLowerCase();
          if (color === "#0f2a3f") return "#";
          if (color === "#c92a2a") return "*";
          return ".";
        })
        .join(""),
    );
    return (
      <Box flexDirection="column">
        {lines.map((l, i) => (
          <Text key={i}>{l}</Text>
        ))}
      </Box>
    );
  }

  return (
    <Box flexDirection="column">
      {renderRows.map((row, y) => (
        <Text key={y}>
          {compactRow(row).map((run, i) => (
            <Text
              key={i}
              color={recolor(run.fg ?? null, overrides)}
              backgroundColor={recolor(run.bg ?? null, overrides)}
            >
              {run.text}
            </Text>
          ))}
        </Text>
      ))}
    </Box>
  );
};

export default KohakuKoi;
