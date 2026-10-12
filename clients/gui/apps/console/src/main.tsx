import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { applyMode, storedMode } from "./theme";
import "./styles.css";

// The mode this person chose, on the document before the first paint, so nobody watches
// the console change colour under them at every load. index.html carries Afterglow.
applyMode(storedMode());

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
