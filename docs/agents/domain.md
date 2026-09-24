# Domain documentation

This repository uses a **single-context** layout:

- Root `CONTEXT.md`: resolved terminology and domain context.
- `docs/adr/`: architecture decision records relevant to the changed area.

Read these before exploring when they exist. Their absence is normal: proceed
without scaffolding placeholders or speculative decisions. Domain recording is
a separate authorized activity, performed lazily when terminology or decisions
are actually resolved; this setup creates neither file nor directory.

Use the glossary's established terms in issues, tests, and proposals. Identify
real vocabulary gaps for the authorized domain-modeling owner rather than
inventing synonyms. Call out conflicts with existing decision records explicitly;
do not silently override them. Continue to read `AGENTS.md` and relevant
existing design/behavior documentation whether or not domain records exist.
