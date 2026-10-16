import { defineConfig, mergeConfig } from "vitest/config";
import app from "./vite.config.ts";

// The console's tests run on its own Vite configuration, with jsdom for a page, against
// the fake plane in `packages/client/test/support` over a real HTTP socket.
export default mergeConfig(
  app,
  defineConfig({
    test: {
      environment: "jsdom",
      include: ["test/**/*.test.{ts,tsx}"],
      testTimeout: 30_000,
      // The nightly's flake hunt runs the files and the tests in each in an order of its
      // own every time (TROUPE_TEST_SHUFFLE=1), so a test that leans on another's
      // leftovers fails there rather than in somebody's pull request.
      sequence: { shuffle: process.env["TROUPE_TEST_SHUFFLE"] === "1" },
    },
  }),
);
