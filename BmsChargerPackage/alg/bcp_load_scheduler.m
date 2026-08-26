function [P_load, loadActive] = bcp_load_scheduler(t, P)
%BCP_LOAD_SCHEDULER  Dynamic-load power demand versus time.
%#codegen
%
%   This is the function behind the Load tab of bcpApp. Whatever it returns at
%   time t IS the watts your dynamic-load block is asked to draw. Nothing else
%   in this package generates a load; the charger only ever ADDS charge power
%   on top of what this returns.
%
%   INPUTS
%     t   1x1  simulation time [s]
%     P   struct of constants (see bcp.LoadSignal.params)
%
%   OUTPUTS
%     P_load      1x1  demanded load power [W], POSITIVE = DRAWN FROM PACK
%     loadActive  1x1  1 when |P_load| exceeds P.IdleThreshold_W
%
%   WAVEFORMS (P.Waveform)
%     0 off       0 W. A real idle, not a hand-off to some other setpoint.
%     1 constant  Offset_W
%     2 sine      Offset_W + Amplitude_W*sin(2*pi*f*tau + phase)
%     3 pulse     Offset_W + Amplitude_W during the on-portion of each period,
%                 Offset_W otherwise
%
%   tau is time since StartTime_s, so phase and duty are referenced to the
%   start of the load, not to t=0. Outside [StartTime_s, StopTime_s) the
%   demand is exactly zero.
%
%   WHY THE SLEW LIMIT EXISTS (P.Slew_W_per_s, default 0 = off)
%     A pulse load is a step discontinuity in the algebraic constraint the
%     Simscape solver has to satisfy. With a hard step the solver either takes
%     a very small step across the edge or, on a stiff pack model, fails to
%     converge. A finite slew rate turns each edge into a ramp the solver can
%     walk across. It is off by default because it is a modelling aid, not
%     physics -- switch it on only if you actually see convergence trouble,
%     and say so when you report results.
%
%   No sign convention ambiguity: this function is always charge-negative /
%   draw-positive. bcp.BmsBuilder applies P.OutputSign once, at the block's
%   output port, if your load block wants the opposite polarity.

persistent yPrev initialised

if isempty(initialised)
    yPrev = 0;
    initialised = true;
end

y = 0;
if t >= P.StartTime_s && t < P.StopTime_s
    tau = t - P.StartTime_s;
    if P.Waveform == 1
        y = P.Offset_W;
    elseif P.Waveform == 2
        y = P.Offset_W + P.Amplitude_W * ...
            sin(2*pi*P.Frequency_Hz*tau + P.Phase_deg*pi/180);
    elseif P.Waveform == 3
        if P.Frequency_Hz > 0
            period = 1 / P.Frequency_Hz;
            local  = mod(tau + (P.Phase_deg/360)*period, period);
            if local < (P.Duty_pct/100) * period
                y = P.Offset_W + P.Amplitude_W;
            else
                y = P.Offset_W;
            end
        else
            y = P.Offset_W;
        end
    end
end

% Clamp before slewing: the clamp is what the load block can physically do,
% the slew is how fast the command may move towards it.
y = min(max(y, P.Pmin_W), P.Pmax_W);

if P.Slew_W_per_s > 0
    dmax = P.Slew_W_per_s * P.Ts;
    y    = yPrev + min(max(y - yPrev, -dmax), dmax);
end
yPrev = y;

P_load     = y;
loadActive = double(abs(y) > P.IdleThreshold_W);
end
