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
| 7 | `state` | scalar | 0 INIT, 1 IDLE, 2 CHARGE, 3 DISCHARGE, 4 FAULT, 5 LOCKOUT |
| 8 | `faults` | scalar | latched bitmask — **simultaneous faults add** |
| 9 | `diag` | 17 | why it did what it did |

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

### `diag`, the 17-element wire

`bcp.Signals.diagNames()`.

| Index | Signal |
|---|---|
| 1 | `demand_present` — the waveform asked for something |
| 2 | `load_active` — what survived the discharge inhibit and the limiter |
| 3 | `arb_reason` — 0 enabled, 1 load active, 2 quiet dwell, 3 pack full, 4 protection, 5 disabled |
| 4 | `dch_ok` |
| 5–10 | instantaneous, unconfirmed flags: OV, UV, OC_chg, OC_dch, OT, UT_chg |
| 11 | `dcl_frac` — 0–1, the fraction of the demand the limiter let through |
| 12 | `limit_state` — 0 unlimited, 1 voltage foldback, 2 current foldback, 3 soft-start, 4 held off |
| 13 | `retry_count` — automatic recoveries inside the retry window |
| 14 | `lockout` — 1 = auto-recovery withdrawn, reset only |
| 15 | `uv_charge_Ah` — charge taken on since the under-voltage latch |
| 16 | `recover_dwell_s` — clear-band dwell recovery currently requires |
| 17 | `soc_raw_min` — **unclamped** minimum SOC as the battery model reported it |

Four pairs, in the order you would look at them when a run does something you
did not expect:

**`demand_present` vs `load_active`.** What the waveform asked for, and what
survived. When they disagree the load is being held off or derated.

**`dcl_frac` and `limit_state`.** How much of the demand the load limiter is
letting through, and which constraint is binding. `dcl_frac` below 1 with no
fault latched is the system working as designed — the limiter is doing the
regulating so the trip does not have to. `bcp.Signals.limitState(code)` names it.

**`retry_count` and `lockout`.** How many automatic recoveries have happened
inside the retry window, and whether auto-recovery has been withdrawn. A retry
count climbing is the signature of a fault that recovery does not fix.

**`uv_charge_Ah` vs `Bms.Q_uv_reset_Ah`.** How much charge has gone back in
since the under-voltage latch, against how much it needs before it will clear.
This is the answer to *why is the load still off, the pack looks fine*.

