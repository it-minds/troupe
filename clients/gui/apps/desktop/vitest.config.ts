import { defineConfig, mergeConfig } from "vitest/config";
import app from "./vite.config.ts";

// The app's tests run on the app's own Vite configuration — the same `@troupe/client`
// alias to source, the same `import.meta.env` — with jsdom for a page. The client's
// tests stay on Node's runner: they need no page, and nothing in them is Vite's.
export default mergeConfig(
  app,
  defineConfig({
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
