// Why: @kohaku-eth/privacy-pools' bundled output imports
// `maci-crypto/build/ts/hashing` (no `.js`). Node's strict ESM resolver
// rejects extension-less specifiers, so we patch only that one path.
import { existsSync } from "node:fs";
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
    if (err && err.code === "ERR_MODULE_NOT_FOUND") {
      const url = err.url;
      if (url) {
        const p = fileURLToPath(url);
        if (existsSync(p + ".js")) {
          return { url: pathToFileURL(p + ".js").href, format: "module", shortCircuit: true };
        }
      }
    }
    throw err;
  }
}
