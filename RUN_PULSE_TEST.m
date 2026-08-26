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
%
%     Each stage runs pulse195_verify, which checks the run against numbers
%     computed from the cell's own lookup tables: the constant-power operating
%     point, coulomb consistency on every pulse and every charge window, the
%     arbitration timing, the state machine and the protection margins.
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

STAGES = [1 2 3];       % edit to run a subset
results = struct('name',{},'ok',{},'checks',{},'failed',{});

%% 1. Fast stand-in, scaled cadence ---------------------------------------
if any(STAGES == 1)
    fprintf('\n\n============ 1/3  fast stand-in, 60 s cadence ============\n');
    [ok, T] = pulse195_harness('Period_s',60, 'StopTime_s',310, 'SOC_init',0.60);
    results(end+1) = struct('name','fast stand-in, 60 s cadence', 'ok',ok, ...
        'checks',height(T), 'failed',sum(~T.Passed));
end

%% 2. Real Simscape pack, scaled cadence ----------------------------------
if any(STAGES == 2)
    fprintf('\n\n============ 2/3  Simscape pack, 60 s cadence ============\n');
    [ok, T] = pulse195_model('Period_s',60, 'StopTime_s',310, 'SOC_init',0.60);
    results(end+1) = struct('name','Simscape pack, 60 s cadence', 'ok',ok, ...
        'checks',height(T), 'failed',sum(~T.Passed));
end

%% 3. Fast stand-in, the real cadence -------------------------------------
if any(STAGES == 3)
    fprintf('\n\n============ 3/3  fast stand-in, real 600 s cadence ============\n');
    [ok, T] = pulse195_harness('Period_s',600, 'StopTime_s',2405, 'SOC_init',0.60);
    results(end+1) = struct('name','fast stand-in, 600 s cadence', 'ok',ok, ...
        'checks',height(T), 'failed',sum(~T.Passed));
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
