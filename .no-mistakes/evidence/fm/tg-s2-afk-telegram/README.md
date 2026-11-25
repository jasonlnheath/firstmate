# S2 live-validation evidence (fm/tg-s2-afk-telegram)

- s2-live-entry-lane-configured.log - /afk entry on a lane-configured lab home:
  record v3 with reach_channels: telegram, announcement + read-back name Telegram.
- s2-live-note-answered.log - captain note from Telegram while away: wake row,
  durable reply, exactly one pushed line (`fm: ...`), second reply refused.
- s2-live-hold-and-laneless.log - hold-for-return reply arm; lane-less home:
  reply records, push fails closed into the journal, engine never invoked.
- s2-live-reach-detection-arms.log - commented-out tg-target => reach none
  (lane-off gesture honored); channel-less wording unchanged; quiet entry with
  the lane configured records reach none.
- s2-live-session-start-digest.log - session-start AFK digest renders the
  record's telegram reach instead of hardcoded hold-for-return.
- s2-live-captain-kind.log - report surface: captainKind recorded, kindless
  fallback, unknown kind and kind-on-routine refused with nothing recorded.
- s2-live-primary-afk.log - the real claude CLI (headless -p, lab FM_HOME)
  drove /afk end to end: the agent wrote the record and announced Telegram
  as the away channel. tmux is absent on this validation host, so the
  interactive TUI primary form could not be driven.
- s2-targeted-suites.log - the six changed/new suites, first pass. The two
  exit=1 entries there are explained below; use the *-clean/*-rerun logs for
  the authoritative passes.
- s2-suite-fm-session-start-clean.log - fm-session-start suite re-run with the
  gate harness's leaked FM_SESSION_START_STATUS_TAIL=3 scrubbed: all 65 pass.
  The first-pass failure was environment contamination from the validation
  agent's own shell, not the change.
- s2-suite-fm-supervision-host-rerun.log / s2-suite-fm-supervision-host-basecommit.log -
  the one remaining failure (`tagged: the host never started a watcher cycle`,
  a faked MINGW/ps -W lock-holder scenario) fails identically on the base
  commit 78e2d695 on this host: pre-existing, unrelated to this change
  (this box deliberately reproduces the rig's environment-sensitive CI
  failures). Every change-specific assertion in the suite passes.

No real Telegram conversation was ever reached: the lab lane's engine was
pinned to a capture stub via config/tg-hermes-bin, and the target id was the
fixture id telegram:424242.
