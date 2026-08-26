function [ok, T, S, out, p] = pulse195_model(varargin)
%PULSE195_MODEL  Run the 195S1P pulse test on the real Simscape pack.
%
%   [ok, T, S, out, p] = pulse195_model()
%   pulse195_model('StopTime_s', 20, 'Rebuild', true)      % quick smoke run
%
%   Builds "pulse195_sim.slx" from a template that already carries the
%   Simscape side -- NewPack, the Dynamic Load, the charge current source, the
%   sensors and the solver configuration -- then replaces the BMS and charger
%   with blocks generated from pulse195_setup, rewires the pack, sets the
%   starting SOC and runs it.
%
%   ONCE BUILT, THE MODEL IS SELF-CONTAINED. The template is read only when
%   Rebuild is true. Nothing about a result depends on the template still
%   existing or still saying what it said.
%
%   OPTIONS
%     Template    model to take the Simscape wiring from.  Default 'untitled'.
%     Model       model to build and run.        Default 'pulse195_sim'.
%     Period_s    pulse repetition period [s].   Default 60.
%     StopTime_s  simulation length [s].         Default 5 periods + 10.
%     SOC_init    starting cell SOC.             Default 0.60.
%     I_sign      pack current polarity, +1 or -1. Default +1; see below.
%     Rebuild     rebuild from the template.     Default true.
%
%   THE WIRING THIS FIXES, AND WHY IT MATTERS
%     NewPack publishes its per-cell quantities twice, at two different widths:
%
%       iCell, socCell, vCell                 15 wide -- one per MODULE
%       socParallelAssembly, vParallelAssembly 195 wide -- one per CELL
%
%     The pack is 15 modules of 13 series cells. bcp_pack_monitor computes pack
%     voltage as mean(V)*S and pack current as sum(I)/S, so S has to count what
%     the array counts. Wire the 15-wide arrays with S = 195 and pack current
%     comes out 13 times too small, silently -- the voltages still look right,
%     because mean() does not care about the width, and only the current is
%     wrong. That is a fault that hides: every trip threshold, the CC setpoint
%     check and the coulomb bookkeeping are all off by 13 and nothing in the
%     model complains.
%
%     So this wires voltage and SOC from the 195-wide arrays, and expands the
%     15-wide current array to 195 with a matrix gain that takes its mean --
%     which is exactly right, because 195 cells in one series string all carry
%     the same current. All three inputs then arrive 195 wide, S = 195 counts
%     cells, and p.verifyWiring reports 'per-cell' instead of 'unknown'.
%
%   I_sign IS +1 FOR THIS PACK, NOT THE PACKAGE DEFAULT OF -1
%     bcp.BmsConfig.I_sign converts the pack model's current polarity to this
%     package's charge-positive convention. The package defaults to -1 on the
%     stated grounds that Simscape Battery reports current positive when
%     discharging. NewPack's iCell output does not: the generated component
%     declares it "Cell current (positive in)", and a measured run agrees --
%     with I_sign = -1 the BMS reads +42.6 A during a discharge pulse, latches
%     an over-current-CHARGE fault within the 0.1 s confirmation window and
%     opens the contactor part-way through the first pulse.
%
%     That is exactly the failure bcp_pack_monitor warns about: get the sign
%     wrong and the BMS trips on charge and never trips on discharge. It is
%     also why it is worth checking rather than inheriting -- verification here
%     asserts the pack current is negative during a pulse, so a future model
%     with the other polarity fails one named check instead of ten.

opt = struct('Template','untitled', 'Model','pulse195_sim', 'Period_s',60, ...
             'StopTime_s',[], 'SOC_init',0.60, 'I_sign',1, 'Rebuild',true, ...
             'Pulse_s',2, 'P_load_W',31250, 'Start_s',5);
for k = 1:2:numel(varargin)
    assert(isfield(opt, varargin{k}), 'pulse195:Option', 'Unknown option "%s".', varargin{k});
    opt.(varargin{k}) = varargin{k+1};
end
if isempty(opt.StopTime_s)
    opt.StopTime_s = opt.Start_s + 5*opt.Period_s + 5;
end

root = fileparts(mfilename('fullpath'));

%% ---- configuration -------------------------------------------------------
[p, ct] = pulse195_setup('Period_s',opt.Period_s, 'Pulse_s',opt.Pulse_s, ...
                         'P_load_W',opt.P_load_W, 'Start_s',opt.Start_s);
p.Bms.I_sign = opt.I_sign;
p = p.sync();
p.report();

model = opt.Model;

