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
%   THE BMS OWNS THE RATE; THIS BLOCK OWNS THE SHAPE
%     I_limit is the charge current the BMS permits. P.I_cc_A is this supply's
%     own rating. The lower binds. That split is the whole reason the charge
%     rate is a one-number change: raise the BMS limit and this block follows,
%     without a matching edit here and without any chance of the two
%     disagreeing about what is allowed.
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
%   TWO LOOPS MEANS TWO INTEGRATORS, AND EACH ONE TRACKS WHAT WAS APPLIED
%     The earlier version ran both control laws off a SHARED integrator, and
%     that is what made the charger limit-cycle at the CC-CV knee. The two
%     loops measure different errors -- the pack error is S times the cell
%     error -- so a single accumulator means whichever loop lost the min()
%     selection last was still writing the state the winner reads. Around the
%     knee the selection alternates every sample, the integrator is driven by
%     two incompatible signals, and the command oscillates between the current
%     ceiling and well below it. Nothing about the thresholds was wrong; the
%     state was shared.
%
%     Each loop now has its own state, and after the command is clamped BOTH
%     states are back-calculated so that each loop's own output equals the
%     command that was actually applied:
%
%         x_k = (I_cmd - Kp_k*e_k) / Ki_k
%
%     For the loop that is running and unsaturated this assignment is the
%     identity, so integral action is untouched. For the loop that lost, and
%     for either loop while the command sits on a limit, it is exact tracking
%     anti-windup: no wind-up during the whole CC phase, and a bumpless
%     handover whenever the binding constraint changes. One expression
%     replaces the old conditional-integration branch and removes both failure
%     modes it had.
%
%   MODE IS A SCHMITT TRIGGER WITH A MINIMUM DWELL, NOT A COMPARISON
%     "At the ceiling" is CC and "below it" is CV, but a bare comparison
%     against the ceiling toggles every sample while the command sits on it.
%     Entering CV needs the command to fall P.Mode_Hyst_frac below the
%     ceiling; returning to CC needs it back within a quarter of that band; and
%     either change has to wait out P.t_mode_min_s. The mode output is a
%     report, and a report that chatters is a report nobody can read.
%
%   TERMINATION DOES NOT DEPEND ON THE MODE
%     A taper is "the command has fallen away BECAUSE the voltage target is
%     satisfied", so that is what is tested: the command below I_taper_A while
%     the highest cell is within V_term_band of its target. Keying it off
%     mode == 3 instead made the termination clock hostage to the mode
%     chattering, and a charge could sit at its target indefinitely without
%     ever accumulating a confirmed taper.
%
%     The confirmation over t_term_s is not optional either. Kp is large by
%     design, so the command dips sharply the instant the target is first
%     reached, before integral action winds up to the true CV equilibrium.
%     Terminating on that dip ends every charge at the knee: the phase sequence
%     looks perfect and the pack is nowhere near full.
%
%   THE TAPER CLOCK ONLY RUNS AT FULL PERMISSION
%     A charge interrupted by the load spends that time at zero current, which
%     is not a taper, so enable == 0 resets the clock rather than advancing it
%     -- see the early return below. A CC phase derated by I_limit sits below
%     I_taper_A without being a taper either, which is what the voltage
%     condition rules out.
%
%   RE-ARMING AFTER DONE
%     done latches, and clears when the highest cell falls back below
%     V_recharge_cell -- i.e. when the load has actually taken charge out of the
%     pack. It does NOT clear merely because enable dropped, or every gap
%     between two load pulses would restart a finished charge.

persistent xCell xPack tTaper done_l modeSt tMode initialised

if isempty(initialised)
    xCell = 0; xPack = 0; tTaper = 0; done_l = false;
    modeSt = 2; tMode = 0; initialised = true;
end

Ts = P.Ts;

% ---- re-arm --------------------------------------------------------------
if done_l && V_max <= P.V_recharge_cell
    done_l = false;
end

V_set = min(P.V_cv_pack, P.V_cv_cell * P.SeriesCount);

% ---- not running ---------------------------------------------------------
if enable < 0.5
    xCell  = 0;
    xPack  = 0;
    tTaper = 0;
    modeSt = 2;                  % re-enter the next charge in CC
    tMode  = 0;
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
    xCell  = 0;
    xPack  = 0;
    tTaper = 0;
    modeSt = 2;
    tMode  = 0;
    I_cmd  = 0;
    P_cmd  = 0;
    I_set  = 0;
    mode   = 4;
    done   = 1;
    return;
end

% ---- ceiling for this sample --------------------------------------------
%  The supply's rating and the BMS's permission, whichever is lower.
Icc = max(min(P.I_cc_A, I_limit), 0);

% ---- precharge: a deeply discharged pack gets a trickle, not the full CC --
%  Pushing 1C into a cell below V_precharge_cell is how a deeply discharged
%  cell becomes a damaged one. A plain current clamp, not a separate loop.
if V_max < P.V_precharge_cell
    I_cmd  = min(P.I_precharge_A, Icc);
    I_set  = I_cmd;
    P_cmd  = I_cmd * V_pack;
    mode   = 1;
    xCell  = 0;
    xPack  = 0;
    tTaper = 0;
    modeSt = 2;
    tMode  = 0;
    done   = 0;
    return;
end

% ---- CC-CV: two PI loops, two voltage targets, lower command wins --------
errCell = P.V_cv_cell - V_max;
errPack = P.V_cv_pack - V_pack;

% Only accumulate where there is integral action to use it. With Ki = 0 the
% loop is pure proportional and an unread accumulator would just grow forever.
if P.Ki_cell > 0
    xCell = xCell + errCell * Ts;
end
if P.Ki_pack > 0
    xPack = xPack + errPack * Ts;
end

uCell = P.Kp_cell * errCell + P.Ki_cell * xCell;
uPack = P.Kp_pack * errPack + P.Ki_pack * xPack;

I_cmd = min(max(min(uCell, uPack), 0), Icc);

% Tracking anti-windup, applied to BOTH loops unconditionally. For the loop
% that is binding and unsaturated this is the identity; for every other case it
% pins the state so the loop's own output equals what was applied. That is what
% makes the handover bumpless and the knee quiet -- see the header.
if P.Ki_cell > 0
    xCell = (I_cmd - P.Kp_cell * errCell) / P.Ki_cell;
end
if P.Ki_pack > 0
    xPack = (I_cmd - P.Kp_pack * errPack) / P.Ki_pack;
end

% ---- which limit is binding? Schmitt trigger plus minimum dwell ----------
band = max(P.Mode_Hyst_frac * Icc, 1e-9);
tMode = tMode + Ts;

if modeSt == 2                       % currently reporting CC
    want = 2;
    if I_cmd < Icc - band, want = 3; end
else                                 % currently reporting CV
    want = 3;
    if I_cmd >= Icc - 0.25*band, want = 2; end
end
if want ~= modeSt && tMode >= P.t_mode_min_s
    modeSt = want;
    tMode  = 0;
end
mode = modeSt;

if P.ForceMode == 2
    I_cmd  = Icc;                    % debug: pin to constant current
    mode   = 2;
    modeSt = 2;
end

% ---- dwell-confirmed taper termination -----------------------------------
%  Keyed off the physics, not off the mode: the command has fallen below the
%  taper threshold AND the cell is sitting at its target. A derated CC meets
%  the first condition and not the second.
atTarget = (V_max >= P.V_cv_cell - P.V_term_band) || ...
           (V_pack >= P.V_cv_pack - P.V_term_band * P.SeriesCount);
if atTarget && I_cmd <= P.I_taper_A
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
