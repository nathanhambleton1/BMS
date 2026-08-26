classdef CellLibrary
%BCP.CELLLIBRARY  Datasheet parameters for the cells this package can auto-fill from.
%
%   The charger's "Auto-fill from pack" button reads one of these entries plus
%   your series/parallel counts and computes every charge parameter from them.
%   That is the whole point of this class: the numbers a charger needs are
%   already on the cell datasheet, and typing them into six fields by hand is
%   how a pack ends up being charged at 3C to 4.2 V per cell.
%
%   ACCURACY BOUNDARY -- READ THIS BEFORE QUOTING RESULTS
%     Capacity, cutoff voltages and the current limits below are datasheet
%     values and are as good as the datasheet. The resistance values are
%     datasheet impedance figures, which is NOT the quantity a pulse test
%     gives you: DC pulse resistance typically runs 30-50% above the 1 kHz AC
%     impedance. Nothing here is measured from your cells.
%
%     For charge-parameter auto-fill that hardly matters -- the thresholds and
%     currents come from the cutoffs and the capacity, which are solid. It
%     matters a great deal if you use R_dc to predict voltage sag under a pulse
%     load. Measure your own if that is the question you are asking.
%
%   ADDING A CELL
%     Copy a static method, change the numbers, add the display name to
%     names(). Nothing else needs to know about it.

    properties
        Name          char   = 'generic'
        Chemistry     char   = 'NMC'
        Q_Ah          double = 4.5     % nominal capacity [Ah]
        V_nom         double = 3.60    % nominal voltage [V]
        V_max         double = 4.20    % charge cutoff [V]
        V_min         double = 2.50    % discharge cutoff [V]
        R_dc_Ohm      double = 0.012   % DC internal resistance [Ohm] @25 degC
        I_chg_std_A   double = 4.35    % standard (datasheet) charge current [A]
        I_chg_max_A   double = 4.35    % maximum charge current [A]
        I_dch_cont_A  double = 45      % continuous discharge current [A]
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
                'Need I_chg_std_A > 0 and I_chg_max_A >= I_chg_std_A.');
            assert(obj.R_dc_Ohm > 0, 'bcp:CellLibrary:R', 'R_dc_Ohm must be positive.');
        end

        function c = C_rate_chg(obj)
        %C_RATE_CHG  Standard charge current expressed as a C-rate.
            c = obj.I_chg_std_A / obj.Q_Ah;
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
        %   Datasheet, 25 degC: 4.5 Ah nominal (4.4 Ah minimum), 3.6 V nominal,
        %   4.2 V / 2.5 V cutoffs, 4.35 A standard charge (~1C) CC-CV to 4.2 V,
        %   45 A continuous discharge, ~9 mOhm typical AC impedance at 1 kHz,
        %   ~16.2 Wh, ~70 g.
        %
        %   R_dc_Ohm below is a 12 mOhm DC pulse ESTIMATE -- not the 9 mOhm AC
        %   figure, and not measured from your cells.
            obj = bcp.CellLibrary( ...
                'Name','Molicel INR-21700-P45B', 'Chemistry','NMC', ...
                'Q_Ah',4.50, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.012, 'I_chg_std_A',4.35, 'I_chg_max_A',4.35, ...
                'I_dch_cont_A',45, 'Mass_kg',0.070, ...
                'Source','Molicel product data sheet, INR-21700-P45B');
            obj = obj.validate();
        end

        function obj = P50B()
        %P50B  Molicel INR-21700-P50B high-power NMC cell.
        %
        %   Datasheet v1.1, 25 degC: 5.00 Ah typical (4.85 Ah minimum), 3.6 V
        %   nominal, 18.0 Wh, 4.2 V / 2.5 V cutoffs, 5.0 A standard charge
        %   CC-CV to 4.2 V, 25 A maximum charge, 60 A continuous discharge,
        %   12.8 mOhm typical DC impedance at 50% SOC, 71 g maximum.
        %
        %   I_chg_max_A is deliberately the 5 A STANDARD charge, not the
        %   datasheet's 25 A maximum. That maximum is qualified by a 70 degC
        %   cutoff and this package has no thermal model to enforce it. Raise it
        %   only once a real temperature signal is wired into the BMS block.
            obj = bcp.CellLibrary( ...
                'Name','Molicel INR-21700-P50B', 'Chemistry','NMC', ...
                'Q_Ah',5.00, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.0128, 'I_chg_std_A',5.00, 'I_chg_max_A',5.00, ...
                'I_dch_cont_A',60, 'Mass_kg',0.071, ...
                'Source','Molicel product data sheet INR-21700-P50B v1.1');
            obj = obj.validate();
        end

        function obj = P42A()
        %P42A  Molicel INR-21700-P42A, for comparison against an older pack build.
            obj = bcp.CellLibrary( ...
                'Name','Molicel INR-21700-P42A', 'Chemistry','NMC', ...
                'Q_Ah',4.20, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.014, 'I_chg_std_A',4.20, 'I_chg_max_A',4.20, ...
                'I_dch_cont_A',45, 'Mass_kg',0.070, ...
                'Source','Molicel product data sheet, INR-21700-P42A');
            obj = obj.validate();
        end

        function obj = Generic21700()
        %GENERIC21700  Neutral starting point when the cell is not in the list.
            obj = bcp.CellLibrary( ...
                'Name','Generic 21700 NMC', 'Chemistry','NMC', ...
                'Q_Ah',4.00, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                'R_dc_Ohm',0.020, 'I_chg_std_A',4.00, 'I_chg_max_A',4.00, ...
                'I_dch_cont_A',30, 'Mass_kg',0.070, ...
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
                      [c.R_dc_Ohm]'*1000, [c.I_chg_std_A]', [c.I_dch_cont_A]', ...
                'VariableNames', {'Cell','Q_Ah','V_max','V_min', ...
                                  'R_dc_mOhm','I_chg_std_A','I_dch_A'});
        end
    end
end
