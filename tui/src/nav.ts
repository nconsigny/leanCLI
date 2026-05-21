import { createContext, useContext } from "react";

/**
 * Browser-style history nav for the screen stack. Plumbed via React
 * context so any widget (notably `widgets/Layout`'s top NavBar) can
 * read availability + trigger nav without prop-drilling through every
 * screen. App.tsx owns the stacks and supplies the implementation;
 * everyone else only consumes.
 */
export type NavApi = {
  canBack: boolean;
  canForward: boolean;
  back: () => void;
  forward: () => void;
};

const noop = () => {};

export const NavContext = createContext<NavApi>({
  canBack: false,
  canForward: false,
  back: noop,
  forward: noop,
});

export function useNav(): NavApi {
  return useContext(NavContext);
}
