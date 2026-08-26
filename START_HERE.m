%% START_HERE  --  open this in MATLAB and press Run (F5). That is the whole thing.
%
%   One entry point for the BMS and charger blocks. It sets up the path, checks
%   the environment, runs the fast unit tests, and opens the UI.
%
%   It finds its own folder at run time, so this whole "BMS" folder can be
%   copied to any other machine and this script still works with no edits.
%   Nothing here is hardcoded to one computer.
%
%   WHAT YOU GET
%     Two blocks you can drop into a battery model built with the Simulink
%     Battery Model Builder:
%
%       BMS      reads the per-cell voltage / SOC / current arrays your battery
%                model already exports, and produces the watts your dynamic-load
%                block should draw. The load waveform -- off, constant, sine or
%                pulse -- is configured in the UI. It also does protection, and
%                it decides when the charger is allowed to run.
%
%       Charger  a CC/CV charger whose parameters are auto-filled from your cell
%                and your series/parallel counts. CC and CV are not modes you
%                select; the handover is automatic because it is not a decision.
%
%     THE LOAD ALWAYS WINS. The BMS revokes the charger's permission the moment
%     the load becomes active, and charging happens in the gaps.
%
%   WHAT IT DOES, IN ORDER
%     1. Puts BmsChargerPackage on the MATLAB path (+bcp, alg, app, tests) via
%        bcp_setup. The generated blocks call functions in alg/, so a model
%        containing them will not compile without this.
%     2. Checks that Simulink is installed. Simscape is NOT required by these
%        blocks -- they are pure signal-domain Simulink, which is why they drop
%        onto a pack model built by any tool. Your battery model needs it; these
%        two do not.
%     3. Runs the algorithm unit tests. No Simulink needed; a couple of seconds.
%     4. Opens the UI (app/bcpApp.m).
%
%   The Simulink build tests are NOT run here. They construct and simulate
%   several models and take about a minute, so they are a deliberate step:
%
%       runtests('tBcpBuild')
%
%   Run them after changing MATLAB releases, or before installing into a model
%   you care about.
%
%   OPTIONS -- edit these two lines if you want different behaviour:
RUN_TESTS = true;    % set false to skip step 3 and open the UI faster
LAUNCH_UI = true;    % set false for a command-line-only session
SIMPLE_UI = true;    % true opens bcpSimple, false opens the full bcpApp
%
%   bcpSimple asks for the nine numbers you have to decide -- cell, series,
%   parallel, pulse power, pulse length, repeat period, charge current, stop
%   SOC, starting SOC -- and derives every threshold and gain from them by the
%   same autofillAll() the full window's "Auto-fill all" button calls. It also
%   states the pulse current, the SOC per pulse and the recharge time as you
%   type, so a load the pack cannot deliver is visible before you run anything.
%
%   bcpApp is still there and still exposes every field. Open it any time with
%   bcpApp, or set SIMPLE_UI = false.

%   Command-line equivalent of everything the UI does:
%
%       spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
%       p    = bcp.Project('Pack', spec).autofillAll();
%       p.Load = bcp.LoadSignal('Waveform','pulse', ...
%                   'Pulse_Amplitude_W',900, 'Pulse_Frequency_Hz',0.1, ...
%                   'Pulse_Duty_pct',30, 'Pmax_W',4000);
%       p = p.sync();
%       p.report()
%
%       h = bcp.Harness(p); h.build();       % prove it on a throwaway model
%       out = h.simulate(600); h.plot(out);
%
%       p.insertInto('myBatteryModel');      % then install for real
%
%   Documentation: README.md in this folder, and docs/INSTALL.md for the
%   step-by-step wiring procedure.

clc; close all;

root   = fileparts(mfilename('fullpath'));
pkgDir = fullfile(root, 'BmsChargerPackage');

fprintf('=== BMS and charger blocks for a Simulink battery model ===\n');
fprintf('    MATLAB %s on %s\n', version('-release'), computer('arch'));
fprintf('    Package: %s\n\n', pkgDir);

