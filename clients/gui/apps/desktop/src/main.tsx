import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

// Inside the desktop shell, `window.troupe` has to exist before anything asks
// `capabilities()` what this host can do — otherwise the first render decides the
// refresh token is going in `localStorage` and the sign-in screen says so. The import
// is dynamic and guarded, so a browser build never fetches the chunk.
async function start(): Promise<void> {
  if (typeof window !== "undefined" && "__TAURI_INTERNALS__" in window) {
    const { installShell } = await import("./shell-tauri");
    await installShell();
  }
  createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
}

void start();
