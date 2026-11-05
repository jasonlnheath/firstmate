# Validation: land docs/tasks/hermes-rig-portability-report.md (target 11ba50af)

Worktree: /home/jason/.no-mistakes/worktrees/5a4bc58bcad7/01M6NYJM9096SS896700GMCRF5, HEAD = 11ba50afe085b1ebe8dd8c6ffca364d40c445044, clean.
Change under test: adds `docs/tasks/hermes-rig-portability-report.md` (142 lines) and classifies it in `docs/documentation-audiences.json` as `maintainer-verification` (4 lines).

## Scenario 1 — real consumer accepts the landed report (live)

```
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=142 local_links=1063   (exit 0)
```

The checker (CI's leaf consumer: ci.yml -> bin/fm-test-run.sh ->
tests/fm-documentation-audiences.test.sh -> bin/fm-doc-audience-check.sh) enforces
exact classification coverage of every tracked prose file plus local-link/anchor
resolution. At the target commit it passes with the report included.

## Scenario 2 — classification is load-bearing: fail-before / pass-after (live)

Removed the 4-line inventory entry (recreating the pre-fix state), then restored:

```
$ python3: surfaces 142 -> 141 (entry docs/tasks/hermes-rig-portability-report.md dropped)
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: unclassified: docs/tasks/hermes-rig-portability-report.md   (exit 1)
$ git checkout -- docs/documentation-audiences.json
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=142 local_links=1063   (exit 0)
$ git status --porcelain   ->  (clean)
```

The failure names exactly the new report, proving the checker exercises the file
and the inventory entry is what makes coverage pass.

## Scenario 3 — CI's own regression test (unit, live: false)

```
$ tests/fm-documentation-audiences.test.sh
ok - documentation inventory classifies every maintained prose surface exactly once
ok - classification, setup routing, and maintained-prose scope fail safely
ok - required documentation owner pointers cannot silently disappear
ok - local links resolve while dates, versions, commands, and incident prose remain semantically reviewed
(exit 0)
```

## Scenario 4 — report's headline merge facts match upstream hermes-agent (read-only gh, live: false)

```
$ gh pr view 11 --repo jasonlnheath/hermes-agent
{"mergeCommit":"a6507979567fb6215403af1b89b919bb3bc97b89","mergedAt":"2026-11-03T06:00:04Z","state":"MERGED",
 "title":"Diet hosted Actions: core CI on the rig runner, artifact workflows retired"}
$ gh api repos/jasonlnheath/hermes-agent/commits/195964f  ->  count: 9
  .github/workflows/tests.yml            <- the 1 workflow lane (e2e)
  tests/ci/test_live_comment.py
  tests/hermes_cli/test_kanban_default_assignee.py
  tests/hermes_cli/test_kanban_per_profile_cap.py
  tests/hermes_cli/test_session_recovery_lost_and_found.py
  tests/hermes_cli/test_update_head_moved_gate.py
  tests/plugins/image_gen/test_openrouter_compat_provider.py
  tests/test_hermes_state.py
  tests/tools/test_browser_real_profile.py
```

Matches the report's claims exactly: PR 11 MERGED, squash a650797, merged
2026-11-03T06:00:04Z; "9 files - 8 test files + 1 workflow lane" — the 8 test
files are the same ones named in report items 1-7, plus tests.yml (item 8).

## Notes

- No rendered-HTML artifact: firstmate publishes prose only as tracked markdown
  (no docs-site/pages pipeline in .github/workflows), so the delivered markdown
  itself plus the checker transcript are the end-user-visible evidence.
- No stale references to the pre-review root path `report-hermes-rig-portability.md`
  anywhere in the tree; only `docs/tasks/hermes-rig-portability-report.md` is tracked.
- Inventory placement matches the sibling task-report block (maintainer-verification,
  alphabetical between bootcamp-hibernate-auto-report.md and usage-warner.md... entry
  sits adjacent to its docs/tasks siblings).
- Worktree left clean; no transient artifacts (the regression test's tmpdir self-cleans via trap).
