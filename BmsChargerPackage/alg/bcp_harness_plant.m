function [Vcell, SOCcell, Icell, V_pack] = bcp_harness_plant(P_net, P)
%BCP_HARNESS_PLANT  A deliberately crude battery stand-in, for testing the blocks.
%#codegen
%
%   THIS IS NOT A BATTERY MODEL. It is a first-order resistive stand-in that
%   exists so the BMS and charger blocks can be exercised end to end without a
%   Simscape licence, without a pack build, and in about a second. Use it to
%   check that the blocks behave -- that the load takes priority, that CC hands
%   over to CV, that a fault latches -- and then run the real questions on your
%   real Battery Model Builder pack.
%
%   What it does model: OCV against SOC, a series resistance that also varies
%   with SOC, coulomb counting, and cell-to-cell spread in resistance and
%   initial SOC. That last one matters more than it looks: without spread, min
%   and max cell voltage are identical and the charger's per-cell CV loop is
%   never distinguishable from a pack-voltage loop, so a whole class of bug
%   tests as passing.
%
%   What it does not model: RC dynamics, temperature, ageing, hysteresis, and
%   any charge or discharge inefficiency. Voltage sag here is exactly I*R0(SOC).
%
%   WHY R0 IS A TABLE AND NOT A NUMBER
%     A real cell's DC resistance is strongly SOC-dependent -- for the Molicel
%     P45B tables the Battery Model Builder generates, it runs from about
%     9.5 mOhm near full to 21 mOhm near empty, better than a factor of two.
%     Under a constant-POWER load that feedback is what sets the operating
%     point: more sag means more current means more sag. A single mid-range
%     resistance gets the pulse current wrong at exactly the ends of the SOC
%     range where you care whether protection trips. bcp.CellTables reads the
%     real curve out of the generated .ssc so the harness and the Simscape pack
%     are talking about the same cell.
%
%   ARRAY LAYOUT: one entry per SERIES ELEMENT, with the P parallel cells of
%   each element lumped. So Icell is the pack current repeated S times, and
%   V_pack is sum(Vcell). This is one of the layouts the Battery Model Builder
%   produces, and bcp_pack_monitor handles it.
%
%   INPUTS
%     P_net  1x1  net power demand [W], DRAW-POSITIVE (load minus charge)
%     P      struct: Ts, S, Q_Ah (element), R0_SOC, R0_TAB, R0_scale (Sx1),
%                    SOC0 (Sx1), OCV_SOC, OCV_V, V_floor
%
%   OUTPUTS
%     Vcell   Sx1  element terminal voltage [V]
%     SOCcell Sx1  element state of charge, 0..1
%     Icell   Sx1  element current [A], CHARGE-POSITIVE (see below)
%     V_pack  1x1  pack terminal voltage [V]
%
%   Icell IS CHARGE-POSITIVE, MATCHING SIMSCAPE BATTERY
%     A pack model's current array polarity is the single easiest thing to get
%     backwards, and bcp.BmsConfig.I_sign is the one place it is converted. The
%     harness emits the same polarity a Simscape Battery pack does -- those
%     components declare their cell current "positive in", which is positive
%     while charging -- so the package default of I_sign = +1 is correct for
%     both, and a harness run exercises the same sign path your real model will.
%
%     This used to emit discharge-positive to match a default of -1, and the
%     default was simply wrong: on a real Battery Model Builder pack it made the
%     BMS read a large positive current during a discharge pulse and latch an
%     over-current-CHARGE fault. Check your own pack against a known discharge
%     anyway -- bcp_pack_monitor says how.

persistent soc V_prev initialised

S = P.S;

if isempty(initialised)
    soc    = P.SOC0(:);
    V_prev = sum(bcp_ocv(P.SOC0(:), P.OCV_SOC, P.OCV_V));
    initialised = true;
end

% ---- power demand -> current, using LAST step's voltage -------------------
%  The plant has the same algebraic loop the BMS does: current depends on
%  voltage, voltage depends on current. Resolved the same way -- one sample of
%  delay -- so the harness needs no iteration and no algebraic-loop solver.
%  Run the plant several times faster than the BMS (bcp.Harness.PlantRatio) and
%  the constant-power operating point settles well inside one BMS sample.
I_pack = -P_net / max(V_prev, P.V_floor);        % charge-positive

% ---- coulomb counting ----------------------------------------------------
soc = soc + I_pack * P.Ts ./ (3600 * P.Q_Ah);
soc = min(max(soc, 0), 1);

% ---- terminal voltage ----------------------------------------------------
%  bcp_ocv is a plain clamped piecewise-linear lookup; it is reused here for
%  the resistance curve rather than duplicating the same loop under a second
%  name. R0_scale carries the per-element spread.
ocv   = bcp_ocv(soc, P.OCV_SOC, P.OCV_V);
r0    = bcp_ocv(soc, P.R0_SOC,  P.R0_TAB) .* P.R0_scale(:);
Vcell = ocv + I_pack * r0;                       % charging raises the terminal

V_pack = sum(Vcell);
V_prev = V_pack;

SOCcell = soc;
Icell   = I_pack * ones(S,1);                    % charge-positive, see header
end
