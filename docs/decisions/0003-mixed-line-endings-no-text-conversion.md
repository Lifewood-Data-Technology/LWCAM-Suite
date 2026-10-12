# 0003. Mixed line endings, and git converts nothing

- **Status:** Accepted

## Context

The tree started as all CRLF files made on Windows. Today some files are CRLF and some are LF. A script that rewrites a whole file with the wrong ending shows every line as changed. This once produced 611 deleted lines for a 45-line change.

## Decision

`.gitattributes` contains `* -text`. Git stores every file exactly as it is on disk and converts nothing. Every file keeps the line ending it already has. New Markdown files use LF.

## Consequences

- Check a file before you rewrite it: `file <path>`.
- Use an editor or a byte-safe script. Git Bash `sed -i` converts a CRLF file to LF.
- Do not run a "normalise line endings" pass. It makes a diff the size of the repository and hides real changes.

## Don't change this unless

You are ready to convert every file in one commit, add a matching `.gitattributes` rule, and tell every contributor. Do it as its own change with no other edits.
