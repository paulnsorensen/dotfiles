---
name: wat
model: sonnet
effort: medium
description: >
  Stop — that last message did not land. Re-pitch it. Use when the user says
  "wat", "wait, what?", "you lost me", "re-pitch that", "I don't follow",
  "explain that again", or invokes /wat. Adapted from mattpocock/skills
  wait-what: re-explains the previous message in ASD-STE100 Simplified Technical
  English, grounded in the project's ubiquitous language.
disable-model-invocation: true
---

Wait — I don't understand where you've got to here. That last message did not
land. Re-pitch it:

1. **Add a little context first.** One or two sentences on what you were doing
   and why, so I don't have to reconstruct it.
2. **Write in ASD-STE100 Simplified Technical English.** Short sentences (max ~20
   words for a statement, ~25 for a procedure). One instruction per sentence.
   Active voice. Present tense. Use approved words in their approved meaning; drop
   jargon, idiom, and filler. Prefer a simple word over a fancy one.
3. **Use this project's ubiquitous language.** Ground the domain terms you use so
   they match the source of truth, not your own paraphrase:
   - `ground` the concepts against `easy-cheese-wiki` and `hallouminate-wiki`
     (the phase/skill vocabulary and the wiki/corpus vocabulary).
   - Also `ground` against `repo:dotfiles:wiki` when the message is about this
     repo's own config, harness wiring, or `ap`.
   - If a term has a precise meaning in those corpora, use it exactly; if the
     wiki and your draft disagree, follow the wiki and say so.

Then give me the re-pitch — nothing else. No apology, no meta-commentary.
