classdef CellLibrary
%BCP.CELLLIBRARY  Datasheet parameters for the cells this package can auto-fill from.
%
%   The charger's "Auto-fill from pack" button and every BMS protection
%   threshold are computed from one of these entries plus your series/parallel
%   counts. That is the whole point of this class: the numbers a charger and a
%   protection layer need are already on the cell datasheet, and typing them
%   into a dozen fields by hand is how a pack ends up being charged at 3C to
%   4.2 V per cell, or tripping on every pulse it was built to deliver.
%
%   THE FOUR CURRENT RATINGS ARE FOUR DIFFERENT NUMBERS
%     Conflating them is the commonest source of a protection layer that is
%     wrong in both directions at once, so they are separate fields:
%
%       I_chg_std_A    the STANDARD charge current. What the datasheet's
%                      capacity, cycle-life and charge-time figures were all
%                      measured at. This is the operating default.
%       I_chg_max_A    the MAXIMUM charge current the cell will accept. Always
%                      qualified by a temperature cutoff on the datasheet. It
%                      is the ceiling you may raise the charge rate to, not a
%                      rate to use blindly.
%       I_dch_cont_A   maximum CONTINUOUS discharge current.
%       I_dch_pulse_A  short-pulse (order 10 s) discharge capability. Higher
%                      than continuous, and the reason a protection layer needs
%                      two over-current tiers rather than one -- see
%                      bcp.BmsConfig.
%
%     Earlier versions of this file set I_chg_max_A equal to I_chg_std_A "to be
%     safe". That is not conservatism, it is a wrong number: it made the
%     charge-current trip 3x too low on a P45B and 5x too low on a P50B, so the
%     BMS refused charge rates the cell is rated for and the only way to charge
%     faster was to hand-edit generated block code.
%
%   ACCURACY BOUNDARY -- READ THIS BEFORE QUOTING RESULTS
%     Capacity, cutoff voltages, the current limits and the temperature ranges
%     below are datasheet values and are as good as the datasheet. Every field
%     the datasheet does not state is marked in that cell's help text as an
%     ESTIMATE, with how it was arrived at. Nothing here is measured from your
%     cells.
%
%     R_dc_Ohm in particular is a DC pulse resistance, which is NOT the 1 kHz
%     AC impedance most datasheets lead with -- DC typically runs 30-100% above
%     AC. It sets only the charger's loop gains (Kp = Kp_frac/R) and the
%     predicted sag in the UI's derived lines. It enters no protection
%     threshold. Measure your own if voltage sag under a pulse load is the
%     question you are asking; bcp.CellTables reads the real SOC-dependent
%     curve out of a generated Simscape pack.
%
%   ADDING A CELL
%     Copy a static method, change the numbers, add the display name to
%     names(). Nothing else needs to know about it.

    properties
        Name          char   = 'generic'
        Chemistry     char   = 'NMC'
        Q_Ah          double = 4.5     % nominal capacity [Ah]
        V_nom         double = 3.60    % nominal voltage [V]
        V_max         double = 4.20    % charge cutoff (end of charge) [V]
        V_min         double = 2.50    % discharge cutoff (end of discharge) [V]
        R_dc_Ohm      double = 0.015   % DC pulse resistance [Ohm] @ 50% SOC, 25 degC

        % --- current ratings, all four of them --------------------------------
        I_chg_std_A   double = 4.35    % standard charge current [A]
        I_chg_max_A   double = 13.50   % maximum charge current [A], datasheet
        I_term_A      double = 0.225   % charge termination current [A]
        I_dch_cont_A  double = 45      % maximum continuous discharge current [A]
        I_dch_pulse_A double = 67.5    % ~10 s pulse discharge capability [A]

        % --- temperature limits, from the datasheet's operating ranges ---------
        T_chg_min_C   double = 0       % below this, do not charge [degC]
        T_chg_max_C   double = 60      % above this, do not charge [degC]
        T_dch_min_C   double = -40     % below this, do not discharge [degC]
        T_dch_max_C   double = 60      % above this, do not discharge [degC]

        Mass_kg       double = 0.070
        Source        char   = ''
    end

    methods
        function obj = CellLibrary(varargin)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
        end

        function obj = validate(obj)
            assert(obj.Q_Ah > 0, 'bcp:CellLibrary:Q', 'Q_Ah must be positive.');
            assert(obj.V_max > obj.V_min, 'bcp:CellLibrary:V', ...
                'V_max must exceed V_min.');
            assert(obj.I_chg_std_A > 0 && obj.I_chg_max_A >= obj.I_chg_std_A, ...
                'bcp:CellLibrary:I', ...
                ['Need I_chg_std_A > 0 and I_chg_max_A >= I_chg_std_A. These are ', ...
                 'two different datasheet numbers: the standard charge current ', ...
                 'and the maximum the cell will accept.']);
            assert(obj.I_dch_cont_A > 0 && obj.I_dch_pulse_A >= obj.I_dch_cont_A, ...
                'bcp:CellLibrary:Idch', ...
                ['Need I_dch_cont_A > 0 and I_dch_pulse_A >= I_dch_cont_A. A pulse ', ...
                 'rating below the continuous rating is a transcription error.']);
            assert(obj.I_term_A > 0 && obj.I_term_A < obj.I_chg_std_A, ...
                'bcp:CellLibrary:Iterm', ...
                'I_term_A must be positive and well below the standard charge current.');
            assert(obj.R_dc_Ohm > 0, 'bcp:CellLibrary:R', 'R_dc_Ohm must be positive.');
            assert(obj.T_chg_max_C > obj.T_chg_min_C && ...
                   obj.T_dch_max_C > obj.T_dch_min_C, 'bcp:CellLibrary:T', ...
                'Temperature ranges must be non-empty intervals.');
        end

        function c = C_rate_chg(obj)
        %C_RATE_CHG  Standard charge current expressed as a C-rate.
            c = obj.I_chg_std_A / obj.Q_Ah;
        end

        function c = C_rate_chg_max(obj)
        %C_RATE_CHG_MAX  Maximum charge current expressed as a C-rate.
            c = obj.I_chg_max_A / obj.Q_Ah;
        end
    end

    methods (Static)

        function n = names()
        %NAMES  Display names, in the order the UI dropdown shows them.
            n = {'Molicel INR-21700-P45B', ...
                 'Molicel INR-21700-P50B', ...
                 'Molicel INR-21700-P42A', ...
                 'Generic 21700 NMC', ...
                 'Custom'};
        end

        function obj = byName(name)
        %BYNAME  Look up a preset by its display name.
            switch char(name)
                case 'Molicel INR-21700-P45B', obj = bcp.CellLibrary.P45B();
                case 'Molicel INR-21700-P50B', obj = bcp.CellLibrary.P50B();
                case 'Molicel INR-21700-P42A', obj = bcp.CellLibrary.P42A();
                case 'Generic 21700 NMC',      obj = bcp.CellLibrary.Generic21700();
                case 'Custom',                 obj = bcp.CellLibrary();
                otherwise
                    error('bcp:CellLibrary:Unknown', ...
                        'Unknown cell "%s". Known cells:\n  %s', ...
                        char(name), strjoin(bcp.CellLibrary.names(), sprintf('\n  ')));
            end
        end

        function obj = P45B()
        %P45B  Molicel INR-21700-P45B high-power NMC cell.
        %
        %   DATASHEET (Molicel INR-21700-P45B product data sheet, doc 80109, and
        %   the Molicel product page)
        %     4.5 Ah typical, 16.2 Wh, 3.6 V nominal, 4.20 V end of charge,
        %     2.50 V end of discharge, 4.35 A standard charge CC-CV to 4.2 V,
        %     13.5 A (3C) maximum charge current, 45 A maximum continuous
        %     discharge with a 45 degC cutoff, charge 0..60 degC, discharge
        %     -40..60 degC, 69-70 g, typical impedance 7 mOhm AC at 30% SOC and
        %     15 mOhm DC at 50% SOC.
        %
        %   ESTIMATES, NOT DATASHEET
        %     I_dch_pulse_A  Molicel publishes no pulse discharge rating for
        %                    this cell, only 10 s power figures -- 184 W at 90%
        %                    SOC and 168 W at 50% -- which work out around 47 A.
        %                    1.5x continuous is used here as a conventional
        %                    short-pulse allowance, and it is the number the
        %                    fast over-current tier is built on. Lower it if
        %                    your duty cycle is not short.
        %     I_term_A       C/20, the usual CC-CV termination criterion. The
        %                    datasheet does not state one.
        %     R_dc_Ohm       the 15 mOhm datasheet DC figure at 50% SOC. The
        %                    Simscape pack generated by Battery Model Builder
        %                    runs nearer 10 mOhm mid-SOC; use bcp.CellTables to
        %                    work from that curve instead of this scalar.
            obj = bcp.CellLibrary( ...
                'Name','Molicel INR-21700-P45B', 'Chemistry','NMC', ...
                'Q_Ah',4.50, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.015, ...
                'I_chg_std_A',4.35, 'I_chg_max_A',13.50, 'I_term_A',4.50/20, ...
                'I_dch_cont_A',45, 'I_dch_pulse_A',67.5, ...
                'T_chg_min_C',0, 'T_chg_max_C',60, ...
                'T_dch_min_C',-40, 'T_dch_max_C',60, ...
                'Mass_kg',0.070, ...
                'Source','Molicel product data sheet, INR-21700-P45B (80109)');
            obj = obj.validate();
        end

        function obj = P50B()
        %P50B  Molicel INR-21700-P50B high-power NMC cell.
        %
        %   DATASHEET (Molicel INR-21700-P50B product data sheet v1.1, doc
        %   80122, and the Molicel product page)
        %     5.00 Ah typical (4.85 Ah minimum), 18.0 Wh, 3.6 V nominal,
        %     4.20 V end of charge, 2.50 V end of discharge, 5.0 A standard
        %     charge, 25 A (5C) maximum charge with a 70 degC cutoff, 60 A
        %     maximum continuous discharge with an 80 degC cutoff, 75 A
        %     short-term peak discharge, 12.8 mOhm DC impedance, 71 g maximum.
        %
        %   THE 25 A MAXIMUM CHARGE IS REAL BUT CONDITIONAL
        %     It is qualified by a cell-temperature cutoff this package cannot
        %     enforce without a temperature signal wired into the BMS block. It
        %     is recorded here because it is the datasheet number and every
        %     protection trip is derived from the rate you actually configure --
        %     but the DEFAULT charge current stays at the 5 A standard charge.
        %     Raise it deliberately, and turn on bcp.BmsConfig.UseTemperature
        %     before you go far above 1C.
        %
        %   ESTIMATES, NOT DATASHEET
        %     I_term_A  C/20.
            obj = bcp.CellLibrary( ...
                'Name','Molicel INR-21700-P50B', 'Chemistry','NMC', ...
                'Q_Ah',5.00, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.0128, ...
                'I_chg_std_A',5.00, 'I_chg_max_A',25.0, 'I_term_A',5.00/20, ...
                'I_dch_cont_A',60, 'I_dch_pulse_A',75, ...
                'T_chg_min_C',0, 'T_chg_max_C',60, ...
                'T_dch_min_C',-40, 'T_dch_max_C',60, ...
                'Mass_kg',0.071, ...
                'Source','Molicel product data sheet INR-21700-P50B v1.1 (80122)');
            obj = obj.validate();
        end

        function obj = P42A()
        %P42A  Molicel INR-21700-P42A, for comparison against an older pack build.
        %
        %   DATASHEET (Molicel INR-21700-P42A product data sheet, doc 80092)
        %     4.20 Ah nominal (4.00 Ah minimum), 3.6 V nominal, 4.20 +/- 0.05 V
        %     end of charge, 2.50 V end of discharge, 4.2 A standard charge,
        %     8.4 A (2C) maximum charge, 50 mA charge termination current, 45 A
        %     continuous discharge, AC impedance < 15 mOhm at 1 kHz, charge
        %     0..60 degC, discharge -40..60 degC, 70 g maximum.
        %
        %   ESTIMATES, NOT DATASHEET
        %     R_dc_Ohm       18 mOhm. The datasheet gives only the < 15 mOhm AC
        %                    figure, and DC pulse resistance on this cell runs
        %                    above it.
        %     I_dch_pulse_A  1.5x continuous, as for the P45B and for the same
        %                    reason: no published pulse rating.
            obj = bcp.CellLibrary( ...
                'Name','Molicel INR-21700-P42A', 'Chemistry','NMC', ...
                'Q_Ah',4.20, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.018, ...
                'I_chg_std_A',4.20, 'I_chg_max_A',8.40, 'I_term_A',0.050, ...
                'I_dch_cont_A',45, 'I_dch_pulse_A',67.5, ...
                'T_chg_min_C',0, 'T_chg_max_C',60, ...
                'T_dch_min_C',-40, 'T_dch_max_C',60, ...
                'Mass_kg',0.070, ...
                'Source','Molicel product data sheet, INR-21700-P42A (80092)');
            obj = obj.validate();
        end

        function obj = Generic21700()
        %GENERIC21700  Neutral starting point when the cell is not in the list.
        %
        %   Nothing here is a datasheet value. It is a deliberately unambitious
        %   21700 NMC: 1C standard charge, 1.5C maximum charge, 7.5C continuous
        %   discharge. Replace every number before quoting a result.
            obj = bcp.CellLibrary( ...
                'Name','Generic 21700 NMC', 'Chemistry','NMC', ...
                'Q_Ah',4.00, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.020, ...
                'I_chg_std_A',4.00, 'I_chg_max_A',6.00, 'I_term_A',0.200, ...
                'I_dch_cont_A',30, 'I_dch_pulse_A',45, ...
                'T_chg_min_C',0, 'T_chg_max_C',45, ...
                'T_dch_min_C',-20, 'T_dch_max_C',60, ...
                'Mass_kg',0.070, ...
                'Source','placeholder -- replace with your own datasheet values');
            obj = obj.validate();
        end

        function T = table()
        %TABLE  Side-by-side comparison of every preset.
            n = bcp.CellLibrary.names();
            n = n(1:end-1);                 % drop 'Custom'
            rows = cell(1, numel(n));
            for k = 1:numel(n)
                rows{k} = bcp.CellLibrary.byName(n{k});
            end
            c = [rows{:}];
            T = table({c.Name}', [c.Q_Ah]', [c.V_max]', [c.V_min]', ...
                      [c.R_dc_Ohm]'*1000, [c.I_chg_std_A]', [c.I_chg_max_A]', ...
                      [c.I_dch_cont_A]', [c.I_dch_pulse_A]', ...
                'VariableNames', {'Cell','Q_Ah','V_max','V_min', ...
                                  'R_dc_mOhm','I_chg_std_A','I_chg_max_A', ...
                                  'I_dch_cont_A','I_dch_pulse_A'});
        end
    end
end