%% ---- build ---------------------------------------------------------------
if opt.Rebuild
    src = fullfile(root, [opt.Template '.slx']);
    assert(isfile(src), 'pulse195:NoTemplate', ...
        ['No template model "%s".\nIt supplies the Simscape half -- the pack, ' ...
         'the Dynamic Load, the charge source and the solver configuration.'], src);
    if bdIsLoaded(model), close_system(model, 0); end
    copyfile(src, fullfile(root, [model '.slx']), 'f');
    load_system(model);

    local_setInitialSOC(model, opt.SOC_init);

    % Replaces any earlier BMS/Charger of the same name and wires the five
    % fixed lines between them. Every line those blocks had to the rest of the
    % model goes with them, which is why they are all redrawn below.
    bcp.Blocks.removeIfPresent([model '/I_cell_expand']);
    paths = p.insertInto(model, 'BmsPosition',[-330 -150 -150 130], ...
                                'ChargerPosition',[-330 200 -150 360]);

    local_wire(model, p, paths);
    local_logPack(model);

    set_param(model, 'SignalLogging','on', 'SignalLoggingName','logsout');
    set_param(model, 'StopTime', num2str(opt.StopTime_s,'%.12g'));
    save_system(model);
    fprintf('[pulse195] Built "%s.slx" from "%s.slx".\n', model, opt.Template);
else
    load_system(model);
    set_param(model, 'StopTime', num2str(opt.StopTime_s,'%.12g'));
end

%% ---- rates ---------------------------------------------------------------
bcp.Rate.audit(model, [p.Bms.Ts p.Charger.Ts]);

%% ---- wiring proof --------------------------------------------------------
%  Compiles and reports the widths actually reaching the BMS. This is the only
%  thing that can confirm the array layout, and it is cheap.
p.verifyWiring(model);

%% ---- run -----------------------------------------------------------------
fprintf('[pulse195] Simulating %g s of the Simscape pack...\n', opt.StopTime_s);
t0 = tic;
out = sim(model);
fprintf('[pulse195] Done in %.1f s wall clock (%.1fx real time).\n', ...
    toc(t0), toc(t0)/opt.StopTime_s);

[ok, T, S] = pulse195_verify(out, p, ct, 'Period_s',opt.Period_s, 'SOC_init',opt.SOC_init, ...
    'Pulse_s',opt.Pulse_s, 'P_load_W',opt.P_load_W, 'Start_s',opt.Start_s);
end

% =========================================================================
function local_setInitialSOC(model, soc)
%LOCAL_SETINITIALSOC  Set every module's initial cell SOC.
%
%   The generated Module components carry socCell as a high-priority initial
%   target defaulting to 1. Left alone, every run starts at 100% SOC, the
%   arbiter latches "complete" on its first sample and the charger never runs
%   -- which looks exactly like an arbitration bug and is not one.
%
%   SETTING socCell IS NOT ENOUGH. Every Simscape variable target has a
%   companion socCell_specify flag, and it ships 'off'. With it off the value
%   is stored, reads back correctly from get_param, appears in the dialog --
%   and is ignored, because the solver is free to choose its own consistent
%   initial condition and does. So the pack silently starts at 100% while the
%   parameter says 60%, which is worse than an error: the run completes and
%   answers a question about a full pack.
blks = find_system([model '/NewPack'], 'LookUnderMasks','all', ...
                   'FollowLinks','on', 'Type','Block');
n = 0;
for k = 1:numel(blks)
    try
        dp = get_param(blks{k}, 'DialogParameters');
    catch
        continue;
    end
    if ~isempty(dp) && isfield(dp, 'socCell')
        set_param(blks{k}, 'socCell', num2str(soc, '%.6g'));
        set_param(blks{k}, 'socCell_specify', 'on');
        set_param(blks{k}, 'socCell_priority', 'High');
        n = n + 1;
    end
end
assert(n > 0, 'pulse195:NoSOC', ...
    'Found no socCell initial target under %s/NewPack.', model);
fprintf('[pulse195] Initial SOC set to %.1f%% on %d module(s).\n', soc*100, n);
end

% -------------------------------------------------------------------------
function local_wire(model, p, paths)
%LOCAL_WIRE  Redraw every line between the pack, the BMS, the charger and the
%   Simscape side. See the header for why the current path gets a gain block.
S    = p.Pack.S;
bms  = get_param(paths.bms, 'Name');
chg  = get_param(paths.charger, 'Name');

vIdx   = local_outIndex(model, 'NewPack', 'vParallelAssembly');
socIdx = local_outIndex(model, 'NewPack', 'socParallelAssembly');
iIdx   = local_outIndex(model, 'NewPack', 'iCell');
nMod   = local_width(model, 'NewPack', iIdx);

