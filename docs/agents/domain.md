# Domain Docs

## Before exploring, read these

- Read `CONTEXT.md` at the repository root, or the relevant contexts from `CONTEXT-MAP.md` if one exists.
- Read applicable ADRs under `docs/adr/`.
- If these files do not exist, proceed silently; domain-modeling creates them lazily.

## File structure

This repository uses a single-context layout: one root `CONTEXT.md` and system-wide decisions under `docs/adr/`.

## Use the glossary's vocabulary

Use canonical terms from `CONTEXT.md` in issues, specifications, code, and tests. Reconsider undefined synonyms or capture a genuine vocabulary gap through domain-modeling.

## Flag ADR conflicts

Surface any contradiction with an existing ADR rather than silently overriding it.
