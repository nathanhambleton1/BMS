function [contactor, chg_ok, dch_ok, state, faults, flags, info] = ...
        bcp_protection(V_min, V_max, T_max, I_pack, reset, P)
%BCP_PROTECTION  Dwell-confirmed, latching pack protection with directional inhibits.
%#codegen
%
%   INPUTS
%     V_min, V_max  1x1  extreme cell voltages [V]
%     T_max         1x1  hottest measured temperature [degC]
%     I_pack        1x1  pack current [A], CHARGE-POSITIVE
%     reset         1x1  logical; a rising edge clears latched faults
%     P             struct of constants (see bcp.BmsConfig)
%
%   OUTPUTS
%     contactor  1x1  1 = closed
%     chg_ok     1x1  1 = charging permitted
%     dch_ok     1x1  1 = discharging permitted
%     state      1x1  0 INIT | 1 IDLE | 2 CHARGE | 3 DISCHARGE | 4 FAULT
%                     5 LOCKOUT (latched, and auto-recovery has been withdrawn)
%     faults     1x1  latched bitmask
%     flags      6x1  instantaneous, unconfirmed conditions, in fault-bit order
%     info       4x1  1 retry count, 2 lockout, 3 Ah charged since the UV latch,
%                     4 the recovery dwell currently required [s]
%
%   FAULT BITS
%     1 OV | 2 UV | 4 OC_charge | 8 OC_discharge | 16 OT | 32 UT_charge
%
%   THE FAULT OUTPUT IS A BITMASK, WHICH IS WHY YOU SEE 5 AND 10
%     faults is the OR of every bit that has latched, so simultaneous faults
%     ADD. The two combinations that turn up constantly are not new fault codes
%     and are not undocumented:
%
%       5  = 4 + 1  = OC_charge    + OV
%       10 = 8 + 2  = OC_discharge + UV
%
%     Both are one physical event reported by two mechanisms, and the ORDER
%     tells you which is which. An over-current confirms in t_i_trip (0.1 s by
%     default) and a voltage fault in t_v_trip (0.5 s), so an over-current that
%     is dragging the pack out of its voltage window shows the current bit
%     first, alone, and picks up the voltage bit about 0.4 s later. That is the
%     4-then-5 and 8-then-10 progression: not a state machine moving on, but a
%     second, slower confirmation completing.
%
%     Read it as "the over-draw was large enough to also breach the voltage
%     limit", which on a discharge means the load was well past what the pack
%     could deliver. bcp.Signals.faultBits decodes any mask into words, and
%     bcp.Signals.faultTable lists every combination you are likely to see.
%
%   OVER-CURRENT IS TWO TIERS SHARING ONE FAULT BIT
%     A cell has two current ratings and one trip cannot honour both. Set the
%     trip at the continuous rating and every pulse the pack was built to
%     deliver fires protection; set it at the pulse rating and a sustained
%     over-draw runs forever. So each direction gets:
%
%       the SUSTAINED tier   P.I_*_trip confirmed over P.t_i_cont
%       the FAST tier        P.I_*_peak confirmed over P.t_i_trip
%
%     Either one latches the same bit, because the consequence is the same:
%     open the pack. What differs is which kind of abuse each one catches. This
%     is how protection ICs stage over-current, and it is why a pulse test does
%     not need its discharge trip disabled to run.
%
%   DIRECTIONAL INHIBITS, NOT ONE BIG CONTACTOR
%     A cell over-voltage means stop charging. It does not mean stop
%     discharging -- discharging is the cure. Likewise under-voltage inhibits
%     the discharge and leaves the charge path open. A protection layer that
%     answers every fault by opening the contactor cannot recover from either
%     one without a human, and in this simulation it would deadlock: the load
%     is what brings an over-voltage pack back into range.
%
%     So only the faults that mean "this pack must be isolated" open the
%     contactor: over-temperature and over-current. Voltage faults inhibit the
%     direction that caused them.
%
%   WHY EVERY TRIP IS DWELL-CONFIRMED
%     An instantaneous trip on a stiff DAE chatters: the solver takes a trial
%     step, the threshold is crossed, the command is cut, voltage recovers, it
%     is restored. The dwell timers are what let this simulate at a sane step
%     size. Recovery uses a separate, wider threshold -- trip and clear must
%     never share a value.
%
%   =====================================================================
%   THE THREE MECHANISMS THAT STOP A RECOVERED FAULT FROM RE-TRIPPING
%   =====================================================================
%
%   The dwell timers and the hysteresis band above are enough for a fault whose
%   cause is external. They are NOT enough for a fault the protection layer
%   cures by acting on it, and under-voltage under a load is exactly that: the
%   sag IS the load, so inhibiting the load removes the sag, the pack reads
%   inside the clear band within one sample, the fault recovers, the load comes
%   back and the sag returns -- deeper, because the lap took charge out.
%
%   Left alone that is an unbounded oscillation: each cycle costs energy and
%   returns almost none, so the excursions grow and end up far below the
%   threshold that was supposed to prevent them. alg/bcp_load_limiter.m is the
%   main answer -- a continuous discharge limit in front of the trip, so the
%   trip rarely fires at all. These three are what protection itself
%   contributes, and each one closes a different escape route.
%
%   1. UNDER-VOLTAGE RECOVERY REQUIRES A CHARGE, NOT A REST (P.Q_uv_reset_Ah)
%
%      A pack that recovers to 3.0 V/cell the instant the load is removed has
%      not gained any energy; it has stopped losing it. Recovering on that
%      measurement is how the cycle above gets its permission to restart, and
%      it is also physically wrong: the cell is at its end of discharge whether
%      or not anything is drawing from it.
%
%      So the under-voltage latch additionally requires Q_uv_reset_Ah of NET
%      CHARGE to have gone into the pack since it latched. Only positive
%      current counts, and the accumulator resets when the latch clears. This
%      is how a production BMS handles under-voltage lockout, for the same
%      reason: the condition is "the pack is empty", and the only thing that
%      answers it is a charge.
%
%      Consequences worth knowing before you set it:
%        - On a load-only run (ChargeEnabled false, or no charger wired) the
%          under-voltage latch is now PERMANENT. That is the correct end of a
%          discharge test -- the pack is empty -- but it does mean the run stops
%          producing load current from that moment. bcp.Project.check says so.
%        - Set it to 0 to get the old rest-is-enough behaviour back.
%
%   2. EVERY AUTOMATIC RECOVERY COSTS MORE THAN THE LAST (P.Retry_Backoff_x)
%
%      The required clear-band dwell is P.t_recover for the first automatic
%      recovery, multiplied by Retry_Backoff_x for the second, again for the
%      third, and so on, capped at P.t_recover_max_s. The counter resets after
%      P.t_retry_window_s of running with nothing latched.
%
%      This is a fault retry counter with exponential backoff, and it is
%      standard on anything that reconnects itself to a load -- protection ICs,
%      inverter grid-reconnect logic, motor drives. Whatever oscillation
%      survives every other mechanism gets slower each lap instead of faster,
%      which converts a runaway into something that either settles or stops.
%
%   3. AFTER ENOUGH RETRIES, AUTO-RECOVERY IS WITHDRAWN (P.N_retry_max)
%
%      Once the counter reaches N_retry_max the lockout latch sets, and from
%      then on AutoRecover cannot clear anything: only a rising edge on the
%      reset port will, and it clears the counter and the lockout with it.
%      state reports 5 rather than 4 so this is visible without decoding info.
%
%      A pack that has faulted, recovered and faulted again N times in half a
%      minute is not experiencing N independent faults. It has a condition that
%      recovery does not fix, and continuing to reconnect it is how a
%      simulation runs for an hour producing a trace nobody can interpret and
%      how hardware welds a contactor. N_retry_max = Inf disables this and
%      leaves only the backoff; 0 makes the first fault terminal.