% 15 module currents -> 195 identical cell currents. A matrix gain of
% ones(S,nMod)/nMod is the mean of the module currents replicated S times,
% which is the correct expansion for one series string and degrades gracefully
% if the modules ever do report slightly different currents.
g = bcp.Blocks.add(model, 'Gain', 'I_cell_expand', [-520 20 -440 80]);
set_param(g, 'Multiplication', 'Matrix(K*u)', ...
             'Gain', sprintf('ones(%d,%d)/%d', S, nMod, nMod));

add_line(model, sprintf('NewPack/%d', iIdx),   'I_cell_expand/1', 'autorouting','on');
add_line(model, 'I_cell_expand/1',  sprintf('%s/3', bms), 'autorouting','on');
add_line(model, sprintf('NewPack/%d', vIdx),   sprintf('%s/1', bms), 'autorouting','on');
add_line(model, sprintf('NewPack/%d', socIdx), sprintf('%s/2', bms), 'autorouting','on');

% BMS load command -> the Dynamic Load's power input, and the charger's current
% command -> the controlled current source, each through the converter that
% already feeds it.
loadIdx = bcp.Project.portIndex(model, bms, 'out', 'P_load_cmd');
add_line(model, sprintf('%s/%d', bms, loadIdx), ...
    [local_converterFeeding(model, 'Dynamic Load') '/1'], 'autorouting','on');

chgIdx = bcp.Project.portIndex(model, chg, 'out', 'I_chg_cmd');
add_line(model, sprintf('%s/%d', chg, chgIdx), ...
    [local_converterFeeding(model, 'Controlled Current') '/1'], 'autorouting','on');
end

% -------------------------------------------------------------------------
function name = local_converterFeeding(model, dstPrefix)
%LOCAL_CONVERTERFEEDING  Name of the Simulink-PS converter that drives DSTPREFIX.
%
%   By name rather than by index: the two converters differ only by a trailing
%   "1", and which one feeds the load is not something to guess at.
blks = find_system(model, 'SearchDepth',1, 'RegExp','on', 'Name','Simulink-PS');
for k = 1:numel(blks)
    ph = get_param(blks{k}, 'PortHandles');
    hs = [ph.Outport, ph.RConn, ph.LConn];
    for j = 1:numel(hs)
        l = get_param(hs(j), 'Line');
        if l <= 0, continue; end
        d = get_param(l, 'DstBlockHandle');
        for m = 1:numel(d)
            if d(m) > 0 && startsWith(get_param(d(m),'Name'), dstPrefix)
                name = get_param(blks{k}, 'Name');
                return;
            end
        end
    end
end
error('pulse195:NoConverter', ...
    'No Simulink-PS converter feeding a block whose name starts "%s".', dstPrefix);
end

% -------------------------------------------------------------------------
function idx = local_outIndex(model, blockName, portName)
%LOCAL_OUTINDEX  Outport index of BLOCKNAME by the outport's NAME.
b = find_system([model '/' blockName], 'SearchDepth',1, 'BlockType','Outport');
for k = 1:numel(b)
    if strcmp(get_param(b{k},'Name'), portName)
        idx = str2double(get_param(b{k},'Port'));
        return;
    end
end
error('pulse195:NoPort', '%s has no outport named "%s".', blockName, portName);
end

% -------------------------------------------------------------------------
function w = local_width(model, blockName, idx)
%LOCAL_WIDTH  Compiled width of one outport. Compiles the model to find out,
%   because nothing else can: signal widths do not exist until a compile.
c = onCleanup(@() bcp.Project.terminateQuietly(model));
feval(model, [], [], [], 'compile');
pw = get_param([model '/' blockName], 'CompiledPortWidths');
w = pw.Outport(idx);
clear c;
end

% -------------------------------------------------------------------------
function local_logPack(model)
%LOCAL_LOGPACK  Mark the pack's own arrays for logging, so the checks have an
%   independent view of the pack alongside the BMS's one-sample-delayed one.
want = {'vParallelAssembly','pack_V_cell'; ...
        'socParallelAssembly','pack_SOC_cell'; ...
        'iCell','pack_I_cell'};
for k = 1:size(want,1)
    try
        idx = local_outIndex(model, 'NewPack', want{k,1});
        ph  = get_param([model '/NewPack'], 'PortHandles');
        l   = get_param(ph.Outport(idx), 'Line');
        if l > 0, bcp.Blocks.logSignal(l, want{k,2}); end
    catch ME
        warning('pulse195:LogFailed', 'Could not log %s: %s', want{k,1}, ME.message);
    end
end
end
