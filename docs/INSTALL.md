# Installing the BMS and charger into your battery model

This is the step-by-step procedure. It assumes you already have a model
containing a pack built with the Simulink Battery Model Builder and a dynamic
load block that takes a watts signal.

Read [blocks.md](blocks.md) if you want the port-by-port reference first, and
[troubleshooting.md](troubleshooting.md) when something goes wrong — it is
organised by the error message you actually see.

---

## Before you start: prove it on the throwaway model

Wiring two new blocks into a Simscape battery model means debugging the blocks,
the wiring, the sign conventions and the solver settings at once, with a
slow simulation between each attempt. Do it in the wrong order and you will
spend an afternoon deciding whether a flat trace is a sign error or a
sample-time error.

So don't. Run this first:

```matlab
run('START_HERE.m')          % path, tests, UI
```

then on the **Install** tab press **Build test harness**, then **Simulate
harness**. That builds `bcp_harness`: the same two blocks, plus a crude
resistive battery stand-in, in a model that runs in about a second and needs no
Simscape licence.

Get these four things right there:

| Question | Where you see the answer |
|---|---|
| Does the load waveform look like what I configured? | panel 1 of the plot, and the Load tab preview |
| Does the charger actually stay off while the load pulses? | panel 4, `load_active` against `arb_reason` |
| Does CC hand over to CV, and does the taper terminate? | `chg_mode` reaching 2, then 3, then 4 |
| Does an over-voltage latch, and does the load clear it? | panel 2 against the trip lines |

The stand-in is emphatically not a battery — `alg/bcp_harness_plant.m` says
exactly what it does and does not model. It is for getting the *blocks* right.
Everything that is a claim about a cell belongs on your real pack.

---

## Step 1 — Configure

Open the UI and fill in the tabs left to right.

```matlab
bcpApp
```

**Pack tab.** Pick your cell and set S and P.

> S and P must count the same thing your battery model's output arrays count. If
> the Battery Model Builder gave you one array entry per cell, they are cell
> counts. If you built the pack from modules and the arrays are per-module, S is
> the number of series **modules**, P the number of parallel strings of modules,
> and the cell fields should hold the **module's** parameters. Step 5 checks
> which one you actually have, so you do not have to guess now.

**Load tab.** Pick the waveform and set its parameters. Watch the preview: the
shaded regions are where the load is active and the charger is locked out, and
the unshaded gaps are the only time charging can happen. If there are no gaps,
the charger will never run — which may be exactly what you want, but it should
be a decision.

**Then press "Auto-fill all"** in the top bar. That derives every BMS protection
threshold and every charge parameter from the pack. It is the intended way to
fill those two tabs; the numbers a CC/CV charger needs are already implied by
the cell datasheet and your S and P.

**Press "Check config".** It cross-checks the tabs against each other and
catches the combinations that produce a run which looks fine and answers a
different question — a charge current above the BMS trip, a quiet dwell longer
than the gap between your pulses, a load peak beyond what the pack can supply.

Save it, so a result can be traced back to a configuration:

```matlab
% or the Save button
p.save('BmsChargerPackage/configs/mypack.mat')
```

---

## Step 2 — Reconcile the sample times

Do this **before** inserting anything. It is the single most common reason a
block that worked in one model refuses to compile in another.

Open your battery model, then on the **Install** tab pick it in **Target model**
(press **Refresh list** if it is not there) and press **Audit sample times**.

The rule:

- **Variable-step solver** — any positive `Ts` works. The solver adds each
  block's sample hits to the list of times it must land on exactly. This is the
  usual case for a Simscape battery model, and you will probably never see a
  rate error.
- **Fixed-step solver** — every discrete `Ts` must be an exact integer multiple
  of the fundamental step. `0.01` on a `0.001` step is fine; `0.01` on a `0.003`
  step is rejected at compile time.
- **A Simscape local solver is a third clock.** A Solver Configuration block
  with *Use local solver* ticked runs the physical network at its own step,
  independently of the model's and of these blocks. The audit reports it
  explicitly because it is the one people forget.

If the audit complains about the fixed step, **Align fixed step** sets it so the
block rates are legal — the greatest common divisor of your two rates divided by
ten, so the continuous plant still gets ten steps per BMS sample. It touches
`FixedStep` and nothing else; solver type, stop time and local solvers are
decisions about your model, not about these blocks.

From a script:

```matlab
bcp.Rate.audit('myBatteryModel', [0.01 0.01])
bcp.Rate.align('myBatteryModel', [0.01 0.01])
```

**Do not set `Ts` to −1 (inherit).** Both blocks hold persistent state — dwell
timers, PI integrators, latches — and every one of them multiplies by `Ts` to
turn samples into seconds. Inherited, `Ts` becomes a lie: the code believes it
runs at the configured period while the solver calls it whenever it likes, and a
"0.5 second" trip confirmation becomes however long 50 variable steps happen to
take. The block runs, logs plausible traces, and times everything wrong.

---

## Step 3 — Insert the blocks

With your model open and selected as the target, press **Insert blocks**.

```matlab
p.insertInto('myBatteryModel')       % same thing from a script
```

You get a `BMS` subsystem, a `Charger` subsystem, and the five lines between
them already drawn — those five are fixed by the port contract, so there is no
reason to make you draw them.

**Inserting is repeatable.** It deletes any previous block of the same name
first, so changing a threshold and re-inserting is the normal edit cycle and
will not accumulate copies. It does drop the wires you drew to the block, which
is why the ports are stable: same names, same order, so redrawing a handful of
lines is the whole cost of a reconfiguration.

