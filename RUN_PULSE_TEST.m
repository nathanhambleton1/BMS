%% RUN_PULSE_TEST  --  the 195S1P Molicel P45B pulse test, end to end.
%
%   Open in MATLAB and press Run (F5).
%
%   THE TEST
%     31250 W drawn for 2 s, repeated once per period, on 195 Molicel
%     INR-21700-P45B cells in series. Between pulses the charger puts the
%     charge back at the cell's standard 4.35 A. Nothing else is going on.
%
%   WHAT THIS SCRIPT DOES
%     1. Fast stand-in plant, scaled cadence   -- proves the control logic
%     2. Real Simscape pack, scaled cadence    -- proves it on the real cell
%     3. Fast stand-in, real 600 s cadence     -- proves the timing you asked for
%     4. The END OF DISCHARGE, limiter on and off -- proves the fault does not cycle
%
%     Stages 1 to 3 run pulse195_verify, which checks the run against numbers
%     computed from the cell's own lookup tables: the constant-power operating
%     point, coulomb consistency on every pulse and every charge window, the
%     arbitration timing, the state machine and the protection margins.
%
%   STAGE 4 IS A DIFFERENT KIND OF CHECK, AND IT IS THE ONE ABOUT PROTECTION
%     Stages 1 to 3 all run at 60% SOC, where 31250 W is nowhere near the pack's
%     limits and protection has nothing to do. That is the right place to
%     validate the arithmetic, and the wrong place to conclude anything about
%     what happens near empty.
%
%     Stage 4 runs the same pulse from 10% SOC, where 31250 W does reach the
%     under-voltage threshold, twice: with the discharge limiter on and off. The
%     number it reports is the count of fault RISING EDGES, because that is the
%     only measurement that separates a run that tripped once from a run that
%     tripped, recovered, and tripped again deeper -- max(faults) reports the
%     same value for both. See the load-limiter section of README.md.
%
%   THE CADENCE IS SCALED IN STAGES 1 AND 2, AND THE PULSE IS NOT
%     2 s at 31250 W is the experiment and is never touched. The 600 s gap is
%     only a rest: with no thermal model and no self-discharge, 598 s of rest
%     and 58 s of rest differ only in solver steps. Stage 3 runs the real 600 s
%     cadence so you can see that the conclusion does not depend on the
%     compression. See the note at the top of pulse195_setup.
%
%   WHERE THE NUMBERS COME FROM
%     bcp.CellTables reads the OCV, resistance and capacity tables out of the
%     .ssc that the Battery Model Builder generated for Batteries.slx, and both
%     the fast plant and the Simscape pack then run on the same cell. That is
%     what makes stage 1 and stage 2 comparable rather than merely similar.
%
%   The UI for all of this is:  bcpSimple

clc;
root = fileparts(mfilename('fullpath'));
run(fullfile(root, 'BmsChargerPackage', 'bcp_setup.m'));
cd(root);

STAGES = [1 2 3 4];     % edit to run a subset
results = struct('name',{},'ok',{},'checks',{},'failed',{});

%% 1. Fast stand-in, scaled cadence ---------------------------------------
if any(STAGES == 1)
    fprintf('\n\n============ 1/4  fast stand-in, 60 s cadence ============\n');
    [ok, T] = pulse195_harness('Period_s',60, 'StopTime_s',310, 'SOC_init',0.60);
    results(end+1) = struct('name','fast stand-in, 60 s cadence', 'ok',ok, ...
        'checks',height(T), 'failed',sum(~T.Passed));
end

%% 2. Real Simscape pack, scaled cadence ----------------------------------
if any(STAGES == 2)
    fprintf('\n\n============ 2/4  Simscape pack, 60 s cadence ============\n');
    [ok, T] = pulse195_model('Period_s',60, 'StopTime_s',310, 'SOC_init',0.60);
    results(end+1) = struct('name','Simscape pack, 60 s cadence', 'ok',ok, ...
        'checks',height(T), 'failed',sum(~T.Passed));
