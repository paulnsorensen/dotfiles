# TUI Critique Rubric

Score each captured screenshot against every axis below. For each failing
axis, record: state, size, axis, what you see, expected, severity
(blocker/major/minor/nit).

## Hierarchy

Most important context sits top-left; status/keybindings sit at the bottom.

- Good: file path and mode indicator top-left, key hints bottom-right.
- Bad: a metadata panel occupies the top-left corner while the primary list
  is pushed below the fold.

## Density vs scannability

Dense output is fine if alignment and whitespace keep it scannable.

- Good: a table with consistent column widths and one blank line between
  groups.
- Bad: wall-of-text rows with no column alignment, forcing left-to-right
  reading of every cell to find a value.

## Alignment lanes

Numbers right-aligned, text left-aligned, consistent column boundaries.

- Good: a size column right-aligned so all decimal points line up.
- Bad: numbers left-aligned next to text, producing a ragged, hard-to-scan
  column.

## Truncation vs wrap

Table/list cells truncate with an ellipsis; free-form text wraps.

- Good: a long filename shows `very-long-filen…` in a fixed-width column.
- Bad: a filename wraps mid-cell onto the next table row, breaking row
  alignment for every row below it.

## Focus visibility

The focused panel or item is unambiguous at a glance.

- Good: the focused panel has a distinct border color plus a reverse-video
  selected row.
- Bad: two panels look identical and only a 1px border color difference
  (invisible in the screenshot) indicates focus.

## Status bar and key hints

A status/key-hint bar is present and shows context-relevant actions.

- Good: bottom bar reads `[NORMAL] file.txt | q:quit ?:help /:search`.
- Bad: no status bar, or one that never updates across different views.

## Color carries meaning + symbol pairing

Color is never the only signal; a symbol or text label always accompanies it.

- Good: an error row is red AND prefixed with `[ERR]`.
- Bad: a red row with no text/symbol marker — invisible under `NO_COLOR` or
  to a colorblind user.

## Narrow-width degradation

At 40x15, the app drops secondary panels/metadata gracefully instead of
corrupting layout.

- Good: sidebar disappears, main content re-flows to full width.
- Bad: sidebar stays pinned at a fixed width, squeezing main content into an
  unreadable sliver, or content is truncated mid-word with no ellipsis.

## Empty and error states are informative

Empty/error states explain what happened and what to do next, not just a
blank screen or a stack trace.

- Good: "No results for 'xyz'. Press / to search again."
- Bad: a blank list area with no text at all.

## No clipped or overlapping widgets

No widget's content is cut off at a pane boundary, and no two widgets
overlap and corrupt each other's rendering.

- Good: a modal dialog is fully contained within the terminal bounds at every
  tested size.
- Bad: a popup extends past the bottom row and its last line is invisible.
