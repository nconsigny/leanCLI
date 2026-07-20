// Why we need a loader:
// - @kohaku-eth/privacy-pools' bundled output imports `maci-crypto/build/ts/hashing`
//   without a `.js` extension. Strict ESM rejects extension-less specifiers.
// - @kohaku-eth/railgun imports `"../pkg"` (a directory). Strict ESM
//   also rejects directory imports — the resolver doesn't auto-fall-back to
//   pkg/index.js the way CJS does.
// Both are patched here without touching package internals.
import { existsSync, statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (err) {
    if (err && err.code === "ERR_MODULE_NOT_FOUND" && /^[a-z@][\w\-@/.]*$/i.test(specifier)) {
      try {
        const withJs = await nextResolve(specifier + ".js", context);
        return withJs;
      } catch (_) { /* fallthrough */ }
    }
    if (err && (err.code === "ERR_MODULE_NOT_FOUND" || err.code === "ERR_UNSUPPORTED_DIR_IMPORT")) {
      const url = err.url;
      if (url) {
        const p = fileURLToPath(url);
        if (existsSync(p + ".js")) {
          return { url: pathToFileURL(p + ".js").href, format: "module", shortCircuit: true };
        }
        try {
          if (statSync(p).isDirectory()) {
            const idx = p.replace(/\/$/, "") + "/index.js";
            if (existsSync(idx)) {
              return { url: pathToFileURL(idx).href, format: "module", shortCircuit: true };
            }
          }
        } catch (_) { /* fallthrough */ }
      }
    }
    throw err;
  }
}
