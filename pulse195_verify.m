function [ok, T, S] = pulse195_verify(out, p, ct, varargin)
%PULSE195_VERIFY  Check a pulse-test run against what the numbers say it should be.
%
%   [ok, T, S] = pulse195_verify(out, p, ct)
%   [ok, T, S] = pulse195_verify(out, p, ct, 'Period_s',60, 'Pulse_s',2)
%
%   OUT is a Simulink.SimulationOutput from either the fast harness or the real
%   Simscape model. P is the bcp.Project the run was configured from and CT is
%   the bcp.CellTables the cell was read from.
%
%   Returns OK (all checks passed), T (a table of every check) and S (the
%   extracted signals, so you can look at anything the checks did not).
%
%   WHAT MAKES THIS A CHECK RATHER THAN A PLOT
%     Every threshold below is computed from the cell tables and the pack
%     topology at verification time, not copied from the run. The pulse current
%     check in particular solves the constant-power operating point
%
%         P = V*I,  V = OCV(SOC) - I*R(SOC)   =>   R*I^2 - OCV*I + P = 0
%
%     from the SOC the run actually reached, and compares it against the
%     current the run actually drew. Nothing in the model computes it that way,
%     so agreeing is evidence rather than a tautology.

opt = struct('Period_s',60, 'Pulse_s',2, 'P_load_W',31250, 'Start_s',5, ...
             'SOC_init',[], 'I_tol_pct',4, 'P_tol_pct',3, 'SOC_tol_pct',8, ...
             'Verbose',true);
for k = 1:2:numel(varargin)
    assert(isfield(opt, varargin{k}), 'pulse195:Option', ...
        'Unknown option "%s".', varargin{k});
    opt.(varargin{k}) = varargin{k+1};
end

S = local_extract(out, p);
Q = p.Pack.Cell.Q_Ah * p.Pack.P;            % Ah, per series element
Sc = p.Pack.S;

chk = {};   % {name, pass, detail}

%% ---- 1. protection never fired -----------------------------------------
maxFault = max(S.faults);
chk(end+1,:) = {'no fault latched', maxFault == 0, ...
    sprintf('max fault mask = %d (%s)', maxFault, bcp.Signals.faultBits(maxFault))};

chk(end+1,:) = {'contactor closed throughout', all(S.contactor > 0.5), ...
    sprintf('%.1f%% of samples closed', 100*mean(S.contactor > 0.5))};

