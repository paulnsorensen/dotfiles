# Tighten

Hedging-phrase audit. No rewriting — the user decides what to cut.

---

Find every hedging phrase in the document I'm about to paste. List
them with line numbers. Do not rewrite — I'll decide which to delete.

Hedge list (catch any of these, plus close synonyms):

- "perhaps", "maybe", "probably", "possibly"
- "might", "could potentially", "may"
- "generally", "in many cases", "often", "typically"
- "it's worth noting", "it's important to", "as noted"
- "arguably", "relatively", "somewhat", "kind of", "sort of"
- "I think", "I believe", "I'd say"
- Passive "is considered", "is thought to be"

Output format: a numbered list, one line per hit:
`L<line> — "<exact phrase>" — <one-word suggestion: delete | replace with specific | keep>`

After the list, append: a count of total hedges per 100 lines. If
the count is > 3 per 100, recommend a second pass.
