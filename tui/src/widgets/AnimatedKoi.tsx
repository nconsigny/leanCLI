import React, { useEffect, useState } from "react";
import { useInput } from "ink";
import KohakuKoi, { type KohakuKoiProps } from "./KohakuKoi.js";

/** Light reaction animation: when the user presses an arrow key, the
 *  koi's eye lights golden-amber for ~180ms then reverts to its baked
 *  navy. The koi-red markings stay untouched.
 *
 *  We piggyback on Ink's broadcast `useInput` — the hook fires for every
 *  consumer, so the surrounding `Select` (or whatever owns navigation)
 *  still receives the keystroke unchanged. */
const FLASH_MS = 180;
const AMBER = "#ffb000";

export default function AnimatedKoi(props: KohakuKoiProps) {
  const [active, setActive] = useState(false);

  useInput((_, key) => {
    if (key.leftArrow || key.rightArrow || key.upArrow || key.downArrow) {
      setActive(true);
    }
  });

  useEffect(() => {
    if (!active) return;
    const t = setTimeout(() => setActive(false), FLASH_MS);
    return () => clearTimeout(t);
  }, [active]);

  return <KohakuKoi {...props} eyeColor={active ? AMBER : undefined} />;
}
