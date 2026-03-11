---
name: warn-deferred-stop
enabled: true
event: stop
pattern: .*
action: warn
---

**Spec completion check before stopping.**

Before you stop, verify you haven't deferred any work:

- Did you leave anything "for now" or "for later"?
- Did you declare anything "out of scope" that was in the spec?
- Did you say "would need to" instead of actually doing it?
- Did you skip any spec items or plan steps?
- Did you suggest the user do something you should have done?
- Did you leave TODO/FIXME comments instead of implementing?

If you deferred ANY work that was in the original spec or plan, go back and complete it now. The Cheese Lord does not accept partial deliveries. Stopping with incomplete spec items is not allowed unless the user explicitly approved the deferral.
