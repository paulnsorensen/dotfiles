# Code review interfaces: tool patterns for decision cards

Decision cards group a diff into a few units and hide code behind a "show me" drill-down. No checked tool does exactly this. CodeRabbit Change Stack is the closest precedent. No checked tool shows per-claim provenance for AI summaries. Research ran on 2026-11-20. Evidence on review load is in [[research/code-review-cognitive-load]].

## Why this page exists

The architecture review viewer shows a few decision cards for a diff. Each card has one sentence, who notices, what changed, tested, watch out with its basis, verdict buttons, and a drafted comment. A "show me" drill-down opens the system map, module contract, symbol diagram, and source. The goal is less load than reading code. This page records which existing tools use similar patterns. See [[architecture/agents-dir]] (architecture review skill) and PR <https://github.com/paulnsorensen/dotfiles/pull/1615>.

Confidence is "certain" unless a line says otherwise. "Vendor claim" means the vendor says it and no independent evidence exists.

## PR and diff review tools

### CodeRabbit Change Stack (closest precedent)

CodeRabbit Change Stack (May 2026) regroups a PR into a small number of independent change cohorts. Each cohort splits into ordered layers. Each layer has its own summary, an optional Mermaid diagram, and only that layer's code ranges. Simple layers stay text-only.

The UI has three panels: navigation, diff, and per-range context. It has J/K keys, viewed marks, and a draft review that posts to GitHub. Source: <https://www.coderabbit.ai/blog/introducing-change-stack-the-first-ai-native-code-review-interface>

Its trust and provenance signals are not verified.

### Other summary and ordering tools

- **CodeRabbit Walkthrough:** summary, grouped changed-files table (one source file plus 27 locale files gives two rows), sequence diagrams, estimated review effort, and merge risk. It is collapsible by default. Source: <https://docs.coderabbit.ai/pr-reviews/walkthroughs>
- **GitHub Copilot PR summary:** generated text with no per-claim provenance. The docs say to review it carefully (seen as a search snippet only). GitHub Files changed has a filter and a file tree. Source: <https://docs.github.com/en/copilot/how-tos/copilot-on-github/copilot-for-github-tasks/create-a-pr-summary>
- **Graphite:** shows the stack on the PR page. Reviewers go bottom-up. An orange bar marks upstack changes. Source: <https://graphite.dev/docs/best-practices-for-reviewing-stacks>
- **Reviewable:** a discussion matrix by To reply, Unresolved, and Resolved, with per-participant dispositions. "Show Unreviewed Diffs" supports re-review. Source: <https://docs.reviewable.io/reviews.html>
- **Gerrit:** related changes and submitted-together sets. The patchset compare UI is not verified. Source: <https://gerrit-review.googlesource.com/Documentation/user-review-ui.html>
- **ReviewStack (Sapling):** one commit per PR in a stack dropdown. It is not battle-tested for large PRs. Source: <https://sapling-scm.com/docs/addons/reviewstack/>
- **Greptile:** a 0-5 confidence score per PR with an explanation. This is vendor marketing. No calibration evidence exists. Source: <https://www.greptile.com/open-source>

### Noise reduction in the diff itself

- **SemanticDiff** hides whitespace and style changes. It detects moves, renames, and refactorings. Source: <https://semanticdiff.com>
- **Difftastic** diffs syntax trees and ignores reformatting. It has no move detection. Source: <https://github.com/Wilfred/difftastic/blob/master/README.md>
- **GitClear Diff Digest** labels moved, copied, and renamed code. It orders files into salience tiers. It shows only changes new since your last review. Its noise percentages are vendor claims. Source: <https://www.gitclear.com/best_ai_diff_viewer>
- **Anthropic's internal review surface** treats comment-only changes differently from sensitive logic. Reviewers examine the intent of the change. Source: <https://www.anthropic.com/research/redesigning-source-control>

## Code-understanding tools (the "show me" layer)

These tools suit the drill-down: a reduced graph with source one step behind it.

