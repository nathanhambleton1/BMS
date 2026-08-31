# Troubleshooting

Organised by what you actually see, not by what is actually wrong.

---

## Compile and setup errors

### "Undefined function 'bcp_pack_monitor'" (or `bcp_protection`, `bcp_arbiter`, `bcp_charger`, `bcp_load_scheduler`, `bcp_tick`)

`BMS_core` and `Charger_core` paste this code in as local functions, so a
model built with a current `insert()` does not need `alg/` on the path at all
— if you are seeing this, the block predates that change. Re-insert it
(`p.insertInto('myModel')`, or **Copy models** in `bcpSimple`) to regenerate
it with the algorithm embedded.

`bcp_ocv` and `bcp_harness_plant` are different: they belong to the test
harness plant model, not to either generated block, so this error for them
means `BmsChargerPackage/alg/` is not on the path in the session building
that harness.

```matlab
run('<path to>/BmsChargerPackage/bcp_setup.m')
```

`START_HERE.m` does it for you, once per MATLAB session.

### "Block diagram 'x' contains 1 algebraic loop"

`BreakFeedbackLoops` is off on one of the blocks, or you turned it off and put
your own delay somewhere that does not break the loop.

Turn it back on (BMS tab and Charger tab), re-insert, redraw the wires. See
[blocks.md](blocks.md#why-the-unit-delays-are-inside-the-blocks) for why the
loop exists at all.

If it is on and you still get this, the loop is elsewhere in your model — the
error message names the blocks in the cycle. Check whether your dynamic load
block itself is direct-feedthrough from voltage to power without a delay.

### "The sample time of this block is not an integer multiple of the fixed step"

Or any of its relatives. This is the one you hit before.

```matlab
bcp.Rate.audit('myModel', [0.01 0.01])    % what is wrong
bcp.Rate.align('myModel', [0.01 0.01])    % fix the FixedStep part
```

The rule, and the three clocks involved, are in
[INSTALL.md step 2](INSTALL.md#step-2--reconcile-the-sample-times). The short
version: with a variable-step solver any positive `Ts` works; with a fixed-step
solver `Ts` must be an exact integer multiple of the fundamental step; and a
Simscape Solver Configuration block with *Use local solver* ticked is a third,
independent clock that the audit reports separately because it is the one people
forget.

Never set `Ts` to −1 to make the error go away. Both blocks convert samples to
seconds by multiplying by `Ts`, so an inherited rate makes every dwell timer and
every integrator gain wrong while the model still runs and still logs plausible
traces.

### "Port width mismatch" on `V_cell`, `SOC_cell` or `I_cell`

The three arrays are not the same width, which means one of them is wired to the
wrong signal. `p.verifyWiring('myModel')` reports all three widths.

### "Port width mismatch": something expected `[7]` and got `[17]`

The BMS block's `pack_meas` output is **7** wide and its `diag` output is **17**.
They are adjacent, unlabelled vectors leaving neighbouring ports, and wiring
`diag` into the charger's `pack_meas` input is the easy mistake. The error is
reported against the charger's input delay, whose initial condition is a
7-element vector -- which is where the `[7]` comes from -- so the message names a
block a long way from the wire that caused it.

Draw `BMS/pack_meas` (output 5) into `Charger/pack_meas` (input 1). Better,
never draw it at all: **Copy models** in `bcpSimple`, or `p.stageBlocks()` /
`p.insertInto(model)`, brings both blocks across with all five BMS-to-charger
lines already drawn.

If the widths are wrong some other way: `bcp.Signals.NUM` and
`bcp.Signals.DIAG_NUM` are the one place either is defined, and the generated
`BMS_core` preallocates `diag` to `DIAG_NUM` so its width is fixed at compile
time regardless of what is wired to the temperature port.

### The MATLAB Function block shows red text / "expected a scalar"

Almost always the SOC array. If your model reports 0–100 rather than 0–1, tick
**SOC array is in percent** on the BMS tab and re-insert.

---

## It compiles, but nothing happens

### The load draws nothing

In order of likelihood:

1. **Waveform is `off`.** Check the Load tab.
2. **`Pmax_W` clamp is below the waveform.** The preview shows a flat line and
   the log carries a `bcp:LoadSignal:Clipped` warning.
3. **`OutputSign` is wrong**, so you are sending your load block negative watts
   and it is refusing to source. Flip it on the Load tab.
4. **Start/stop window excludes the whole run.** `StopTime_s` is exclusive.
5. **A latched under-voltage is inhibiting the discharge.** Look at `diag`
   channels 1 and 2: if `demand_present` is 1 while `load_active` is 0,
   protection is holding the load off. Channel 6 (`flag_UV`) confirms it.

### The charger never runs

Read `arb_reason`, `diag` channel 3. It tells you exactly which gate is closed:

| Code | Meaning | What to do |
|---|---|---|
| 0 | charging enabled | it *is* running; check `chg_mode` instead |
| 1 | load is active | expected under a continuous load — the load has priority |
| 2 | waiting out the quiet dwell | `t_quiet_s` is longer than your pulse gap |
| 3 | pack full | SOC ≥ `SOC_stop`, or the completion latch is set |
| 4 | blocked by protection | read `faults` |
| 5 | disabled in configuration | `ChargeEnabled` is off |

Code 2 with a pulse load is the classic. The gap between pulses is
`(100 − duty)/frequency` seconds; if that is shorter than `t_quiet_s`, the
charger never gets a window and nothing about the run looks broken.
`p.check()` catches it.

Code 1 with a constant load is not a bug — a constant load never goes idle, and
strict load priority means exactly that. Use a pulse load, or turn on
`AllowConcurrent` knowing it changes what the pack experiences.

### The pack never fills

Press **Estimate charge time** on the Charger tab. If your load's average draw
is at or above the charge current, the pack will settle wherever load and charge
balance and never reach `SOC_stop`. The tab says so explicitly.

Otherwise check the stop time. A 22.5 Ah pack at 21.75 A takes about 45 minutes
of *charging time* to go from 20% to 95%, and the load steals most of the clock.

---

## It runs, but the numbers are wrong

### Every current has the wrong sign

`I_sign` on the BMS tab. Simscape Battery components declare cell current
*positive in* — positive while **charging** — which is this package's own
convention, so the default is `+1`. Set it to `-1` only for a model that reports
discharge as positive.

The symptom of getting it wrong is distinctive: the BMS over-current-trips
during a **discharge** pulse, never trips during a charge, and `state` reads
CHARGE while the pack empties.

### Pack voltage is P times too large, or currents are all scaled by a constant

`S` is counting the wrong thing. Run:

```matlab
p.verifyWiring('myModel')
```

It compiles the model and reports whether the arrays are per-cell (`S*P` wide)
or per-series-element (`S` wide). Either is fine — pack voltage is computed as
`mean(V)*S` and pack current as `sum(I)/S`, and both forms are correct for both
layouts. What matters is that `S` counts the same thing the array counts. If the
arrays are per-**module**, set `S` and `P` to module counts and put the module's
parameters in the cell fields.

### Every charge ends in an over-voltage fault

The CV target is at or above the over-voltage trip. A trip is a fault threshold,
not the operating limit: set it at the target and every charge that succeeds
trips protection at the moment it succeeds. Leave 20–50 mV. `p.check()` reports
this, and **Auto-fill all** sets the trip to the cell cutoff plus 50 mV.

### The charge stops a quarter of the way up

Two candidates:

- **`V_cv_pack` does not match `S × V_cv_cell`.** The lower target always binds,
  so a 14S target left on a 20S pack stops the charge 26 V early. `sync()`
  rescales it when you change `S`, and `ChargerConfig.validate` warns if you set
  it by hand.
- **The supply is smaller than the rate the BMS permits.** `Charger.I_cc_A` and
  `Charger.P_chg_max_W` are the *supply's* ratings, and the charger commands the
  lower of them and the BMS limit. If either is below `Bms.I_chg_max_A × V_max`,
  the supply is what ends the charge. `p.check()` reports both.

### Raising the charge rate does nothing

There is one number: **Charge current** in `bcpSimple`, `Bms.I_chg_max_A` in a
script, or `I_CHG_MAX_A` at the top of the generated `BMS_core` block. Set it
through `p.setChargeCurrent(A)` -- which is what the UI field calls -- and both
charge over-current trips, the supply current rating and the supply power
ceiling all move with it.

Set `Bms.I_chg_max_A` on its own and the trips stay where they were, so a large
enough increase fires protection instead of charging faster. `validate` rejects
a trip below the permitted rate outright, and `p.check()` reports a supply that
cannot source what the BMS is now permitting.

Editing `I_CHG_MAX_A` inside a pasted block works, and the trips follow it
because they are computed from it three lines down -- but the next `insert()`
overwrites the block, so put the value you settle on back into
`bcp.BmsConfig.I_chg_max_A`.

### `chg_mode` toggles rapidly between CC and CV

Fixed by the two-integrator rewrite of `bcp_charger`. If you still see it, you
are running an older copy of `alg/bcp_charger.m`.

The cause was a single PI integrator shared by the max-cell loop and the
pack-voltage loop. Those two measure errors that differ by a factor of `S`, so
around the knee -- where the `min()` selection alternates every sample -- the
integrator was driven by two incompatible signals and the command oscillated
between the current ceiling and well below it. The mode output followed, and
because termination used to be keyed off `mode == 3`, the taper clock kept
resetting: the charge could sit at its target indefinitely without finishing.

Three changes, all in `bcp_charger`. Each loop has its own integrator. Both are
back-calculated after the command is clamped, so every loop tracks what was
actually applied and the handover is bumpless. And the mode output is a Schmitt
trigger (`Mode_Hyst_frac`) with a minimum dwell (`t_mode_min_s`). Termination is
now keyed off the current *and* the cell being within `V_term_band` of its
target, never off the mode.

`tBcpAlgorithms/modeDoesNotChatterAtTheKnee` and
`tBcpBuild/chargerModeDoesNotChatterThroughTheKnee` are the regression tests.

### The charge ends at the CC–CV knee, with the pack nearly empty

`t_term_s` is too short — at or near one sample. At the CC-to-CV handover the
command dips to near zero for a moment while the integrator winds up from empty,
and terminating on that dip ends every charge at the knee with a perfect-looking
phase sequence. Two seconds is a sensible floor; `validate` requires more than
one `Ts` and auto-fill sets `max(2, 20*Ts)`.

### The charger chatters on and off

`SOC_restart` too close to `SOC_stop`, or `V_recharge` too close to the CV
target. Both need real hysteresis. `validate` rejects equal SOC values.

### The fault keeps clearing and re-tripping, and each voltage dip is deeper

This is the cyclic fault chain, and it has a specific cause. Cutting the load
removes the sag that tripped it, so the pack immediately reads inside the clear
band, the fault recovers, the full load comes back, and the next sag is deeper
because the lap cost charge. Each iteration takes energy out and returns almost
none, so the excursions grow and end up well below the threshold that was
supposed to prevent them.

Count the **rising edges** on `faults`, not its maximum: a run that tripped once
and a run that cycled thirty times report the same maximum.

Four things stop it, and all four are on by default. If you are seeing the chain,
one of them is off or mis-set:

| Symptom on `diag` | Setting to check |
|---|---|
| `dcl_frac` stays at 1 right up to the trip | `Bms.UseLoadLimiter` is false |
| `dcl_frac` drops but too late | the load edge is a step — see the next entry |
| `uv_charge_Ah` stays 0 and the latch clears anyway | `Bms.Q_uv_reset_Ah` is 0 |
| `retry_count` climbs and never locks out | `Bms.N_retry_max` is `Inf`, or `Retry_Backoff_x` is 1 |

The full argument is in
[blocks.md](blocks.md#discharge-limiting-and-why-the-trip-is-not-the-operating-limit)
and `alg/bcp_load_limiter.m`.

**One transient excursion below the trip is expected and is not the chain.** The
limiter is feedback, not prediction: it cannot derate a demand it has not yet
seen at this state of charge, so the *first* large pulse at a new operating point
reaches the pack's actual equilibrium voltage before the limit closes. Measured
on the bundled 195S1P pack, 31250 W pulses from 8% SOC:

| Pulse | Lowest cell | `dcl_frac` at start | Time below the 2.50 V trip |
|---|---|---|---|
| 1 | 2.4033 V | 1.000 | 0.010 s |
| 2 | 2.5798 V | 0.834 | 0 |
| 3–15 | 2.5798 V | 0.829 → 0.749 | 0 |

The first excursion lasts one sample, which is fifty times shorter than
`t_v_trip`, so it cannot latch — the dwell is what covers it. Afterwards the
limit is retained (it only reopens while current is flowing) and every subsequent
pulse is regulated to the bottom of the foldback band exactly. If you need the
first excursion suppressed too, lengthen the load edge or widen
`V_fold_band_V` — both give the limiter more samples before the pack arrives.

### Protection chatters, and the simulation crawls

`t_v_trip` or `t_i_trip` near zero. An instantaneous trip on a stiff DAE
oscillates against the solver: it takes a trial step, the threshold is crossed,
the command is cut, voltage recovers, it clears. The dwell timers are what let
this simulate at a sane step size. 0.5 s for voltage and 0.1 s for current are
reasonable.

### A pulse load will not converge, or the step size collapses at each edge

A hard pulse edge is a step discontinuity in the algebraic constraint the
Simscape solver has to satisfy. Set **Slew limit** on the Load tab to something
finite — it turns each edge into a ramp the solver can walk across.

**There is now a second reason to set it, and it is the stronger one.** The load
limiter reads pack voltage through the BMS block's input unit delay and can only
change the command on the following sample, so it has **two samples of loop
latency** whatever `Fold_Fall_per_s` is set to. A step edge therefore reaches
full demand before the limiter has responded to any part of it. Give the edge at
least four samples — 40 ms at `Ts = 0.01` — so the limiter sees the demand rising
and has acted twice by the time it arrives.

`bcp.Project.check()` reports a step edge as an issue when the peak demand
exceeds half the pack's continuous discharge rating, which is where two samples
starts to matter. On a small load relative to the pack it says nothing, because
there a step edge is harmless.

It is still a modelling aid rather than physics. If you use it, say so when you
report results: you have changed the load the pack sees. `pulse195_setup.m`
section 6 works out the energy cost for the bundled test — the rise gives up
about half an edge time at full power and the fall gains the same back, so the
two cancel to first order.

---

## Behaviour that looks wrong and is not

### `I_chg_cmd` is exactly zero on the very first sample

By design. The charger's `pack_meas` delay is seeded with a full pack so that
before its first real conversion it commands nothing — a charger whose first act
is to push current into a pack it has not measured is the failure being avoided.
`I_chg_cmd` is exactly zero for that sample, and `tBcpBuild` asserts it.

### An over-voltage fault does not open the contactor

Also by design. Over-voltage inhibits charging and leaves the discharge path
open, because the load is the cure. Only over-current and over-temperature
isolate the pack. See
[blocks.md](blocks.md#fault-bits).

### The load is derated and `dcl_frac` is below 1, with no fault latched

That is the load limiter working, and it is the intended behaviour near the end
of a discharge. It derates continuously as the cells approach their cutoff so
the trip does not have to fire — see
[blocks.md](blocks.md#discharge-limiting-and-why-the-trip-is-not-the-operating-limit).

Read `diag(12)` (`limit_state`) for which constraint is binding:

| `limit_state` | Meaning |
|---|---|
| 0 | nothing binding |
| 1 | voltage foldback — the lowest cell is in the band above `V_uv_trip` |
| 2 | current foldback — the draw is approaching `I_dch_peak_A` |
| 3 | soft-start ramp after a discharge inhibit |
| 4 | held off by protection |

If the limiter engages **earlier in the run than you expected**, the pack cannot
deliver the load at that state of charge — which is a finding, not a fault.
Compute `P_max = Voc²/(4R)` at that SOC and compare it against your demand;
`pulse195_setup.m` section 6 works the arithmetic for the bundled pack. If you
want the pulse to run unlimited over a wider range, widen the band with
`V_fold_band_V` / `V_fold_margin_V` — but the trip is then closer, and below
`P_max` there is no setting that makes an impossible demand possible.

### `faults` reads 5, or 10, and that value is not in the fault-bit table

Because it is not a fault code — it is a **sum**. `faults` is a bitmask and
simultaneous faults OR together:

```text
 5 = 4 + 1 = OC_charge    + OV
10 = 8 + 2 = OC_discharge + UV
```

`bcp.Signals.faultBits(10)` prints `UV + OC_discharge`, and
`bcp.Signals.faultTable()` lists every mask you are likely to see with what each
one means.

**Seeing 4 for a moment and then 5 — or 8 and then 10 — is one event, not two.**
An over-current confirms in `t_i_trip` (0.1 s by default) and a voltage fault in
`t_v_trip` (0.5 s), so an over-current large enough to also breach the voltage
window shows the current bit first, alone, and picks up the voltage bit about
0.4 s later. Nothing changed state in between; a second, slower confirmation
completed.

On a discharge, `10` means the draw was well past what the pack could deliver at
that state of charge. Check `dcl_frac` on `diag(11)`: if it never left 1, the
load limiter is off and the trip is doing work it should not have to.

`12` (`4 + 8`, over-current in **both** directions) is different in kind — no
load does that. It means `I_sign` is wrong or the current array is miswired.

### `state` reports 5, which is not INIT/IDLE/CHARGE/DISCHARGE/FAULT

5 is **LOCKOUT**: a fault is latched *and* auto-recovery has been withdrawn
because the retry counter reached `Bms.N_retry_max`. Only a rising edge on the
reset port will clear it now, and that clears the counter too.

It means the pack faulted, recovered and faulted again `N_retry_max` times inside
`t_retry_window_s`. That is not N independent faults — it is one condition that
recovery does not fix. Read `diag(13)` for the count and see the cyclic-fault
entry above for what to check.

`Bms.N_retry_max = Inf` disables the lockout and leaves only the dwell backoff.

### The SOC goes slightly negative

That is the battery model, not the BMS. A Simscape `table_battery` integrates
coulombs over the *rated* capacity with **no floor**, so discharging past empty
drives SOC below zero and the component neither clamps nor complains. Its OCV and
resistance *tables* are clamped (`extrapolation_option = nearest`), so past empty
the cell holds its end-of-table voltage and resistance and goes on sourcing
current forever at a plausible-looking terminal voltage. The pack model has no
concept of being empty.

`Bms.SOC_clamp` (on by default) limits the SOC the BMS *reports* to 0–1, because
every SOC comparison in this package is written against a 0–1 quantity. The
unclamped minimum is published on `diag(17)` (`soc_raw_min`) so the excursion
stays visible.

- **A fraction of a percent** is coulomb-counting overshoot against a rated
  rather than measured capacity. Normal, and not worth chasing.
- **A sustained negative reading** means the run kept discharging a pack the
  model was no longer modelling. Everything after that point describes nothing;
  treat it as the end of the useful part of the run.

If you are hitting it on a long discharge, the run is doing what it is supposed
to and simply going on too long. Shorten the run, start higher, or enable the
charger.

### The load never comes back after an under-voltage, and the pack looks fine

By design. An under-voltage latch now needs `Bms.Q_uv_reset_Ah` of **charge** to
have gone back in before it will clear — resting is not recovery. A cell that
returns to 3.0 V the instant the load is removed has stopped losing energy, not
gained any, and it is still at its end of discharge. Recovering on that reading
is exactly what lets the cyclic fault chain restart.

Read `diag(15)` (`uv_charge_Ah`) against `Bms.Q_uv_reset_Ah`: that pair tells you
how far along the requirement is.

**On a load-only run the latch is therefore permanent.** With `ChargeEnabled`
false or no charger wired, the first under-voltage event ends the discharge for
the rest of the run — which is the correct end of a discharge test, but it does
mean no more load current. `p.check()` says so before you build. Set
`Q_uv_reset_Ah = 0` for the old rest-is-enough behaviour, or enable the charger.

### A discharge pulse goes above the discharge trip and nothing happens

By design, and it is the point of staging over-current in two tiers.
`I_dch_trip` is the cell's **continuous** rating, confirmed over `t_i_cont_s`
(10 s by default); `I_dch_peak_A` is the **pulse** rating, confirmed over
`t_i_trip` (0.1 s). A two-second pulse above the continuous rating reaches
neither, which is correct -- a continuous rating is a thermal limit over
minutes. The same current that does not stop latches after `t_i_cont_s`.

Shorten `t_i_cont_s` if your load is meant to be continuous. Both tiers set the
same fault bit, so nothing downstream has to know which one fired.

### The pack's cells are all identical

They are, unless you have asked otherwise. Two separate reasons:

- **No spread has been applied.** `bcp.CellVariation` writes initial SOC,
  capacity and resistance spread into any Simscape battery pack, in any model:

  ```matlab
  v = bcp.CellVariation('SOC_spread_pct',2, 'R_spread_pct',10, 'Seed',7);
  v.apply('myBatteryModel')     % v.revert() puts every parameter back
  ```

  It is also the **Apply to pack** button under Additional settings in
  `bcpSimple`.

- **The pack is built at Lumped model resolution**, which is Battery Model
  Builder's default. A lumped Module contains *one* cell model standing in for
  all `S*P` cells, with equations forcing every parallel assembly to the same
  voltage and SOC -- there is no per-cell state to vary. `apply()` counts what
  it found and tells you which case you are in. Variation goes in per component
  instance, so on a lumped pack it is module-to-module spread; rebuild at
  Detailed resolution for genuine cell-to-cell spread.

Spread matters more than it looks: without it, min, mean and max cell voltage
are the same number, a per-cell CV loop is indistinguishable from a
pack-voltage one, and the per-cell over-voltage trip is unreachable. Whole
classes of bug test as passing.

### Temperature protection never fires

`UseTemperature` is off, so the OT/UT paths are wired to an internal 25 °C
constant. They are present and visibly inert rather than pretending to be a
thermal model. There is no thermal network in this package; wire a real
temperature signal from your battery model and turn the port on.

---

## Reading a run

```matlab
out = sim('myModel');

bcp.Signals.describe()                    % the pack_meas wire contract
bcp.Signals.diagNames()                   % the diag wire contract, 17 channels
bcp.Signals.arbReason(2)                  % 'waiting out the quiet dwell'
bcp.Signals.chargerMode(3)                % 'CV'
bcp.Signals.bmsState(5)                   % 'LOCKOUT'
bcp.Signals.faultBits(10)                 % 'UV + OC_discharge'
bcp.Signals.limitState(1)                 % 'voltage foldback'
bcp.Signals.faultTable()                  % every mask you are likely to see
```

Every output of both blocks is marked for logging by the builders, so
`out.logsout` already has `bms_*` and `chg_*` elements without you adding a
single scope.

Pull a `diag` channel by NAME rather than by column number — the width has
changed once already and it will change again:

```matlab
D  = squeeze(out.logsout.getElement('bms_diag').Values.Data);
if size(D,1) == bcp.Signals.DIAG_NUM, D = D.'; end
dn = bcp.Signals.diagNames();
dcl = D(:, strcmp(dn, 'dcl_frac'));
```

**The four numbers worth looking at first when a run surprises you:**

```matlab
faults = squeeze(out.logsout.getElement('bms_faults').Values.Data);
sum(diff(double(faults(:) > 0)) > 0)      % fault RISING EDGES -- >1 means cycling
min(D(:, strcmp(dn,'dcl_frac')))          % <1 = the limiter was doing the work
max(D(:, strcmp(dn,'retry_count')))       % >0 = something recovered and re-tripped
min(D(:, strcmp(dn,'soc_raw_min')))       % <0 = the pack model went past empty
```

`max(faults)` is not one of them. A run that tripped once and a run that cycled
thirty times report the same maximum.

---

## When you have changed MATLAB release

Run the build tests. They construct and simulate real models, so they catch a
moved library path or a renamed block dialog parameter — the two things that
break programmatic model building across releases.

```matlab
runtests('tBcpAlgorithms')   % seconds, no Simulink
runtests('tBcpBuild')        % about a minute, needs Simulink
runtests('tBcpApp')          % UI wiring
```

Verified against MATLAB R2025b on Windows.
