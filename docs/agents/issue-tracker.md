# Issue tracker: GitHub

Issues and PRDs for `lazarh/umbriel-noctalia-debian-script` live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`.
- **Read an issue**: `gh issue view <number> --comments`, also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments` with appropriate filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`.
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`.
- **Close**: `gh issue close <number> --comment "..."`.

Infer the repo from `git remote -v`; `gh` does this automatically inside the clone.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares one number space across issues and PRs, so resolve an ambiguous number with `gh pr view <number>` and fall back to `gh issue view <number>`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

Used by `/wayfinder`. The map is a single issue with child issues as tickets.

- **Map**: an issue labelled `wayfinder:map`, holding Destination, Notes, Decisions-so-far, Not-yet-specified, and Out-of-scope sections.
- **Child ticket**: an issue linked to the map through GitHub sub-issues. If sub-issues are unavailable, add it to a task list in the map and put `Part of #<map>` at the top of its body. Apply one `wayfinder:<type>` label.
- **Blocking**: use GitHub's native issue dependencies. POST to `repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by` with the blocker's numeric database `issue_id`. If unavailable, use a `Blocked by: #<number>` line in the child body.
- **Frontier query**: list open map children, then drop tickets with open blockers or assignees. The first remaining child in map order wins.
- **Claim**: `gh issue edit <number> --add-assignee @me` before any ticket work.
- **Resolve**: post the answer as a comment, close the ticket, and append its linked one-line gist to the map's Decisions-so-far.