- **SciTools Understand:** a Variant dropdown switches Simplified, Cluster (collapsible groups), Butterfly (both directions), Internal, Relationship (path between two picked entities), and Compare without a restart. Source: <https://docs.scitools.com/help/graphs/open-a-graph.html>
- **Understand Compare:** draws both versions at once. It colours entities added, modified, or removed. A click on a node opens the file diff. Sources: <https://blog.scitools.com/visualizing-change> and <https://docs.scitools.com/help/compare/compare-project-versions.html>
- **Understand Changes Treemap:** sizes and colours by churn. Changed entities open a side-by-side diff. Metric deltas use Diff* names (same compare page).
- **Understand dependency compare:** unchanged edges are black. A bold outline marks a node whose contents changed while its dependency stayed the same. Source: <https://docs.scitools.com/help/dependencies/browse-and-export-dependencies.html>
- **Understand reference walks:** graphs walk the references behind a reduced graph, with source at each step. Depth limits control size. Sources: <https://blog.scitools.com/code-browsing-from-graphs> and <https://scitools.com/graphs>
- **Understand layout:** the main window is IDE-like. It docks a Project Browser, an Architecture Browser, an Information Browser (a tree of facts for one entity), and a Source Previewer. A "Sync" toggle makes a panel follow each click. A right-click on any entity opens Graphical Views. Each graph opens in its own tab with a Variant selector. Sources: <https://scitools.com/code-navigation> and <https://blog.scitools.com/stepping-thru-code-with-understand>
- **Understand 7.1 (AI summaries):** a click on a graph node shows a code preview and an AI summary from a local LLM. Source: <https://docs.scitools.com/help/release-notes/releases/understand-7-1.html>
- **Understand 8.0 (2026-05-13, build 1253):** adds Rust support, local or remote AI model choice, a larger MCP server with architecture-analysis tools, a global search bar, and Data Sequence and Input Output diagrams. Source: <https://docs.scitools.com/help/release-notes/releases/understand-8-0.html> (checked 2026-11-21)
- **Sourcetrail:** three linked views (search, graph, code). The code view shows the active symbol's definition first and references below. A click on an edge shows its source location. Bundle nodes show a count of hidden nodes. Edge thickness shows count. Custom Trail has a depth slider. The project was archived in December 2021. Sources: <https://github.com/CoatiSoftware/Sourcetrail/blob/master/DOCUMENTATION.md> and <https://github.com/coatisoftware/sourcetrail>
- **CodeSee Review Maps:** one map per PR. Green is added, red is removed, orange is modified, and white is unchanged but depends on a changed file (possible impact). A click isolates a file's dependencies. A double-click opens the diff. A right-click marks viewed. Authors can give a Tour. Source: <https://docs.codesee.io/docs/user-guide>. GitKraken acquired CodeSee on 2024-05-14 (<https://www.gitkraken.com/blog/gitkraken-launches-devex-platform-acquires-codesee>). Current product status: speculating.
- **NDepend:** diffs against a baseline. The Dependency Matrix marks changed cells with + (added dependency) or - (removed) and explains on hover. The vendor says graphs were unreadable beyond a few dozen boxes before v2020.1, and the matrix scales better but is less intuitive (vendor claim). Sources: <https://www.ndepend.com/docs/dependency-structure-matrix-dsm> and <https://www.ndepend.com/features/code-diff>
- **Structure101:** a Levelized Structure Map with expand/collapse depth, auto-grouped tangles, and filters. What-if edits use Action Lists (third-party slides and transcript only).
- **Lattix:** a hierarchical DSM plus a box-in-box Conceptual Architecture Diagram. Source: <https://docs.lattix.com/lattix/userGuide/Working_with_the_Dependency_Structure_Matrix_DSM.html>
- **Sourcegraph:** hover docs, go to definition, and find references split into precise and search-based results. Source: <https://sourcegraph.com/docs/code-navigation>

## Weaknesses to design around

- Graphs become hairballs as size grows. Depth limits, clusters, and bundle counts reduce this.
- Matrices are less intuitive than graphs.
- Understand Compare needs a second analysed project.

## Patterns worth borrowing

- Colour by change type, and mark "unchanged but depends on changed" as possible impact (CodeSee, Understand).
- Open source one step behind any reduced graph (Understand, Sourcegraph, Sourcetrail).
- Show a count for hidden nodes (Sourcetrail bundles).
- Keep a viewed mark and a "show unreviewed" re-review filter (CodeSee, Reviewable, GitClear).

## Architecture diagram tools with no visual version diff

IcePanel has drafts with a Changes list, and versions as static snapshots. No visual version diff was found. Source: <https://docs.icepanel.io/future-state-design/drafts>. Structurizr relies on text diffs in git. Source: <https://docs.structurizr.com/as-code>

_Source: research brief for PR 1615, run 2026-11-20 · Updated: 2026-11-20 · Supersedes: none_
