classdef PackSpec
%BCP.PACKSPEC  Cell choice plus series/parallel topology, and everything derivable from it.
%
%   This is the object the charger auto-fill reads. Set the cell and the two
%   counts; every pack-level quantity below is computed, never stored, so it
%   cannot drift out of step with the topology.
%
%       spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S', 14, 'P', 5);
%       disp(spec.summary());
%
%   WHAT S AND P MUST COUNT
%     S and P must describe the same thing your battery model's output arrays
%     describe. If the Battery Model Builder gave you one array entry per cell,
%     S and P are cell counts. If you built the pack from modules and the
%     arrays are per-module, S is the number of series MODULES and P the number
%     of parallel strings of modules -- and Cell should then hold the MODULE's
%     parameters, not a single cell's. bcp_pack_monitor divides by S to get pack
%     current, so an S that counts the wrong thing scales every current in the
%     BMS by a constant factor.
%
%     bcp.BmsBuilder checks the array width it is actually wired to against
%     S*P and S at build time and tells you which layout it found, so you do
%     not have to guess.

    properties
        Cell = bcp.CellLibrary.P45B()   % bcp.CellLibrary
        S    double = 14                % cells (or modules) in series
        P    double = 5                 % cells (or modules) in parallel
    end

    properties (Dependent)
        Q_Ah        % pack capacity [Ah]
        V_nom       % nominal pack voltage [V]
        V_max       % fully charged pack voltage [V]
        V_min       % fully discharged pack voltage [V]
        Wh          % nominal pack energy [Wh]
        R_dc_Ohm    % pack DC resistance [Ohm]
        I_chg_std_A % pack standard charge current [A]
        I_chg_max_A % pack maximum charge current [A]
        I_dch_A     % pack continuous discharge current [A]
        P_dch_W     % continuous discharge power at nominal voltage [W]
        NCells      % total cells (or modules)
    end

    methods
        function obj = PackSpec(varargin)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
            obj = obj.validate();
        end

        function obj = validate(obj)
            assert(obj.S >= 1 && mod(obj.S,1) == 0, 'bcp:PackSpec:S', ...
                'S must be a positive integer (got %g).', obj.S);
            assert(obj.P >= 1 && mod(obj.P,1) == 0, 'bcp:PackSpec:P', ...
                'P must be a positive integer (got %g).', obj.P);
            obj.Cell = obj.Cell.validate();
        end

        function v = get.Q_Ah(obj),        v = obj.Cell.Q_Ah * obj.P;          end
        function v = get.V_nom(obj),       v = obj.Cell.V_nom * obj.S;         end
        function v = get.V_max(obj),       v = obj.Cell.V_max * obj.S;         end
        function v = get.V_min(obj),       v = obj.Cell.V_min * obj.S;         end
        function v = get.Wh(obj),          v = obj.Q_Ah * obj.V_nom;           end
        function v = get.R_dc_Ohm(obj),    v = obj.Cell.R_dc_Ohm * obj.S / obj.P; end
        function v = get.I_chg_std_A(obj), v = obj.Cell.I_chg_std_A * obj.P;   end
        function v = get.I_chg_max_A(obj), v = obj.Cell.I_chg_max_A * obj.P;   end
        function v = get.I_dch_A(obj),     v = obj.Cell.I_dch_cont_A * obj.P;  end
        function v = get.P_dch_W(obj),     v = obj.I_dch_A * obj.V_nom;        end
        function v = get.NCells(obj),      v = obj.S * obj.P;                  end

        function s = summary(obj)
        %SUMMARY  One printable block of the pack numbers the charger needs.
            s = sprintf([ ...
                '%s  %dS%dP  (%d cells)\n' ...
                '  capacity      %.2f Ah    energy  %.0f Wh\n' ...
                '  voltage       %.2f V nominal,  %.2f V full,  %.2f V empty\n' ...
                '  DC resistance %.1f mOhm  (datasheet estimate, not measured)\n' ...
                '  charge        %.1f A standard (%.2fC),  %.1f A maximum\n' ...
                '  discharge     %.0f A continuous  (%.0f W at nominal)\n'], ...
                obj.Cell.Name, obj.S, obj.P, obj.NCells, ...
                obj.Q_Ah, obj.Wh, ...
                obj.V_nom, obj.V_max, obj.V_min, ...
                obj.R_dc_Ohm*1000, ...
                obj.I_chg_std_A, obj.Cell.C_rate_chg(), obj.I_chg_max_A, ...
                obj.I_dch_A, obj.P_dch_W);
        end

        function layout = classifyArray(obj, n)
        %CLASSIFYARRAY  Which array layout does a width of N correspond to?
        %
        %   Called by bcp.BmsBuilder once it knows how wide the signal it was
        %   wired to actually is. Returns 'per-cell', 'per-series' or
        %   'unknown'. 'unknown' is not fatal -- bcp_pack_monitor's mean()*S
        %   and sum()/S forms do not need to know -- but it does mean S is
        %   probably counting the wrong thing, so the caller warns.
            if n == obj.NCells && obj.P > 1
                layout = 'per-cell';
            elseif n == obj.S
                layout = 'per-series';
            elseif n == obj.NCells
                layout = 'per-cell';        % P == 1, the two coincide
            else
                layout = 'unknown';
            end
        end

        function report(obj)
            fprintf('%s', obj.summary());
        end
    end
end
