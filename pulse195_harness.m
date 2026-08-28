function [ok, T, S, out, p] = pulse195_harness(varargin)
%PULSE195_HARNESS  Run the 195S1P pulse test on the fast stand-in plant.
%
%   [ok, T, S, out, p] = pulse195_harness()
%   pulse195_harness('StopTime_s', 3000, 'SOC_init', 0.90)
%
%   Seconds per run instead of minutes, so this is where the control logic gets
%   proven: the arbitration, the state machine, the protection thresholds, the
%   charge command and the coulomb bookkeeping. The plant is fed the same cell
%   tables Batteries.slx runs on (bcp.CellTables), so the voltages and currents
%   are comparable with the Simscape run rather than merely plausible.
%
%   What it still is not: bcp_harness_plant has no RC dynamics, no temperature
%   and no charge inefficiency, and it lumps each series element. Run
%   pulse195_model for the answer on the real pack.
%
%   OPTIONS
%     Period_s    pulse repetition period [s].   Default 60.
%     StopTime_s  simulation length [s].         Default 5 periods + 10.
%     SOC_init    starting SOC of the stand-in.  Default 0.60.
%     Edge_s      pulse rise/fall time [s].      Default 0.05; see
%                 pulse195_setup section 6 for why it is not zero.
%     LimiterOn   continuous discharge limiting. Default true. Set it false to
%                 reproduce a result from before alg/bcp_load_limiter.m existed.
%     Verbose     print the per-check verification table. Default true. Set it
%                 false when the run is DELIBERATELY outside what pulse195_verify
%                 describes -- a deep-discharge run, or one with the limiter
%                 turned off -- where most of those checks do not apply and
%                 printing them as failures is just misleading.
%     Plot        draw the four-panel figure.    Default false.

opt = struct('Period_s',60, 'StopTime_s',[], 'SOC_init',0.60, 'Plot',false, ...
             'Pulse_s',2, 'P_load_W',31250, 'Start_s',5, 'Edge_s',0.05, ...
             'LimiterOn',true, 'Verbose',true);
for k = 1:2:numel(varargin)
    assert(isfield(opt, varargin{k}), 'pulse195:Option', 'Unknown option "%s".', varargin{k});
    opt.(varargin{k}) = varargin{k+1};
end
if isempty(opt.StopTime_s)
    opt.StopTime_s = opt.Start_s + 5*opt.Period_s + 5;
end

[p, ct] = pulse195_setup('Period_s',opt.Period_s, 'Pulse_s',opt.Pulse_s, ...
                         'P_load_W',opt.P_load_W, 'Start_s',opt.Start_s, ...
                         'Edge_s',opt.Edge_s);
p.Bms.UseLoadLimiter = opt.LimiterOn;
p = p.sync();
if opt.Verbose, p.report(); end

h = bcp.Harness(p, 'CellTables', ct, 'SOC_init', opt.SOC_init);
h.build();
out = h.simulate(opt.StopTime_s);
h.summary(out);

[ok, T, S] = pulse195_verify(out, p, ct, 'Period_s',opt.Period_s, 'SOC_init',opt.SOC_init, ...
    'Pulse_s',opt.Pulse_s, 'P_load_W',opt.P_load_W, 'Start_s',opt.Start_s, ...
    'Edge_s',opt.Edge_s, 'Verbose',opt.Verbose);

if opt.Plot, h.plot(out); end
end
