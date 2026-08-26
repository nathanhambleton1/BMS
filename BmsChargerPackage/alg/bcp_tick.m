function tOut = bcp_tick(tIn, cond, Ts)
%BCP_TICK  Dwell accumulator: count up while COND holds, reset the moment it does not.
%#codegen
%
%   Shared by bcp_protection and bcp_arbiter so both use the same definition
%   of "this condition has held for long enough". A separate file rather than a
%   local function because both callers are compiled into MATLAB Function
%   blocks, and a local subfunction would have to be duplicated in each.
if cond
    tOut = tIn + Ts;
else
    tOut = 0;
end
end
