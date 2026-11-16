// The grammars a code frame is highlighted from (issue #659): highlight.js's, through
// lowlight, which hands back a tree rather than HTML, so a highlighted line is drawn as
// elements like the rest of a reply and nothing reaches `innerHTML`. This module is
// loaded the first time a frame asks for it (`highlight.ts`), never on first paint.
//
// The set is what a coding agent writes: TypeScript (and TSX), JavaScript, Python,
// Elixir, Rust, Go, JSON, YAML, shell, SQL, HTML, CSS, Markdown, diffs, TOML and
// Dockerfiles. A fence in any other language is drawn as it was written.

import { createLowlight } from "lowlight";
import bash from "highlight.js/lib/languages/bash";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import elixir from "highlight.js/lib/languages/elixir";
import go from "highlight.js/lib/languages/go";
import ini from "highlight.js/lib/languages/ini";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import markdown from "highlight.js/lib/languages/markdown";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import shell from "highlight.js/lib/languages/shell";
import sql from "highlight.js/lib/languages/sql";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import type { Lines, Segment } from "./highlight";

const lowlight = createLowlight({ bash, css, diff, dockerfile, elixir, go, ini, javascript, json, markdown, python, rust, shell, sql, typescript, xml, yaml });

// Names a fence uses that the grammars do not list among their own.
const ALIASES: Record<string, string> = { exs: "elixir", ex: "elixir", toml: "ini", jsonl: "json", console: "shell" };

/** The grammar a fence's first word names, or null when there is none for it. */
export function grammarOf(word: string): string | null {
  const name = word.toLowerCase();
  const known = ALIASES[name] ?? name;
  return lowlight.registered(known) ? known : null;
}

type Tree = ReturnType<typeof lowlight.highlight>;
type Node = Tree["children"][number];

/**
 * `code` highlighted in `language`, as lines of segments: a segment is a run of text and
 * the kind of token it is (`keyword`, `string`, `title function_`, …), the innermost the
 * grammar gave it. A token that spans lines (a block comment, a long string) is split at
 * each line's end, so a frame can cut its body by lines. Null when the language is not
 * one of the set.
 */
export function highlight(code: string, language: string): Lines | null {
  const name = grammarOf(language);
  if (!name) return null;
  const tree = lowlight.highlight(name, code);
  const lines: Lines = [[]];
  const put = (text: string, kind: string | undefined): void => {
    text.split("\n").forEach((part, i) => {
      if (i > 0) lines.push([]);
      if (part === "") return;
      const segment: Segment = kind ? { text: part, kind } : { text: part };
      lines[lines.length - 1]!.push(segment);
    });
  };
  const walk = (node: Node, kind: string | undefined): void => {
    if (node.type === "text") return put(node.value, kind);
    if (node.type !== "element") return;
    const classes = node.properties["className"];
    const own = Array.isArray(classes) ? classes.map((c) => String(c).replace(/^hljs-/, "")).join(" ") : "";
    for (const child of node.children) walk(child, own || kind);
  };
  for (const node of tree.children) walk(node, undefined);
  return lines;
}
