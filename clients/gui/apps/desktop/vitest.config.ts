import { defineConfig, mergeConfig } from "vitest/config";
import app from "./vite.config";

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
    },
  }),
);
