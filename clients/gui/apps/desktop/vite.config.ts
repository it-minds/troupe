import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// A plain web build. The same bundle is what a Tauri or Electron shell would load, so
// nothing here assumes Node APIs in the renderer.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, strictPort: true },
  build: { target: "es2022", sourcemap: true },
});