persistent st tOV tUV tOCc tOCd tOCcF tOCdF tOT tUT tClr latched prevReset
persistent retryN tQuiet lockout Q_uv initialised

if isempty(initialised)
    st = 0; tOV = 0; tUV = 0; tOCc = 0; tOCd = 0; tOCcF = 0; tOCdF = 0;
    tOT = 0; tUT = 0; tClr = 0; latched = uint32(0); prevReset = false;
    retryN = 0; tQuiet = 0; lockout = false; Q_uv = 0;
    initialised = true;
end

Ts = P.Ts;

% ---- instantaneous conditions -------------------------------------------
%  Every one is forced scalar. V_max, T_max and I_pack are scalars by
%  contract, but the block that calls this is wired by hand in someone else's
%  model, and a vector arriving on the temperature port would otherwise grow
%  flags -- and with it the diag output -- to a width nothing downstream
%  expects. A width mismatch on a diagnostic port is a compile error a long way
%  from its cause, so the reduction happens here as well as at the caller.
vmax = max(V_max(:));
vmin = min(V_min(:));
tmax = max(T_max(:));
ipk  = sum(I_pack(:));

cOV  = vmax >= P.V_ov_trip;
cUV  = vmin <= P.V_uv_trip;
cOCc = ipk  >  P.I_chg_trip;          % sustained tier, charge
cOCd = ipk  < -P.I_dch_trip;          % sustained tier, discharge
cOCcF = ipk >  P.I_chg_peak;          % fast tier, charge
cOCdF = ipk < -P.I_dch_peak;          % fast tier, discharge
cOT  = tmax >= P.T_ot_trip;
cUT  = (tmax <= P.T_ut_trip) && (ipk > 0);   % cold-charge inhibit only

