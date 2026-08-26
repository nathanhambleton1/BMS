function [chg_enable, I_chg_limit, reason] = ...
        bcp_arbiter(loadActive, SOC_pack, V_max, chg_ok, chg_done, P)
%BCP_ARBITER  Load-first arbitration between the dynamic load and the charger.
%#codegen
%
%   THE LOAD ALWAYS WINS. This function is the only place that decides whether
%   the charger is allowed to run, and its first rule is that an active load
%   revokes permission immediately -- within one sample, no ramp-down
%   negotiation. Charging happens in the gaps between load activity, which is
%   what you want when the load is the thing under test and the charge is just
%   housekeeping.
%
%   INPUTS
%     loadActive  1x1  from bcp_load_scheduler
%     SOC_pack    1x1  0..1
%     V_max       1x1  highest cell voltage [V]
%     chg_ok      1x1  charge permission from bcp_protection
%     chg_done    1x1  charger reports taper termination
%     P           struct of constants (see bcp.BmsConfig)
%
%   OUTPUTS
%     chg_enable   1x1  1 = the charger may run
%     I_chg_limit  1x1  ceiling the charger must respect [A]
%     reason       1x1  why charging is or is not enabled:
%                         0 enabled
%                         1 load is active
%                         2 waiting out the quiet dwell
%                         3 pack is full (SOC/voltage satisfied)
%                         4 blocked by protection
%                         5 charging disabled in configuration
%
%   THE QUIET DWELL (P.t_quiet_s)
%     Enabling the charger the instant a pulse ends would start a charge into
%     the gap between two pulses of a burst. t_quiet_s is how long the load has
%     to stay quiet before the charger is trusted to have a window. Set it
%     longer than the gap inside a burst and shorter than the gap between
%     bursts. Zero is legal and means "charge in every gap, however short".
%
%   COMPLETION LATCHES WITH HYSTERESIS (SOC_stop / SOC_restart)
%     Without the latch, a pack that reaches SOC_stop stops charging, relaxes a
%     few millivolts, drops back under the threshold and starts again -- a
%     charge/rest chatter that burns simulation time and looks like a control
%     bug in the results. The latch clears only when SOC falls to SOC_restart,
%     or when the highest cell falls below V_recharge.
%
%   CONCURRENT CHARGING (P.AllowConcurrent)
%     Off by default: charging is inhibited whenever the load is active. Turn it
%     on to let the charger run through the load, derated to I_chg_headroom_A so
%     the sum of load and charge current stays inside the pack's limits. That is
%     a different experiment -- the pack no longer sees the load current you
%     configured -- so it is opt-in.

persistent tQuiet complete initialised

if isempty(initialised)
    tQuiet = 0; complete = false; initialised = true;
end

% ---- completion latch -----------------------------------------------------
if SOC_pack >= P.SOC_stop || chg_done > 0.5
    complete = true;
end
if complete && (SOC_pack <= P.SOC_restart || V_max <= P.V_recharge)
    complete = false;
end

% ---- quiet dwell ----------------------------------------------------------
tQuiet = bcp_tick(tQuiet, loadActive < 0.5, P.Ts);

% ---- decision -------------------------------------------------------------
wantCharge = (SOC_pack < P.SOC_stop) && ~complete;

if ~P.ChargeEnabled
    chg_enable = 0; reason = 5;
elseif chg_ok < 0.5
    chg_enable = 0; reason = 4;
elseif ~wantCharge
    chg_enable = 0; reason = 3;
elseif loadActive > 0.5 && ~P.AllowConcurrent
    chg_enable = 0; reason = 1;
elseif tQuiet < P.t_quiet_s && ~P.AllowConcurrent
    chg_enable = 0; reason = 2;
else
    chg_enable = 1; reason = 0;
end

% ---- current ceiling ------------------------------------------------------
%  Two independent ceilings, whichever is lower: the protection trip minus a
%  margin (never command a current that trips your own over-current), and the
%  concurrent-charging headroom when the load is running.
lim = P.I_chg_trip * P.I_chg_margin;
if loadActive > 0.5 && P.AllowConcurrent
    lim = min(lim, P.I_chg_headroom_A);
end
I_chg_limit = max(lim, 0);
end
