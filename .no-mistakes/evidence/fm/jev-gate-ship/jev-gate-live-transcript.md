# Jev gate — live product drive (2026-10-13T02:30Z)

Fixture: isolated plain git checkout at /tmp/jev-live-xF6Z with the shipped transport, policy,
screener, and override helper copied in (bin/), FM_STATE_OVERRIDE pointing at scratch
state dirs. Real node + bash; no test-harness fakes except where a scenario names the
documented FM_JEV_COMMAND_SCREENER seam. One scenario (S5c/S5 first attempt) hit the
real api.typesafe.ai consult because the ambient environment exports TYPESAFE_API_KEY.

------------------------------------------------------------------
=== S1a: absent config/jev-gate => inert even for rm -rf / ===
exit=0 stdout_bytes=0
state/jev-gate absent (correct)

=== S1b: enforce posture activated ===
=== S2: rm -rf / under enforce => exit 2, [JG-R1] on stderr, empty stdout ===
exit=2
stdout: 
stderr: [JG-R1] rm -rf against a protected path (/) — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).

=== S2b: rm -rf $HOME/.ssh ===
[JG-R1] rm -rf against a protected path (/home/jason/.ssh) — blocked by the Jev damage-control gate (stage: regex, confidence: 1.00).
exit=0

------------------------------------------------------------------
=== S3: redirect-protected — every spelling of the operator must resolve identically ===
spaced   "echo x >> /etc/hosts"            exit=2  [JG-R7] output redirection into a protected path (/etc/hosts) — blocked by the Jev damag
unspaced "echo x >>/etc/hosts"             exit=2  [JG-R7] output redirection into a protected path (/etc/hosts) — blocked by the Jev damag
tab      "echo x >\\t/etc/hosts"           exit=2  [JG-R7] output redirection into a protected path (/etc/hosts) — blocked by the Jev damag
tab 2>   "cmd 2>\\t/etc/hosts"             exit=2  [JG-R7] output redirection into a protected path (/etc/hosts) — blocked by the Jev damag
home key "echo x >\$HOME/.ssh/authk"       exit=2  [JG-R7] output redirection into a protected path (/home/jason/.ssh/authorized_keys) — bl
--- carve-outs must allow with no event ---
/dev/null  "echo hi > /dev/null"           exit=0  
unsp 2>/dev/null "cmd 2>/dev/null"         exit=0  
tab   2>/dev/null "cmd 2>\\t/dev/null"     exit=0  
events before=8 after=8 (equal => no event for carve-outs)

=== S4: git-discard-primary (R10) in the primary checkout ===
git reset --hard                           exit=2  [JG-R10] discard-shaped git operation in the primary checkout — blocked by the Jev damag
git clean -fd                              exit=2  [JG-R10] discard-shaped git operation in the primary checkout — blocked by the Jev damag
git checkout -- .                          exit=2  [JG-R10] discard-shaped git operation in the primary checkout — blocked by the Jev damag
git restore .                              exit=2  [JG-R10] discard-shaped git operation in the primary checkout — blocked by the Jev damag
--- same shapes outside the primary checkout: no deterministic block ---
outside: exit=0  

------------------------------------------------------------------
=== S5: marker command consults the REAL screener; no TYPESAFE_API_KEY => off => fail-open allow ===
exit=0 stderr=[] stdout=[]
counters: jev_off=0
event: 

------------------------------------------------------------------

=== S6: breaker opens after 3 consecutive screener failures; 4th marker allows WITHOUT consulting ===
attempt 1: exit=0 screener_calls=1
attempt 2: exit=0 screener_calls=2
attempt 3: exit=0 screener_calls=3
attempt 4: exit=0 screener_calls=3
breaker state: {"consecutive_failures":3,"open_since":1791858185820,"cooldown_until":1791858485820}
counters: jev_error=3 jev_degraded=2 
breaker_open event: 1
degraded event (allow w/o consult): 1

------------------------------------------------------------------
=== S5b: no TYPESAFE_API_KEY => screener reports off => fail-open allow, no network ===
exit=0 stderr=[]
counter: jev_off 1
event: jev/off

=== S5c: REAL API consult, destructive at/above floor => enforce block [JG-J1] ===
exit=0 stdout=[]
stderr: 
off choice=null conf=null floor=null
allow choice=grey-reversible conf=0.67 floor=0.8

------------------------------------------------------------------
=== S5d: destructive@0.95 (>= floor 0.8) in ENFORCE => block [JG-J1], cache hint forwarded only with FM_JEV_GATE_CACHE_OUT ===
plain exit=2 stdout_bytes=0
stderr: [JG-J1] classified destructive (confidence: 0.95, floor: 0.80) — blocked by the Jev damage-control gate (stage: jev).
cache-out exit=2 stdout=[cache	destructive	0.95]
deny reason clean of cache line: 0 cache-mentions in stderr

=== S8: shadow posture => same command allows, would_block event; unknown value degrades to shadow ===
shadow exit=0 stderr=[]
unknown-value exit=0 stderr=[]
shadow jev destructive
shadow regex rm-protected

------------------------------------------------------------------
=== S7a: Bearer/Authorization secrets are redacted in the event journal ===
exit=0
"cmd":"curl -H \"
0

=== S7b: override helper status verifies the chain ===
status exit=0
window: closed
counters:
  allow_free=0
  consult_benign=0
  consult_grey=1
  consult_uncertain=0
  low_confidence_pass=0
  block_regex=1
  block_jev=3
  block_repeat=0
  near_miss=0
  jev_off=1
  jev_timeout=0
  jev_error=1
  jev_degraded=0
  override_opened=0
  override_pass=0
  overridden_block=0
  override_expired=0
breaker: closed
chain: verified
false-block proxy: overridden/(regex+jev blocks) = 0/4
jev availability: timeouts=0 errors=1 degraded=0 off=1 consults=1
near-misses: 0

=== S7c: tamper with one event char => status exits non-zero with BROKEN ===
status exit=1
chain: BROKEN at seq 5 (hash mismatch)

------------------------------------------------------------------

=== S9: record-override audit action + helper off (advisory close) ===
record-override open exit=0
record-override expire exit=0
bogus verb exit=2 stderr=[error: record-override needs open|close|expire]
override_open reason=pilot tuning window
override_close reason=ttl done
counters: override_opened=1 override_expired=1 
--- helper off removes the published view and records override_close ---
window: open (remaining ~136802362 min)
reason: x
off exit=0
view removed
window: closed
      2 override_close
      1 override_open

------------------------------------------------------------------
=== S10: 1 MiB journal rotation, 3 rotations kept, chain stays verifiable ===
events.jsonl size: 59950 bytes
rotation files: 1 : events-1791858346910.jsonl

------------------------------------------------------------------
rotated file size: 1049933 bytes (>= 1 MiB at rotation)
active file chain:
chain: verified
near-misses: 260
rotated file chain (independently self-chained):
HASH MISMATCH
rotated-file hashes recomputed OK, lines=247

------------------------------------------------------------------
=== S13: orphaned lock (dead holder) is stolen, evaluation proceeds, lock cleaned ===
eval exit=0
lock cleaned up

=== S14: screener input capped at 8192 bytes ===
exit=0
bytes handed to screener: 8192 (cap 8192); command bytes: 9022

=== S15: hung screener => timeout fail-open (allow + jev_timeout), no wedge ===
exit=0 elapsed=1051ms (bounded ~1s, not 30s)
counter: jev_timeout 1

