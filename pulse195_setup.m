function [p, ct] = pulse195_setup(varargin)
%PULSE195_SETUP  The 195S1P Molicel P45B pulse-load test, as a bcp.Project.
%
%   [p, ct] = pulse195_setup()
%   [p, ct] = pulse195_setup('Period_s', 600)     % real timing
%
%   THE TEST
%     A 31250 W load pulse, 2 s long, repeated once per period, on a 195S1P
%     pack of Molicel INR-21700-P45B cells. Between pulses the charger tops the
%     pack back up at the cell's standard charge current. Nothing else.
%
%   OPTIONS
%     Period_s   pulse repetition period [s].     Default 60. Real value 600.
%     Pulse_s    pulse length [s].                Default 2.
%     P_load_W   pulse power [W].                 Default 31250.
%     Start_s    quiet time before the first pulse [s]. Default 5.
%     Ts         BMS and charger sample period [s].    Default 0.01.
%     Edge_s     rise and fall time of each pulse [s]. Default 0.05. See
%                section 6 -- 0 is not accepted, because a step edge is what
%                the load limiter cannot catch.
%
%   WHY THE DEFAULT PERIOD IS 60 s AND NOT 600 s
%     The pulse is the experiment; the gap is not. Nothing in this package or
%     in the pack model changes with time alone -- there is no thermal model,
%     no self-discharge, no ageing -- so a 598 s rest and a 58 s rest differ
%     only in how many solver steps they cost, and at 195 series Simscape
%     elements that is the whole run time.
%
%     What compressing the gap DOES change is the charge-to-discharge energy
%     ratio. A 2 s pulse takes about 0.026 Ah out; the charger puts 4.35 A back
%     for the whole gap, which is 0.070 Ah in 58 s and 0.72 Ah in 598 s. Both
%     are net-charging by a wide margin, which is the property that matters --
%     the pack climbs between pulses either way. The 60 s version just climbs
%     ten times more slowly per pulse, so a short run shows several pulses
%     against a visibly rising SOC instead of one pulse and a flat line.
%
%     Pass 'Period_s', 600 for the real timing. The pulse itself is never
%     scaled: 2 s at 31250 W is the thing under test.
%
%   EVERY THRESHOLD HERE IS AUTO-FILLED. THAT IS NEW, AND IT IS THE POINT
%     This file used to override one of them, I_dch_trip, because a single
%     discharge trip derived from the cell's CONTINUOUS rating fires on any
%     pulse worth testing. Protection is now two-tiered -- see section 5 -- so
%     the auto-filled values handle this load on their own and the override is
%     gone. The whole project can be reproduced from the UI by choosing the
%     cell, typing 195 and 1, and pressing Auto-fill all.

opt = struct('Period_s',60, 'Pulse_s',2, 'P_load_W',31250, 'Start_s',5, ...
             'Ts',0.01, 'Edge_s',0.05);
