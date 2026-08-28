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

        DIAG_NUM = 10   % elements in the BMS block's diag output
        %  The single definition of that width. The generated BMS_core
        %  preallocates diag to exactly this, and everything that unpacks it
        %  reads the number from here rather than writing 10 again -- because a
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
        %DIAGNAMES  What is in the BMS block's 10-element diag output.
        %
        %   demand_present vs load_active is the pair worth watching: the first
        %   is what the waveform asked for, the second is what survived the
        %   discharge inhibit. When they disagree, protection is holding the
        %   load off, and arb_reason says what the charger is doing about it.
            n = {'demand_present', 'load_active', 'arb_reason', 'dch_ok', ...
                 'flag_OV', 'flag_UV', 'flag_OC_chg', 'flag_OC_dch', ...
                 'flag_OT', 'flag_UT_chg'};
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
            switch round(code)
                case 0, s = 'INIT';
                case 1, s = 'IDLE';
                case 2, s = 'CHARGE';
                case 3, s = 'DISCHARGE';
                case 4, s = 'FAULT';
                otherwise, s = sprintf('unknown (%g)', code);
            end
        end

        function s = faultBits(mask)
        %FAULTBITS  Latched fault bitmask -> readable list.
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
