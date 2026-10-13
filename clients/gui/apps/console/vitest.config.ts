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
    },
  }),
);
