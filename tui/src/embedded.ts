import { createContext } from "react";

/** True when a screen is being rendered *inside* the dashboard's main
 *  pane (an in-pane sub-flow / menu) rather than as a full-screen view.
 *
 *  The dashboard's main pane is only ~58% of the terminal width, so the
 *  space-hungry koi column (24 cols) that frames every full-screen flow
 *  would force the content to wrap or spill. Frame widgets (`KoiFrame`,
 *  and `Layout`/`RpcRunner` through it) read this flag and drop the koi
 *  column when embedded, so menus fit the pane instead of escaping it.
 *
 *  Defaults to `false` — every full-screen surface keeps the koi. Only
 *  the dashboard sets it `true`, once, around its main-pane content. */
export const EmbeddedContext = createContext(false);