if ~isfolder(pkgDir)
    error('bcp:PackageNotFound', ...
        ['Expected a "BmsChargerPackage" folder next to this script:\n  %s\n' ...
         'Keep START_HERE.m and BmsChargerPackage/ together.'], pkgDir);
end

%% 1. Path -----------------------------------------------------------------
%  bcp_setup is the single definition of this project's path. Duplicating the
%  addpath calls here is how the two copies drift apart.
run(fullfile(pkgDir, 'bcp_setup.m'));
fprintf('[1/4] Path configured (+bcp, alg, app, tests).\n');

%% 2. Toolboxes -------------------------------------------------------------
haveSim = ~isempty(ver('simulink'));
if haveSim
    fprintf('[2/4] Simulink found.\n');
    if isempty(ver('simscape'))
        fprintf(['      Simscape is not installed. These two blocks do not need\n' ...
                 '      it -- they are pure Simulink. Your battery model will.\n']);
    end
else
    fprintf(2, '[2/4] MISSING: Simulink.\n');
    fprintf(['      The UI, the load preview, the charge-parameter auto-fill and\n' ...
             '      the algorithm tests all still work. Inserting blocks into a\n' ...
             '      model does not.\n']);
end

%% 3. Unit tests ------------------------------------------------------------
%  These exercise the load scheduler, the protection state machine, the
%  arbitration rule and the CC-CV law as plain functions -- no model compile.
%  That is the payoff for keeping them in alg/ rather than inside the blocks.
if RUN_TESTS
    fprintf('\n[3/4] Running algorithm unit tests...\n');
    results = runtests('tBcpAlgorithms');
    nFail = sum([results.Failed]);
    if nFail > 0
        fprintf(2, ['      %d of %d FAILED. Read the output above before trusting\n' ...
                    '      anything this package produces.\n'], nFail, numel(results));
    else
        fprintf('      All %d passed.\n', numel(results));
    end
    if haveSim
        fprintf(['      The Simulink build tests are separate and take about a\n' ...
                 '      minute:  runtests(''tBcpBuild'')\n']);
    end
else
    fprintf('\n[3/4] Unit tests skipped (RUN_TESTS = false).\n');
end

%% 4. UI --------------------------------------------------------------------
if LAUNCH_UI && SIMPLE_UI
    fprintf('\n[4/4] Opening the short UI...\n');
    app = bcpSimple(); %#ok<NASGU>  keep the handle alive in the base workspace
    fprintf('      Done. Set the numbers top to bottom, then press Run.\n\n');
    fprintf('      The line under each group says what your numbers mean for\n');
    fprintf('      this pack -- the current the pulse will really draw, the SOC\n');
    fprintf('      it costs, and whether the gap is long enough to put it back.\n');
    fprintf('      They update as you type, so a load the pack cannot deliver\n');
    fprintf('      shows up before you spend a run finding out.\n\n');
    fprintf('      Every field:      bcpApp\n');
    fprintf('      The whole test:   RUN_PULSE_TEST\n\n');
elseif LAUNCH_UI
    fprintf('\n[4/4] Opening the full UI...\n');
    app = bcpApp(); %#ok<NASGU>  keep the handle alive in the base workspace
    fprintf('      Done. The window is yours.\n\n');
    fprintf('      Pack tab first, then Load, then press "Auto-fill all".\n');
    fprintf('      Never installed these blocks? Install tab -> "Build test\n');
    fprintf('      harness" builds a throwaway model with a crude battery\n');
    fprintf('      stand-in so you can get the behaviour right in one second\n');
    fprintf('      per run, before touching the model you care about.\n\n');
    fprintf('      Shorter window any time with:  bcpSimple\n\n');
else
    fprintf('\n[4/4] UI skipped (LAUNCH_UI = false). Open it with:  bcpSimple\n\n');
end