chk(end+1,:) = {'never entered FAULT state', ~any(S.state == 4), ...
    sprintf('states seen: %s', mat2str(unique(round(S.state)).'))};

%% ---- 2. the load command is the waveform that was asked for -------------
[pulses, npulse] = local_pulses(S.t, S.P_load, opt.P_load_W/2);

% The last pulse may be cut short by the stop time; the width check below
% excludes partials, so allow the count to be off by one either way.
expN = floor((S.t(end) - opt.Start_s) / opt.Period_s) + 1;
chk(end+1,:) = {'pulse count', abs(npulse - expN) <= 1, ...
    sprintf('%d pulses in %.0f s, expected about %d', npulse, S.t(end), expN)};

if npulse > 0
    widths = pulses(:,2) - pulses(:,1);
    full   = widths(widths > 0.5*opt.Pulse_s);     % drop a truncated last pulse
    wErr   = max(abs(full - opt.Pulse_s));
    chk(end+1,:) = {'pulse width', wErr <= 3*S.dt + 1e-9, ...
        sprintf('%.4f .. %.4f s, want %.3f s (tol 3 steps = %.3f s)', ...
        min(full), max(full), opt.Pulse_s, 3*S.dt)};

    if npulse >= 2
        per    = diff(pulses(:,1));
        pErr   = max(abs(per - opt.Period_s));
        chk(end+1,:) = {'pulse period', pErr <= 3*S.dt + 1e-9, ...
            sprintf('%.4f .. %.4f s, want %.3f s', min(per), max(per), opt.Period_s)};
    end

    onMask = local_mask(S.t, pulses);
    pk = max(S.P_load);
    chk(end+1,:) = {'commanded pulse power', abs(pk - opt.P_load_W) < 1, ...
        sprintf('peak P_load_cmd = %.1f W, want %.0f W', pk, opt.P_load_W)};
    chk(end+1,:) = {'zero load between pulses', max(abs(S.P_load(~onMask))) < 1e-6, ...
        sprintf('max |P_load_cmd| off-pulse = %.3g W', max(abs(S.P_load(~onMask))))};
else
    onMask = false(size(S.t));
    chk(end+1,:) = {'pulse present', false, 'no pulses found in the run'};
end

%% ---- 3. the pack answered the pulse the way the tables say it must ------
%  Compare against the constant-power root, evaluated at the SOC the run was
%  actually at when each pulse landed. Sampled at the END of each pulse, where
%  the operating point has settled and the plant's one-step voltage lag has
%  washed out.
%  The sign convention comes first, because everything downstream reads as
%  nonsense if it is wrong and none of it names the cause. I_pack is
%  charge-positive by this package's definition, so a load pulse must be
%  negative. If it is not, bcp.BmsConfig.I_sign is backwards for this pack.
if npulse > 0
    Iduring = S.I_pack(onMask);
    chk(end+1,:) = {'pack current is negative (discharging) during pulses', ...
        ~isempty(Iduring) && median(Iduring) < 0, ...
        sprintf(['median I_pack during pulses = %+.2f A; positive here means ' ...
                 'I_sign is backwards for this pack model'], median(Iduring))};
end

if npulse > 0
    nFull = sum(pulses(:,2) - pulses(:,1) > 0.5*opt.Pulse_s);
    Ipred = zeros(nFull,1); Imeas = Ipred; Vmeas = Ipred; Pmeas = Ipred; socAt = Ipred;
    for k = 1:nFull
        idx = find(S.t <= pulses(k,2) - 2*S.dt, 1, 'last');
        socAt(k) = S.SOC(idx);
        Voc = ct.ocv(socAt(k)) * Sc;
        R   = ct.r0(socAt(k)) * Sc / p.Pack.P;
        d   = Voc^2 - 4*R*opt.P_load_W;
        Ipred(k) = (Voc - sqrt(max(d,0))) / (2*R);
        Imeas(k) = -S.I_pack(idx);           % charge-positive -> draw-positive
        Vmeas(k) =  S.V_pack(idx);
        Pmeas(k) =  Vmeas(k) * Imeas(k);
    end
    err = 100 * abs(Imeas - Ipred) ./ Ipred;
    chk(end+1,:) = {'pulse current matches the constant-power root', ...
        max(err) <= opt.I_tol_pct, ...
        sprintf('measured %.2f-%.2f A vs predicted %.2f-%.2f A, worst error %.2f%%', ...
        min(Imeas), max(Imeas), min(Ipred), max(Ipred), max(err))};

    pErr = 100 * abs(Pmeas - opt.P_load_W) / opt.P_load_W;
    chk(end+1,:) = {'pack actually delivered the commanded watts', ...
        max(pErr) <= opt.P_tol_pct, ...
        sprintf('V*I = %.0f-%.0f W against a %.0f W command, worst error %.2f%%', ...
        min(Pmeas), max(Pmeas), opt.P_load_W, max(pErr))};

    % Against the FAST tier, because that is the only one a 2 s pulse can
    % reach: the sustained tier confirms over t_i_cont_s, which is longer than
    % the pulse. A pulse above the sustained threshold is expected and fine --
    % that is the whole reason protection is staged.
    chk(end+1,:) = {'pulse current stayed under the fast discharge trip', ...
        max(Imeas) < p.Bms.I_dch_peak_A, ...
        sprintf(['peak %.2f A against a %.0f A fast trip (%.0f%% margin); the ', ...
                 '%.0f A sustained trip needs %.0f s of dwell and the pulse is shorter'], ...
        max(Imeas), p.Bms.I_dch_peak_A, 100*(p.Bms.I_dch_peak_A/max(Imeas)-1), ...
        p.Bms.I_dch_trip, p.Bms.t_i_cont_s)};
end

%% ---- 4. SOC moved by exactly the charge that went through ---------------
%  Coulomb consistency, per pulse and per charge window. This is the check that
%  catches a capacity or an S that is counting the wrong thing: the currents
%  can look right and the SOC still move by the wrong amount.
if npulse > 0
    dSOCmeas = zeros(nFull,1); dSOCpred = dSOCmeas;
    for k = 1:nFull
        i0 = find(S.t <= pulses(k,1), 1, 'last');
        i1 = find(S.t <= pulses(k,2), 1, 'last');
        dSOCmeas(k) = S.SOC(i1) - S.SOC(i0);
        Ah = trapz(S.t(i0:i1), S.I_pack(i0:i1)) / 3600;     % negative on a draw
        dSOCpred(k) = Ah / Q;
    end
    e = 100 * abs(dSOCmeas - dSOCpred) ./ abs(dSOCpred);
    chk(end+1,:) = {'SOC drop per pulse = integrated current / capacity', ...
        max(e) <= opt.SOC_tol_pct, ...
        sprintf('measured %.4f%% vs coulomb-counted %.4f%% per pulse, worst error %.2f%%', ...
        -100*mean(dSOCmeas), -100*mean(dSOCpred), max(e))};
end

chgMask = S.chg_enable > 0.5;
if any(chgMask)
    win = local_pulses(S.t, double(chgMask), 0.5);
    win = win(win(:,2)-win(:,1) > 5, :);        % windows worth measuring
    if ~isempty(win)
        dm = zeros(size(win,1),1); dp = dm;
        for k = 1:size(win,1)
            i0 = find(S.t <= win(k,1), 1, 'last');
            i1 = find(S.t <= win(k,2), 1, 'last');
            dm(k) = S.SOC(i1) - S.SOC(i0);
            dp(k) = trapz(S.t(i0:i1), S.I_pack(i0:i1)) / 3600 / Q;
        end
        e = 100 * abs(dm - dp) ./ abs(dp);
        chk(end+1,:) = {'SOC rise per charge window = integrated current / capacity', ...
            max(e) <= opt.SOC_tol_pct, ...
            sprintf('measured %.4f%% vs coulomb-counted %.4f%% per window, worst error %.2f%%', ...
            100*mean(dm), 100*mean(dp), max(e))};
    end
end

%% ---- 5. the charger did what the arbiter allowed ------------------------
chk(end+1,:) = {'charger held off for the whole of every pulse', ...
    ~any(chgMask & onMask), ...
    sprintf('%d samples with the charger enabled during a pulse', sum(chgMask & onMask))};

if any(chgMask)
    Ichg = S.I_chg_cmd(chgMask);
    settled = Ichg(Ichg > 0.1);
    chk(end+1,:) = {'charge current sits at the permitted charge rate', ...
        ~isempty(settled) && abs(median(settled) - p.chargeCurrent()) < 0.05, ...
        sprintf('median %.3f A against a %.3f A permitted rate', ...
                median(settled), p.chargeCurrent())};
    chk(end+1,:) = {'charge current never exceeded the BMS ceiling', ...
        max(S.I_chg_cmd) <= max(S.I_chg_limit) + 1e-6, ...
        sprintf('peak command %.3f A, ceiling %.3f A', ...
        max(S.I_chg_cmd), max(S.I_chg_limit))};
    chk(end+1,:) = {'measured charge current never reached the charge trip', ...
        max(S.I_pack) < p.Bms.I_chg_trip, ...
        sprintf('peak %.3f A against a %.1f A trip', max(S.I_pack), p.Bms.I_chg_trip)};

    % The command line, not the measurement: a charger that is not enabled
    % must be commanding nothing at all.
    off = S.I_chg_cmd(~chgMask);
    chk(end+1,:) = {'charge command is zero whenever the charger is off', ...
        isempty(off) || max(abs(off)) < 1e-9, ...
        sprintf('max |I_chg_cmd| while disabled = %.3g A', max(abs(off)))};
end

%  P_net_cmd is what a bidirectional load block is wired to, and it is supposed
%  to be the load demand with the charge power already taken out. If that
%  arithmetic is wrong the harness plant sees a different pack duty than the
%  one configured, and nothing else in the run says so.
%  P_chg arrives at the BMS through its input unit delay, so the subtraction is
%  of the PREVIOUS sample's charge power. That is not an approximation to
%  tolerate, it is the loop-breaking delay the block is built around -- so find
%  which lag makes the identity exact and report it, rather than allowing a
%  slop band that would also pass if the arithmetic were wrong.
lagErr = inf(1,3);
for lag = 0:2
    pc = [zeros(lag,1); S.P_chg_cmd(1:end-lag)];
    lagErr(lag+1) = max(abs(S.P_net - (S.P_load - pc)));
end
[netErr, bestLag] = min(lagErr);
chk(end+1,:) = {'P_net_cmd = P_load_cmd - P_chg_cmd', netErr < 1e-6, ...
    sprintf('exact at a %d-sample charge-power lag (worst disagreement %.3g W)', ...
    bestLag-1, netErr)};

% The quiet dwell: after a pulse ends the charger must wait t_quiet_s.
if npulse > 0 && p.Bms.t_quiet_s > 0
    lateOK = true; worst = 0;
    for k = 1:nFull
        i1 = find(S.t <= pulses(k,2), 1, 'last');
        j  = find(chgMask(i1:end), 1, 'first');
        if isempty(j), continue; end
        delay = S.t(i1+j-1) - pulses(k,2);
        worst = max(worst, abs(delay - p.Bms.t_quiet_s));
        if delay < p.Bms.t_quiet_s - 3*S.dt, lateOK = false; end
    end
    chk(end+1,:) = {'charger waited out the quiet dwell', lateOK, ...
        sprintf('re-enable delay within %.3f s of the %.2f s dwell', ...
        worst, p.Bms.t_quiet_s)};
end

%% ---- 6. states and voltages --------------------------------------------
if npulse > 0
    stOn = S.state(onMask);
    chk(end+1,:) = {'BMS reports DISCHARGE during pulses', ...
        mean(stOn == 3) > 0.95, ...
        sprintf('%.1f%% of pulse samples in state 3', 100*mean(stOn == 3))};
end
if any(chgMask)
    stC = S.state(chgMask & S.I_pack > 0.05);
    chk(end+1,:) = {'BMS reports CHARGE while charging', ...
        isempty(stC) || mean(stC == 2) > 0.95, ...
        sprintf('%.1f%% of charging samples in state 2', 100*mean(stC == 2))};
end

chk(end+1,:) = {'cell voltage stayed inside the trip band', ...
    min(S.V_min) > p.Bms.V_uv_trip && max(S.V_max) < p.Bms.V_ov_trip, ...
    sprintf('%.3f .. %.3f V against trips %.2f / %.2f V', ...
    min(S.V_min), max(S.V_max), p.Bms.V_uv_trip, p.Bms.V_ov_trip)};

% Pack voltage against mean cell voltage x S -- catches an S that counts the
% wrong thing, which is the single most likely wiring mistake on this pack.
vErr = max(abs(S.V_pack - S.V_mean*Sc));
chk(end+1,:) = {'V_pack = mean(V_cell) x S', vErr < 0.5, ...
    sprintf('worst disagreement %.4f V over the run', vErr)};

%% ---- 7. the pack came back up ------------------------------------------
%  Not S.SOC(1): pack_meas is read through the BMS's input unit delays, so its
%  first sample is whatever those delays initialise to and not the pack's
%  starting SOC. Step past them before calling anything the starting value.
k0 = find(S.t >= S.t(1) + 10*S.dt, 1, 'first');
chk(end+1,:) = {'pack net-charged over the run', S.SOC(end) > S.SOC(k0), ...
    sprintf('SOC %.2f%% -> %.2f%% (%+.2f%%)', ...
    100*S.SOC(k0), 100*S.SOC(end), 100*(S.SOC(end)-S.SOC(k0)))};

%  A Simscape initial target that was set but not enabled reads back correctly
%  from get_param and is then ignored by the solver, so the only way to know
%  the pack started where you asked is to look at where it started.
if ~isempty(opt.SOC_init)
    chk(end+1,:) = {'pack started at the requested SOC', ...
        abs(S.SOC(k0) - opt.SOC_init) < 0.01, ...
        sprintf('started at %.2f%%, asked for %.2f%%', ...
        100*S.SOC(k0), 100*opt.SOC_init)};
end

%% ---- report -------------------------------------------------------------
%  A check whose condition came out empty did not pass -- it failed to be
%  evaluated, which is a worse outcome than failing, so say so rather than
%  letting an empty quietly drop a row out of the table.
pass = false(size(chk,1),1);
for k = 1:size(chk,1)
    v = chk{k,2};
    if isempty(v)
        pass(k)   = false;
        chk{k,3}  = sprintf('NOT EVALUATED (condition was empty) -- %s', chk{k,3});
    else
        pass(k)   = all(logical(v(:)));
    end
end
T = table(chk(:,1), pass, chk(:,3), 'VariableNames', {'Check','Passed','Detail'});
ok = all(T.Passed);

if opt.Verbose
    fprintf('\n=== pulse195 verification ===\n');
    for k = 1:height(T)
        if T.Passed(k), tag = 'PASS'; else, tag = 'FAIL'; end
        fprintf('  [%s] %-52s %s\n', tag, T.Check{k}, T.Detail{k});
    end
    if ok
        fprintf('  ---- %d of %d checks passed.\n\n', height(T), height(T));
    else
        fprintf(2, '  ---- %d of %d FAILED.\n\n', sum(~T.Passed), height(T));
    end
end
end

% =========================================================================
function S = local_extract(out, p)
%LOCAL_EXTRACT  Pull the signals the checks need out of logsout.
g = @(n) out.logsout.getElement(n).Values;

meas = g('bms_pack_meas');
M = squeeze(meas.Data);
if size(M,1) == bcp.Signals.NUM, M = M.'; end

S.t      = meas.Time(:);
S.dt     = median(diff(S.t));
S.V_pack = M(:, bcp.Signals.V_PACK);
S.V_min  = M(:, bcp.Signals.V_MIN);
S.V_max  = M(:, bcp.Signals.V_MAX);
S.SOC    = M(:, bcp.Signals.SOC_PACK);
S.I_pack = M(:, bcp.Signals.I_PACK);
S.V_mean = S.V_pack / p.Pack.S;

S.P_load     = local_resample(g('bms_P_load_cmd'),  S.t);
S.P_net      = local_resample(g('bms_P_net_cmd'),   S.t);
S.state      = local_resample(g('bms_state'),       S.t);
S.faults     = local_resample(g('bms_faults'),      S.t);
S.contactor  = local_resample(g('bms_contactor'),   S.t);
S.chg_enable = local_resample(g('bms_chg_enable'),  S.t);
S.I_chg_limit= local_resample(g('bms_I_chg_limit'), S.t);
S.I_chg_cmd  = local_resample(g('chg_I_chg_cmd'),   S.t);
S.chg_mode   = local_resample(g('chg_mode'),        S.t);
S.P_chg_cmd  = local_resample(g('chg_P_chg_cmd'),   S.t);
S.chg_done   = local_resample(g('chg_done'),        S.t);

D = squeeze(g('bms_diag').Data);
if size(D,1) == 10, D = D.'; end
S.diag = interp1(g('bms_diag').Time(:), D, S.t, 'previous', 'extrap');
S.arb_reason = S.diag(:,3);
end

function y = local_resample(ts, t)
d = squeeze(ts.Data);
y = interp1(ts.Time(:), d(:), t, 'previous', 'extrap');
end

function [seg, n] = local_pulses(t, y, thresh)
%LOCAL_PULSES  Start and stop times of every interval where y exceeds THRESH.
%
%   The stop time is the first sample that is OFF, so that a half-open
%   [start, stop) mask covers exactly the ON samples. An interval still on at
%   the end of the record has no such sample, so the stop is put one step past
%   the end -- otherwise the final ON sample falls outside its own interval and
%   turns up as load during a gap. That happens whenever the run stops on a
%   pulse edge, which a whole number of periods does exactly.
on = y(:) > thresh;
d  = diff([false; on; false]);
i0 = find(d > 0);
i1 = find(d < 0) - 1;
n  = numel(i0);
step = median(diff(t));
seg = zeros(n,2);
for k = 1:n
    seg(k,1) = t(i0(k));
    if i1(k) < numel(t)
        seg(k,2) = t(i1(k)+1);
    else
        seg(k,2) = t(end) + step;
    end
end
end

function m = local_mask(t, seg)
m = false(size(t));
for k = 1:size(seg,1)
    m = m | (t >= seg(k,1) & t < seg(k,2));
end
end
