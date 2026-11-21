# Live validation: fm/firstmate-ci-suite-green-1 (base 2987e914 -> target 40d59a4f)
Date: 2026-11-21 (UTC). Host: Arch/CachyOS, bash 5.3.20, GNU coreutils timeout 9.12, perl 5.44,
node 22.23.3. Suites run serially through the project's own runner, one at a time.

## Behavioral drives (before/after where the CI failure was reproducible locally)
- run-bounded-matrix.txt: base run_bounded + uutils-style timeout -> exit 137, watcher SIGKILLed
  mid-INT-cleanup (reproduced the hosted CI 137); target + same shim -> 124 with cleanup complete
  (perl fallback); target + real GNU timeout -> 124 via the GNU path.
- tripwire-step.sh + tripwire-matrix.txt: the ci.yml "Assert full history" step script extracted
  verbatim and executed against 5 real git states - healthy full clone passes; stale .git/shallow
  residue over complete history is repaired (file dropped, exit 0) even with origin unreachable;
  genuine depth-1 truncation, a foreign shallow entry, and an entry with a missing parent each
  fail loudly with the ::error message.
- rex-leaf-uutils-emulation.txt: under an emulated uutils multicall coreutils, the old leaf
  (symlink to sleep) dies "unknown program" before existing; the new leaf (symlink to bash loop)
  stays alive under its own visible path.
- calm-queued-rows-base-repro.txt: the base queued-rows fixture against a genuine
  @earendil-works/pi-coding-agent@1.5.2 npm install crashes with exactly the hosted-CI TypeError
  (this.pendingBashComponents is not iterable, interactive-mode.js:4009); the target suite passes
  the same test against the same package.
- sequence-assertion-strength.txt: the new sequence-claims assertions (verbatim from the suite)
  still fail on a duplicate value, on 19 values, on a non-1 start, and on missing durable claims,
  while a gap-carrying unique 20-value set passes - the intended contract, not a weakening.
- data-untrack-refusal-repro.txt: re-tracking a captain-private data/ report in a throwaway clone
  is refused by bin/fm-doc-audience-check.sh ("unclassified"), reproducing the original refusal.
- public-followup-readonly-stdout.txt: the changed poll test passes on this bash 5.3.20 host; the
  base closed-fd form also passes here (the fd-reclaim quirk is specific to the hosted bash 5.3.9
  build, so the reported failure is not reproducible on this host - noted, not guessed at).

## Workflow semantic model (python/yaml parse of .github/workflows/ci.yml)
Every job on runs-on: self-hosted (lint, test-coverage, tests-portable-parallel-1/2,
tests-timing-aggregate, invariants) checks out with fetch-depth: 0 - the base had none of these.
Both "Install the Pi package" steps (parallel-1 and serial) install @1.5.2 and hard-assert the
installed version via npm ls + jq. The spawn-lineage tripwire step exists on tests-portable-parallel-1.

## Suite runs (bin/fm-test-run.sh, serial, this session)
- tests/fm-wake-queue.test.sh                      exit=0  119.6s  (incl. "concurrent append plus
  drain preserves durable records" and the unchanged live-holder lock refusals)
- tests/fm-remote-transport-lanes.test.sh          exit=0   71.0s  (incl. the 20-way concurrent
  sequence allocator + new uniqueness/count/start-at-1 assertions)
- tests/fm-documentation-audiences.test.sh         exit=0    1.9s; bin/fm-doc-audience-check.sh ok
  (surfaces=143, local_links=1063); git ls-files data/ empty; data/ gitignored
- tests/fm-calm-pi-extension.test.sh               exit=0   16.2s  vs real Pi 1.5.2 npm package
  (FM_PI_PACKAGE_DIR over a global-layout install in /tmp; tmux E2E variants skip - no tmux here)
- tests/fm-backend-rex.test.sh                     exit=0   11.5s
- tests/fm-public-followup.test.sh                 exit=0  238.9s  (incl. "a rejection wake
  survives a poll that could not write its line")
- tests/fm-remote-secondmate-lifecycle-e2e.test.sh exit=0  459.6s
- tests/fm-self-repo-role.test.sh                  exit=0    3.4s  (spawn lineage gate still
  refuses a shallow clone: "undeterminable lineage or publication target refuses")
