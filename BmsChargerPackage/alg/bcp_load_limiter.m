function [P_load, dcl_frac, limitState, foldFrac, softFrac] = ...
        bcp_load_limiter(P_demand, V_min, I_pack, dch_ok, P)
%BCP_LOAD_LIMITER  Continuous discharge derating, so protection rarely has to trip.
%#codegen
%
%   INPUTS
%     P_demand  1x1  what the load waveform asks for [W], DRAW-POSITIVE
%     V_min     1x1  lowest cell voltage [V]
%     I_pack    1x1  pack current [A], CHARGE-POSITIVE
%     dch_ok    1x1  discharge permission from bcp_protection
%     P         struct of constants (see bcp.BmsConfig.limiterParams)
%
%   OUTPUTS
%     P_load      1x1  the load command that survives [W]
%     dcl_frac    1x1  0..1, the factor actually applied to the demand
%     limitState  1x1  0 no limiting | 1 voltage foldback | 2 current foldback
%                      3 soft-start ramp | 4 held off by protection
%     foldFrac    1x1  0..1, the adaptive limit on its own
%     softFrac    1x1  0..1, the re-engagement ramp on its own
%
%   THE PROBLEM THIS EXISTS TO SOLVE
%     A trip is a binary event and a constant-power load is positive feedback,
%     and those two together oscillate. The cycle, seen on any long discharge
%     that reaches the under-voltage threshold:
%
%       a pulse sags the pack under V_uv_trip
%         -> the dwell confirms, UV latches, dch_ok drops
%         -> the load command goes to zero
%         -> the sag disappears in one sample, because the sag WAS the load
%         -> the pack is now inside the clear band, so the fault recovers
%         -> the full load slams back on
%         -> a deeper sag, because SOC is lower and R0 is higher than last time
%
%     Each lap takes charge out and puts almost none back, so every dip is
%     deeper than the last and the excursions run far below the threshold that
%     was supposed to prevent them. Nothing in that chain is a coding error:
%     it is what a bang-bang controller does to a load whose current RISES as
%     the voltage it caused FALLS. I = P/V, so a 10% sag is an 11% current rise
%     is more sag.
%
%     Protection cannot fix this by itself. Whatever the threshold and whatever
%     the dwell, a binary trip removes its own trigger. The fix is to stop
%     using the trip as the operating limit and put a continuous limit in front
%     of it -- which is what a real pack does.
%
%   WHAT A REAL PACK DOES: A PUBLISHED DISCHARGE LIMIT
%     Production BMSs broadcast a discharge current or power limit -- DCL on
%     most CAN protocols -- and the inverter or motor controller is required to
%     obey it. That limit slides down continuously as the cells approach their
%     cutoff. The contactor-opening trip still exists, and in a healthy system
%     it never fires, because the limit got there first. Protection becomes the
%     backstop it was always meant to be instead of the thing doing the
%     regulating.
%
%     dcl_frac is that limit, as a fraction of the demand. A fraction rather
%     than absolute watts because it then needs no separate rating: the closed
%     loop is what finds the pack's real capability at this SOC, and it finds it
%     every sample rather than from a number somebody typed in.
%
%   THE LIMIT MOVES BY RATE, NOT BY FORMULA, AND THAT IS THE STABILITY ARGUMENT
%     The obvious implementation -- frac = f(V_min) evaluated fresh each sample
%     -- reintroduces the oscillation in analogue form. Its loop gain is
%     df/dV * dV/dP * P_demand, and dV/dP goes to infinity as a constant-power
%     draw approaches the pack's maximum power point, so there is no choice of
%     f that is stable across the SOC range. The system is at its most unstable
%     exactly where the limiter is needed most.
%
%     So the limit is a rate-limited integrator instead:
%
%       V_min below V_fold_end     close down, at a rate proportional to how
%                                  far below, capped at Fold_Fall_per_s
%       V_min above V_fold_start   reopen, slowly, at Fold_Rise_per_s
%       in between                 hold
%
%     The step per sample is bounded by rate*Ts no matter how large the error
%     is, so the loop cannot amplify a transient however steep dV/dP has
%     become. The deadband between V_fold_end and V_fold_start is what stops
%     the integrator hunting: once V_min is inside it the limit stops moving,
%     and the pack sits just above its cutoff delivering what it can.
%
%     Falling is roughly eighty times faster than rising by default, and the
%     asymmetry is the whole point. Cells sag in milliseconds and recover over
%     seconds; a limiter that reopened as fast as it closed would just be the
%     trip again with extra steps.
%
%   THE LIMIT ONLY REOPENS WHILE CURRENT IS FLOWING
%     At rest V_min relaxes to OCV, which is far above V_fold_start, so a
%     limiter that reopened during the gap between two pulses would arrive at
%     the next pulse having forgotten everything the last one taught it. But an
%     open-circuit voltage is not evidence that the pack can deliver power --
%     that is precisely the measurement that misled the bang-bang controller
%     above.
%
%     So reopening requires |I_pack| > I_learn_A: under load, because the load
%     is actively proving the limit is safe, or under charge, because the charge
%     is replacing what the load took. At rest there is no new evidence, so the
%     limit holds what it has.
%
%   THE SOFT-START RAMP
%     Independent of the adaptive limit, and it handles the other half of the
%     cycle. When dch_ok comes back after an inhibit, the load is re-engaged
%     over t_softstart_s rather than in one sample. A contactor closing into a
%     31 kW load is an inrush nobody builds for, an inverter soft-starts for
%     exactly this reason, and in simulation a step re-engagement is also the
%     one thing most likely to drive a stiff pack model straight back under the
%     threshold before the limiter has had a sample to react.
%
%     While inhibited, foldFrac is FROZEN -- not reset. The pre-trip limit was
%     demonstrably too high, so restoring it on recovery would throw away the
%     only useful thing the failed attempt produced.
%
%   WHAT THIS IS NOT
%     It is not a replacement for protection, and it does not touch the charge
%     direction. Charge is current-controlled by the charger against a limit the
%     BMS publishes, so it already has the continuous limit this adds; the
%     discharge was the direction being regulated by its own trip.
%
%     It is also not a substitute for a load that respects a limit. In this
%     package the BMS commands the load, so the limit is enforceable by
%     construction. On real hardware, DCL is a request.

