function [I_cmd, P_cmd, mode, V_set, I_set, done] = ...
        bcp_charger(V_pack, V_max, I_meas, enable, I_limit, P)
%BCP_CHARGER  Precharge / CC / CV charge supervisor with dwell-confirmed termination.
%#codegen
%
%   INPUTS
%     V_pack   1x1  pack terminal voltage [V]
%     V_max    1x1  highest cell voltage [V]
%     I_meas   1x1  measured pack current [A], CHARGE-POSITIVE
%     enable   1x1  permission from bcp_arbiter (the load has priority)
%     I_limit  1x1  current ceiling from bcp_arbiter [A]
%     P        struct of constants (see bcp.ChargerConfig)
%
%   OUTPUTS
%     I_cmd  1x1  commanded charge current [A], >= 0
%     P_cmd  1x1  commanded charge power  [W], >= 0
%     mode   1x1  0 OFF | 1 PRECHARGE | 2 CC | 3 CV | 4 DONE
%     V_set  1x1  the voltage the supply is programmed to [V]
%     I_set  1x1  the current the supply is programmed to [A]
%     done   1x1  1 once the taper has terminated the charge
%
%   THE CV LOOP REGULATES THE HIGHEST CELL, NOT THE PACK VOLTAGE
%     On a pack with real cell-to-cell spread these are different problems.
%     Pack-voltage CV will happily push the highest cell past its over-voltage
%     trip while the pack average still looks fine, and that is the single most
%     common way a programmatically built charge controller destroys cells --
%     first in simulation, then in hardware. This loop takes the LOWER of the
%     two commands: the one that holds the maximum cell at V_cv_cell, and the
%     one that holds the pack at V_cv_pack. Whichever binds first, binds.
%
%   TERMINATION IS DWELL-CONFIRMED, AND THAT IS NOT OPTIONAL
%     Kp is large by design -- tens of amps per volt -- so the proportional
%     term saturates the loop for any error above a few tens of millivolts, and
%     clamping anti-windup holds the integrator at zero for the whole CC phase.
%     The instant the highest cell reaches the target, the error collapses to
%     nearly zero and, with the integrator still empty, the command dips to
%     near zero before integral action winds it up to the true CV equilibrium.
%     Terminating on that dip ends every charge at the CC-CV knee: the phase
%     sequence looks perfect and the pack is nowhere near full. Confirming the
%     taper over t_term_s rides through the transient, because a genuine taper
%     persists and the transient does not.
%
%   MODE SWITCHING IS AUTOMATIC AND DERIVED, NOT COMMANDED
%     There is no "CC mode" input. The mode output reports which limit is
%     currently binding: the command sits at the current ceiling (CC) or below
%     it because a voltage target is holding it down (CV). One control law, two
%     names for what it is doing. ForceMode exists only to pin the loop while
%     debugging and defaults to automatic.
%
%   THE TAPER CLOCK RUNS ONLY IN CV, AND ONLY AT FULL PERMISSION
%     Two ways to get a false termination, both guarded here. A CC phase
%     derated by I_limit can sit below I_taper_A without being a taper, so the
%     clock requires mode == 3. And a charge interrupted by the load spends
%     that time at zero current, which is not a taper either, so enable == 0
%     resets the clock rather than advancing it -- see the early return below.
%
%   RE-ARMING AFTER DONE
%     done latches, and clears when the highest cell falls back below
%     V_recharge_cell -- i.e. when the load has actually taken charge out of the
%     pack. It does NOT clear merely because enable dropped, or every gap
%     between two load pulses would restart a finished charge.

persistent integ tTaper done_l initialised

if isempty(initialised)
    integ = 0; tTaper = 0; done_l = false; initialised = true;
end

Ts = P.Ts;

% ---- re-arm --------------------------------------------------------------
if done_l && V_max <= P.V_recharge_cell
    done_l = false;
end

V_set = min(P.V_cv_pack, P.V_cv_cell * P.SeriesCount);

% ---- not running ---------------------------------------------------------
if enable < 0.5
    integ  = 0;
    tTaper = 0;
    I_cmd  = 0;
    P_cmd  = 0;
    I_set  = 0;
    if done_l
        mode = 4;
    else
        mode = 0;
    end
    done = double(done_l);
    return;
end

if done_l
    integ  = 0;
    tTaper = 0;
    I_cmd  = 0;
    P_cmd  = 0;
    I_set  = 0;
    mode   = 4;
    done   = 1;
    return;
end

% ---- ceiling for this sample --------------------------------------------
Icc = max(min(P.I_cc_A, I_limit), 0);

% ---- precharge: a deeply discharged pack gets a trickle, not the full CC --
%  Pushing 1C into a cell below V_precharge_cell is how a deeply discharged
%  cell becomes a damaged one. A plain current clamp, not a separate loop.
if V_max < P.V_precharge_cell
    I_cmd  = min(P.I_precharge_A, Icc);
    I_set  = I_cmd;
    P_cmd  = I_cmd * V_pack;
    mode   = 1;
    integ  = 0;
    tTaper = 0;
    done   = 0;
    return;
end

% ---- CC-CV: one PI loop, two voltage targets, lower command wins ----------
errCell = P.V_cv_cell - V_max;
errPack = P.V_cv_pack - V_pack;

trialCell = P.Kp_cell * errCell + P.Ki_cell * (integ + errCell * Ts);
trialPack = P.Kp_pack * errPack + P.Ki_pack * (integ + errPack * Ts);

if trialCell <= trialPack
    unsat  = trialCell;
    errAct = errCell;
else
    unsat  = trialPack;
    errAct = errPack;
end

I_cmd = min(max(unsat, 0), Icc);

% Clamping anti-windup: integrate only while the output is not saturated.
% Without this the integrator winds up through the entire CC phase and the
% handover into CV overshoots straight into the over-voltage trip.
if abs(I_cmd - unsat) < 1e-9
    integ = integ + errAct * Ts;
end

% ---- which limit is binding? --------------------------------------------
if I_cmd >= Icc - 1e-9
    mode = 2;                        % current-limited: CC
else
    mode = 3;                        % voltage-limited: CV
end

if P.ForceMode == 2
    I_cmd = Icc;                     % debug: pin to constant current
    mode  = 2;
end

% ---- dwell-confirmed taper termination -----------------------------------
if mode == 3 && I_cmd <= P.I_taper_A
    tTaper = tTaper + Ts;
else
    tTaper = 0;
end
if tTaper >= P.t_term_s
    done_l = true;
    I_cmd  = 0;
    mode   = 4;
end

I_set = Icc;
P_cmd = I_cmd * V_pack;
done  = double(done_l);
end