for k = 1:2:numel(varargin)
    assert(isfield(opt, varargin{k}), 'pulse195:Option', ...
        'Unknown option "%s". Valid: %s.', varargin{k}, ...
        strjoin(fieldnames(opt).', ', '));
    opt.(varargin{k}) = varargin{k+1};
end
assert(opt.Pulse_s < opt.Period_s, 'pulse195:Duty', ...
    'Pulse_s (%g) must be shorter than Period_s (%g).', opt.Pulse_s, opt.Period_s);
assert(opt.Edge_s >= 4*opt.Ts, 'pulse195:Edge', ...
    ['Edge_s (%g s) must span at least four BMS samples (%g s). The limiter has ', ...
     'two samples of loop latency -- the measurement is already one sample old ', ...
     'and it can only act on the next one -- so an edge of two samples reaches ', ...
     'full demand before the limiter has responded to any part of it, which is ', ...
     'a step as far as the limiter is concerned. Four samples gives it two ', ...
     'chances on the way up. See section 6.'], opt.Edge_s, 4*opt.Ts);
assert(opt.Edge_s < 0.1*opt.Pulse_s, 'pulse195:Edge', ...
    ['Edge_s (%g s) must be under a tenth of Pulse_s (%g s), or the ramp is a ', ...
     'material part of the pulse and the energy delivered is no longer the ', ...
     'number in the test description.'], opt.Edge_s, opt.Pulse_s);

%% 1. The cell -------------------------------------------------------------
%  Read from the .ssc the Battery Model Builder generated for Batteries.slx,
%  not from bcp.CellLibrary. The library holds datasheet scalars; the pack
%  model runs on these tables. They disagree -- 4.168 V at full rather than
%  4.20, and a resistance that moves by a factor of two across the SOC range --
%  and a harness result computed from one cannot be checked against a Simscape
%  result computed from the other.
ct   = bcp.CellTables.fromPackage(fullfile(fileparts(mfilename('fullpath')), '+Batteries'));
cell = ct.toCellLibrary();          % capacity and R from the table; limits from
                                    % the datasheet, because a limit is not a
                                    % model parameter and is not in the table

%% 2. The pack -------------------------------------------------------------
%  195 cells in series, one deep. S counts what the BMS's input arrays count,
%  so this is only correct if the block is wired to the 195-wide
%  vParallelAssembly / socParallelAssembly outputs. NewPack also exposes
%  15-wide per-module arrays, and wiring those with S = 195 gets pack current
%  wrong by a factor of 13. pulse195_model.m does the wiring and
%  p.verifyWiring() proves it after the fact.
spec = bcp.PackSpec('Cell', cell, 'S', 195, 'P', 1);

p = bcp.Project('Pack', spec);
p = p.autofillAll();                % every threshold and gain from the pack

%% 3. The load -------------------------------------------------------------
duty = 100 * opt.Pulse_s / opt.Period_s;
p.Load = bcp.LoadSignal( ...
    'Waveform',           'pulse', ...
    'Pulse_Base_W',       0, ...        % a real rest between pulses, not a trickle
    'Pulse_Amplitude_W',  opt.P_load_W, ...
    'Pulse_Frequency_Hz', 1/opt.Period_s, ...
    'Pulse_Duty_pct',     duty, ...
    'Pulse_Phase_deg',    0, ...
    'StartTime_s',        opt.Start_s, ...  % let the charger show first
    'Pmin_W',             0, ...            % no accidental regen through the load
    'Pmax_W',             1.12 * opt.P_load_W, ...
    'Slew_W_per_s',       opt.P_load_W / opt.Edge_s, ...   % see section 6
    'IdleThreshold_W',    5, ...
    'OutputSign',         1);

%% 4. Sample rate ----------------------------------------------------------
p.Bms.Ts     = opt.Ts;
p.Charger.Ts = opt.Ts;

%% 5. Why the auto-filled discharge protection fits this pulse -------------
%  This load is not continuous, and the pack does not get to choose its
%  current: 31250 W into a sagging pack draws
%
%      I = (Voc - sqrt(Voc^2 - 4*R*P)) / (2*R)
%
%  which for these tables is about 42.6 A at 100% SOC, 45.9 A at 95%, 48.9 A
%  at 60% and 55.4 A at 20%. Against ONE trip at 1.10 x the cell's 45 A
%  continuous rating -- 49.5 A -- the designed pulse fires protection anywhere
%  below about 50% SOC. The protection layer would be tripping on the
%  experiment rather than on a fault, which is why this file used to raise that
%  trip to 60 A by hand.
%
%  bcp.BmsConfig now stages over-current the way real protection does, in two
%  tiers per direction:
%
%      49.5 A confirmed over t_i_cont_s = 10 s   the CONTINUOUS rating
%      74.3 A confirmed over t_i_trip   = 0.1 s  the PULSE rating
%
%  A 2 s pulse at 55 A reaches neither: it is far too short to accumulate ten
%  seconds of dwell, and far below the pulse tier. A 55 A load that did NOT
%  stop would latch after ten seconds, which is correct -- 45 A continuous is a
%  thermal limit over minutes, and this is 2 s at a 3% duty cycle. Below about
%  5% SOC the sag drives the pulse current toward the fast tier, and by then
%  the under-voltage trip is the one doing the work anyway.
%
%  So there is nothing to override here. The distinction between "briefly above
%  the continuous rating" and "over-current" is now in the protection layer
%  itself, where it belongs, instead of in a single threshold that had to be
%  wrong in one direction or the other.

%% 6. Why this test needs the load limiter, and a soft pulse edge ------------
%  Section 5 covers over-current. UNDER-VOLTAGE is the harder problem on this
%  pack, and it is arithmetic rather than opinion.
%
%  A constant-power load into a source with resistance has a maximum
%  deliverable power, at the point where the source impedance matches:
%
%      P_max(SOC) = Voc(SOC)^2 / (4 * R(SOC))
%
%  For these tables at 195S1P:
%
%      SOC    Voc      R_pack   P_max      pulse current   lowest cell
%      100%   812.8 V  1.857 O  88.9 kW    42.6 A          4.11 V
%       60%   738.8 V  2.034 O  67.1 kW    48.9 A          3.28 V
%       20%   658.8 V  1.708 O  63.5 kW    55.4 A          2.89 V
%       10%   638.7 V  2.332 O  43.7 kW    63.8 A          2.51 V
%        5%   628.7 V  2.865 O  34.5 kW    76.0 A          2.13 V
%        3%   624.6 V  3.237 O  30.1 kW    -- no solution --
%
%  Three things fall out of that table, and each one bites:
%
%  1. The under-voltage trip at 2.50 V/cell is first reached at about 10% SOC.
%     Not at the end of the discharge -- with a tenth of the pack's charge left.
%
%  2. Below about 3% SOC the 31250 W demand EXCEEDS P_max and the operating
%     point does not exist. There is no voltage at which the pack delivers
%     31250 W; the quadratic has no real root. A solver asked for it drives the
%     voltage toward collapse, which is where the "dip peaks go way under the
%     limit" excursions come from. Nothing is wrong with the pack model: the
%     demand is impossible.
%
%  3. Between the two, dV/dP is enormous. At 5% SOC the pulse is at 90% of
%     P_max, and there a 1% change in demand moves the terminal voltage by
%     several percent. Any binary controller in that region oscillates.
%
%  A trip cannot manage this, because cutting the load removes the sag that
%  tripped it -- see alg/bcp_load_limiter.m for the full cycle. The limiter can,
%  because it derates continuously and regulates the lowest cell into a band
%  just above the trip:
%
%      full load above 2.78 V/cell   (V_uv_trip + 0.08 + 0.20)
%      zero load at    2.58 V/cell   (V_uv_trip + 0.08)
%
%  Read against the table: the design pulse runs completely unlimited down to
%  about 15% SOC, is progressively derated from there, and near empty delivers
%  whatever holds the pack at 2.58 V/cell instead of demanding the impossible.
%  The under-voltage trip stops being reached at all, which is what a trip is
%  for.
%
%  THE PULSE EDGE IS NO LONGER A STEP, AND THAT IS NOT COSMETIC
%    Slew_W_per_s used to be 0 here, which is a 31250 W discontinuity in the
%    algebraic constraint the Simscape solver has to satisfy. Two separate
%    problems with that, now that a limiter exists:
%
%      The solver. A hard step on a 195-element stiff pack model either costs a
%      very small step across the edge or fails to converge outright.
%
%      The limiter. It reads a measurement that is already one sample old and
%      can only act on the next sample, so a step gets two full samples -- 20 ms
%      -- of undiminished demand whatever its fall rate. At 5% SOC, 20 ms at
%      31250 W is enough to reach the trip the limiter exists to avoid.
%
%    THE LATENCY IS TWO SAMPLES, SO THE EDGE HAS TO BE LONGER THAN THAT
%      The limiter reads pack voltage through the BMS block's input unit delay,
%      so its measurement is already one sample old, and it can only change the
%      command on the following sample. That is two samples of loop latency --
%      20 ms at Ts = 0.01 -- before the first derated command reaches the load,
%      whatever Fold_Fall_per_s is set to.
%
%      An edge of two samples therefore reaches full demand before the limiter
%      has responded to any part of it: a step, in every way that matters here.
%      Edge_s = 0.05 spans five samples, so the limiter sees the demand at
%      roughly 20%, 40% and 60% before it arrives, and has acted twice by the
%      time it does. The assertion above enforces four as the minimum.
%
%      50 ms is 2.5% of the 2 s pulse. The energy cost is close to exactly zero
%      rather than small: the rise gives up about half of one edge time at full
%      power and the fall gains the same amount back, so the two cancel to first
%      order and the pulse still delivers 31250 W for 2 s to well inside every
%      tolerance in pulse195_verify. It is also a more honest model of a real
%      load, none of which step. bcp.Project.check() reports it as an issue if
%      you set it back to zero on a load this size.

p = p.sync();
end
