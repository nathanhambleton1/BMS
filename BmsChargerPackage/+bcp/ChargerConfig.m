classdef ChargerConfig
%BCP.CHARGERCONFIG  Charge parameters, normally produced by auto-fill rather than typed.
%
%   The intended way to populate this object is from the pack:
%
%       spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
%       chg  = bcp.ChargerConfig.fromPack(spec);           % 1C standard charge
%       chg  = bcp.ChargerConfig.fromPack(spec, 'C_rate', 0.5);   % gentler
%       chg.report()
%
%   Every number a CC-CV charger needs is already implied by the cell datasheet
%   and the series/parallel counts. Deriving them is reproducible; typing them
%   into eight fields is how a 14S pack ends up with a 4.2 V CV target.
%
%   CC AND CV ARE NOT MODES YOU SELECT
%     There is no mode switch. One PI loop runs against two voltage targets and
%     a current ceiling, and the mode output reports which of them is currently
%     binding: at the ceiling is CC, below it is CV. The handover is automatic
%     because it is not a decision -- it is which constraint is active. See
%     bcp_charger for why the termination test has to be dwell-confirmed.
%
%   SIGN CONVENTION: the charger only ever commands positive (charging)
%   current. It has no authority to discharge and no path to.

    properties
        % --- execution ---------------------------------------------------------
        Ts double = 0.01    % charger sample period [s]
        %  Usually the same as the BMS Ts. It does not have to be, but both must
        %  divide the model's fixed step -- run bcp.Rate.audit.

        BreakFeedbackLoops logical = true
        %  Unit Delay on every measurement input, inside the block. Same reason
        %  as bcp.BmsConfig.BreakFeedbackLoops: the charger reads the voltage
        %  its own current command produces, which is an algebraic loop.

        SeriesCount double = 14   % needed to convert the per-cell CV target

        % --- current -----------------------------------------------------------
        I_cc_A       double = 21.75  % constant-current setpoint [A]
        I_taper_A    double = 1.125  % terminate when the command tapers below this [A]
        I_precharge_A double = 2.25  % trickle for a deeply discharged pack [A]
        P_chg_max_W  double = 1300   % supply power ceiling [W]

        % --- voltage -----------------------------------------------------------
        V_cv_cell double = 4.20   % CV target for the HIGHEST cell [V]
        V_cv_pack double = 58.80  % CV target for the pack [V]
        %  The loop takes whichever of these binds first. On a pack with real
        %  cell spread they are different constraints, and the per-cell one is
        %  the one that protects cells.

        V_precharge_cell double = 3.00 % below this, trickle instead of full CC [V]
        V_recharge_cell  double = 4.05 % below this, a finished charge re-arms [V]

        % --- loop tuning --------------------------------------------------------
        Kp_cell double = 125    % [A/V] proportional gain, max-cell loop
        Ki_cell double = 250    % [A/(V s)] integral gain, max-cell loop
        Kp_pack double = 8.93   % [A/V] proportional gain, pack loop
        Ki_pack double = 17.86  % [A/(V s)] integral gain, pack loop

        % --- termination --------------------------------------------------------
        t_term_s double = 2.0   % taper must hold this long to terminate [s]

        % --- debugging ----------------------------------------------------------
        ForceMode double = 0
        %  0 automatic (use this). 2 pins the command to the current ceiling so
        %  you can watch an unregulated CC charge run into the BMS over-voltage
        %  trip -- useful exactly once, when you are checking the protection
        %  layer actually fires.

        LogSignals logical = true
    end

    properties (SetAccess = private)
        DerivedFrom char = ''    % how this object was filled, for the report
    end

    methods
        function obj = ChargerConfig(varargin)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
            obj = obj.validate();
        end

        function obj = validate(obj)
            assert(obj.Ts > 0 && isfinite(obj.Ts), 'bcp:ChargerConfig:Ts', ...
                'Ts must be positive and finite.');
            assert(obj.SeriesCount >= 1 && mod(obj.SeriesCount,1) == 0, ...
                'bcp:ChargerConfig:S', 'SeriesCount must be a positive integer.');
            assert(obj.I_cc_A > 0, 'bcp:ChargerConfig:Icc', ...
                'I_cc_A must be positive.');
            assert(obj.I_taper_A > 0 && obj.I_taper_A < obj.I_cc_A, ...
                'bcp:ChargerConfig:Itaper', ...
                ['I_taper_A (%g) must be positive and below I_cc_A (%g), or the ', ...
                 'charge terminates in its first sample.'], obj.I_taper_A, obj.I_cc_A);
            assert(obj.I_precharge_A > 0 && obj.I_precharge_A <= obj.I_cc_A, ...
                'bcp:ChargerConfig:Ipre', ...
                'I_precharge_A must be positive and no greater than I_cc_A.');
            assert(obj.V_cv_cell > obj.V_precharge_cell, 'bcp:ChargerConfig:V', ...
                'V_cv_cell must exceed V_precharge_cell.');
            assert(obj.V_recharge_cell < obj.V_cv_cell, 'bcp:ChargerConfig:Recharge', ...
                ['V_recharge_cell (%g) must be below V_cv_cell (%g), or a finished ', ...
                 'charge re-arms immediately and never reports done.'], ...
                obj.V_recharge_cell, obj.V_cv_cell);
            assert(obj.Kp_cell > 0 && obj.Kp_pack > 0, 'bcp:ChargerConfig:Gains', ...
                'Proportional gains must be positive.');
            assert(obj.Ki_cell >= 0 && obj.Ki_pack >= 0, 'bcp:ChargerConfig:Gains', ...
                'Integral gains must be >= 0.');
            assert(obj.t_term_s > obj.Ts, 'bcp:ChargerConfig:Term', ...
                ['t_term_s (%g) must exceed Ts (%g). A one-sample confirmation is ', ...
                 'no confirmation: it terminates on the CC-to-CV transient dip.'], ...
                obj.t_term_s, obj.Ts);
            assert(any(obj.ForceMode == [0 2]), 'bcp:ChargerConfig:ForceMode', ...
                'ForceMode must be 0 (automatic) or 2 (pin to CC).');

            % A pack CV target that is not S times the cell target means one of
            % the two loops can never bind, which makes half the controller dead
            % code and is nearly always a typo in one field or the other.
            expect = obj.V_cv_cell * obj.SeriesCount;
            if abs(obj.V_cv_pack - expect) > 0.05 * expect
                warning('bcp:ChargerConfig:CVMismatch', ...
                    ['V_cv_pack is %.2f V but %d cells at %.2f V is %.2f V. The ', ...
                     'lower target always binds, so the other loop is inert. ', ...
                     'Check SeriesCount, or re-run fromPack.'], ...
                    obj.V_cv_pack, obj.SeriesCount, obj.V_cv_cell, expect);
            end
        end

        function P = params(obj)
        %PARAMS  Flatten to the struct bcp_charger expects.
            P = struct( ...
                'Ts',               obj.Ts, ...
                'SeriesCount',      obj.SeriesCount, ...
                'I_cc_A',           obj.I_cc_A, ...
                'I_taper_A',        obj.I_taper_A, ...
                'I_precharge_A',    obj.I_precharge_A, ...
                'V_cv_cell',        obj.V_cv_cell, ...
                'V_cv_pack',        obj.V_cv_pack, ...
                'V_precharge_cell', obj.V_precharge_cell, ...
                'V_recharge_cell',  obj.V_recharge_cell, ...
                'Kp_cell',          obj.Kp_cell, ...
                'Ki_cell',          obj.Ki_cell, ...
                'Kp_pack',          obj.Kp_pack, ...
                'Ki_pack',          obj.Ki_pack, ...
                't_term_s',         obj.t_term_s, ...
                'ForceMode',        obj.ForceMode);
        end

        function t = estimatedChargeTime_h(obj, spec, socFrom, socTo)
        %ESTIMATEDCHARGETIME_H  Rough CC-phase duration, for sanity-checking StopTime.
        %
        %   CC phase only, ignoring the CV taper -- so it is an underestimate of
        %   a full charge by roughly 20-30%, and it says nothing about the time
        %   the load steals. It exists to catch the case where you have asked
        %   for a 4-hour charge inside a 60-second simulation.
            if nargin < 3, socFrom = 0.2; end
            if nargin < 4, socTo   = obj.usableSOCTarget(); end
            t = (socTo - socFrom) * spec.Q_Ah / obj.I_cc_A;
        end

        function s = usableSOCTarget(~)
            s = 0.95;
        end

        function report(obj)
            fprintf('Charger: Ts=%g s, %dS\n', obj.Ts, obj.SeriesCount);
            if ~isempty(obj.DerivedFrom)
                fprintf('     auto-filled from %s\n', obj.DerivedFrom);
            end
            fprintf('     CC  %.2f A   ->  CV %.3f V/cell (%.2f V pack)\n', ...
                obj.I_cc_A, obj.V_cv_cell, obj.V_cv_pack);
            fprintf('     terminate below %.2f A held for %.1f s;  re-arm below %.2f V/cell\n', ...
                obj.I_taper_A, obj.t_term_s, obj.V_recharge_cell);
            fprintf('     precharge %.2f A while any cell is under %.2f V\n', ...
                obj.I_precharge_A, obj.V_precharge_cell);
            fprintf('     gains: cell %.1f A/V + %.1f A/(V s),  pack %.2f A/V + %.2f A/(V s)\n', ...
                obj.Kp_cell, obj.Ki_cell, obj.Kp_pack, obj.Ki_pack);
            if obj.ForceMode ~= 0
                fprintf(2,'     ForceMode = %d -- the CV loop is bypassed. Debug only.\n', ...
                    obj.ForceMode);
            end
        end
    end

    methods (Static)
        function obj = fromPack(spec, varargin)
        %FROMPACK  Derive every charge parameter from the cell and the topology.
        %
        %   obj = bcp.ChargerConfig.fromPack(spec)
        %   obj = bcp.ChargerConfig.fromPack(spec, 'C_rate', 0.5, 'Ts', 0.005)
        %
        %   NAME-VALUE OPTIONS
        %     C_rate     charge current as a multiple of pack capacity. Default
        %                is the cell's own datasheet standard charge, which for
        %                the Molicel P-series is about 1C.
        %     Taper_C    termination current as a C-rate. Default C/20, the
        %                usual CC-CV termination criterion.
        %     Ts         sample period [s]. Default 0.01.
        %     Tau_cv_s   closed-loop time constant of the CV loop [s]. Default
        %                0.5. Raise it if the CV handover rings.
        %     Kp_frac    proportional gain as a fraction of 1/R. Default 0.3.
        %
        %   WHERE THE GAINS COME FROM
        %     The plant the CV loop sees is nearly resistive: pushing dI amps
        %     into the pack raises the terminal voltage by dI*R. So 1/R is the
        %     gain that would correct the whole error in one step, and any
        %     sensible proportional gain is a fraction of it. Kp_frac = 0.3
        %     leaves plenty of margin for the fact that R is a datasheet
        %     estimate and the real cell has RC dynamics this ignores.
        %
        %     The cell loop uses R_cell/P (what one series level sees per pack
        %     amp) and the pack loop uses R_cell*S/P. Those differ by exactly S,
        %     which is why the two loops reach their targets together instead of
        %     fighting.
        %
        %   WHAT THIS DOES NOT KNOW
        %     Temperature. Molicel's high maximum charge currents are qualified
        %     by a cell-temperature cutoff, and this package has no thermal
        %     model, so the default is the STANDARD charge current, never the
        %     maximum. Ask for a higher C_rate explicitly if you mean it.
            arguments
                spec (1,1) bcp.PackSpec
            end
            arguments (Repeating)
                varargin
            end
            opt = struct('C_rate',[], 'Taper_C',1/20, 'Ts',0.01, ...
                         'Tau_cv_s',0.5, 'Kp_frac',0.3);
            for k = 1:2:numel(varargin)
                assert(isfield(opt, varargin{k}), 'bcp:ChargerConfig:Option', ...
                    'Unknown option "%s". Valid: %s.', varargin{k}, ...
                    strjoin(fieldnames(opt)', ', '));
                opt.(varargin{k}) = varargin{k+1};
            end

            c = spec.Cell;

            % --- current ---------------------------------------------------
            if isempty(opt.C_rate)
                I_cc  = spec.I_chg_std_A;
                howI  = sprintf('%.1f A datasheet standard charge (%.2fC)', ...
                                I_cc, c.C_rate_chg());
            else
                I_cc  = opt.C_rate * spec.Q_Ah;
                howI  = sprintf('%.2fC = %.1f A', opt.C_rate, I_cc);
                if I_cc > spec.I_chg_max_A + 1e-9
                    warning('bcp:ChargerConfig:OverCRate', ...
                        ['%.2fC is %.1f A, above this pack''s %.1f A datasheet ', ...
                         'maximum charge current. Clamping to the maximum. The ', ...
                         'datasheet maximum is also usually qualified by a ', ...
                         'temperature cutoff this package cannot enforce.'], ...
                        opt.C_rate, I_cc, spec.I_chg_max_A);
                    I_cc = spec.I_chg_max_A;
                end
            end

            I_taper = opt.Taper_C * spec.Q_Ah;
            I_pre   = min(0.10 * spec.Q_Ah, I_cc);

            % --- gains: the plant is R, so the gain is a fraction of 1/R ----
            R_cellLevel = c.R_dc_Ohm / spec.P;      % Ohm per pack amp, one series level
            R_pack      = spec.R_dc_Ohm;            % Ohm per pack amp, whole pack
            Kp_cell = opt.Kp_frac / R_cellLevel;
            Kp_pack = opt.Kp_frac / R_pack;

            obj = bcp.ChargerConfig( ...
                'Ts',               opt.Ts, ...
                'SeriesCount',      spec.S, ...
                'I_cc_A',           I_cc, ...
                'I_taper_A',        I_taper, ...
                'I_precharge_A',    I_pre, ...
                'P_chg_max_W',      I_cc * spec.V_max, ...
                'V_cv_cell',        c.V_max, ...
                'V_cv_pack',        spec.V_max, ...
                'V_precharge_cell', max(3.00, c.V_min + 0.5), ...
                'V_recharge_cell',  c.V_max - 0.15, ...
                'Kp_cell',          Kp_cell, ...
                'Ki_cell',          Kp_cell / opt.Tau_cv_s, ...
                'Kp_pack',          Kp_pack, ...
                'Ki_pack',          Kp_pack / opt.Tau_cv_s, ...
                't_term_s',         max(2.0, 20*opt.Ts));

            obj.DerivedFrom = sprintf('%s %dS%dP: %s, taper C/%.0f, R=%.1f mOhm', ...
                c.Name, spec.S, spec.P, howI, 1/opt.Taper_C, R_pack*1000);
        end
    end
end
