import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The console as a plain web build, on the same stack as the desktop app and sharing
// nothing of it but the protocol client and the design tokens.
//
// Where the bundle is served from: `/` in development, and its own path on the plane's
// host in a deployment, `/console/` unless the image was built otherwise. Baked in
// because Vite writes it into every asset URL, so the chart's `console.basePath` must
// match what the image was built with. Normalised as the desktop app's is, so `console`,
// `/console` and `/console/` all mean the same thing, and a POSIX shell on Windows that
// rewrites a leading slash into a drive path has nothing to rewrite.
const raw = (process.env["TROUPE_CONSOLE_BASE"] ?? "/").trim();
const base = raw === "" || raw === "/" ? "/" : `/${raw.replace(/^\/+|\/+$/g, "")}/`;

export default defineConfig({
  base,
  plugins: [react()],
  // The package's version, for the shell's footer. pnpm sets it for every script it runs.
  define: { __TROUPE_VERSION__: JSON.stringify(process.env["npm_package_version"] ?? "dev") },
  resolve: {
    alias: {
      // The client from its source, as the desktop app takes it, so a change to an admin
      // method reaches the running console without a separate build.
      "@troupe/client": fileURLToPath(new URL("../../packages/client/src/index.ts", import.meta.url)),
    },
  },
  // Beside the desktop app's 5173, so both can run at once against one fake plane.
  server: { port: 5174, strictPort: true },
  build: { target: "es2022", sourcemap: true },
});