% Preallocated, so the width of this output is a compile-time constant of 6
% whatever code generation infers about the conditions above.
flags = zeros(6,1);
flags(1) = double(cOV);
flags(2) = double(cUV);
flags(3) = double(cOCc || cOCcF);
flags(4) = double(cOCd || cOCdF);
flags(5) = double(cOT);
flags(6) = double(cUT);

% ---- confirmation timers -------------------------------------------------
tOV   = bcp_tick(tOV,   cOV,   Ts);
tUV   = bcp_tick(tUV,   cUV,   Ts);
tOCc  = bcp_tick(tOCc,  cOCc,  Ts);
tOCd  = bcp_tick(tOCd,  cOCd,  Ts);
tOCcF = bcp_tick(tOCcF, cOCcF, Ts);
tOCdF = bcp_tick(tOCdF, cOCdF, Ts);
tOT   = bcp_tick(tOT,   cOT,   Ts);
tUT   = bcp_tick(tUT,   cUT,   Ts);

newFault = uint32(0);
if tOV >= P.t_v_trip, newFault = bitor(newFault, uint32(1)); end
if tUV >= P.t_v_trip, newFault = bitor(newFault, uint32(2)); end
if (tOCc >= P.t_i_cont) || (tOCcF >= P.t_i_trip)
    newFault = bitor(newFault, uint32(4));
end
if (tOCd >= P.t_i_cont) || (tOCdF >= P.t_i_trip)
    newFault = bitor(newFault, uint32(8));
end
if tOT >= P.t_T_trip, newFault = bitor(newFault, uint32(16)); end
if tUT >= P.t_T_trip, newFault = bitor(newFault, uint32(32)); end

latched = bitor(latched, newFault);

% ---- clear conditions (hysteresis band; all must hold together) ----------
%  Current has no separate clear threshold: being back inside the SUSTAINED
%  trip is what "no longer over-current" means, in both directions.
allClear = (vmax <= P.V_ov_clear) && (vmin >= P.V_uv_clear) && ...
           (ipk <= P.I_chg_trip) && (ipk >= -P.I_dch_trip) && ...
           (tmax <= P.T_ot_clear) && (tmax >= P.T_ut_trip);
tClr = bcp_tick(tClr, allClear, Ts);

resetEdge = reset && ~prevReset;
prevReset = reset;