`soc_raw_min` going negative means the pack model has been discharged past its
rated capacity. That is the battery model, not the BMS — see
[Negative SOC](#negative-soc) below.

### The two vector outputs are 7 and 17 wide, and they sit next to each other

`pack_meas` (output 5) is 7 wide and goes to the charger. `diag` (output 9) is
17 wide and goes to a scope. Wiring `diag` where `pack_meas` belongs is the easy
mistake, and the error Simulink reports is a width mismatch against the
*charger's* input delay — "expected `[7]`, got `[17]`" — which names a block a
long way from the wire that caused it.

`bcp.Signals.NUM` and `bcp.Signals.DIAG_NUM` are the single definition of each
width, and the generated `BMS_core` preallocates `diag` to `DIAG_NUM` so its
width is a compile-time constant whatever is wired to the temperature port. The
reliable way to avoid the question entirely is to copy both blocks together —
`p.stageBlocks()`, `p.insertInto(model)`, or **Copy models** in `bcpSimple` —
which brings all five internal lines pre-drawn.

### Fault bits

| Bit | Value | Fault | Effect |
|---|---|---|---|
| 1 | 1 | cell over-voltage | inhibits **charging** only |
| 2 | 2 | cell under-voltage | inhibits **discharging** only |
| 3 | 4 | pack over-current, charging | opens the contactor |
| 4 | 8 | pack over-current, discharging | opens the contactor |
| 5 | 16 | over-temperature | opens the contactor |
| 6 | 32 | under-temperature while charging | inhibits **charging** only |

`bcp.Signals.faultBits(mask)` turns the number into words, and
`bcp.Signals.faultTable()` prints every mask a run is likely to show.

**Simultaneous faults ADD, so 5 and 10 are not fault codes — they are sums.**
This is the single most common "what is this value" question, and both answers
are the same shape:

| `faults` | Bits | What happened |
|---|---|---|
| 5 | 4 + 1 | charge over-current that also drove a cell over-voltage |
| 10 | 8 + 2 | discharge over-current that also sagged a cell under-voltage |

And the **order** is diagnostic. An over-current confirms in `t_i_trip`
(0.1 s by default) and a voltage fault in `t_v_trip` (0.5 s), so an over-current
big enough to also breach the voltage window shows the current bit **first,
alone**, and picks up the voltage bit about 0.4 s later. Seeing `4` and then `5`,
or `8` and then `10`, is not a state machine moving on — it is one physical event
whose second, slower confirmation has just completed.

On a discharge, `10` reads as *the over-draw was well past what the pack could
deliver at that state of charge*. If you are seeing it on a pulse test, the load
current is above the fast discharge tier **and** the sag is reaching the
under-voltage threshold, which usually means the pulse is being asked for at a
lower SOC than the pack can support it at. `dcl_frac` on `diag(11)` will show
whether the limiter tried to prevent it.

`4 + 8 = 12` — over-current confirmed in *both* directions — is different in
kind: no load does that. It means `I_sign` is wrong or the current array is
miswired. Check pack current against a known discharge.

**Over-current is two tiers sharing one bit.** A cell has two current ratings and
one threshold cannot honour both: set it at the continuous rating and every
pulse the pack was built to deliver fires protection; set it at the pulse rating
and a sustained over-draw runs forever. So each direction has

| Tier | Threshold | Confirmed over | What it catches |
|---|---|---|---|
| sustained | `I_dch_trip` / `I_chg_trip` | `t_i_cont_s` (10 s) | the continuous rating, exceeded for long enough to matter |
| fast | `I_dch_peak_A` / `I_chg_peak_A` | `t_i_trip` (0.1 s) | the pulse rating, i.e. a genuine fault |

Either latches the same bit, because the consequence is the same. This is how
protection ICs stage over-current, and it is why a pulse test does not need its
discharge trip raised by hand to run.

**Directional inhibits, not one big contactor.** A cell over-voltage means stop
charging; it does not mean stop discharging, because discharging is the cure.
Likewise under-voltage inhibits the discharge and leaves the charge path open. A
protection layer that answers every fault by opening the contactor cannot
recover from either one without a human — and in this simulation it would
deadlock, because the load is what brings an over-voltage pack back into range.
So only the faults that mean *this pack must be isolated* open the contactor.

### Discharge limiting, and why the trip is not the operating limit

A trip is binary and a constant-power load is positive feedback, and those two
together oscillate. The cycle, on any discharge that reaches the under-voltage
threshold:

```text
sag under V_uv_trip  ->  UV latches, dch_ok drops  ->  load command goes to 0
   ->  the sag disappears, because the sag WAS the load
   ->  the pack reads inside the clear band, so the fault recovers
   ->  full load slams back on  ->  a DEEPER sag, because SOC is lower and R0 higher
```

Each lap costs charge and returns almost none, so the dips grow and end up far
below the threshold that was supposed to prevent them. Nothing in that chain is
a coding error — it is what a bang-bang controller does to a load whose current
*rises* as the voltage it caused *falls*. `I = P/V`, so a 10% sag is an 11%
current rise is more sag. Protection cannot fix it by itself: whatever the
threshold and whatever the dwell, a binary trip removes its own trigger.

So the trip stops being the operating limit. `alg/bcp_load_limiter.m` puts a
continuous limit in front of it — the discharge current/power limit a production
BMS publishes on CAN as DCL, and which the inverter is required to obey. It
slides down as the cells approach their cutoff, and protection becomes the
backstop it was always meant to be.

Four mechanisms, each closing a different escape route:

| Mechanism | Where | What it stops |
|---|---|---|
| continuous foldback (`UseLoadLimiter`) | `bcp_load_limiter` | the trip firing at all |
| soft-start on re-engagement (`t_softstart_s`) | `bcp_load_limiter` | a step re-engagement going straight back under |
| UV clears only on charge (`Q_uv_reset_Ah`) | `bcp_protection` | recovering on a rest, which gained no energy |
| retry backoff and lockout (`Retry_Backoff_x`, `N_retry_max`) | `bcp_protection` | any surviving cycle running forever |

**The limit moves by rate, not by formula, and that is the stability argument.**
Evaluating `frac = f(V_min)` fresh each sample just reintroduces the oscillation
in analogue form: its loop gain is `df/dV · dV/dP · P_demand`, and `dV/dP` goes
to infinity as a constant-power draw approaches the pack's maximum power point
`P_max = Voc²/(4R)`. There is no `f` that is stable across the SOC range — the
system is at its most unstable exactly where the limiter is needed most.

Instead the limit is a rate-limited integrator with a deadband:

| `V_min` | What the limit does |
|---|---|
| below `V_fold_end` | closes, at a rate proportional to how far below, capped at `Fold_Fall_per_s` |
| between the two | holds still |
| above `V_fold_start` | reopens, slowly, at `Fold_Rise_per_s` |

The step per sample is bounded by `rate · Ts` however large the error is, so the
loop cannot amplify a transient whatever `dV/dP` has become. The deadband is
what stops the integrator hunting: once `V_min` is inside it the limit stops
moving, and the pack sits just above its cutoff delivering what it can.

Two more properties worth knowing, because both look like bugs until they are
explained:

**The limit only reopens while current is flowing** (`Fold_Learn_frac`). At rest
`V_min` relaxes to OCV, far above the band — but an open-circuit voltage is not
evidence the pack can deliver power; it is precisely the measurement that misled
the bang-bang trip. Reopening therefore needs `|I_pack|` above a threshold:
under load because the load is proving it, or under charge because the charge is
replacing what the load took. At rest the limit holds what it has.

**An inhibit freezes the limit rather than resetting it.** The pre-trip limit was
demonstrably too high, and that is the one useful thing the failed attempt
established.

There are two samples of loop latency — the measurement comes through the BMS's
input unit delay, and the command can only change on the next sample — so a
**step** load edge reaches full demand before the limiter has responded to any
part of it. Give a large pulse load a `Slew_W_per_s` spanning at least four
samples; `bcp.Project.check()` says so when the load is big enough for it to
matter.

<a name="negative-soc"></a>
### Negative SOC is the battery model, not the BMS

A Simscape `table_battery` — which is what the Battery Model Builder generates —
computes state of charge as a plain integral of cell current over the *rated*
capacity:

```text
socCell(t) = socCell(0) + ∫ i dt / (3600 · AH)
```

There is no floor on that integrator. Take out more coulombs than the rated
capacity holds and SOC goes below zero, and the component neither clamps nor
complains. What it *does* clamp is the tables: the generated component sets
`extrapolation_option = nearest`, so below `SOC = 0` the OCV and R0 lookups hold
their `SOC = 0` values.

Which explains the shape of what you see. Past empty the cell keeps its
end-of-table OCV — 3.172 V for the bundled P45B tables — and its end-of-table
resistance, so it goes on sourcing current forever at a plausible-looking
voltage while SOC drifts negative. **The pack model has no concept of being
empty.** The only thing that stops a discharge is the under-voltage trip, and if
that trip keeps clearing, nothing does.

`Bms.SOC_clamp` (on by default) limits the SOC the BMS *reports* to 0–1, because
`SOC_stop`, `SOC_restart` and every SOC comparison in this package are written
against a 0–1 quantity. The unclamped minimum is still published on `diag(17)`
so the excursion is visible rather than absorbed.

How to read it:

- **A fraction of a percent negative** is coulomb-counting overshoot against a
  capacity that is rated rather than measured. Normal.
- **A sustained negative reading** means the run kept discharging a pack the
  model was no longer modelling. Treat it as the end of the useful part of the
  run, not as a BMS fault. `pulse195_verify` checks for it explicitly.

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

There is no mode switch on the charger. Two PI loops run against two voltage
targets and a current ceiling, and `mode` reports which constraint is currently
binding: at the ceiling is CC, below it is CV. The handover is automatic because
it is not a decision — it is which constraint is active.

**Nor is the charge rate set here.** `I_limit` from the BMS and this block's own
`I_cc_A` are two ceilings and the lower binds, and `I_cc_A` is the *supply's*
rating. So the rate is one number — `Bms.I_chg_max_A` — with the two charge
over-current trips derived from it, and there is nothing in the charger to keep
in step.

Four details in those loops are load-bearing.

**The CV loop regulates the highest cell, not the pack voltage.** On a pack with
real cell-to-cell spread those are different problems. Pack-voltage CV will
happily push the highest cell past its over-voltage trip while the pack average
still looks fine, and that is the most common way a programmatically built
charge controller destroys cells — first in simulation, then in hardware. The
loop takes the lower of the two commands: the one holding the maximum cell at
`V_cv_cell`, and the one holding the pack at `V_cv_pack`.

**Two loops means two integrators, each tracking what was applied.** They used
to share one, and that is what made the charger limit-cycle at the knee: the two
loops measure errors differing by a factor of `S`, so whichever lost the `min()`
selection last was still writing the state the winner read, and around the knee
the selection alternates every sample. Each loop now has its own state, and
after the command is clamped both are back-calculated so that each loop's own
output equals what was actually applied:

```
x_k = (I_cmd - Kp_k * e_k) / Ki_k
```

For the loop that is running and unsaturated this is the identity, so integral
action is untouched. For the loop that lost, and for either loop sitting on a
limit, it is exact tracking anti-windup: no wind-up through the CC phase, and a
bumpless handover whenever the binding constraint changes.

**`mode` is a Schmitt trigger with a minimum dwell.** Entering CV needs the
command to fall `Mode_Hyst_frac` below the ceiling; returning to CC needs it
back within a quarter of that band; and either change waits out `t_mode_min_s`.
A bare comparison against the ceiling toggles every sample while the command
sits on it, and a report that chatters is a report nobody can read.

**Termination is dwell-confirmed, and does not depend on the mode.** A taper is
"the command has fallen away *because* the voltage target is satisfied", so that
is what is tested: the command below `I_taper_A` while the highest cell is
within `V_term_band` of its target. Keying it off `mode == 3` made the
termination clock hostage to the mode, and a charge could sit at its target
indefinitely without ever accumulating a confirmed taper.

The confirmation over `t_term_s` is not optional either. `Kp` is large by design,
so the command dips sharply the instant the target is first reached, before
integral action winds up to the true CV equilibrium. Terminate on that dip and
every charge ends at the CC–CV knee: the phase sequence looks perfect on a scope
and the pack is nowhere near full. The clock also resets when `enable` drops — a
charge paused by the load spends that time at zero current, which is not a taper
— and the voltage condition is what rules out a CC phase derated by `I_limit`.

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
