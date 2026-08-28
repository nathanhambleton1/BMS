# BMS and charger blocks for a Simulink battery model

Two blocks you can drop into a pack built with the Simulink Battery Model
Builder, plus a UI that configures them.

**BMS** — reads the per-cell voltage, SOC and current arrays your battery model
already exports, and produces the watts your dynamic-load block should draw. The
load waveform (off, constant, sine, pulse) is configured in the UI. It also does
protection, and it decides when the charger is allowed to run.

**Charger** — a CC/CV charger whose parameters are auto-filled from your cell and
your series/parallel counts. CC and CV are not modes you select; the handover is
automatic because it is not a decision — it is which constraint is binding.

**The load always wins.** The BMS revokes the charger's permission the moment the
load becomes active, and charging happens in the gaps between load activity.
That is the point of the arbitration: the load is the thing under test and the
charge is housekeeping.

## Start

```matlab
run('START_HERE.m')     % path, checks, tests, UI
```

Then, in the window: **Pack** tab, **Load** tab, **Auto-fill all**, **Check
config**. On the **Install** tab, press **Build test harness** and **Simulate
harness** — that runs the same two blocks against a crude battery stand-in in
about a second, with no Simscape licence, so you can get the behaviour right
before touching the model you care about.

When it behaves, follow [docs/INSTALL.md](docs/INSTALL.md).

## Documentation

