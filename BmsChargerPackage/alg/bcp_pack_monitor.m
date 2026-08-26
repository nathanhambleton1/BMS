function meas = bcp_pack_monitor(Vcell, SOCcell, Icell, P)
%BCP_PACK_MONITOR  Reduce the battery model's per-cell arrays to pack scalars.
%#codegen
%
%   INPUTS
%     Vcell    Nx1  per-element terminal voltage [V]   from your battery model
%     SOCcell  Mx1  per-element state of charge       from your battery model
%     Icell    Kx1  per-element current [A]           from your battery model
%     P        struct of constants (see bcp.BmsConfig)
%
%   OUTPUT
%     meas     7x1  the pack measurement vector, indices per bcp.Signals:
%                     1 V_pack     [V]
%                     2 V_cell_min [V]
%                     3 V_cell_max [V]
%                     4 SOC_pack   [0..1]
%                     5 SOC_min    [0..1]
%                     6 SOC_max    [0..1]
%                     7 I_pack     [A]  CHARGE-POSITIVE
%
%   WHY mean()*S AND sum()/S RATHER THAN sum() AND sum()
%     The Battery Model Builder emits arrays whose length depends on how you
%     configured the pack: one entry per cell (S*P entries), one entry per
%     series element with the parallel strings lumped (S entries), or one entry
%     per module. Which one you get is a build option, and getting it wrong by
%     summing blindly gives a pack voltage that is P times too large -- a
%     mistake that looks plausible on a scope.
%
%     Parallel cells share a voltage, so mean(Vcell)*S is the pack voltage for
%     BOTH the per-cell and the per-series-element layout. Series cells share a
%     current, so sum(Icell)/S is the pack current for both. These two forms
%     are correct without knowing which array shape you were given, and they
%     stay correct if you rebuild the pack with a different layout.
%
%     If your arrays are per-MODULE rather than per-cell, set
%     bcp.BmsConfig.SeriesCount to the number of series MODULES, because that
%     is what the array is now counting.
%
%   SIGN CONVENTION
%     P.I_sign converts your battery model's current polarity to this
%     package's charge-positive convention. Simscape Battery blocks report
%     current positive out of the positive terminal -- i.e. positive when
%     DISCHARGING -- so the default is -1. Get this wrong and the BMS will
%     over-current-trip on a charge and never trip on a discharge. Check it
%     once against a known discharge, then leave it alone.

Vmean = mean(Vcell);
Vmin  = min(Vcell);
Vmax  = max(Vcell);

soc = SOCcell;
if P.SOC_in_percent
    soc = soc / 100;
end

I_pack = P.I_sign * sum(Icell) / P.SeriesCount;

meas = [ Vmean * P.SeriesCount;   % 1 V_pack
         Vmin;                    % 2 V_cell_min
         Vmax;                    % 3 V_cell_max
         mean(soc);               % 4 SOC_pack
         min(soc);                % 5 SOC_min
         max(soc);                % 6 SOC_max
         I_pack ];                % 7 I_pack, charge-positive
end