% ---- mechanism 1: the under-voltage latch wants charge, not rest ---------
%  Only positive (charging) current counts, and the accumulator is zeroed
%  whenever the latch is not held, so it always measures charge taken on since
%  THIS under-voltage event rather than since the start of the run.
uvHeld = bitand(latched, uint32(2)) ~= 0;
if uvHeld
    Q_uv = Q_uv + max(ipk, 0) * Ts / 3600;
else
    Q_uv = 0;
end
uvSatisfied = (~uvHeld) || (Q_uv >= P.Q_uv_reset_Ah);

% ---- mechanism 2: the dwell each recovery has to earn --------------------
dwellReq = min(P.t_recover * P.Retry_Backoff_x^retryN, P.t_recover_max_s);

% ---- mechanism 3: auto-recovery is withdrawn after enough retries --------
if retryN >= P.N_retry_max
    lockout = true;
end

% ---- recovery ------------------------------------------------------------
if latched ~= 0
    autoOk  = P.AutoRecover && ~lockout && allClear && uvSatisfied && ...
              (tClr >= dwellReq);
    % A reset edge is a human saying they have looked at it, so it answers the
    % lockout, the backoff and the charge requirement -- but not the clear
    % band. Clearing a fault whose condition is still present just re-latches
    % on the next sample and burns a retry doing it.
    manualOk = resetEdge && allClear && (tClr >= P.t_recover);

    if autoOk || manualOk
        latched = uint32(0);
        tOV = 0; tUV = 0; tOCc = 0; tOCd = 0; tOCcF = 0; tOCdF = 0;
        tOT = 0; tUT = 0; Q_uv = 0;
        tQuiet = 0;
        if manualOk
            retryN  = 0;
            lockout = false;
        else
            retryN = retryN + 1;
        end
    end
end

% ---- the retry window ---------------------------------------------------
%  Measured as time spent RUNNING with nothing latched, which is the only
%  reading that means what the counter is for: "this pack has been fine for a
%  while, so the next fault is a fresh one rather than the same one again."
%
%  THE LOCKOUT GOES WITH THE COUNTER, and that is not cosmetic. lockout is set
%  the moment retryN reaches N_retry_max, which is one sample AFTER the Nth
%  successful clear -- so there is a window in which nothing is latched and the
%  lockout is already armed. Leaving it armed through a window that then expires
%  cleanly would mean a pack that recovered N times, ran perfectly for
%  t_retry_window_s, and was still refused its next automatic recovery for the
%  rest of the run.
%
%  The forgiveness cannot be exploited by a pack that is genuinely cycling,
%  because this branch only runs while latched == 0: a locked-out fault holds
%  the latch, which pins tQuiet at zero, so the window never expires and the
%  lockout stands until a reset edge.
if latched == 0
    tQuiet = tQuiet + Ts;
    if tQuiet >= P.t_retry_window_s
        retryN  = 0;
        lockout = false;
    end
else
    tQuiet = 0;
end

% ---- decode the latch into permissions -----------------------------------
fOV  = bitand(latched, uint32(1))  ~= 0;
fUV  = bitand(latched, uint32(2))  ~= 0;
fOCc = bitand(latched, uint32(4))  ~= 0;
fOCd = bitand(latched, uint32(8))  ~= 0;
fOT  = bitand(latched, uint32(16)) ~= 0;
fUT  = bitand(latched, uint32(32)) ~= 0;

isolate = fOT || fOCc || fOCd;              % faults that must open the pack
chg_ok  = double(~(isolate || fOV || fUT));
dch_ok  = double(~(isolate || fUV));
contactor = double(~isolate);

% ---- state ---------------------------------------------------------------
if latched ~= 0
    if lockout
        st = 5;
    else
        st = 4;
    end
elseif ipk > 0.05
    st = 2;
elseif ipk < -0.05
    st = 3;
else
    st = 1;
end

state  = st;
faults = double(latched);

info = zeros(4,1);
info(1) = retryN;
info(2) = double(lockout);
info(3) = Q_uv;
info(4) = dwellReq;
end