| If you want to... | Read |
|---|---|
| install the blocks into your battery model, step by step | [docs/INSTALL.md](docs/INSTALL.md) |
| know what every port and signal means | [docs/blocks.md](docs/blocks.md) |
| fix an error, or a run that looks wrong | [docs/troubleshooting.md](docs/troubleshooting.md) |
| understand a fault mask like 5 or 10 | [Reading `faults`](#reading-faults-5-and-10-are-sums-not-codes) |
| work out why the load is being derated, or why a fault keeps re-tripping | [The four protection mechanisms](#the-four-protection-mechanisms-and-what-each-one-is-for) |
| work out why SOC went negative | [Negative SOC](#negative-soc-is-the-battery-model-not-the-bms) |

## Four things that will bite you, and where they are handled

**Algebraic loops.** The BMS reads the pack voltage and current that its own load
command determines. Wired directly, that is an algebraic loop, and Simulink
either refuses to compile or solves it iteratively at every step. Both blocks
carry a Unit Delay on every measurement input, *inside* the block — because a
delay you have to remember to add outside is a delay someone forgets. One sample
of sensor delay is also the honest model: a real BMS acts on the previous
conversion, never on the present instant.

`tBcpBuild/unitDelaysAreWhatMakeItSolvable` builds the same model twice, with the
delays off and on, and asserts the first fails and the second runs.

**Sample times.** Both blocks run at an explicit discrete rate, and with a
fixed-step solver that rate must be an exact integer multiple of the model's
fundamental step. A Simscape local solver is a third, independent clock.
`bcp.Rate.audit` reports all three and says which number to change;
`bcp.Rate.align` fixes the `FixedStep` case and touches nothing else.

Neither block will accept an inherited rate. Both hold persistent state — dwell
timers, PI integrators, latches — and every one of them multiplies by `Ts` to
turn samples into seconds. Inherited, a "0.5 second" trip confirmation becomes
however long 50 arbitrary solver steps happen to take, and the block runs, logs
plausible traces, and times everything wrong.

**Array layout and sign conventions.** Whether your battery model's arrays are
one entry per cell or one per series element is a build option, and nothing can
tell you which before a compile. `p.verifyWiring(model)` compiles and reports
it. The BMS computes pack voltage as `mean(V)*S` and pack current as `sum(I)/S`,
which are correct for both layouts — so it does not need to know, but `S` does
need to count the same thing the array counts.

Simscape Battery components — everything Battery Model Builder generates
included — declare their cell current *positive in*, which is positive while
**charging**. This package is charge-positive throughout, so the two conventions
already agree and `I_sign` defaults to `+1`. It is the single place a model with
the opposite polarity gets converted. Check it once: pack current must read
negative while the load is running.

**A trip is not an operating limit, and using it as one oscillates.** A
constant-power load is positive feedback — `I = P/V`, so the current *rises* as
the voltage it caused *falls* — and a binary trip on positive feedback is a
bang-bang loop that removes its own trigger. Near the end of a discharge:

```text
sag under V_uv_trip  ->  UV latches, dch_ok drops  ->  load command goes to 0
   ->  the sag disappears, because the sag WAS the load
   ->  the pack reads inside the clear band, so the fault recovers
   ->  full load slams back on  ->  a DEEPER sag: lower SOC, higher R0
```

Each lap costs charge and returns almost none, so the excursions **grow** and end
up well below the threshold that was supposed to prevent them. No threshold and
no dwell fixes it, because the trip is what makes it stop being true.

So the discharge gets a **continuous limit in front of the trip** — the discharge
current/power limit a production BMS publishes on CAN as DCL, and which the
inverter is required to obey. Protection goes back to being the backstop it was
always meant to be. Measured on the bundled 195S1P pack, 31250 W pulses from 8%
SOC, 300 s:

| | fault rising edges | lowest cell | lowest `dcl_frac` | lockout |
|---|---|---|---|---|
| limiter off | **4** | 2.3896 V | 1.000 | latched |
| limiter on | **0** | 2.4033 V (one 10 ms sample) | 0.728 | never |

With the limiter on, pulse 1 finds the operating point and pulses 2–15 are
regulated to 2.5798 V — the bottom of the foldback band, 80 mV above the trip —
every time. `tBcpBuild/aRecoveredFaultDoesNotChatterBackAndForth` asserts the
edge count, because `max(faults)` cannot see this failure: a run that tripped
once and a run that cycled thirty times report the same maximum.

Full argument in [docs/blocks.md](docs/blocks.md#discharge-limiting-and-why-the-trip-is-not-the-operating-limit)
and `alg/bcp_load_limiter.m`.

## What is modeled

- Load demand as off / constant / sine / pulse, with a start-stop window, power
  clamps, an idle threshold that defines "the load is active", and a slew limit
  that does two jobs: it turns each pulse edge into a ramp the Simscape solver
  can walk across, and it gives the discharge limiter enough samples to react
  before the pack arrives at full demand
- Per-cell arrays reduced to pack scalars, layout-agnostic
- Dwell-confirmed, latching protection with hysteresis recovery: over- and
  under-voltage, over-current in both directions, over- and under-temperature
- **Two-tier over-current per direction** — the cell's continuous rating
  confirmed over a long dwell and its pulse rating over a short one, because one
  threshold cannot honour both: set it at the continuous rating and every pulse
  the pack was built for trips protection; set it at the pulse rating and a
  sustained over-draw runs forever
- **Directional inhibits** — over-voltage stops charging and leaves the discharge
  open, because the load is the cure; only over-current and over-temperature
  isolate the pack
- **Continuous discharge limiting** (`alg/bcp_load_limiter.m`) — the load is
  derated smoothly as the cells approach their cutoff, so protection stays a
  backstop instead of doing the regulating. A rate-limited integrator with a
  deadband rather than a formula, because the loop gain of `frac = f(V_min)` goes
  to infinity as a constant-power draw approaches the pack's maximum power point
- **Recovery that cannot re-trip** — an under-voltage latch clears only after a
  real charge and not a rest, every automatic recovery costs a longer dwell than
  the last, and after enough retries auto-recovery is withdrawn and the BMS waits
  for a reset
- Load-first arbitration with a configurable quiet dwell, SOC stop/restart
  hysteresis, a voltage re-arm threshold, and an opt-in concurrent-charging mode
- Precharge / CC / CV charging with automatic handover, a CV loop that regulates
  the **highest cell** rather than the pack average, per-loop tracking
  anti-windup for a bumpless handover, a hysteresis band and minimum dwell on
  the reported mode, and dwell-confirmed taper termination keyed off the physics
  rather than off the mode
- **One number sets the charge rate.** `Bms.I_chg_max_A` is published to the
  charger every sample; both charge over-current trips are derived from it, and
  the charger's own settings are the *supply's* ratings. `p.setChargeCurrent(A)`
  moves all of them together
- Charge-parameter auto-fill from a cell datasheet plus S and P, including loop
  gains derived from the pack resistance
- Cell-to-cell variation (`bcp.CellVariation`) written into any Simscape battery
  pack in any model — initial SOC, capacity and resistance, seeded and exactly
  revertible
- A test harness with a resistive battery stand-in, for proving the blocks
  without a Simscape licence

## The four protection mechanisms, and what each one is for

These are the settings on the **BMS** tab under *Fault handling* and *Discharge
limiting*. All four are on by default. Each closes a different escape route out
of the cycle in the previous section, and it is worth knowing which is which
before turning any of them off.

| # | Mechanism | Settings | Without it |
|---|---|---|---|
| 1 | continuous discharge foldback | `UseLoadLimiter`, `V_fold_margin_V`, `V_fold_band_V`, `I_fold_frac`, `Fold_Fall_per_s`, `Fold_Rise_per_s` | the trip is the operating limit, and it cycles |
| 2 | soft-start on re-engagement | `t_softstart_s` | the load slams back on after a recovery and goes straight back under |
| 3 | under-voltage clears only on charge | `Q_uv_reset_Ah` | recovery on a rest, which gained no energy — the cell is still at end of discharge |
| 4 | retry backoff, then lockout | `Retry_Backoff_x`, `t_recover_max_s`, `t_retry_window_s`, `N_retry_max` | any surviving cycle runs for the whole simulation |

**1 is the main one.** The limiter regulates the lowest cell into a band just
above `V_uv_trip` — 2.580 to 2.780 V by default for a 2.50 V cutoff — and holds
it there, delivering whatever the pack can rather than demanding what it cannot.
Two of its properties look like bugs until they are explained:

- *The limit only reopens while current is flowing* (`Fold_Learn_frac`). At rest
  the lowest cell relaxes to OCV, far above the band — but an open-circuit
  voltage is not evidence the pack can deliver power; it is precisely the
  measurement that misled the bang-bang trip. Load counts as evidence, charge
  counts as evidence, rest does not.
- *An inhibit freezes the limit rather than resetting it.* The pre-trip limit was
  demonstrably too high, and that is the one useful thing the failed attempt
  established.

**It is feedback, not prediction.** The limiter cannot derate a demand it has not
yet seen at this state of charge, so the *first* large pulse at a new operating
point reaches the pack's real equilibrium voltage before the limit closes. On the
bundled pack that excursion lasts one 10 ms sample — fifty times shorter than
`t_v_trip`, so it cannot latch — and every pulse after it is regulated exactly.
Lengthen the load edge or widen `V_fold_band_V` if you need the first one
suppressed too.

**Two samples of loop latency, so give a big pulse load a slew rate.** The
measurement arrives through the BMS's input unit delay, and the command can only
change on the following sample. A *step* edge therefore reaches full demand before
the limiter has responded to any part of it, whatever `Fold_Fall_per_s` is set to.
Four samples of ramp is the minimum. `bcp.Project.check()` raises it when the peak
demand exceeds half the pack's continuous discharge rating, and stays quiet when
it does not — a step edge on a small load relative to the pack is harmless.

**3 has a consequence worth knowing before you hit it.** On a load-only run
(`ChargeEnabled` false, or no charger wired) the under-voltage latch is
**permanent**: the first under-voltage event ends the discharge for the rest of the
run. That is the correct end of a discharge test, since the pack is empty, but it
does mean no more load current from that moment. `p.check()` warns before you
build, and `Q_uv_reset_Ah = 0` restores the old rest-is-enough behaviour.

`UseLoadLimiter = false` restores the pre-limiter behaviour bit for bit, for
reproducing an earlier result. `pulse195_model('LimiterOn', false)` and
`pulse195_harness('LimiterOn', false)` do it for the bundled test, and stage 4 of
`RUN_PULSE_TEST.m` runs both sides and prints the comparison. Stage 4 uses the
fast stand-in plant, so its voltages differ from the Simscape numbers above by a
few tens of millivolts; the fault-edge counts are the same, 4 against 0, which is
the part that is about the control law rather than about the cell model.

## Reading `faults`: 5 and 10 are sums, not codes

`faults` is a **bitmask**, so simultaneous faults add. The two combinations that
come up constantly, and are in no list of fault codes because they are not codes:

```text
 5 = 4 + 1 = OC_charge    + OV
10 = 8 + 2 = OC_discharge + UV
```

**Seeing `4` and then `5`, or `8` and then `10`, is one physical event rather than
a state machine moving on.** An over-current confirms in `t_i_trip` (0.1 s by
default) and a voltage fault in `t_v_trip` (0.5 s), so an over-current large
enough to also breach the voltage window shows the current bit **first, alone**,
and picks up the voltage bit about 0.4 s later. A second, slower confirmation
completed; nothing else changed.

On a discharge, `10` reads as *the over-draw was well past what the pack could
deliver at that state of charge*. `12` (`4 + 8`, over-current in both directions
at once) is different in kind: no load does that, and it means `I_sign` is wrong
or the current array is miswired.

```matlab
bcp.Signals.faultBits(10)     % 'UV + OC_discharge'
bcp.Signals.faultTable()      % every mask a run is likely to show, decoded
```

`state` has a sixth value for the same reason people ask about `faults`: **5 is
LOCKOUT** — a fault is latched *and* auto-recovery has been withdrawn, so only a
reset edge will clear it.

## Negative SOC is the battery model, not the BMS

A Simscape `table_battery` — what the Battery Model Builder generates, and what
`+Batteries/` contains — computes state of charge as a plain integral of cell
current over the **rated** capacity:

```text
socCell(t) = socCell(0) + integral(i dt) / (3600 * AH)
```

There is no floor on that integrator. Take out more coulombs than the rated
capacity holds and SOC goes below zero, and the component neither clamps nor
complains. What it *does* clamp is the **tables**: the generated component sets
`extrapolation_option = nearest`, so below `SOC = 0` the OCV and R0 lookups hold
their `SOC = 0` values instead of extrapolating.

Which explains the shape of what you see. Past empty the cell keeps its
end-of-table OCV — 3.172 V for the bundled P45B tables — and its end-of-table
resistance, so it goes on sourcing current forever at a plausible-looking voltage
while SOC drifts negative. **The pack model has no concept of being empty.** The
only thing that stops a discharge is the under-voltage trip, and if that trip
keeps clearing, nothing does — which is the other half of why the previous
section matters.

`Bms.SOC_clamp`, on by default, limits the SOC the BMS *reports* to 0–1. Every
SOC comparison in this package (`SOC_stop`, `SOC_restart`, the arbiter's
completion latch) is written against a 0–1 quantity, so the clamp is load-bearing
rather than cosmetic. The unclamped minimum is still published on `diag(17)`
(`soc_raw_min`) so the excursion is visible rather than absorbed, and
`pulse195_verify` checks it explicitly.

How to read it:

- **A fraction of a percent negative** is coulomb-counting overshoot against a
  capacity that is rated rather than measured. Normal, and not worth chasing.
- **A sustained negative reading** means the run kept discharging a pack the model
  was no longer modelling. Everything after that point describes nothing — treat
  it as the end of the useful part of the run, not as a BMS fault.

## Accuracy limits — read before quoting results

The bundled Molicel entries (P45B, P50B, P42A) carry datasheet capacity, cutoff
voltages and current limits, which are as good as the datasheet. **The resistance
values are datasheet impedance figures, not pulse measurements of your cells** —
DC pulse resistance typically runs 30–50% above the 1 kHz AC value.

That barely affects charge-parameter auto-fill, which derives from the cutoffs
and the capacity. It matters a great deal if you use the model to predict voltage
sag under a pulse load. Measure your own cells before treating sag as design
evidence.

**There is no thermal model.** With the temperature input off, the BMS holds
25 °C and the over/under-temperature paths are present and demonstrably inert
rather than pretending. That is why auto-fill defaults the charge *rate* to the
datasheet standard charge and never to the maximum: maxima are qualified by a
cell-temperature cutoff this package cannot enforce until a real temperature
signal is wired in. The datasheet maximum is recorded and is the ceiling you may
raise the rate to — deliberately, and `p.check()` says so when you do.

**Pulse discharge ratings are estimates where the datasheet has none.** Molicel
publishes a pulse figure for the P50B (75 A) and not for the P45B or P42A, where
`I_dch_pulse_A` is 1.5x continuous by convention. That number is what the fast
over-current tier is built on, so lower it if your duty cycle is not short. Each
entry in `bcp.CellLibrary` marks which of its fields are datasheet and which are
estimates.

The harness plant is a resistive first-order stand-in with a generic NMC OCV
curve. It is for testing the blocks, not for answering questions about a cell —
`alg/bcp_harness_plant.m` says so at length.

## Tests

```matlab
runtests('tBcpAlgorithms')   % 83 tests, seconds, no Simulink
runtests('tBcpBuild')        % 12 tests, about a minute, builds and simulates
runtests('tBcpApp')          % 10 tests, UI wiring
```

The algorithm tests cover the control laws as plain functions. The build tests
cover what those cannot: that the generated code compiles, that the sample times
reconcile, that the loop-breaking delays are load-bearing, and that the emergent
behaviour of two interacting blocks is what the design intended.

Three of the build tests are about the discharge cycle specifically, and they are
a set rather than three independent checks:

- `protectionDoesNotDeadlockAgainstItsOwnLoad` runs a heavy load into
  under-voltage **with the limiter off**, and asserts the inhibit path still
  recovers when the trip does fire.
- `loadLimiterKeepsThePackOutOfUnderVoltage` runs the same scenario with the
  limiter on, and asserts the fault never latches, that `dcl_frac` actually left
  1 (so the scenario was severe enough to prove something), and that the lowest
  cell stayed above the trip.
- `aRecoveredFaultDoesNotChatterBackAndForth` counts fault **rising edges** over
  a 600 s deep-discharge run. `max(faults)` cannot see this failure at all: a run
  that tripped once and a run that cycled thirty times report the same maximum. The app tests cover the one
thing a UI over a configuration object can get wrong silently: the window and the
object disagreeing.

## Layout

```text
BMS/
|-- README.md
|-- START_HERE.m
|-- docs/
|   |-- INSTALL.md            step-by-step wiring procedure
|   |-- blocks.md             port and signal reference
|   `-- troubleshooting.md    organised by the error you see
`-- BmsChargerPackage/
    |-- bcp_setup.m           the single definition of the path
    |-- +bcp/
    |   |-- Signals.m         the wire contracts, in one place
    |   |-- CellLibrary.m     Molicel P45B / P50B / P42A datasheet entries
    |   |-- PackSpec.m        cell + S/P, everything else derived
    |   |-- LoadSignal.m      the load waveform, and its preview
    |   |-- BmsConfig.m       BMS settings, with fromPack auto-fill
    |   |-- ChargerConfig.m   charge settings, with fromPack auto-fill
    |   |-- BmsBuilder.m      builds the BMS block into a model
    |   |-- ChargerBuilder.m  builds the charger block into a model
    |   |-- Project.m         the four configs, kept consistent
    |   |-- Harness.m         the throwaway test model
    |   |-- CellTables.m      the cell's real curves, read out of a generated .ssc
    |   |-- CellVariation.m   cell-to-cell spread, applied to any pack in any model
    |   |-- Rate.m            sample-time audit and alignment
    |   `-- Blocks.m          library paths and wiring helpers
    |-- alg/                  the control laws, as testable plain functions
    |     |-- bcp_pack_monitor.m   per-cell arrays -> pack scalars, SOC clamped
    |     |-- bcp_load_scheduler.m the load waveform
    |     |-- bcp_load_limiter.m   continuous discharge derating (the DCL)
    |     |-- bcp_protection.m     dwell-confirmed latching, retry backoff, lockout
    |     |-- bcp_arbiter.m        load-first load/charge arbitration
    |     `-- bcp_charger.m        precharge / CC / CV
    |-- app/bcpSimple.m       the short UI: the numbers, then Copy models
    |-- app/bcpApp.m          the full UI, every field of bcp.Project
    |-- tests/                algorithm, build and UI suites
    `-- configs/              saved configurations
```

The `+bcp` classes are configuration and construction; `alg/` is the control
laws. The split is deliberate: the laws are plain functions on the path, so they
are unit-testable outside Simulink and the generated blocks are thin wrappers
around exactly the code the tests exercise. The UI is a view over
`bcp.Project` — every control writes to that object and nothing else, so a UI run
and a scripted run cannot produce different models.

## Compatibility

Verified against MATLAB R2025b and Simulink 25.2 on Windows. The blocks
themselves need only Simulink; Simscape is your battery model's requirement, not
theirs. Re-run `tBcpBuild` after changing MATLAB release — library paths and
block dialog parameter names are not a documented API and do move.

No licence file is included. Add whatever your team requires before
redistribution.
