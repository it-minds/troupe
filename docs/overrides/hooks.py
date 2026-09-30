"""What the documentation site adds to MkDocs, as hooks (`hooks:` in mkdocs.yml).

The version. `VERSION` at the repository root is the one version of everything released
(Decision 668). `on_config` reads it into `extra.troupe_version`, which the banner in
`main.html` shows, so the site says which release it describes and nobody keeps a copy.

The repository's other documents. MkDocs builds one directory, `docs/`, and some of what
a reader needs lives elsewhere because something reads it there: `PROTOCOL.md` (the
TUI's tests), the daemon's and the TUI's READMEs (the core's config tests),
`CONTRIBUTING.md` and `SECURITY.md` (GitHub). So a nav entry that names no file in
`docs/` names one by its path from the repository root, and `on_files` puts that file on
the site at the same path. Nothing is copied into `docs/` and nothing is generated into
the repository.

The links. Every link is written for GitHub, relative to the file it is in, and
`scripts/doc-links.exs` checks that its target exists. `on_page_markdown` rewrites each
one whose target is not where the site has it: a page that leaves `docs/` for another on
the site, to that page; any link to a file or directory the site does not carry (the
code, the chart, `LICENSE`), to it on GitHub at `main`. A link to something that is not
in the repository at all is a warning, which `strict: true` makes a failed build, as
MkDocs does for a broken link between two pages of `docs/`.
"""

import logging
import posixpath
import re
from pathlib import Path

from mkdocs.structure.files import File

log = logging.getLogger("mkdocs.plugins.troupe")

BRANCH = "main"

# Recomputed by on_files on every build, so `mkdocs serve` sees a nav that changed.
_state = {"root": Path("."), "docs": "docs", "mirrored": set(), "repo_url": ""}

_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
_FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
_CODE_SPAN = re.compile(r"(`+).*?\1")
_INLINE = re.compile(r"(\]\(\s*)(<[^>]*>|[^)\s]+)((?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\))")
_DEFINITION = re.compile(r"^( {0,3}\[[^\]]+\]:\s*)(<[^>]*>|\S+)")


def on_config(config):
    root = Path(config.config_file_path).resolve().parent
    config.extra["troupe_version"] = (root / "VERSION").read_text(encoding="utf-8").strip()
    return config


def on_files(files, *, config):
    root = Path(config.config_file_path).resolve().parent
    docs = Path(config.docs_dir).resolve().relative_to(root).as_posix()
    mirrored = set()

    for path in _nav_paths(config.nav):
        source = root / path
        if files.get_file_from_path(path) is None and source.is_file():
            files.append(File.generated(config, path, abs_src_path=str(source)))
            mirrored.add(path)

    _state.update(root=root, docs=docs, mirrored=mirrored, repo_url=config.repo_url.rstrip("/"))
    return files


def on_page_markdown(markdown, *, page, config, files):
    src = page.file.src_uri
    here = src if src in _state["mirrored"] else f"{_state['docs']}/{src}"
    return rewrite(markdown, lambda target: _site_target(target, here, src, files))


def rewrite(markdown, target_for):
    """Every link target in `markdown` outside code, passed through `target_for`.

    `target_for` returns the new target, or None to keep the old one. Fenced code and code
    spans are left alone, as `scripts/doc-links.exs` leaves them unchecked.
    """
    lines = markdown.split("\n")
    fence = None

    for n, line in enumerate(lines):
        marker = _FENCE.match(line)

        if fence is None and marker:
            fence = marker.group(1)
        elif fence is not None:
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence):
                fence = None
        else:
            lines[n] = _rewrite_line(line, target_for)

    return "\n".join(lines)


def _rewrite_line(line, target_for):
    def swap(match):
        target = match.group(2)
        bracketed = target.startswith("<") and target.endswith(">")
        new = target_for(target[1:-1] if bracketed else target)
        if new is None:
            return match.group(0)
        return match.group(1) + (f"<{new}>" if bracketed else new) + match.group(3)

    definition = _DEFINITION.match(line)
    if definition:
        return _DEFINITION.sub(swap, line, count=1)

    out, pos = [], 0
    for span in _CODE_SPAN.finditer(line):
        out.append(_INLINE.sub(swap, line[pos : span.start()]))
        out.append(span.group(0))
        pos = span.end()
    out.append(_INLINE.sub(swap, line[pos:]))
    return "".join(out)


def _site_target(target, here, src, files):
    """Where `target`, written in the repository file `here`, is for the site page `src`."""
    if _SCHEME.match(target) or target.startswith("#"):
        return None

    path, suffix = _split(target)
    if path == "":
        return None

    base = "" if path.startswith("/") else posixpath.dirname(here)
    resolved = _normalise(posixpath.join(base, path.lstrip("/")))
    if resolved is None:
        log.warning("%s links to %s, which is outside the repository", here, target)
        return None

    on_site = _on_site(resolved, files)
    source = _state["root"] / resolved

    if on_site is None and not source.exists():
        log.warning("%s links to %s, which is not in the repository", here, target)
        return None

    if on_site is not None:
        new = posixpath.relpath(on_site, posixpath.dirname(src) or ".")
        # A link between two pages of docs/ is MkDocs' to resolve and check, unchanged.
        if new == path and src not in _state["mirrored"] and resolved.startswith(_state["docs"] + "/"):
            return None
        return new + suffix

    if resolved == ".":
        return _state["repo_url"] + suffix

    kind = "tree" if source.is_dir() else "blob"
    return f"{_state['repo_url']}/{kind}/{BRANCH}/{resolved}{suffix}"


def _on_site(resolved, files):
    """The site path of the repository path `resolved`, or None if the site lacks it.

    A directory is on the site when its README.md or index.md is.
    """
    docs = _state["docs"] + "/"

    for candidate in (resolved, f"{resolved}/README.md", f"{resolved}/index.md"):
        if candidate in _state["mirrored"]:
            return candidate
        if candidate.startswith(docs):
            inside = candidate[len(docs) :]
            found = files.get_file_from_path(inside)
            if found is not None and inside not in _state["mirrored"] and not found.inclusion.is_excluded():
                return inside

    return None


def _split(target):
    for i, char in enumerate(target):
        if char in "#?":
            return target[:i], target[i:]
    return target, ""


def _normalise(path):
    parts = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return "/".join(parts) if parts else "."


def _nav_paths(nav):
    for item in nav or []:
        values = item.values() if isinstance(item, dict) else [item]
        for value in values:
            if isinstance(value, list):
                yield from _nav_paths(value)
            elif isinstance(value, str) and not _SCHEME.match(value):
                yield value
