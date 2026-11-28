#!/usr/bin/env python3
"""Extract release notes for a version tag from CHANGELOG.md (with git log fallback).

Outputs:
  - Markdown file for GitHub Releases (--markdown-out)
  - HTML fragment (no DOCTYPE/body tags) for Sparkle's generate_appcast --embed-release-notes (--html-out)
"""

import argparse
import html
import re
import subprocess
import sys
from pathlib import Path


def extract_section(changelog_text: str, tag: str) -> str | None:
    version = tag.lstrip("v")
    # Match "## v1.0.20" or "## 1.0.20" (optionally followed by " - 2026-11-27" or similar)
    header_re = re.compile(
        rf"^##[ \t]+\[?v?{re.escape(version)}\]?(?:[ \t]+.*)?$",
        re.MULTILINE,
    )
    match = header_re.search(changelog_text)
    if not match:
        return None
    start = match.end()
    next_header = re.search(r"^##\s+", changelog_text[start:], re.MULTILINE)
    body = changelog_text[start : start + next_header.start()] if next_header else changelog_text[start:]
    body = body.strip()
    return body or None


def git_fallback_notes(tag: str) -> str:
    try:
        prev = subprocess.check_output(
            ["git", "describe", "--tags", "--abbrev=0", f"{tag}^"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        rev_range = f"{prev}..{tag}"
    except Exception:
        rev_range = "-n 5"

    try:
        cmd = ["git", "log", "--pretty=format:- %s"]
        if rev_range.startswith("-n"):
            cmd.extend(rev_range.split())
        else:
            cmd.append(rev_range)
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
        if out:
            return out
    except Exception:
        pass
    return f"- Release {tag}."


def format_inline_md(text: str) -> str:
    escaped = html.escape(text)
    # Inline code `...`
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    # Bold **...**
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    return escaped


def markdown_to_sparkle_html(tag: str, md_body: str, repo_slug: str | None) -> str:
    lines = md_body.splitlines()
    html_parts: list[str] = [
        "<style>",
        "body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px; line-height: 1.45; margin: 12px 16px; }",
        "h3 { font-size: 14px; margin: 0 0 8px 0; }",
        "ul { margin: 0 0 10px 0; padding-left: 18px; }",
        "li { margin: 4px 0; }",
        "code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; padding: 1px 4px; border-radius: 3px; background: rgba(127, 127, 127, 0.16); }",
        ".footer { margin-top: 10px; font-size: 11px; opacity: 0.75; }",
        "@media (prefers-color-scheme: dark) { body { color: #f2f2f7; } a { color: #64d2ff; } }",
        "</style>",
        f"<h3>What&apos;s New in MeuralSync {html.escape(tag)}</h3>",
    ]

    in_list = False
    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            if in_list:
                html_parts.append("</ul>")
                in_list = False
            continue
        if line.startswith("### "):
            if in_list:
                html_parts.append("</ul>")
                in_list = False
            html_parts.append(f"<h4>{format_inline_md(line[4:])}</h4>")
        elif line.startswith("- ") or line.startswith("* "):
            if not in_list:
                html_parts.append("<ul>")
                in_list = True
            html_parts.append(f"<li>{format_inline_md(line[2:])}</li>")
        else:
            if in_list:
                html_parts.append("</ul>")
                in_list = False
            html_parts.append(f"<p>{format_inline_md(line)}</p>")

    if in_list:
        html_parts.append("</ul>")

    if repo_slug:
        changelog_url = f"https://github.com/{repo_slug}/blob/main/CHANGELOG.md"
        html_parts.append(
            f'<p class="footer"><a href="{html.escape(changelog_url)}">View full changelog on GitHub</a></p>'
        )

    return "\n".join(html_parts) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract release notes for Sparkle and GitHub Releases.")
    parser.add_argument("tag", help="Release tag (e.g. v1.0.20)")
    parser.add_argument("--changelog", default="CHANGELOG.md", help="Path to CHANGELOG.md")
    parser.add_argument("--repo", default="", help="GitHub repository slug (e.g. owner/repo)")
    parser.add_argument("--markdown-out", required=True, help="Output path for Markdown release notes")
    parser.add_argument("--html-out", required=True, help="Output path for Sparkle HTML fragment")
    args = parser.parse_args()

    changelog_path = Path(args.changelog)
    notes_md = None
    if changelog_path.is_file():
        notes_md = extract_section(changelog_path.read_text(encoding="utf-8"), args.tag)

    if not notes_md:
        notes_md = git_fallback_notes(args.tag)

    Path(args.markdown_out).write_text(notes_md + "\n", encoding="utf-8")
    sparkle_html = markdown_to_sparkle_html(args.tag, notes_md, args.repo or None)
    Path(args.html_out).write_text(sparkle_html, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
