import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// A plain web build. The same bundle is what a Tauri or Electron shell would load, so
// nothing here assumes Node APIs in the renderer.
//
// Where the bundle is served from. `/` in development and for a desktop shell, which
// owns its whole origin; a sub-path in a deployment that puts the GUI beside something
// else on one host. Being on the plane's own origin is worth a little config: same
// origin means no CORS allowlist to keep in step, and one fewer thing to get wrong.
// Normalised rather than taken literally, so `app`, `/app` and `/app/` all mean the
// same thing. A leading slash is what a POSIX shell on Windows rewrites into a drive
// path when it is passed to `docker build --build-arg`, and a bundle whose asset URLs
// begin `/Program Files/Git/app/` is a broken image that builds perfectly.
const raw = (process.env["TROUPE_GUI_BASE"] ?? "/").trim();
const base = raw === "" || raw === "/" ? "/" : `/${raw.replace(/^\/+|\/+$/g, "")}/`;

export default defineConfig({
  base,
  plugins: [react()],
  resolve: {
    alias: {
      // The client is resolved to its source, not its `dist`. Without this a change to
      // the protocol client only reaches the running app after a separate build, and
      // what you are looking at is quietly one build behind.
      "@troupe/client": fileURLToPath(new URL("../../packages/client/src/index.ts", import.meta.url)),
    },
  },
  server: { port: 5173, strictPort: true },
  build: { target: "es2022", sourcemap: true },
});
