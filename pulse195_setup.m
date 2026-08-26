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
%   WHAT IS DELIBERATELY NOT THE AUTO-FILLED DEFAULT
%     One threshold, I_dch_trip, and the reason is written at the point of
%     change below. Everything else on this project comes from
%     autofillAll() -- i.e. from the cell and the topology -- so it can be
%     reproduced from the UI by choosing the cell, typing 195 and 1, and
%     pressing Auto-fill all.

opt = struct('Period_s',60, 'Pulse_s',2, 'P_load_W',31250, 'Start_s',5, 'Ts',0.01);
for k = 1:2:numel(varargin)
    assert(isfield(opt, varargin{k}), 'pulse195:Option', ...
        'Unknown option "%s". Valid: %s.', varargin{k}, ...
        strjoin(fieldnames(opt).', ', '));
    opt.(varargin{k}) = varargin{k+1};
end
assert(opt.Pulse_s < opt.Period_s, 'pulse195:Duty', ...
    'Pulse_s (%g) must be shorter than Period_s (%g).', opt.Pulse_s, opt.Period_s);

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
    'Slew_W_per_s',       0, ...            % hard edges; see the note in the report
    'IdleThreshold_W',    5, ...
    'OutputSign',         1);

%% 4. Sample rate ----------------------------------------------------------
p.Bms.Ts     = opt.Ts;
p.Charger.Ts = opt.Ts;

%% 5. The one threshold that is not auto-filled ----------------------------
%  fromPack sets I_dch_trip to 1.10 x the cell's 45 A CONTINUOUS rating, which
%  rounds to 50 A. That is the right default for a continuous load and the
%  wrong one here, because this load is not continuous and the pack does not
%  get to choose its current: 31250 W into a sagging pack is
%
%      I = (Voc - sqrt(Voc^2 - 4*R*P)) / (2*R)
%
%  which for these tables is 42.6 A at 100% SOC, 45.9 A at 95%, 48.9 A at 60%
%  and 55.4 A at 20%. A 50 A trip therefore fires on the designed pulse
%  anywhere below about 50% SOC -- the protection layer would be tripping on
%  the experiment rather than on a fault.
%
%  60 A leaves 23% margin over the worst case inside the intended 60-100% SOC
%  operating band, and still trips the pulse below about 13% SOC, which is
%  where sag genuinely does start pulling cells toward the 2.45 V floor. It is
%  above the cell's 45 A continuous rating on purpose: 45 A is a thermal limit
%  over minutes, and this is 2 s at a 3% duty cycle.
%
%  This is a judgement about the application, not about the cell, which is
%  exactly why auto-fill does not make it for you. Change it here and nowhere
%  else.
p.Bms.I_dch_trip = 60;

p = p.sync();
end
