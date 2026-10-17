import { readFileSync } from "node:fs";
import { defineConfig, mergeConfig } from "vitest/config";
import app from "./vite.config.ts";

// The app's tests run on the app's own Vite configuration — the same `@troupe/client`
// alias to source, the same `import.meta.env` — with jsdom for a page. The client's
// tests stay on Node's runner: they need no page, and nothing in them is Vite's.

// The version the app says it is, as `pnpm test` gives it, also where nothing set it: `vitest`
// run on its own, or through `pnpm exec`, left `npm_package_version` unset, the app said `dev`,
// and the tests that compare it with a plane's policy failed whatever the machine was doing.
const version =
  process.env["npm_package_version"] ?? (JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string }).version;

export default mergeConfig(
  app,
  defineConfig({
    define: { __TROUPE_VERSION__: JSON.stringify(version) },
    test: {
      environment: "jsdom",
      include: ["test/**/*.test.tsx"],
      testTimeout: 30_000,
      // The nightly's flake hunt runs the files and the tests in each in an order of its
      // own every time (TROUPE_TEST_SHUFFLE=1), so a test that leans on another's
      // leftovers fails there rather than in somebody's pull request.
      sequence: { shuffle: process.env["TROUPE_TEST_SHUFFLE"] === "1" },
    },
  }),
);
