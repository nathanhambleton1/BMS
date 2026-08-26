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
%   What it does model: OCV against SOC, a series resistance, coulomb counting,
%   and cell-to-cell spread in capacity, resistance and initial SOC. That last
%   one matters more than it looks: without spread, min and max cell voltage are
%   identical and the charger's per-cell CV loop is never distinguishable from a
%   pack-voltage loop, so a whole class of bug tests as passing.
%
%   What it does not model: RC dynamics, temperature, ageing, hysteresis,
%   anything nonlinear in the resistance, and any charge or discharge
%   inefficiency. Voltage sag here is exactly I*R.
%
%   ARRAY LAYOUT: one entry per SERIES ELEMENT, with the P parallel cells of
%   each element lumped. So Icell is the pack current repeated S times, and
%   V_pack is sum(Vcell). This is one of the two layouts the Battery Model
%   Builder produces, and bcp_pack_monitor handles both.
%
%   INPUTS
%     P_net  1x1  net power demand [W], DRAW-POSITIVE (load minus charge)
%     P      struct: Ts, S, Q_Ah (element), R0 (Sx1), SOC0 (Sx1),
%                    OCV_SOC, OCV_V, V_floor
%
%   OUTPUTS
%     Vcell   Sx1  element terminal voltage [V]
%     SOCcell Sx1  element state of charge, 0..1
%     Icell   Sx1  element current [A], DISCHARGE-POSITIVE (see below)
%     V_pack  1x1  pack terminal voltage [V]
%
%   Icell IS DISCHARGE-POSITIVE ON PURPOSE
%     Simscape Battery blocks report current positive out of the positive
%     terminal, so the array a real pack model hands you is discharge-positive
%     and bcp.BmsConfig.I_sign defaults to -1 to convert it. The harness copies
%     that convention rather than the convenient one, so that a sign error in
%     the default configuration shows up here instead of in your real model.

persistent soc V_prev initialised

S = P.S;

if isempty(initialised)
    soc   = P.SOC0(:);
    V_prev = sum(bcp_ocv(P.SOC0(:), P.OCV_SOC, P.OCV_V));
    initialised = true;
end

% ---- power demand -> current, using LAST step's voltage -------------------
%  The plant has the same algebraic loop the BMS does: current depends on
%  voltage, voltage depends on current. Resolved the same way -- one sample of
%  delay -- so the harness needs no iteration and no algebraic-loop solver.
I_pack = -P_net / max(V_prev, P.V_floor);        % charge-positive

% ---- coulomb counting ----------------------------------------------------
soc = soc + I_pack * P.Ts ./ (3600 * P.Q_Ah);
soc = min(max(soc, 0), 1);

% ---- terminal voltage ----------------------------------------------------
ocv   = bcp_ocv(soc, P.OCV_SOC, P.OCV_V);
Vcell = ocv + I_pack * P.R0(:);                  % charging raises the terminal

V_pack = sum(Vcell);
V_prev = V_pack;

SOCcell = soc;
Icell   = -I_pack * ones(S,1);                   % discharge-positive, see header
end