end

%% 3. Fast stand-in, the real cadence -------------------------------------
if any(STAGES == 3)
    fprintf('\n\n============ 3/4  fast stand-in, real 600 s cadence ============\n');
    [ok, T] = pulse195_harness('Period_s',600, 'StopTime_s',2405, 'SOC_init',0.60);
    results(end+1) = struct('name','fast stand-in, 600 s cadence', 'ok',ok, ...
        'checks',height(T), 'failed',sum(~T.Passed));
end

%% 4. The end of discharge, with the limiter on and off --------------------
%  The scenario protection actually has to handle, and the one stages 1 to 3
%  cannot see. 31250 W from 10% SOC sags the lowest cell to about 2.5 V, which
%  is the under-voltage trip -- so this is where a trip used as an operating
%  limit starts cycling against its own load.
if any(STAGES == 4)
    fprintf('\n\n============ 4/4  end of discharge, 10%% SOC ============\n');
    warnState = warning('off','bcp:Project:Issues');
    deep = struct('tag',{},'edges',{},'Vmin',{},'dcl',{},'retry',{},'lock',{});
    for limiterOn = [true false]
        if limiterOn, tag = 'limiter ON'; else, tag = 'limiter OFF'; end
        fprintf('\n---- %s ----\n', tag);
        [~,~,S] = pulse195_harness('Period_s',20, 'StopTime_s',300, ...
            'SOC_init',0.10, 'LimiterOn',limiterOn);
        deep(end+1) = struct('tag',tag, ...
            'edges', sum(diff(double(S.faults > 0)) > 0), ...
            'Vmin',  min(S.V_min), ...
            'dcl',   min(S.dcl_frac), ...
            'retry', max(S.retry_count), ...
            'lock',  sum(S.lockout > 0.5)); %#ok<SAGROW>
    end
    warning(warnState);

    p4 = pulse195_setup('Period_s',20);
    fprintf('\n  UV trip %.3f V/cell;  foldback band %.3f .. %.3f V/cell\n', ...
        p4.Bms.V_uv_trip, p4.Bms.V_fold_end(), p4.Bms.V_fold_start());
    fprintf('  %-12s %10s %10s %10s %9s %9s\n', ...
        'run','faultEdges','minVcell','min dcl','retries','lockoutN');
    for k = 1:numel(deep)
        d = deep(k);
        fprintf('  %-12s %10d %10.4f %10.4f %9g %9d\n', ...
            d.tag, d.edges, d.Vmin, d.dcl, d.retry, d.lock);
    end

    on = deep(strcmp({deep.tag},'limiter ON'));
    ok = on.edges <= 1;
    if ok
        fprintf(['\n  With the limiter on the latch set %d time(s). More than ', ...
                 'once would be the cyclic\n  fault chain; see the load-limiter ', ...
                 'section of README.md.\n'], on.edges);
    else
        fprintf(2, ['\n  The latch set %d times WITH the limiter on. That is ', ...
                    'the cyclic fault chain, and\n  it should not be ', ...
                    'reachable -- read diag(11) dcl_frac and diag(13) ', ...
                    'retry_count.\n'], on.edges);
    end
    results(end+1) = struct('name','end of discharge, limiter on', 'ok',ok, ...
        'checks',1, 'failed',double(~ok));
end

%% Summary ----------------------------------------------------------------
fprintf('\n\n================== summary ==================\n');
for k = 1:numel(results)
    if results(k).ok, tag = 'PASS'; else, tag = 'FAIL'; end
    fprintf('  [%s] %-34s %d checks, %d failed\n', tag, results(k).name, ...
        results(k).checks, results(k).failed);
end
if all([results.ok])
    fprintf('\n  Everything passed.\n');
    fprintf('  The model built in stage 2 is "pulse195_sim.slx" -- open it to look around.\n\n');
else
    fprintf(2, '\n  Something failed. The per-check detail is above.\n\n');
end
