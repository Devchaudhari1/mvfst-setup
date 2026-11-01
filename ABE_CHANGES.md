# Alternative Backoff with ECN (ABE) for CUBIC in mvfst: Change Report

## 1. Summary

This work adds Alternative Backoff with ECN (RFC 8511) to mvfst's CUBIC congestion controller. When a congestion signal arrives as an ECN Congestion Experienced (CE) mark instead of a packet loss, CUBIC now reduces its congestion window (cwnd) by a gentler factor: 0.85 instead of 0.7.

| Item | Detail |
|---|---|
| Base commit | `1c7dfc8ce6f3db4f18267aeaecd47afcb6c4b961` of `facebook/mvfst` |
| mvfst changes | 8 files, 265 insertions, 21 deletions (uncommitted, in `~/mvfst/mvfst`) |
| New experiment scripts | 3 files in `~/mvfst/experiments/` |
| New unit tests | 12, in `quic/congestion_control/test/CubicSteadyTest.cpp` |

Section 11 gives the in-depth reasoning behind every change, and section 8 lists known limitations, including one that may need a code change before the results are final.

### Current status

**The C++ changes have not been compiled and the unit tests have not been run.** The mvfst build was blocked by a permission check because it runs downloaded code, so it has to be started by the user. No experiments have been run and no cwnd graphs exist yet.

| Check | Status |
|---|---|
| C++ code compiles | Not tested |
| New and existing unit tests pass | Not tested |
| `topology.sh` and `run_arms.sh` | Syntax check only; never executed |
| `plot_cwnd.py` | Ran on one small synthetic qlog; not yet run on a real trace |
| Expected results in section 7 | Predictions, not measurements |

## 2. Background

### What ECN and ABE do

A router using an Active Queue Management (AQM) algorithm such as CoDel or PIE can signal congestion by setting a CE mark on a packet, without dropping it. The receiver reports the mark back to the sender, and in QUIC this is a cumulative CE count in the ACK frame.

Traditionally, senders treat a CE mark exactly like a loss. RFC 8511 argues that this is too cautious:

- **A loss** often means a large buffer has overflowed, so a deep reduction is needed to drain it.
- **A CE mark** from an AQM usually means the queue is still short, so a deep reduction leaves the link underused.

