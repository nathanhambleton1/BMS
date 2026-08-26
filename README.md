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

## Three things that will bite you, and where they are handled

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

Simscape Battery blocks report current positive when *discharging*. This package
is charge-positive throughout, and `I_sign` (default `−1`) is the single place
that conversion happens.

## What is modeled

- Load demand as off / constant / sine / pulse, with a start-stop window, power
  clamps, an optional slew limit for solver-friendly pulse edges, and an idle
  threshold that defines "the load is active"
- Per-cell arrays reduced to pack scalars, layout-agnostic
- Dwell-confirmed, latching protection with hysteresis recovery: over- and
  under-voltage, over-current in both directions, over- and under-temperature
- **Directional inhibits** — over-voltage stops charging and leaves the discharge
  open, because the load is the cure; only over-current and over-temperature
  isolate the pack
- Load-first arbitration with a configurable quiet dwell, SOC stop/restart
  hysteresis, a voltage re-arm threshold, and an opt-in concurrent-charging mode
- Precharge / CC / CV charging with automatic handover, a CV loop that regulates
  the **highest cell** rather than the pack average, clamping anti-windup, and
  dwell-confirmed taper termination
- Charge-parameter auto-fill from a cell datasheet plus S and P, including loop
  gains derived from the pack resistance
- A test harness with a resistive battery stand-in, for proving the blocks
  without a Simscape licence

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
rather than pretending. That is also why auto-fill never uses a datasheet
*maximum* charge current: those are qualified by a cell-temperature cutoff this
package cannot enforce, so the default is always the standard charge.

The harness plant is a resistive first-order stand-in with a generic NMC OCV
curve. It is for testing the blocks, not for answering questions about a cell —
`alg/bcp_harness_plant.m` says so at length.

## Tests

```matlab
runtests('tBcpAlgorithms')   % 57 tests, seconds, no Simulink
runtests('tBcpBuild')        %  8 tests, about a minute, builds and simulates
runtests('tBcpApp')          % 10 tests, UI wiring
```

The algorithm tests cover the control laws as plain functions. The build tests
cover what those cannot: that the generated code compiles, that the sample times
reconcile, that the loop-breaking delays are load-bearing, and that the emergent
behaviour of two interacting blocks is what the design intended — including that
protection does not deadlock against its own load. The app tests cover the one
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
    |   |-- Rate.m            sample-time audit and alignment
    |   `-- Blocks.m          library paths and wiring helpers
    |-- alg/                  the control laws, as testable plain functions
    |-- app/bcpApp.m          the UI
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
