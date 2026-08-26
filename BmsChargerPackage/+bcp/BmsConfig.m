classdef BmsConfig
%BCP.BMSCONFIG  Everything the BMS block needs, and nothing the charger owns.
%
%   Every field here becomes a numeric literal inside the generated MATLAB
%   Function blocks. That is deliberate: the customisation point is this object
%   plus a rebuild, not hand-editing blocks in the model. Rebuilding is a
%   second or two.
%
%   SIGN CONVENTION: POSITIVE CURRENT = CHARGING, everywhere inside this
%   package. I_sign below is where your battery model's polarity is converted
%   to that convention, and it is the only place that conversion happens.

    properties
        % --- execution -------------------------------------------------------
        Ts double = 0.01    % BMS sample period [s] (100 Hz)
        %  Must divide the model's fixed step exactly -- bcp.Rate.audit checks
        %  this and tells you what to change. This is the single most common
        %  reason a working block fails to compile in someone else's model.

        BreakFeedbackLoops logical = true
        %  Insert a Unit Delay on every measurement input, inside the block.
        %
        %  LEAVE THIS ON. The BMS reads pack voltage and current and commands
        %  the load power that determines them, so the direct path closes an
        %  algebraic loop and Simulink either refuses to compile or solves it
        %  iteratively at every step. One sample of delay at the sensor is also
        %  the honest model: a real BMS acts on the previous conversion, not on
        %  the present instant. Turn it off only if you have put your own delay
        %  or rate transition outside the block.

        % --- pack topology (must match your battery model's arrays) ----------
        SeriesCount double = 14   % series cells (or modules) -- see bcp.PackSpec
        I_sign      double = -1   % +1, or -1 if your model reports discharge as positive
        SOC_in_percent logical = false  % true if the SOC array is 0..100

        % --- protection: voltage ---------------------------------------------
        V_ov_trip  double = 4.25   % per-cell over-voltage trip [V]
        %  ABOVE the cell's 4.20 V charge cutoff on purpose, and this is not a
        %  typo. A trip is a fault threshold, not an operating limit. Set it AT
        %  the CV target and every charge that succeeds trips protection at the
        %  moment it succeeds: the highest cell reaches 4.200 V, the trip fires,
        %  the contactor logic inhibits charging, and the run looks like a
        %  protection bug when it is a threshold that left no room. 50 mV of
        %  margin is the usual amount. bcp.Project.check() flags the mistake if
        %  you set them equal.

        V_ov_clear double = 4.10   % OV recovery threshold [V]
        V_uv_trip  double = 2.50   % per-cell under-voltage trip [V]
        V_uv_clear double = 2.80   % UV recovery threshold [V]
        t_v_trip   double = 0.50   % voltage fault confirmation time [s]

        % --- protection: current ---------------------------------------------
        I_chg_trip double = 25.0   % pack charge current limit [A]
        I_dch_trip double = 250.0  % pack discharge current limit, magnitude [A]
        t_i_trip   double = 0.10   % current fault confirmation time [s]

        % --- protection: temperature ------------------------------------------
        UseTemperature logical = false
        %  false wires an internal 25 degC constant instead of a T_cell input
        %  port. The OT/UT paths are then present and inert: correct, and
        %  visibly not doing anything, which is better than a stub that looks
        %  like a thermal model. Turn it on once your battery model exports
        %  temperature and the port appears.

        T_ot_trip  double = 60.0   % over-temperature trip [degC]
        T_ot_clear double = 50.0
        T_ut_trip  double = 0.0    % below this, charging is inhibited [degC]
        t_T_trip   double = 5.0    % thermal confirmation time [s]

        % --- fault handling ----------------------------------------------------
        AutoRecover logical = true % false = latch until the reset port is pulsed
        t_recover   double  = 2.0  % dwell inside the clear band before recovery [s]
        UseResetPort logical = false % add a reset inport (else an internal 0)

        % --- load / charge arbitration ------------------------------------------
        UseCharger logical = true
        %  false removes the P_chg and chg_done inports and wires internal
        %  zeros instead. Set it false for the first installation step: wire
        %  the BMS to your battery and your load, confirm the load waveform
        %  drives the pack the way you expect, and only then add the charger.
        %  Debugging one block is easier than debugging two.

        ChargeEnabled logical = true    % false = never charge, load only
        AllowConcurrent logical = false
        %  false is strict load priority: no charging while the load is active.
        %  true lets the charger run through the load, derated to
        %  I_chg_headroom_A. That changes what the pack experiences, so it is a
        %  different experiment rather than a refinement -- opt in knowingly.

        t_quiet_s double = 1.0     % load must be idle this long before charging
        SOC_stop    double = 0.95  % stop charging at this SOC [0..1]
        SOC_restart double = 0.85  % allow charging again below this SOC [0..1]
        V_recharge  double = 4.05  % or when the highest cell falls below this [V]
        I_chg_margin  double = 0.90 % command at most this fraction of I_chg_trip
        I_chg_headroom_A double = 5.0 % concurrent-charging ceiling [A]

        % --- outputs -------------------------------------------------------------
        LogSignals logical = true  % mark the block's outputs for signal logging
    end

    methods
        function obj = BmsConfig(varargin)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
            obj = obj.validate();
        end

        function obj = validate(obj)
            assert(obj.Ts > 0 && isfinite(obj.Ts), 'bcp:BmsConfig:Ts', ...
                'Ts must be positive and finite (got %g).', obj.Ts);
            assert(obj.SeriesCount >= 1 && mod(obj.SeriesCount,1) == 0, ...
                'bcp:BmsConfig:S', 'SeriesCount must be a positive integer.');
            assert(obj.I_sign == 1 || obj.I_sign == -1, 'bcp:BmsConfig:Isign', ...
                'I_sign must be +1 or -1.');

            assert(obj.V_ov_clear < obj.V_ov_trip, 'bcp:BmsConfig:Hyst', ...
                'V_ov_clear (%g) must be below V_ov_trip (%g) -- trip and clear must differ.', ...
                obj.V_ov_clear, obj.V_ov_trip);
            assert(obj.V_uv_clear > obj.V_uv_trip, 'bcp:BmsConfig:Hyst', ...
                'V_uv_clear (%g) must be above V_uv_trip (%g).', ...
                obj.V_uv_clear, obj.V_uv_trip);
            assert(obj.T_ot_clear < obj.T_ot_trip, 'bcp:BmsConfig:Hyst', ...
                'T_ot_clear must be below T_ot_trip.');
            assert(obj.I_chg_trip > 0 && obj.I_dch_trip > 0, 'bcp:BmsConfig:I', ...
                'Current trips must be positive magnitudes.');

            assert(obj.SOC_restart < obj.SOC_stop, 'bcp:BmsConfig:SOCHyst', ...
                ['SOC_restart (%g) must be below SOC_stop (%g). Equal values ', ...
                 'make the charger chatter on and off at the threshold.'], ...
                obj.SOC_restart, obj.SOC_stop);
            assert(obj.SOC_stop > 0 && obj.SOC_stop <= 1, 'bcp:BmsConfig:SOC', ...
                'SOC_stop must lie in (0,1].');
            assert(obj.SOC_restart >= 0, 'bcp:BmsConfig:SOC', ...
                'SOC_restart must be >= 0.');
            assert(obj.V_recharge < obj.V_ov_trip, 'bcp:BmsConfig:Recharge', ...
                ['V_recharge (%g) must be below V_ov_trip (%g), or the charger ', ...
                 're-arms into an over-voltage fault.'], obj.V_recharge, obj.V_ov_trip);
            assert(obj.t_quiet_s >= 0, 'bcp:BmsConfig:Quiet', ...
                't_quiet_s must be >= 0.');
            assert(obj.I_chg_margin > 0 && obj.I_chg_margin <= 1, ...
                'bcp:BmsConfig:Margin', 'I_chg_margin must lie in (0,1].');

            if ~obj.AutoRecover && ~obj.UseResetPort
                warning('bcp:BmsConfig:NoRecovery', ...
                    ['AutoRecover is off and there is no reset port, so the first ', ...
                     'latched fault ends the run. Set UseResetPort = true or ', ...
                     'AutoRecover = true.']);
            end
        end

        function obj = fromPack(obj, spec)
        %FROMPACK  Fill the topology- and cell-dependent fields from a pack spec.
        %
        %   The protection thresholds come straight off the cell datasheet, and
        %   the current trips are the datasheet limits with a little headroom.
        %   Everything to do with arbitration timing is left alone -- that is
        %   about your load, not about your cells.
            arguments
                obj
                spec (1,1) bcp.PackSpec
            end
            c = spec.Cell;
            obj.SeriesCount = spec.S;
            % 50 mV above the charge cutoff, and 50 mV below the discharge
            % cutoff. Trips bracket the operating window; they do not define
            % it. A trip set exactly at the cutoff fires on every successful
            % full charge and every legitimate full discharge.
            obj.V_ov_trip   = c.V_max + 0.05;
            obj.V_ov_clear  = c.V_max - 0.10;
            obj.V_uv_trip   = c.V_min - 0.05;
            obj.V_uv_clear  = c.V_min + 0.30;
            obj.V_recharge  = c.V_max - 0.15;
            % Trip 15% above the datasheet charge limit: the trip is a fault
            % threshold, not the operating limit, and it must sit clear of the
            % current the charger is entitled to command.
            obj.I_chg_trip  = round(spec.I_chg_max_A * 1.15, 1);
            obj.I_dch_trip  = round(spec.I_dch_A * 1.10, 0);
            obj = obj.validate();
        end

        function P = protectionParams(obj)
        %PROTECTIONPARAMS  Flatten to the struct bcp_protection expects.
            P = struct( ...
                'Ts',          obj.Ts, ...
                'V_ov_trip',   obj.V_ov_trip,  'V_ov_clear', obj.V_ov_clear, ...
                'V_uv_trip',   obj.V_uv_trip,  'V_uv_clear', obj.V_uv_clear, ...
                't_v_trip',    obj.t_v_trip, ...
                'I_chg_trip',  obj.I_chg_trip, 'I_dch_trip', obj.I_dch_trip, ...
                't_i_trip',    obj.t_i_trip, ...
                'T_ot_trip',   obj.T_ot_trip,  'T_ot_clear', obj.T_ot_clear, ...
                'T_ut_trip',   obj.T_ut_trip,  't_T_trip',   obj.t_T_trip, ...
                'AutoRecover', obj.AutoRecover, 't_recover',  obj.t_recover);
        end

        function P = arbiterParams(obj)
        %ARBITERPARAMS  Flatten to the struct bcp_arbiter expects.
            P = struct( ...
                'Ts',               obj.Ts, ...
                'ChargeEnabled',    obj.ChargeEnabled, ...
                'AllowConcurrent',  obj.AllowConcurrent, ...
                't_quiet_s',        obj.t_quiet_s, ...
                'SOC_stop',         obj.SOC_stop, ...
                'SOC_restart',      obj.SOC_restart, ...
                'V_recharge',       obj.V_recharge, ...
                'I_chg_trip',       obj.I_chg_trip, ...
                'I_chg_margin',     obj.I_chg_margin, ...
                'I_chg_headroom_A', obj.I_chg_headroom_A);
        end

        function P = monitorParams(obj)
        %MONITORPARAMS  Flatten to the struct bcp_pack_monitor expects.
            P = struct( ...
                'SeriesCount',    obj.SeriesCount, ...
                'I_sign',         obj.I_sign, ...
                'SOC_in_percent', obj.SOC_in_percent);
        end

        function report(obj)
            fprintf('BMS: Ts=%g s, %dS, protection OV %.2f V / UV %.2f V per cell\n', ...
                obj.Ts, obj.SeriesCount, obj.V_ov_trip, obj.V_uv_trip);
            fprintf('     current trips: charge %.1f A, discharge %.0f A\n', ...
                obj.I_chg_trip, obj.I_dch_trip);
            if obj.ChargeEnabled
                if obj.AllowConcurrent
                    pri = sprintf('concurrent, charge derated to %.1f A under load', ...
                        obj.I_chg_headroom_A);
                else
                    pri = sprintf('LOAD FIRST, charge only after %.2f s idle', ...
                        obj.t_quiet_s);
                end
                fprintf('     arbitration: %s\n', pri);
                fprintf('     charge window: SOC %.0f%% -> %.0f%%, re-arm below %.2f V/cell\n', ...
                    obj.SOC_restart*100, obj.SOC_stop*100, obj.V_recharge);
            else
                fprintf('     arbitration: charging DISABLED (load only)\n');
            end
            if ~obj.UseTemperature
                fprintf('     temperature: no input -- held at 25 degC, OT/UT wired but inert\n');
            end
        end
    end
end
