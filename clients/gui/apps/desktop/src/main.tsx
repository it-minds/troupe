import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { applyAppearance, storedMode, storedTheme } from "./theme";
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
  // Before the first render, not during it: the ground a person chose is on the
  // document by the time anything is painted, so nobody watches the app change colour
  // underneath them at every launch. index.html carries the default until this runs.
  applyAppearance(storedTheme(), storedMode());

  createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
}

void start();
