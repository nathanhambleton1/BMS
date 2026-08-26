# Block reference

Two blocks, both pure signal-domain Simulink. No Simscape ports, no Simscape
licence needed by these blocks themselves — which is why they drop onto a pack
model built by any tool.

---

## BMS

One `MATLAB Function` block, `BMS_core`, running at `Ts`, surrounded by a Digital
Clock and a Unit Delay on every measurement input.

`BMS_core` has a **fixed signature regardless of configuration**. Optional
inputs become internal constants rather than changing the signature, so there is
exactly one code path to keep correct and enabling the temperature input is a
wiring change instead of a code-generation change.

### Inports

Optional ports renumber when you enable or disable them. `portMap()` prints the
numbering for your exact configuration.

| # | Name | Width | Meaning | Present when |
|---|---|---|---|---|
| 1 | `V_cell` | vector | per-cell terminal voltage [V] | always |
| 2 | `SOC_cell` | vector | per-cell state of charge | always |
| 3 | `I_cell` | vector | per-cell current [A], **your model's polarity** | always |
| 4 | `T_cell` | vector | temperature [°C] | `UseTemperature` |
| 5 | `P_chg` | scalar | charge power from the charger [W] | `UseCharger` |
| 6 | `chg_done` | scalar | charger termination flag | `UseCharger` |
| 7 | `reset` | scalar | rising edge clears latched faults | `UseResetPort` |

All three arrays must be the same width. `verifyWiring` checks it.

### Outports

| # | Name | Width | Meaning |
|---|---|---|---|
| 1 | `P_load_cmd` | scalar | load demand [W] → a load block that can only sink |
| 2 | `P_net_cmd` | scalar | load minus charge [W] → a load block that can source and sink |
| 3 | `chg_enable` | scalar | → charger `enable` |
| 4 | `I_chg_limit` | scalar | → charger `I_limit` |
| 5 | `pack_meas` | 7 | → charger, and everything that wants pack scalars |
| 6 | `contactor` | scalar | 1 = closed |
| 7 | `state` | scalar | 0 INIT, 1 IDLE, 2 CHARGE, 3 DISCHARGE, 4 FAULT |
| 8 | `faults` | scalar | latched bitmask |
| 9 | `diag` | 10 | why it did what it did |

**Use output 1 or output 2, never both.**

### `pack_meas`, the 7-element wire

Defined in one place, `bcp.Signals`. `bcp.Signals.describe()` prints it.

| Index | Signal | Unit |
|---|---|---|
| 1 | `V_pack` | V |
| 2 | `V_cell_min` | V |
| 3 | `V_cell_max` | V |
| 4 | `SOC_pack` | 0–1 |
| 5 | `SOC_min` | 0–1 |
| 6 | `SOC_max` | 0–1 |
| 7 | `I_pack` | A, **charge-positive** |

### `diag`, the 10-element wire

`bcp.Signals.diagNames()`.

| Index | Signal |
|---|---|
| 1 | `demand_present` — the waveform asked for something |
| 2 | `load_active` — what survived the discharge inhibit |
| 3 | `arb_reason` — 0 enabled, 1 load active, 2 quiet dwell, 3 pack full, 4 protection, 5 disabled |
| 4 | `dch_ok` |
| 5–10 | instantaneous, unconfirmed flags: OV, UV, OC_chg, OC_dch, OT, UT_chg |

`demand_present` against `load_active` is the pair worth watching. When they
disagree, protection is holding the load off, and `arb_reason` says what the
charger is doing about it.

### Fault bits

| Bit | Value | Fault | Effect |
|---|---|---|---|
| 1 | 1 | cell over-voltage | inhibits **charging** only |
| 2 | 2 | cell under-voltage | inhibits **discharging** only |
| 3 | 4 | pack over-current, charging | opens the contactor |
| 4 | 8 | pack over-current, discharging | opens the contactor |
| 5 | 16 | over-temperature | opens the contactor |
| 6 | 32 | under-temperature while charging | inhibits **charging** only |

`bcp.Signals.faultBits(mask)` turns the number into words.

**Directional inhibits, not one big contactor.** A cell over-voltage means stop
charging; it does not mean stop discharging, because discharging is the cure.
Likewise under-voltage inhibits the discharge and leaves the charge path open. A
protection layer that answers every fault by opening the contactor cannot
recover from either one without a human — and in this simulation it would
deadlock, because the load is what brings an over-voltage pack back into range.
So only the faults that mean *this pack must be isolated* open the contactor.

---

## Charger

One `MATLAB Function` block, `Charger_core`, at `Ts`, with a Unit Delay on
`pack_meas`.

### Inports

| # | Name | Width | Meaning |
|---|---|---|---|
| 1 | `pack_meas` | 7 | from the BMS |
| 2 | `enable` | scalar | from the BMS |
| 3 | `I_limit` | scalar | from the BMS |

`enable` and `I_limit` are **commands, not measurements**, so they are not
delayed — the BMS has already run this sample. Only `pack_meas` closes a loop
through the battery, so only `pack_meas` needs the delay.

### Outports

