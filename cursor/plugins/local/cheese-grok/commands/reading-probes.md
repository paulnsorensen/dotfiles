# Reading probes

Six probing prompts that replace "summarize this file". Use them when
reading unfamiliar code — they force the AI into critic/interpreter
mode rather than author mode.

Pick the one that fits your current question. Paste it into chat with
the file or symbol filled in.

---

**Hypothesis probe**
I think `X` works by `Y`. Find the strongest evidence in this repo
that I'm wrong. Cite file:line.

**Counterexample search**
Show me the file that most contradicts the pattern in `path/foo.ts`.
Cite the specific divergence.

**Archaeologist**
Find the commit that introduced `function_name`. Quote the commit
message. Was the original intent the same as today's usage?

**Decoy hunt**
What's a function in this codebase that looks important by name but is
actually dead or near-dead code? Cite the file, the most recent caller,
and the test (or its absence).

**Senior pushback**
If I told you `feature X` is implemented in `path/foo.ts`, what would
you check first to verify that claim — and what would you check second
if the first check passed?

**Reverse summary**
Here is my one-paragraph summary of `path/foo.ts`: <paste>. Don't agree
or rewrite — list what I left out that a maintainer would consider
important.
