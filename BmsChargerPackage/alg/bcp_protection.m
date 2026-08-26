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
%     flags      6x1  instantaneous, unconfirmed conditions
%
%   FAULT BITS
%     1 OV | 2 UV | 4 OC_charge | 8 OC_discharge | 16 OT | 32 UT_charge
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

persistent st tOV tUV tOCc tOCd tOT tUT tClr latched prevReset initialised

if isempty(initialised)
    st = 0; tOV = 0; tUV = 0; tOCc = 0; tOCd = 0; tOT = 0; tUT = 0;
    tClr = 0; latched = uint32(0); prevReset = false; initialised = true;
end

Ts = P.Ts;

% ---- instantaneous conditions -------------------------------------------
cOV  = V_max >= P.V_ov_trip;
cUV  = V_min <= P.V_uv_trip;
cOCc = I_pack >  P.I_chg_trip;
cOCd = I_pack < -P.I_dch_trip;
cOT  = T_max >= P.T_ot_trip;
cUT  = (T_max <= P.T_ut_trip) && (I_pack > 0);   % cold-charge inhibit only

flags = double([cOV; cUV; cOCc; cOCd; cOT; cUT]);

% ---- confirmation timers -------------------------------------------------
tOV  = bcp_tick(tOV,  cOV,  Ts);
tUV  = bcp_tick(tUV,  cUV,  Ts);
tOCc = bcp_tick(tOCc, cOCc, Ts);
tOCd = bcp_tick(tOCd, cOCd, Ts);
tOT  = bcp_tick(tOT,  cOT,  Ts);
tUT  = bcp_tick(tUT,  cUT,  Ts);

newFault = uint32(0);
if tOV  >= P.t_v_trip, newFault = bitor(newFault, uint32(1));  end
if tUV  >= P.t_v_trip, newFault = bitor(newFault, uint32(2));  end
if tOCc >= P.t_i_trip, newFault = bitor(newFault, uint32(4));  end
if tOCd >= P.t_i_trip, newFault = bitor(newFault, uint32(8));  end
if tOT  >= P.t_T_trip, newFault = bitor(newFault, uint32(16)); end
if tUT  >= P.t_T_trip, newFault = bitor(newFault, uint32(32)); end

latched = bitor(latched, newFault);

% ---- clear conditions (hysteresis band; all must hold together) ----------
allClear = (V_max <= P.V_ov_clear) && (V_min >= P.V_uv_clear) && ...
           (I_pack <= P.I_chg_trip) && (I_pack >= -P.I_dch_trip) && ...
           (T_max <= P.T_ot_clear) && (T_max >= P.T_ut_trip);
tClr = bcp_tick(tClr, allClear, Ts);

resetEdge = reset && ~prevReset;
prevReset = reset;

if latched ~= 0
    canClear = (tClr >= P.t_recover) && allClear;
    if (P.AutoRecover && canClear) || (resetEdge && canClear)
        latched = uint32(0);
        tOV = 0; tUV = 0; tOCc = 0; tOCd = 0; tOT = 0; tUT = 0;
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
elseif I_pack > 0.05
    st = 2;
elseif I_pack < -0.05
    st = 3;
else
    st = 1;
end

state  = st;
faults = double(latched);
end
