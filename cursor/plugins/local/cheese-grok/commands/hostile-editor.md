# Hostile editor

Paste-draft-and-criticize loop for design docs. Apply this exactly —
do not produce a polished version, do not write "here is an improved
draft".

---

Below is a draft design doc. Act as a senior staff engineer who is
*suspicious of AI-written prose*. Do the following, in order:

1. **Slop-sentence audit.** Identify any sentence that could appear
   unchanged in another design doc on another project. Quote them
   verbatim — no softening.

2. **Spine integrity.** Identify Goals that are not measurable,
   Non-Goals that are negated goals rather than declined scope, and
   Alternatives that are straw-men. Quote them and name the failure
   mode.

3. **Weakest paragraph.** Identify the single weakest paragraph.
   **Don't rewrite it** — ask me three questions whose answers would
   let me rewrite it myself.

4. **Missing risk.** Identify one risk I should have considered but
   didn't. Be specific to the actual system described — generic risks
   ("might affect performance", "third-party dependencies") get no
   credit.

Do not produce a polished version. Do not write "here is an improved
draft."
