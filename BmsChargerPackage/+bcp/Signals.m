classdef Signals
%BCP.SIGNALS  The one definition of what is in the pack measurement vector.
%
%   The BMS block reduces your battery model's per-cell arrays to a single
%   7-element vector and hands that one wire to the charger. This class is the
%   only place the index-to-meaning mapping is written down. Everything that
%   packs or unpacks that vector -- bcp_pack_monitor, the generated charger
%   code, the plotting helpers -- reads it from here.
%
%   If you add a channel, add it at the END and bump NUM. Inserting one in the
%   middle silently reinterprets every existing wire.

    properties (Constant)
        V_PACK   = 1    % pack terminal voltage [V]
        V_MIN    = 2    % lowest cell voltage [V]
        V_MAX    = 3    % highest cell voltage [V]
        SOC_PACK = 4    % mean state of charge [0..1]
        SOC_MIN  = 5    % lowest cell SOC [0..1]
        SOC_MAX  = 6    % highest cell SOC [0..1]
        I_PACK   = 7    % pack current [A], CHARGE-POSITIVE
        NUM      = 7

        DIAG_NUM = 17   % elements in the BMS block's diag output
        %  The single definition of that width. The generated BMS_core
        %  preallocates diag to exactly this, and everything that unpacks it
        %  reads the number from here rather than writing 17 again -- because a
        %  width written down twice is a width that will disagree with itself,
        %  and the symptom is a Simulink port mismatch reported against whatever
        %  the wire happens to reach.
    end

    methods (Static)
        function n = names()
            n = {'V_pack','V_cell_min','V_cell_max', ...
                 'SOC_pack','SOC_min','SOC_max','I_pack'};
        end

        function u = units()
            u = {'V','V','V','-','-','-','A'};
        end

        function n = diagNames()
        %DIAGNAMES  What is in the BMS block's diag output, channel by channel.
        %
        %   THE FOUR PAIRS WORTH WATCHING, in the order you would look at them
        %   when a run does something you did not expect:
        %
        %     demand_present vs load_active
        %       what the waveform asked for, and what survived. When they
        %       disagree the load is being held off or derated.
        %
        %     dcl_frac and limit_state
        %       how much of the demand the load limiter is letting through, and
        %       which constraint is binding. dcl_frac below 1 with no fault
        %       latched is the system working as designed: the limiter is doing
        %       the regulating so the trip does not have to.
        %
        %     retry_count and lockout
        %       how many automatic recoveries have happened inside the retry
        %       window, and whether auto-recovery has been withdrawn. A retry
        %       count climbing is the signature of a fault that recovery does
        %       not fix.
        %
        %     uv_charge_Ah vs Q_uv_reset_Ah
        %       how much charge has gone back in since the under-voltage latch,
        %       against how much it needs before it will clear. This is the
        %       answer to "why is the load still off, the pack looks fine".
        %
        %   soc_raw_min is the unclamped minimum SOC the battery model reported.
        %   Negative means the pack model has been discharged past its rated
        %   capacity; alg/bcp_pack_monitor.m explains why it does not stop.
            n = {'demand_present', 'load_active', 'arb_reason', 'dch_ok', ...
                 'flag_OV', 'flag_UV', 'flag_OC_chg', 'flag_OC_dch', ...
                 'flag_OT', 'flag_UT_chg', ...
                 'dcl_frac', 'limit_state', ...
                 'retry_count', 'lockout', 'uv_charge_Ah', 'recover_dwell_s', ...
                 'soc_raw_min'};
        end

        function u = diagUnits()
            u = {'-','-','code','-', ...
                 '-','-','-','-','-','-', ...
                 '0..1','code', ...
                 'count','-','Ah','s', ...
                 '-'};
        end

        function s = arbReason(code)
        %ARBREASON  Decode the arbiter's reason code into words.
            switch round(code)
                case 0, s = 'charging enabled';
                case 1, s = 'load is active';
                case 2, s = 'waiting out the quiet dwell';
                case 3, s = 'pack full (SOC/voltage satisfied)';
                case 4, s = 'blocked by protection';
                case 5, s = 'charging disabled in configuration';
                otherwise, s = sprintf('unknown (%g)', code);
            end
        end

        function s = chargerMode(code)
        %CHARGERMODE  Decode the charger's mode output into words.
            switch round(code)
                case 0, s = 'OFF';
                case 1, s = 'PRECHARGE';
                case 2, s = 'CC';
                case 3, s = 'CV';
                case 4, s = 'DONE';
                otherwise, s = sprintf('unknown (%g)', code);
            end
        end

        function s = bmsState(code)
        %BMSSTATE  Decode the BMS state output into words.
        %
        %   4 and 5 are both "something is latched". The difference is whether
        %   the BMS is still willing to clear it by itself: LOCKOUT means the
        %   retry counter reached N_retry_max and auto-recovery has been
        %   withdrawn, so only a reset edge will clear anything.
            switch round(code)
                case 0, s = 'INIT';
                case 1, s = 'IDLE';
                case 2, s = 'CHARGE';
                case 3, s = 'DISCHARGE';
                case 4, s = 'FAULT';
                case 5, s = 'LOCKOUT';
                otherwise, s = sprintf('unknown (%g)', code);
            end
        end

        function s = limitState(code)
        %LIMITSTATE  Decode the load limiter's state into words.
            switch round(code)
                case 0, s = 'unlimited';
                case 1, s = 'voltage foldback';
                case 2, s = 'current foldback';
                case 3, s = 'soft-start ramp';
                case 4, s = 'held off by protection';
                otherwise, s = sprintf('unknown (%g)', code);
            end
        end

        function s = faultBits(mask)
        %FAULTBITS  Latched fault bitmask -> readable list.
        %
        %   THE FAULT OUTPUT IS A BITMASK AND SIMULTANEOUS FAULTS ADD
        %     This is why a run shows values that are not in any list of fault
        %     codes: 5 and 10 are not codes, they are sums.
        %
        %       5  = 4 + 1 = OC_charge    + OV
        %       10 = 8 + 2 = OC_discharge + UV
        %
        %     Seeing 4 for a moment and then 5 -- or 8 and then 10 -- is one
        %     physical event confirming twice at two different speeds. The
        %     over-current tier confirms in t_i_trip (0.1 s by default) and the
        %     voltage fault in t_v_trip (0.5 s), so the current bit lands first
        %     and the voltage bit joins it about 0.4 s later. Nothing has
        %     changed state in between; a second, slower confirmation finished.
        %
        %     On a discharge that reads: the over-draw was large enough to pull
        %     the pack out of its voltage window as well, which means the load
        %     was well past what the pack could deliver at that SOC.
        %
        %   See also bcp.Signals.faultTable.
            names = {'OV','UV','OC_charge','OC_discharge','OT','UT_charge'};
            m = uint32(round(mask));
            hit = {};
            for k = 1:6
                if bitand(m, uint32(2^(k-1))) ~= 0
                    hit{end+1} = names{k}; %#ok<AGROW>
                end
            end
            if isempty(hit)
                s = 'none';
            else
                s = strjoin(hit, ' + ');
            end
        end

        function T = faultTable(masks)
        %FAULTTABLE  Every fault mask a run is likely to show, decoded.
        %
        %   bcp.Signals.faultTable()            the common ones, with meanings
        %   bcp.Signals.faultTable([4 5 10])    decode specific values
        %
        %   Print this the first time a run reports a mask you do not recognise.
        %   There are 63 possible masks and no table lists them all; the point
        %   of this one is that the values people actually hit are combinations,
        %   and the combination is more informative than either bit alone.
            if nargin < 1 || isempty(masks)
                masks = [0 1 2 4 5 8 10 12 16 32];
                why = { ...
 'healthy'; ...
 'over-voltage alone: the charger pushed a cell past V_ov_trip. Charge inhibited, discharge left open -- the load is the cure.'; ...
 'under-voltage alone: a cell reached V_uv_trip and held for t_v_trip. Discharge inhibited, charge left open. Clearing it needs Q_uv_reset_Ah of charge, not a rest.'; ...
 'charge over-current alone: above I_chg_trip for t_i_cont, or above I_chg_peak for t_i_trip. Contactor OPEN -- over-current isolates the pack.'; ...
 '4+1. Charge over-current that also drove a cell over-voltage. The current bit confirms first (t_i_trip), the voltage bit joins it t_v_trip later. One event, two confirmations.'; ...
 'discharge over-current alone: the load exceeded a discharge tier for its dwell. Contactor OPEN.'; ...
 '8+2. Discharge over-current that also sagged a cell under-voltage -- the load was well past what the pack could deliver at that SOC. The most common non-obvious mask on a pulse test at low SOC.'; ...
 '4+8. Over-current confirmed in BOTH directions, which needs a sign flip or a wiring error rather than a load. Check I_sign against a known discharge.'; ...
 'over-temperature. Contactor OPEN. Only reachable with UseTemperature on and a real temperature signal wired in.'; ...
 'cold-charge inhibit: below T_ut_trip while charging. Charge inhibited, discharge left open.'};
            else
                masks = masks(:).';
                why = repmat({''}, numel(masks), 1);
            end
            bits = cell(numel(masks),1);
            for k = 1:numel(masks)
                bits{k} = bcp.Signals.faultBits(masks(k));
            end
            T = table(masks(:), bits, why, ...
                'VariableNames', {'faults','Bits','Meaning'});
            disp(T);
        end

        function s = unpack(v)
        %UNPACK  Measurement vector -> named struct, for scripts and plots.
            n = bcp.Signals.names();
            s = struct();
            for k = 1:bcp.Signals.NUM
                s.(n{k}) = v(k);
            end
        end

        function T = describe()
        %DESCRIBE  Print the wire contract. Run this when reading a scope trace.
            T = table((1:bcp.Signals.NUM)', bcp.Signals.names()', ...
                      bcp.Signals.units()', ...
                'VariableNames', {'Index','Signal','Unit'});
            disp(T);
        end
    end
end