**Start with the charger switched off.** On the BMS tab, untick **Charger
ports**. That removes the `P_chg` and `chg_done` inports and wires internal
zeros instead. Prove the load path drives your pack the way you expect, then
come back and turn it on. Debugging one block beats debugging two.

---

## Step 4 — Draw the wires

### Into the BMS

Find the measurement outputs on your Battery Model Builder pack — the arrays of
per-cell voltage, state of charge, and current — and wire them to the first
three BMS inports:

```
battery cell voltage array  ->  BMS.V_cell
battery cell SOC array      ->  BMS.SOC_cell
battery cell current array  ->  BMS.I_cell
```

All three must be the **same width**. Step 5 checks that.

If you enabled the temperature input, `T_cell` follows them. If you enabled the
reset port, it is last. `p.insertInto` prints the port map for your exact
configuration, and so does:

```matlab
bcp.BmsBuilder(p.Bms, p.Load).portMap()
```

### Out of the BMS, to your dynamic load

**Pick one of these two. Never both.**

**(a) Bidirectional load block — start here.** If your load block can source as
well as sink power, one wire does everything:

```
BMS.P_net_cmd  ->  dynamic load power input
```

`P_net_cmd` is already the load demand minus the charge power, so the charger
needs no physical connection of its own. Nothing else to build.

**(b) Unidirectional load block.** If your load can only sink, use the load
demand on its own and give the charger its own current source:

```
BMS.P_load_cmd     ->  dynamic load power input
Charger.I_chg_cmd  ->  Simulink-PS Converter  ->  Controlled Current Source
                                                  across the pack terminals
```

Mind the polarity of the current source: this package is **charge-positive**, so
`I_chg_cmd` is positive when it should be pushing current *into* the pack.
Option (b) is the more faithful arrangement — the charger has a real physical
port and its own losses — and it is the only option if your load cannot source.

### Sign conventions, the two that actually bite

**Battery current polarity.** Simscape Battery blocks report current positive
*out of* the positive terminal — positive when **discharging**. This package is
charge-positive internally, so `bcp.BmsConfig.I_sign` defaults to `-1` to
convert. Get it wrong and the BMS over-current-trips on a charge and never trips
on a discharge. Check it once against a known discharge, then leave it alone.

**Load output polarity.** `P_load_cmd` and `P_net_cmd` are draw-positive:
positive watts come out of the pack. If your dynamic load block wants negative
watts for a draw, set **Output sign** to `-1` on the Load tab. Set it once;
everything else in the package stays draw-positive.

**SOC units.** Tick **SOC array is in percent** on the BMS tab if your model
reports 0–100 rather than 0–1.

---

## Step 5 — Verify the wiring

Press **Verify wiring**.

```matlab
p.verifyWiring('myBatteryModel')
```

This compiles the model, reads the actual compiled port widths, and tells you
whether the arrays reaching the BMS are one entry per cell (`S*P`) or one per
series element with the parallel strings lumped (`S`). **Nothing can tell you
that before a compile** — which array layout the Battery Model Builder produces
is a build option.

Either layout is fine. The BMS computes pack voltage as `mean(V)*S` and pack
current as `sum(I)/S`, and both forms are correct for both layouts, so it does
not need to know. What it does need is for `S` to be counting the right thing:
pack current is divided by `S`, so an `S` that counts the wrong thing scales
every current in the BMS by a constant factor. If the check reports "matches
neither", that is what has happened.

It also verifies the three arrays are the same width. If they are not, one of
them is wired to the wrong signal.

---

## Step 6 — Run it

Set a stop time long enough for something to happen. Use **Estimate charge
time** on the Charger tab as a sanity check: it reports the CC-phase duration
and warns you if your load's average draw is at or above the charge current, in
which case the pack will never fill — it will settle wherever load and charge
balance.

Every interesting signal inside both blocks is already marked for logging, so
you do not need to add scopes:

```matlab
out = sim('myBatteryModel');

% what the arbiter did, and why
diag = out.logsout.getElement('bms_diag').Values;
disp(bcp.Signals.diagNames())

% decode the codes into words
bcp.Signals.arbReason(2)      % 'waiting out the quiet dwell'
bcp.Signals.chargerMode(3)    % 'CV'
bcp.Signals.faultBits(5)      % 'OV + OC_charge'
bcp.Signals.describe()        % the pack_meas wire contract
```

---

## One thing to remember afterwards

The generated blocks call functions in `BmsChargerPackage/alg/`, so **`bcp_setup`
must have run in the session before your model will compile**. `START_HERE.m`
does that. If you send the model to a colleague, send this folder with it — or
add this to your model's `PostLoadFcn`:

```matlab
run('<path to>/BmsChargerPackage/bcp_setup.m')
```

That hardcodes a path into the model, which is why it is not the default.

---

## The shortest version

```matlab
run('START_HERE.m')                                  % path + UI

% configure in the UI, or:
spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
p    = bcp.Project('Pack', spec).autofillAll();
p.Load = bcp.LoadSignal('Waveform','pulse', 'Pulse_Amplitude_W',900, ...
            'Pulse_Frequency_Hz',0.1, 'Pulse_Duty_pct',30, 'Pmax_W',4000);
p = p.sync();
p.report()                                           % includes the cross-checks

h = bcp.Harness(p); h.build(); h.plot(h.simulate(600));   % prove it

open_system('myBatteryModel')
bcp.Rate.audit('myBatteryModel', [p.Bms.Ts p.Charger.Ts])
p.insertInto('myBatteryModel')
% ... draw the wires from step 4 ...
p.verifyWiring('myBatteryModel')
```
