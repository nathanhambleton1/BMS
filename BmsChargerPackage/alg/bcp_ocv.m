function v = bcp_ocv(soc, socBP, vBP)
%BCP_OCV  Piecewise-linear open-circuit voltage lookup.
%#codegen
%
%   Written out by hand rather than calling interp1 so that it is unambiguously
%   code-generatable inside a MATLAB Function block on any release, and so the
%   clamping at both ends of the table is visible rather than a name-value
%   option someone has to remember.
%
%   INPUTS
%     soc    Nx1  state of charge, 0..1 (clamped to the table's range)
%     socBP  Mx1  breakpoints, strictly increasing
%     vBP    Mx1  open-circuit voltage at each breakpoint [V]
%
%   OUTPUT
%     v      Nx1  interpolated OCV [V]
%
%   Used only by the test harness plant. The BMS and charger blocks do not need
%   an OCV table -- they work from measured voltage and the SOC your battery
%   model reports, which is the whole reason they can be dropped onto a pack
%   model built by someone else.

n = numel(soc);
m = numel(socBP);
v = zeros(n,1);

for k = 1:n
    s = min(max(soc(k), socBP(1)), socBP(m));
    j = 1;
    for i = 1:m-1
        if s >= socBP(i)
            j = i;
        end
    end
    span = socBP(j+1) - socBP(j);
    if span > 0
        f = (s - socBP(j)) / span;
    else
        f = 0;
    end
    v(k) = vBP(j) + f * (vBP(j+1) - vBP(j));
end
end