| # | Name | Meaning |
|---|---|---|
| 1 | `I_chg_cmd` | commanded charge current [A], ≥ 0 |
| 2 | `P_chg_cmd` | commanded charge power [W], ≥ 0 → back to the BMS |
| 3 | `mode` | 0 OFF, 1 PRECHARGE, 2 CC, 3 CV, 4 DONE |
| 4 | `V_set` | the voltage the supply is programmed to [V] |
| 5 | `I_set` | the current the supply is programmed to [A] |
| 6 | `done` | 1 once the taper has terminated → back to the BMS |

The charger only ever commands positive current. It has no authority to
discharge and no path to.

---

## The five lines between them

Drawn for you by `insertInto`.

```
BMS.pack_meas    ->  Charger.pack_meas
BMS.chg_enable   ->  Charger.enable
BMS.I_chg_limit  ->  Charger.I_limit
Charger.P_chg_cmd ->  BMS.P_chg
Charger.done      ->  BMS.chg_done
```

Three go BMS → charger (measurement, permission, ceiling) and two come back
(charge power, termination). The BMS decides *when*; the charger decides *how
much*. Two blocks both deciding when to charge is how you get a charger that
runs during a pulse because each one thought the other had yielded.

---

## Why CC and CV are not modes you select

There is no mode switch on the charger. One PI loop runs against two voltage
targets and a current ceiling, and `mode` reports which constraint is currently
binding: at the ceiling is CC, below it is CV. The handover is automatic because
it is not a decision — it is which constraint is active.

Two details in that loop are load-bearing.

**The CV loop regulates the highest cell, not the pack voltage.** On a pack with
real cell-to-cell spread those are different problems. Pack-voltage CV will
happily push the highest cell past its over-voltage trip while the pack average
still looks fine, and that is the most common way a programmatically built
charge controller destroys cells — first in simulation, then in hardware. The
loop takes the lower of the two commands: the one holding the maximum cell at
`V_cv_cell`, and the one holding the pack at `V_cv_pack`.

**Termination is dwell-confirmed, and that is not optional.** `Kp` is large by
design, so the proportional term saturates for any error above a few tens of
millivolts, and clamping anti-windup holds the integrator at zero through the
whole CC phase. The instant the highest cell reaches the target the error
collapses to nearly zero and, with the integrator still empty, the command dips
to near zero before integral action winds it up to the true CV equilibrium.
Terminate on that dip and every charge ends at the CC–CV knee: the phase
sequence looks perfect on a scope and the pack is nowhere near full. Confirming
the taper over `t_term_s` rides through the transient, because a genuine taper
persists and the transient does not.

The taper clock also requires `mode == 3` and resets when `enable` drops. A CC
phase derated by `I_limit` can sit below `I_taper_A` without being a taper, and
a charge paused by the load spends that time at zero current, which is not one
either.

---

## Load priority

`bcp_arbiter` is the only place that decides whether the charger may run, and
its first rule is that an active load revokes permission immediately — within
one sample, no ramp-down negotiation.

The order inside `BMS_core` matters and is worth stating:

1. reduce the arrays to pack scalars
2. evaluate the load waveform
3. run protection
4. **apply the discharge inhibit to the load command, then compute
   `load_active` from the gated value**
5. arbitrate
6. shape the outputs

Step 4 is the subtle one. Feed the *ungated* demand to the arbiter and an
under-voltage fault holds the load flag high forever: the arbiter sees a busy
load, refuses to charge, and the pack sits at its floor for the rest of the run
— deadlocked by its own protection, with an idle charger beside it. The cure for
under-voltage is a charge. `tBcpBuild/protectionDoesNotDeadlockAgainstItsOwnLoad`
is that test.

The **quiet dwell** (`t_quiet_s`) is how long the load must stay idle before the
charger is trusted to have a window. Set it longer than the gap inside a pulse
burst and shorter than the gap between bursts. Set it longer than *every* gap
and the charger never runs — and nothing about the run looks broken, which is
why `bcp.Project.check()` compares it against your pulse gap.

`AllowConcurrent` lets the charger run through the load, derated to
`I_chg_headroom_A`. That changes what the pack experiences, so it is a different
experiment rather than a refinement, and it is off by default.

---

## Why the unit delays are inside the blocks

The BMS reads pack voltage and current and commands the load power that
determines them. Wired directly that is an algebraic loop, and Simulink either
refuses to compile it or solves it iteratively at every step — slow, and liable
to fail to converge on a stiff pack model. The charger has the same loop through
its own current command.

A Unit Delay at each measurement input cuts the loop at the sensor, which is
also where a real BMS cuts it: a controller acts on the previous conversion,
never on the present instant.

They live inside the blocks on purpose. Delays you have to remember to add
outside are delays someone forgets, and the failure shows up as a compile error
weeks later in a model nobody has touched.

**The initial conditions are derived, not chosen.** Whatever a delay holds at
t = 0 is what protection and arbitration see for the first sample, so an initial
condition that resembles a fault produces a fault. Zero volts is the obvious
trap: it reads as a dead short and starts the under-voltage dwell timer on every
run. So the voltage delay is seeded halfway between the OV and UV *clear*
thresholds — inside the no-fault window by construction, for any chemistry,
without the builder knowing which — and the SOC delay below `SOC_restart`, so
the completion latch cannot arm before the first measurement. The charger's
`pack_meas` delay is seeded with a full pack, so its first act is to command
nothing.

`tBcpBuild/chargeReachesCVAndTerminatesOnTaper` asserts that first sample is
zero amps.