ABE therefore applies a smaller reduction to CE marks. RFC 8511's experiments suggest beta_ecn = 0.85 for CUBIC, compared with beta_loss = 0.7. Mozilla's neqo uses the same 0.85 value (PR #3233).

### Requirements taken from RFC 8511

| Requirement | How it is met |
|---|---|
| Loss response is unchanged | `onPacketLoss` still uses `steadyState_.reductionFactor` (0.7) |
| Respond to CE at most once per RTT | `endOfRecovery` check in `maybeReduceOnClassicEcn` |
| Keep reducing each RTT if congestion persists | CE on packets sent after the last reduction triggers a new one |
| No further reduction for a loss in the same RTT | Existing `endOfRecovery` check in `onPacketLoss` |
| ABE not recommended when cwnd <= ssthresh | Slow start (Hystart) uses 0.7 |

## 3. What was found in mvfst before making changes

These findings shaped the design. The most important one changes the meaning of the project.

### Stock CUBIC ignores classic ECN

mvfst's `Cubic::onEcnCongestionEvent` already exists, but it only reduces cwnd when `conn_.ecnState == ECNState::ValidatedL4S`. With classic ECN, the state is `ValidatedECN`, so the function only updates `lastCECount_` and cwnd is untouched.

ABE therefore could not be added by changing a constant. The whole classic CE response had to be added first.

### tperf could not enable classic ECN

tperf set `enableEcnOnEgress` only under `--use_l4s_ecn`. There was no way to run a classic ECN experiment with it.

### The ECN plumbing already worked

These parts needed no changes:

- ECT(0) marking on the socket (`updateSocketTosSettings`)
- ECN validation up to `ValidatedECN` (`validateECNState`)
- Delivery of CE counts to congestion control through `AckEvent::ecnCECount`
- Receiver-side reading and echoing of marks (`readEcnOnIngress`, tperf `--read_ecn`)

### Two hazards in the existing control flow

**Stale CE counts.** `onPacketAcked` returns early for ACKs of packets sent before recovery began, and `onPacketAckedInRecovery` never reads CE counts. A CE check placed only in the Steady path would see old marks on the first ACK after recovery and reduce a second time for the same congestion event.

**Hystart's exit block.** `onPacketAckedInHystart` has a `SCOPE_EXIT` block that can set `state_ = Steady` and clear `lastMaxCwndBytes`. A reduction made inside that function would have been overwritten as it returned.

Both hazards shaped where the new check was placed (section 4.3).

## 4. Changes to CUBIC

### 4.1 Passing the factor into `cubicReduction`

**File:** `quic/congestion_control/QuicCubic.cpp`, `QuicCubic.h`

```cpp
void Cubic::cubicReduction(
    TimePoint reductionTime,
    float reductionFactor) noexcept {
  ...
  steadyState_.lastReductionTime = reductionTime;
  cwndBytes_ = boundedCwnd(
      cwndBytes_ * reductionFactor,
```

**What changed:** the factor is now a parameter instead of always being `steadyState_.reductionFactor`. The time parameter was renamed from `lossTime` because it is no longer always a loss.

**Why:** this function also maintains `lastMaxCwndBytes` (W_max), `lastReductionTime` and `estRenoCwnd`, and enforces the cwnd bounds. A CE reduction needs all of that, so reusing it is safer than a second copy.

### 4.2 Extracting `enterRecovery`

**What changed:** the block inside `if (startsNewRecovery)` in `onPacketLoss` moved unchanged into a new function. The only additions are the factor and the qlog reason as parameters.

```cpp
void Cubic::enterRecovery(
    TimePoint reductionTime,
    float reductionFactor,
    const char* reason) {
  recoveryState_.endOfRecovery = Clock::now();
  cubicReduction(reductionTime, reductionFactor);
  if (state_ == CubicStates::Hystart || state_ == CubicStates::Steady) {
    state_ = CubicStates::FastRecovery;
  }
  ssthresh_ = cwndBytes_;
  if (conn_.pacer) {
    conn_.pacer->refreshPacingRate(
        cwndBytes_ * pacingGain(), conn_.lossState.srtt);
  }
  QLOG(...);
}
```

`onPacketLoss` now calls it with the values it always used:

```cpp
enterRecovery(loss.lossTime, steadyState_.reductionFactor, kCubicLoss);
```

**Why:** a CE reduction needs the same steps as a loss reduction, and sharing them gives several things without extra code:

- Setting `endOfRecovery` provides the once-per-RTT limit, and also stops a following loss from cutting again.
- Moving to `FastRecovery` means recovery-exit logic recalculates the cubic curve from the new window.
- `onPacketAckedInRecovery` asserts `cwndBytes_ == ssthresh_`, which `ssthresh_ = cwndBytes_` keeps true.
- The pacer learns the new rate immediately.

Loss behaviour is intended to be identical to before.

### 4.3 The new CE response: `maybeReduceOnClassicEcn`

This is the core of the change.

```cpp
void Cubic::maybeReduceOnClassicEcn(const AckEvent& ack) {
  const float ecnReductionFactor =
      conn_.transportSettings.ccaConfig.cubicEcnReductionFactor;
  if (ecnReductionFactor <= 0.0f || conn_.ecnState != ECNState::ValidatedECN ||
      ack.ecnCECount <= lastCECount_) {
    return;
  }
  lastCECount_ = ack.ecnCECount;
  if (recoveryState_.endOfRecovery.has_value() &&
      *recoveryState_.endOfRecovery >= ack.largestNewlyAckedPacketSentTime) {
    return;
  }
  invalidateSpuriousLossUndo();
  enterRecovery(
      ack.ackTime,
      state_ == CubicStates::Hystart ? steadyState_.reductionFactor
                                     : ecnReductionFactor,
      kCubicEcn);
}
```

Each step has a specific purpose:

| Step | Why |
|---|---|
| Return if the factor is 0 | Off by default, so existing behaviour is unchanged unless enabled |
| Return unless state is `ValidatedECN` | Ignores L4S connections, and ECN paths that are unproven or failed validation |
| Return if the CE count has not risen | The count is cumulative, so only an increase means new marks |
| Update `lastCECount_` before the RTT check | Marks seen during recovery are consumed, which removes the stale-count hazard |
| Check against `endOfRecovery` | Marks on packets sent before the last reduction belong to congestion already handled, which gives once per RTT |
| `invalidateSpuriousLossUndo()` | CE is real congestion, so a later "spurious loss" undo must not restore the larger window. The L4S path does the same |
| 0.7 in Hystart, the ECN factor otherwise | RFC 8511 does not currently recommend ABE when cwnd <= ssthresh |

### 4.4 Where it is called

```cpp
void Cubic::onPacketAcked(const AckEvent& ack) {
  auto currentCwnd = cwndBytes_;
  maybeReduceOnClassicEcn(ack);
  if (recoveryState_.endOfRecovery.has_value() &&
      *recoveryState_.endOfRecovery >= ack.largestNewlyAckedPacketSentTime) {
    ...
    return;
  }
  switch (state_) { ...
```

**Why at the top:** this single location avoids both hazards from section 3.

- It runs before the early return, so marks are never missed.
- After a reduction, `endOfRecovery` is the current time, so the same ACK takes the early return. The Hystart and Steady handlers never run for it, so the `SCOPE_EXIT` block cannot overwrite the new state.

The early return still writes a qlog metric update, so the reduced cwnd appears in the trace.

**Change from the approved plan:** the plan put the check in the existing Hystart and Steady paths, with early returns and extra `lastCECount_` updates. Reading the code showed that would fail, because `SCOPE_EXIT` runs even on an early return. The single check is simpler and leaves those handlers unmodified.

### 4.5 Resulting event flow

```text
ACK arrives
  |
  v
onPacketAckOrLoss
  |-- loss reported? --> onPacketLoss --> enterRecovery(0.7, "cubic loss")
  |
  v
onPacketAcked
  |
  v
maybeReduceOnClassicEcn
  |-- feature off, not ValidatedECN, or no new CE --> no action
  |-- new CE, packet sent before last reduction   --> update count only
  |-- new CE, packet sent after last reduction    -->
  |       Hystart: enterRecovery(0.7,  "cubic ecn")
  |       otherwise: enterRecovery(0.85, "cubic ecn")
  v
Skip the ACK if its packet predates the reduction; otherwise normal handling
```

Because loss is processed first, an ACK reporting both a loss and a CE mark gives a single 0.7 reduction.

### 4.6 Worked example

Start in congestion avoidance with cwnd = 3000 bytes:

| Event | Result |
|---|---|
| CE mark | cwnd = 3000 × 0.85 = 2550, state `FastRecovery` |
| Another CE mark on a packet sent before that cut | No change |
| Loss of a packet sent before that cut | No change |
| CE mark on a packet sent after that cut | cwnd = 2550 × 0.85 = 2167 |
| Or instead, loss of a packet sent after that cut | cwnd = 2550 × 0.7 = 1785 |

## 5. Supporting changes

### 5.1 New setting: `cubicEcnReductionFactor`

**File:** `quic/state/TransportSettings.h`

```cpp
float cubicEcnReductionFactor{0.0f};
```

**Why a single float instead of an on/off switch:** one value produces every behaviour the experiments need.

| Value | Behaviour |
|---|---|
| 0 (default) | Stock mvfst: CE does not reduce cwnd |
| 0.7 | Classic ECN: CE treated the same as loss |
| 0.85 | ABE |

**Why the default is 0:** existing users see no behaviour change, and the existing tests should be unaffected.

### 5.2 New qlog reason: `kCubicEcn`

**File:** `quic/logging/QLoggerConstants.h`

```cpp
constexpr auto kCubicEcn = "cubic ecn";
```

**Why:** the validation has to separate CE reductions from loss reductions. Without its own label, a 0.7 cut in the ABE run could not be attributed to a loss. It appears as the `trigger` field beside the existing `"cubic loss"`.

### 5.3 tperf flags

**Files:** `quic/tools/tperf/tperf.cpp`, `TperfServer.h`, `TperfServer.cpp`

| Flag | Default | Effect |
|---|---|---|
| `--enable_ecn` | false | Sets `enableEcnOnEgress` without `useL4sEcn`, so the sender marks ECT(0) |
| `--cubic_ecn_beta` | 0.0 | Sets `cubicEcnReductionFactor` |

**Why:** tperf is the traffic generator for the experiments and had no classic ECN mode (section 3). The values pass through two new `TPerfServer` constructor parameters, placed next to the existing ECN parameters.

**Why the server only:** the tperf server is the data sender. The client only has to echo marks, and the existing `--read_ecn` flag already does that, so `TperfClient` is unchanged. The plan had originally included client changes, which turned out to be unnecessary.

## 6. Unit tests

**File:** `quic/congestion_control/test/CubicSteadyTest.cpp`, in a new `CubicClassicEcnTest` fixture.

The fixture starts from cwnd = 3000 in Steady, in `ValidatedECN` state with a factor of 0.85. The existing `CMakeLists.txt` entry for this file already includes it.

| Test | What it proves |
|---|---|
| `CeInSteadyUsesEcnReductionFactor` | Core ABE behaviour: 3000 becomes 2550, state `FastRecovery` |
| `CeReductionKeepsRecoveryInvariant` | Leaving recovery after a CE cut works, with `cwnd == ssthresh` intact |
| `SecondCeInSameRttDoesNotReduce` | Once-per-RTT limit |
| `CeAfterRecoveryReducesAgain` | Persistent congestion keeps reducing: 2167 |
| `MarksSeenDuringRecoveryDoNotReduceOnExit` | Stale-count hazard is fixed |
| `LossInSameRttAsCeDoesNotReduce` | No double reduction after CE then loss |
| `LaterLossUsesLossReductionFactor` | Loss still uses 0.7: 1785 |
| `LossReportedWithCeReducesOnce` | Loss and CE in one ACK give one 0.7 cut: 2100 |
| `CeInHystartUsesLossReductionFactor` | Slow start uses 0.7: 2000 becomes 1400 |
| `DisabledByDefault` | Factor 0 leaves stock behaviour |
| `IgnoredUntilEcnIsValidated` | No response during `AttemptingECN` |
| `DoesNotApplyToL4s` | L4S connections are unaffected |

The `sendAfterReduction` helper sleeps for 1 ms before sending, so the packet's sent time is genuinely later than the reduction. Real packets are never dated in the future, and a future timestamp would have made the tests timing-dependent.

## 7. Experiment scripts

All three are in `~/mvfst/experiments/`.

### `topology.sh`: dumbbell testbed

```text
server --- r1 ===bottleneck=== r2 --- client
```

| Choice | Value | Why |
|---|---|---|
| Namespaces | `abe-server`, `abe-r1`, `abe-r2`, `abe-client` | Matches the brief's Linux netns dumbbell |
| Bottleneck rate | 100 Mbit via `htb` on r1, towards r2 | Data flows server to client |
| AQM | `fq_codel`, with `ecn` or `noecn` | Same AQM in each arm, so only ECN differs |
| RTT | 40 ms via `netem` on separate interfaces | Keeps delay out of the AQM's qdisc |
| Offloads | TSO, GSO and GRO off | Lets the qdisc see real packets |

The bandwidth-delay product is about 370 packets, large enough to show the cubic curve instead of the Reno-friendly region.

### `run_arms.sh`: experiment runner

Runs each arm for a default of 5 runs of 120 s each, saving qlogs, logs and qdisc statistics to `results/arm-<X>/run-<N>/`.

| Arm | AQM | Sender flags | Purpose |
|---|---|---|---|
| A | `noecn` | ECN off, beta 0 | Step 4 baseline |
| B | `ecn` | ECN on, beta 0 | Step 5 as written |
| C | `ecn` | ECN on, beta 0.7 | Classic ECN comparison |
| D | `ecn` | ECN on, beta 0.85 | ABE, step 8 |

**Why arm C was added:** the brief compares ABE against "ECN enabled". In stock mvfst that means CE is ignored (arm B), which reflects a missing feature rather than a larger beta. Comparing C with D isolates the effect of ABE.

### `plot_cwnd.py`: plots and validation

Produces `cwnd.png`, with one panel per arm, and `reductions.csv`, listing cwnd before and after every reduction and its trigger. It also prints the median, minimum and maximum ratio per arm and trigger.

Events are matched on their `congestion_window` and `trigger` data fields, because qlog event names vary by version. `time` is read in milliseconds, as written by `QLoggerTypes.cpp`.

### Expected results (D compared with C)

| Check | Expected |
|---|---|
| Cut at each CE event | Ratio about 0.85 vs about 0.70 |
| Sawtooth | Shallower |
| Recovery time K | About 5.2 s vs 6.5 s |
| Throughput | Higher in D |
| Queue delay | Comparable, as CoDel still enforces its target |
| Arm A | Reductions of about 0.7 on loss |
| Arm B | cwnd keeps growing through CE marks until a drop |

K comes from K = cbrt(W_max × (1 − beta) / C), with W_max = 370 packets and C = 0.4. These figures apply only to a cut made at or above W_max. A cut below W_max in arm D gives K = 0, as explained in section 8.

Arm D will not show 0.85 on every `cubic ecn` row. The first CE mark normally arrives in slow start, where the code deliberately uses 0.7, so expect one 0.7 `ecn` cut near the start of each run. Any later 0.7 cut should be labelled `loss`.

## 8. Known limitations

- **Most important: fast convergence removes the plateau on some ABE cuts.** `lastMaxReductionFactor` is unchanged at 0.85, which equals the ABE factor. When a CE cut happens below W_max, both new values come out the same: W_max = 0.85 × cwnd and new cwnd = 0.85 × cwnd. `updateTimeToOrigin` then sees no gap and sets K = 0, so that cycle has no concave phase and no plateau. Loss is unaffected, because its 0.7 cut leaves a gap to the 0.85 W_max. This is likely to appear when marks persist across consecutive RTTs, and it would change the shape of the arm D graph.
  - RFC 9438 defines this value as (1 + beta) / 2, which is 0.85 for beta 0.7 but 0.925 for beta 0.85.
  - A likely fix is to compute it from `reductionFactor` in `cubicReduction`. That keeps loss behaviour identical and gives K of about 4.1 s at W_max = 370 packets.
  - This fix is **not applied**. RFC 9438 also says fast convergence SHOULD be disabled for a single flow, as in these experiments, and mvfst has no setting for that.
- **`tcpEstimationIncreaseFactor` still derives from 0.7.** It is 0.529, while the same formula with beta 0.85 gives 0.243, so after a CE cut the Reno-friendly estimate grows about 2.2 times faster than it should. The code uses `max(cwnd, estRenoCwnd)`, so this can make ABE more aggressive, mainly at low bandwidth-delay products.
- **CE counts are not tracked per packet number space.** RFC 9002 keeps one counter per space, while mvfst's existing `lastCECount_` is a single value. This should have little effect, as handshake traffic is brief.
- **Marks consumed without a cut do not cancel a spurious-loss undo.** If marks arrive during a loss recovery and that loss is later found to be spurious, the undo still restores the larger window.
- **neqo comparison is incomplete.** Only a summary of PR #3233 was reviewed, not its source. The first two items above should be compared against it.
- **Reduction is based on cwnd, not FlightSize.** RFC 8511 defines it from FlightSize, whereas mvfst's existing reduction uses cwnd. The new code stays consistent with mvfst, which should be noted in the report.
- **Slow-start use of 0.7 is a conservative choice.** RFC 8511 leaves this area open for further experimentation.
- **CE before validation is ignored.** Marks that arrive before `ValidatedECN` cause no reduction. Validation needs 10 acknowledged packets, so this window is short.
- **The qlog "old state" field is always `Steady`.** This is existing behaviour carried over from the loss path, so that field is not reliable. The `trigger` field is the one used.
- **Mobile builds may warn about unused `reason`.** `QLOG` compiles to nothing there. It is harmless and outside this project's scope.

## 9. Remaining steps

1. Build mvfst with `BUILD_TOOLS=ON`, using `--src-dir=.` so the local edits are compiled.
2. Run the unit tests and fix anything found, since this is the first compilation.
3. Run `run_arms.sh` as root.
4. Confirm `ecn_mark` is nonzero in `qdisc.txt` for arms B, C and D. If it is zero, ECN was not tested in those runs.
5. Run `plot_cwnd.py` and compare the results with section 7.

## 10. Files changed

| File | Change |
|---|---|
| `quic/congestion_control/QuicCubic.cpp` | CE response, `enterRecovery`, factor parameter |
| `quic/congestion_control/QuicCubic.h` | New declarations |
| `quic/congestion_control/test/CubicSteadyTest.cpp` | 12 new tests |
| `quic/logging/QLoggerConstants.h` | `kCubicEcn` |
| `quic/state/TransportSettings.h` | `cubicEcnReductionFactor` |
| `quic/tools/tperf/tperf.cpp` | New flags |
| `quic/tools/tperf/TperfServer.h`, `TperfServer.cpp` | Flag wiring |
| `experiments/topology.sh` | New: testbed |
| `experiments/run_arms.sh` | New: experiment runner |
| `experiments/plot_cwnd.py` | New: plots and analysis |

## 11. In-depth rationale for every change

Each entry covers the problem, what would go wrong without the change, why this design was chosen, and what it costs.

The new CE logic is not a new idea. RFC 9002 (Appendix B) specifies the same structure for QUIC:

```text
ProcessECN(ack, pn_space):
  if (ack.ce_counter > ecn_ce_counters[pn_space]):
    ecn_ce_counters[pn_space] = ack.ce_counter
    sent_time = sent_packets[ack.largest_acked].time_sent
    OnCongestionEvent(sent_time)
```

`OnCongestionEvent` does nothing if `sent_time` falls inside the current recovery period. `maybeReduceOnClassicEcn` follows those steps, with ABE's factor as the one difference. Following the standard algorithm was preferred over inventing a new one.

### 11.1 `cubicReduction` takes a factor

**Problem.** The reduction was hard-wired to `steadyState_.reductionFactor`, so the function could only ever apply the loss factor.

**Without it.** The only ways to apply 0.85 would be to change the shared factor, or to duplicate the function:

- Changing `steadyState_.reductionFactor` to 0.85 would also change the loss response, which RFC 8511 forbids.
- Temporarily swapping the value around a call would be fragile and hard to read.
- A separate copy would need to keep W_max, `lastReductionTime`, `estRenoCwnd` and the cwnd bounds in step with the original.

**Why this design.** The factor is the only thing that differs between the two kinds of reduction, so making it the only parameter states that directly. The rename from `lossTime` to `reductionTime` stops the name being wrong: for CE it receives the ACK time.

**Why the ACK time for CE.** A CE mark has no loss time, and the sender learns of the congestion when the ACK arrives. `lastReductionTime` is the zero point of the cubic curve, and `calculateCubicCwndDelta` measures from it.

**What it does not need.** K did not have to change. `updateTimeToOrigin` calculates K from the actual gap between W_max and cwnd, not from a fixed beta, so a shallower cut gives a shorter K automatically. This is why ABE needs so little change to the curve itself.

**Cost.** W_max handling is shared too, which is the source of the fast-convergence problem in section 8.

### 11.2 `enterRecovery` extracted from `onPacketLoss`

**Problem.** The steps that begin a recovery period were inside `onPacketLoss`, so CE handling could not use them.

**Without it.** Each step is needed by a CE cut, and each has its own failure if missed:

| Step | What goes wrong if a CE cut skips it |
|---|---|
| Set `endOfRecovery` | No once-per-RTT limit: every ACK with new marks cuts again, collapsing cwnd within one RTT |
| Move to `FastRecovery` | The cubic curve is not recalculated from the new cwnd by the recovery-exit path |
| `ssthresh_ = cwndBytes_` | The check `MVCHECK_EQ(cwndBytes_, ssthresh_)` in `onPacketAckedInRecovery` fails and aborts the process |
| Refresh the pacer | The sender keeps pacing at the old rate. The early return in `onPacketAcked` skips the usual refresh, so this one is essential |
| Write qlog | The reduction is invisible to the analysis |

**Why a shared function.** Two copies of this sequence could drift apart without any test noticing. A single function guarantees that CE and loss recovery behave the same apart from the factor and label.

**Why not reuse the existing L4S path.** `onEcnCongestionEvent` handles frequent, small L4S reductions, and its design does not suit classic ECN:

- It sets W_max to the reduced cwnd and K to 0, forgetting the previous operating point. CUBIC's plateau depends on remembering that point.
- It scales the cut by the L4S mark fraction from `EcnL4sTracker`, which is not what ABE specifies.
- It does not enter recovery.

Sharing the classic path also means ABE cuts follow the same recovery rules as loss cuts, which keeps the two comparable in the graphs.

**Cost.** During recovery the pacing gain is 1.25 and cwnd does not grow, so a CE cut inherits loss-style behaviour for about one RTT. That is intended, and it matches RFC 9002's treatment of a CE increase as entering recovery.

### 11.3 `maybeReduceOnClassicEcn`, step by step

**Problem.** Nothing responded to CE marks when ECN was classic rather than L4S, so an AQM could only slow a sender by dropping packets.

**Why a new function instead of extending `onEcnCongestionEvent`.** The existing function is only called from the Hystart and Steady handlers. It cannot see marks in recovery, and it runs too late to avoid the Hystart exit block. Keeping classic logic separate also leaves the L4S path exactly as it was.

#### Guard: factor must be above 0

The feature stays off unless requested, so any other mvfst user sees no change. This is the usual expectation for a change to a shared library, and it is also what allows arm B to measure stock behaviour with the same binary.

#### Guard: state must be `ValidatedECN`

This check does two jobs:

- **It excludes L4S.** L4S connections are `ValidatedL4S` and have their own response, and running both would reduce twice for the same marks. L4S also marks far more often, so a 0.85 cut per RTT would be badly wrong there.
- **It requires validated ECN.** Validation confirms that the path and peer report ECN consistently. RFC 9002 applies its ECN response on a path "validated to support" ECN, and acting on unproven counts could cut cwnd on bad data.

The cost is that marks before validation are ignored. Validation needs 10 acknowledged packets, so this window is short.

#### Guard: CE count must have risen

ACK frames carry a cumulative count, not "new marks since the last ACK". Every ACK after the first mark has a nonzero count, so testing for nonzero would cut on every ACK. Only an increase means something new happened.

#### Update `lastCECount_` before the RTT check

This ordering is what removes the stale-count hazard. If the update came after the check, marks arriving during recovery would be left unrecorded and the first ACK after recovery would see an apparent increase. The sender would then cut a second time for congestion it had already handled. RFC 9002 uses the same order.

#### Once-per-RTT check against `endOfRecovery`

An ACK's marks describe the network when those packets passed through it. If the packet was sent before the last reduction, its mark reflects the sending rate before that reduction, so it says nothing about whether the cut was enough.

Comparing sent time against the last reduction is how RFC 9002 defines this, and it has two benefits over a timer:

- No RTT estimate is needed.
- It adapts to the actual path delay.

It also delivers RFC 8511's "keep reducing while congestion persists". Packets sent after the cut can trigger another cut, about one RTT later.

The same check also protects the opposite order, because `onPacketLoss` uses the same `endOfRecovery`: a loss of a packet sent before a CE cut does not cut again.

#### `invalidateSpuriousLossUndo()`

mvfst can undo a loss reduction if the "lost" packet is later acknowledged, and this feature is on by default (`enableSpuriousLossRecovery{true}`). `undoSpuriousLoss` restores the earlier cwnd and `endOfRecovery`.

Without this call, the following could happen:

1. A loss cuts cwnd from 3000 to 2100 and records 3000 for a possible undo.
2. A CE mark cuts cwnd to 1785.
3. The "lost" packet turns up, so the undo raises cwnd to 3000.

That would erase a genuine congestion signal. A CE mark is proof of congestion even when the loss was not, so the stored undo must be discarded. The L4S path does the same.

#### Choosing the factor

```cpp
state_ == CubicStates::Hystart ? steadyState_.reductionFactor
                               : ecnReductionFactor
```

RFC 8511 does not currently recommend ABE when cwnd <= ssthresh, which is slow start. In slow start cwnd doubles each RTT and can far overshoot, so a gentle cut risks leaving a large queue.

The check uses the state instead of comparing cwnd and ssthresh literally. mvfst keeps `cwndBytes_ == ssthresh_` throughout recovery, so a literal comparison would choose 0.7 for a CE cut arriving at the end of recovery. Persistent congestion would then get the wrong factor. Using the state captures what the RFC means, which is slow start.

### 11.4 Calling it at the top of `onPacketAcked`

**Problem.** The check needs to see every ACK, and a reduction must not be disturbed by the later handlers.

**Why not the Steady and Hystart handlers.** That was the original plan, and reading the code ruled it out:

- **They do not see every ACK.** The early return for pre-recovery packets, and `onPacketAckedInRecovery`, never reach them.
- **Hystart undoes the cut.** Its `SCOPE_EXIT` runs however the function returns. If `hystartState_.found` is set, the block forces `state_ = Steady` and clears `lastMaxCwndBytes`, cancelling recovery while cwnd stays reduced.
- **Steady assumes growth.** Its code carries the comment "From here on, the cwnd can only increase", which a mid-function reduction would break.

**Why the top works.** After a reduction, `endOfRecovery` holds the current time, which is later than the ACKed packet's sent time. The early return that follows then fires by itself, with no extra branches. That return already writes a qlog metric update, so the graph still records the new cwnd.

**Why after loss.** `onPacketAckOrLoss` processes loss first. If one ACK reports both, the loss cut happens and CE is then skipped by the same check. The outcome is a single 0.7 cut, the safer choice when both signals appear together.

**Why `onPacketAcked` rather than `onPacketAckOrLoss`.** `onPacketAcked` only runs when an ACK newly acknowledges a packet, which guarantees `largestNewlyAckedPacketSentTime` is meaningful.

### 11.5 `cubicEcnReductionFactor` setting

**Problem.** The factor has to be chosen per connection and changed without recompiling.

**Why a transport setting.** `ccaConfig` is where mvfst keeps CUBIC tuning, including the neighbouring `l4sCETarget`. Applications already pass it in, and `Cubic` can read it directly through `conn_`, so the constructor and `CongestionControllerFactory` stay unchanged.

**Why a float rather than a bool.** A bool would need a separate way to run the classic 0.7 arm. The float gives every experiment arm from one binary, so the only difference between runs is one flag value. That removes rebuilds as a source of experimental difference.

**Why not change `kDefaultCubicReductionFactor`.** That constant is used for the loss response and to derive `kCubicTCPFriendlyEstimateIncreaseFactor`, so it cannot change without altering loss behaviour.

**Cost.** Values are not range-checked. A value of 1 or above would give no reduction or would grow cwnd on congestion. This is acceptable for an experiment, but a range check should be added before proposing this upstream.

### 11.6 `kCubicEcn` qlog reason

**Problem.** Step 9 needs proof that each reduction used the right factor, and a cwnd graph alone cannot show why a cut happened.

**Without it.** A 0.7 cut in the ABE arm would be ambiguous: it could be a real loss or a bug that applied the wrong factor. The two can only be told apart if the trace records the cause.

**Why a string constant.** It follows the existing `kCubicLoss` convention and reuses the `trigger` field already in qlog, so no qlog format change is needed.

### 11.7 tperf `--enable_ecn`

**Problem.** Steps 5, 8 and 9 all need a classic ECN sender, and tperf could only enable ECN together with L4S.

**Why not reuse `--use_l4s_ecn`.** That flag sends ECT(1) instead of ECT(0), and also turns on `onlyGrowCwndWhenLimited` and `leaveHeadroomForCwndLimited`. It would be a different experiment.

**Why `if (enableEcn_)` rather than a direct assignment.** Writing `settings.enableEcnOnEgress = enableEcn_` would switch ECN off when only `--use_l4s_ecn` was given, because that line runs after the L4S block. The `if` leaves L4S working as before. If both flags are given, L4S wins, because `useL4sEcn` selects ECT(1).

### 11.8 tperf `--cubic_ecn_beta`

**Problem.** Experiment scripts need to set the factor from the command line.

**Why a double converted to float.** gflags has no float flag type, so `DEFINE_double` plus `static_cast<float>` is the standard approach.

**Why constructor parameters.** tperf's other options all reach `TPerfServer` through its constructor. Following that pattern is more verbose but keeps the code consistent. The new parameters are next to the ECN ones, and the matching member order avoids `-Wreorder` warnings.

**Why it is applied unconditionally.** The default of 0 already means "off", so an extra `if` would add nothing.

### 11.9 Server-only tperf changes

**Problem.** The plan had included client changes, but reading tperf showed the data flow runs the other way from what the names suggest.

**Why the server only.** In tperf the server sends data, so its cwnd is the one being measured. The client must report marks back, and `--read_ecn` already does this. Validation also only looks at the counts the sender receives, so marking ACKs with ECT(0) would add nothing. Leaving `TperfClient` alone removes changes with no purpose.

### 11.10 Unit tests

**Problem.** The experiments show aggregate behaviour, but rare orderings like "loss and CE in one ACK" may never appear in a run, and a bug there could look like network noise.

**Why these tests.** Each exists because a specific mistake is plausible:

| Test group | Mistake it would catch |
|---|---|
| Core factor | Applying 0.7, or the wrong state |
| Recovery invariant | A crash on the `MVCHECK_EQ` in recovery |
| Same-RTT and recovery-exit tests | Repeated cuts, or the stale-count hazard |
| Persistent congestion | Over-correcting so that only one cut ever happens |
| Loss interaction | Double cuts, or the loss factor changing |
| Hystart | Using ABE in slow start, or `SCOPE_EXIT` overriding recovery |
| Disabled, unvalidated, L4S | Changing behaviour for anyone who did not opt in |

**Why a fixture in `CubicSteadyTest.cpp`.** The file is already registered in CMake and tests the same behaviour, and the fixture removes repeated setup across 12 tests.

**Why exact cwnd values.** Asserting 2550 instead of "less than 3000" separates 0.85 from 0.7. A loose check would pass with the wrong factor.

**Why real time passes in `sendAfterReduction`.** `endOfRecovery` uses the real clock, so a packet must really be sent later. An artificial future timestamp can fall after a following reduction, which never happens in practice and would make the tests timing-dependent.

### 11.11 `topology.sh`

| Decision | Reason |
|---|---|
| Four namespaces with two routers | Gives a true bottleneck link, as the brief's dumbbell requires, with the AQM on a router instead of an endpoint |
| `htb` rate limit | veth has no natural speed limit, so a bottleneck must be created for a queue to form |
| `fq_codel` as the AQM | RFC 8511 was motivated by CoDel-style AQMs that keep queues short, and the module is already loaded here. With a single flow it behaves like CoDel |
| Same AQM for `ecn` and `noecn` | With a different AQM in the no-ECN arm, a change in the graph could come from either difference |
| `netem` on separate interfaces | CoDel measures time spent in its queue. Inside the same qdisc tree, fixed delay would look like a standing queue and cause constant marking |
| 100 Mbit and 40 ms | About 370 packets of BDP. A small BDP would put CUBIC in its Reno-friendly region and hide the curve |
| Large `netem` limit | Stops `netem` dropping packets, so the only drops come from the AQM |
| Offloads off | Packets stay at real size, so the AQM and `tcpdump` see what was actually sent |
| Script requires root | Network namespaces and `tc` need root privileges |

### 11.12 `run_arms.sh`

| Decision | Reason |
|---|---|
| Four arms | A and B match the brief's steps 4 and 5, and C gives the fair comparison with D |
| Same binary for all | Only flags and the AQM's ECN mode differ |
| 5 runs each | One run cannot show whether a difference is real or chance |
| 120 s per run | Covers many sawtooth cycles of about 5 to 6 s, after startup has passed |
| Rebuild topology per run | Clears queues and qdisc counters, so one run cannot affect the next |
| Save `qdisc.txt` | Proves marks actually happened. Without marks, an "ECN" arm would really be testing nothing |
| `trap` cleanup | Removes namespaces and the server even if a run fails, so a failed run does not break the next |

### 11.13 `plot_cwnd.py`

| Decision | Reason |
|---|---|
| Read cwnd from qlog | It records the sender's actual cwnd, which packet captures can only estimate |
| One panel per arm | Sawtooth shapes are hard to compare when overlaid |
| Plot one run per arm | Overlaying five runs would hide the sawtooth |
| Use all runs for ratios | Statistics benefit from every event, unlike the plot |
| Output `reductions.csv` | Step 9 asks for validation, and numbers are stronger evidence than judging a graph by eye |
| Group ratios by trigger | Keeps CE cuts and loss cuts apart, using `kCubicEcn` |
| Match on data fields | qlog event names vary by version, while `congestion_window` and `trigger` are fixed in `QLoggerTypes.cpp` |
| Stop with an error if no cwnd is found | A silent empty graph could be mistaken for a result |