persistent fold soft prevOk initialised

if isempty(initialised)
    fold        = 1;
    soft        = 1;
    prevOk      = true;
    initialised = true;
end

Ts   = P.Ts;
vmin = min(V_min(:));
ipk  = sum(I_pack(:));
idch = max(-ipk, 0);                  % discharge magnitude, >= 0
allowed = dch_ok > 0.5;

% ---- pass-through when the limiter is off --------------------------------
%  Exactly the old behaviour, bit for bit: a hard gate and nothing else. Worth
%  keeping reachable, because it is the configuration every earlier result was
%  produced under.
if ~P.Enabled
    fold   = 1;
    soft   = 1;
    prevOk = allowed;
    if allowed
        P_load = P_demand;  dcl_frac = 1;  limitState = 0;
    else
        P_load = 0;         dcl_frac = 0;  limitState = 4;
    end
    foldFrac = 1;
    softFrac = double(allowed);
    return;
end

% ---- the adaptive limit --------------------------------------------------
%  Two independent margins, voltage and current. Each contributes a RATE, and
%  the most restrictive rate wins -- so the limit closes at whichever margin is
%  in the worse trouble, and reopens only when both are clear.
vBand = max(P.V_fold_start - P.V_fold_end, 1e-3);
iBand = max(P.I_fold_end   - P.I_fold_start, 1e-3);

dfV = 0;  dfI = 0;  clearV = false;  clearI = false;
if vmin < P.V_fold_end
    eV  = min((P.V_fold_end - vmin) / vBand, 1);
    dfV = -P.Fold_Fall_per_s * eV * Ts;
elseif vmin > P.V_fold_start
    clearV = true;
end
if idch > P.I_fold_start
    eI  = min((idch - P.I_fold_start) / iBand, 1);
    dfI = -P.Fold_Fall_per_s * eI * Ts;
else
    clearI = true;
end

% Whichever margin says "close down harder" is the one that is obeyed.
df = min(dfV, dfI);

limitCause = 0;
if df < 0
    limitCause = 1;                        % voltage, unless current is worse
    if dfI < dfV, limitCause = 2; end
else
    % Reopening needs BOTH margins clear AND current actually flowing -- see
    % the header on why an open-circuit voltage proves nothing.
    if allowed && clearV && clearI && (abs(ipk) > P.I_learn_A)
        df = P.Fold_Rise_per_s * Ts;
    end
end

% Frozen while inhibited: the pre-trip limit was too high, and that is the one
% fact the failed attempt established.
if allowed || df < 0
    fold = min(max(fold + df, P.Fold_Floor), 1);
end

% ---- the re-engagement ramp ----------------------------------------------
if ~allowed
    soft = 0;
elseif ~prevOk && P.t_softstart_s > 0
    soft = 0;                              % rising edge of permission
end
prevOk = allowed;

if allowed
    if P.t_softstart_s > 0
        soft = min(soft + Ts / P.t_softstart_s, 1);
    else
        soft = 1;
    end
end

% ---- combine ------------------------------------------------------------
if ~allowed
    dcl_frac   = 0;
    limitState = 4;
else
    dcl_frac = min(fold, soft);
    if soft < fold - 1e-9
        limitState = 3;                    % the ramp is the binding constraint
    elseif dcl_frac < 1 - 1e-9
        limitState = limitCause;
        if limitState == 0, limitState = 1; end   % holding, not yet reopened
    else
        limitState = 0;
    end
end

P_load   = dcl_frac * P_demand;
foldFrac = fold;
softFrac = soft;
end
