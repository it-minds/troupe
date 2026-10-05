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

The decisions. `docs/decisions/` holds one file per decision, its front matter first
(Decision 790). `on_files` reads every one's front matter, and `on_page_markdown` puts a
heading, a line of what the front matter says and the paths it governs on each decision's
page, and the index, newest first, where a log's README has `<!-- decisions:index -->`.
The index is made here, as the site is built, and is not a file in the repository: a
committed index would be the one file every pull request that decides something changes,
which is the conflict one file per decision is for.
"""

import logging
import posixpath
import re
from pathlib import Path

from mkdocs.structure.files import File
from mkdocs.utils import meta as front_matter

log = logging.getLogger("mkdocs.plugins.troupe")

BRANCH = "main"

# Recomputed by on_files on every build, so `mkdocs serve` sees a nav that changed.
_state = {"root": Path("."), "docs": "docs", "mirrored": set(), "repo_url": "", "decisions": {}}

# A decision's page, `decisions/<log>/<number>-<slug>.md`; the repository's log has no
# directory of its own.
_DECISION = re.compile(r"^decisions/(?:(?P<log>[^/]+)/)?(?P<number>\d{4,})-[^/]+\.md$")
_INDEX = "<!-- decisions:index -->"
_LOG_NAMES = {"": "Decision", "tui": "TUI decision", "daemon": "Daemon decision"}

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

    _state.update(
        root=root,
        docs=docs,
        mirrored=mirrored,
        repo_url=config.repo_url.rstrip("/"),
        decisions=_decisions(files),
    )
    return files


def on_page_markdown(markdown, *, page, config, files):
    src = page.file.src_uri
    here = src if src in _state["mirrored"] else f"{_state['docs']}/{src}"
    markdown = decision_page(markdown, src, page.meta, _state["decisions"])
    return rewrite(markdown, lambda target: _site_target(target, here, src, files))


def _decisions(files):
    """Every decision's front matter, by log ("" for the repository's), with its page."""
    found = {}
    for file in files:
        match = _DECISION.match(file.src_uri)
        if match and file.abs_src_path:
            _body, data = front_matter.get_data(Path(file.abs_src_path).read_text(encoding="utf-8"))
            log = match.group("log") or ""
            found.setdefault(log, []).append({**data, "page": posixpath.basename(file.src_uri)})
    return found


def decision_page(markdown, src, meta, decisions):
    """`markdown` for the page `src`, with what the decisions add to it.

    A decision's page gets its title as the heading, a line with its number, status, date
    and issue, a note naming what superseded it, and the paths it governs at the end. A
    log's README gets the index of that log in place of `<!-- decisions:index -->`.
    """
    match = _DECISION.match(src)
    if match:
        log = match.group("log") or ""
        return _decision(markdown, log, meta, decisions.get(log, []))

    index = re.match(r"^decisions/(?:(?P<log>[^/]+)/)?README\.md$", src)
    if index and _INDEX in markdown:
        return markdown.replace(_INDEX, _index(decisions.get(index.group("log") or "", [])))

    return markdown


def _decision(markdown, log, meta, same_log):
    number = meta.get("number")
    facts = [f"{_LOG_NAMES.get(log, log + ' decision')} {number}", str(meta.get("status", ""))]
    if meta.get("date"):
        facts.append(str(meta["date"]))
    if meta.get("issue"):
        facts.append(f"issue [#{meta['issue']}]({_state['repo_url']}/issues/{meta['issue']})")
    replaced = _numbered(meta.get("supersedes"), same_log)
    if replaced:
        facts.append(f"supersedes {replaced}")

    head = [f"# {meta.get('title', number)}", "", "*" + " · ".join(facts) + "*", ""]

    by = _numbered([d.get("number") for d in same_log if number in _list(d.get("supersedes"))], same_log)
    if str(meta.get("status", "")).startswith("superseded"):
        head += ['!!! warning "Superseded"', "", f"    Superseded{' by ' + by if by else ''}.", ""]
    elif by:
        head += ['!!! note "Superseded in part"', "", f"    In part by {by}.", ""]

    paths = ", ".join(f"`{path}`" for path in _list(meta.get("paths")))
    return "\n".join(head) + "\n" + markdown.strip("\n") + f"\n\n**Governs:** {paths}\n"


def _index(same_log):
    rows = ["| No. | Decision | Date |", "|---:|---|---|"]
    for decision in sorted(same_log, key=lambda d: d.get("number") or 0, reverse=True):
        title = str(decision.get("title", "")).replace("|", "\\|")
        if str(decision.get("status", "")).startswith("superseded"):
            title += " *(superseded)*"
        rows.append(f"| [{decision.get('number')}]({decision['page']}) | {title} | {decision.get('date', '')} |")
    return "\n".join(rows)


def _numbered(numbers, same_log):
    """`numbers` as links to their pages in the same log, where they have one."""
    pages = {d.get("number"): d["page"] for d in same_log}
    return ", ".join(f"[{n}]({pages[n]})" if n in pages else str(n) for n in _list(numbers))


def _list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


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
