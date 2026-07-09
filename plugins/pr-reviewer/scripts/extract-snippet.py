#!/usr/bin/env python3
"""extract-snippet.py — deterministic source-snippet extraction for finding-id hashing.

Reads the literal source text at a resolved (file, post-change-line) location directly
from the file on disk — not reported by an LLM — so it can feed compute-fid.py without
depending on an LLM reproducing identical prose across runs. Call this after resolve-line.py
has already turned a sub-agent's diff-line into a real (file, line) pair.

Prints only the exact flagged line (no surrounding context), verbatim (no normalization —
compute-fid.py normalizes internally). Deliberately single-line, not a multi-line window:
a finding's identity should survive unrelated edits to neighboring lines (e.g. a comment or
blank line added above/below) — including context would change the fid on every such edit
even though the actual flagged line, and the bug it represents, didn't change. The accepted
tradeoff is a rare fid collision when two distinct findings share byte-identical single-line
text, the same file, and the same category.

Usage:
    extract-snippet.py <file> <line>

<file> is repo-relative, resolved against the current working directory (the review
worktree). <line> is 1-indexed, matching resolve-line.py's output.
"""
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: extract-snippet.py <file> <line>", file=sys.stderr)
        sys.exit(2)

    path, line_str = sys.argv[1], sys.argv[2]
    try:
        line = int(line_str)
    except ValueError:
        print(f"ERROR: <line> must be an integer, got {line_str!r}", file=sys.stderr)
        sys.exit(2)

    try:
        with open(path, "r", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        print(f"ERROR: could not read '{path}': {e}", file=sys.stderr)
        sys.exit(1)

    if line < 1 or line > len(lines):
        print(f"ERROR: line {line} is outside '{path}' (1..{len(lines)})", file=sys.stderr)
        sys.exit(1)

    print(lines[line - 1].rstrip("\n"))


if __name__ == "__main__":
    main()
