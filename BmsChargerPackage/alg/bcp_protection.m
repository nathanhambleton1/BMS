function [contactor, chg_ok, dch_ok, state, faults, flags] = ...
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
%     faults     1x1  latched bitmask
%     flags      6x1  instantaneous, unconfirmed conditions, in fault-bit order
%
%   FAULT BITS
%     1 OV | 2 UV | 4 OC_charge | 8 OC_discharge | 16 OT | 32 UT_charge
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

persistent st tOV tUV tOCc tOCd tOCcF tOCdF tOT tUT tClr latched prevReset initialised

if isempty(initialised)
    st = 0; tOV = 0; tUV = 0; tOCc = 0; tOCd = 0; tOCcF = 0; tOCdF = 0;
    tOT = 0; tUT = 0; tClr = 0; latched = uint32(0); prevReset = false;
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

if latched ~= 0
    canClear = (tClr >= P.t_recover) && allClear;
    if (P.AutoRecover && canClear) || (resetEdge && canClear)
        latched = uint32(0);
        tOV = 0; tUV = 0; tOCc = 0; tOCd = 0; tOCcF = 0; tOCdF = 0;
        tOT = 0; tUT = 0;
    end
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
    st = 4;
elseif ipk > 0.05
    st = 2;
elseif ipk < -0.05
    st = 3;
else
    st = 1;
end

state  = st;
faults = double(latched);
end
