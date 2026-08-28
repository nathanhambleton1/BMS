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
%
%   THE BMS OWNS THE CHARGE RATE. THE CHARGER OBEYS IT.
%     I_chg_max_A is the one number that sets how fast this system charges. It
%     is published to the charger every sample on the I_chg_limit output, and
%     the charger takes min(its own supply rating, that limit) -- so there is
%     no second place to change and no way for the two to disagree.
%
%     The over-current trips are DERIVED from it (I_chg_trip and I_chg_peak_A,
%     via OC_trip_margin and OC_peak_margin), which is what makes raising the
%     charge rate a one-number edit that keeps protection intact rather than a
%     hunt through both blocks. Set the trips by hand afterwards if you want
%     them somewhere else; validate() only insists they stay above the rate the
%     BMS itself permits, because a trip below your own operating point is a
%     charge that faults out the moment it works.
%
%   OVER-CURRENT IS TWO TIERS, NOT ONE
%     A cell has two current ratings -- continuous and short-pulse -- and a
%     single trip cannot honour both. Set it at the continuous rating and every
%     pulse the pack was built to deliver trips protection; set it at the pulse
%     rating and a sustained over-draw runs forever. So:
%
%       I_dch_trip   confirmed over t_i_cont_s (default 10 s). The continuous
%                    rating. A 2 s pulse never accumulates enough dwell.
%       I_dch_peak_A confirmed over t_i_trip (default 0.1 s). The pulse rating.
%                    This is the one that catches a genuine fault.
%
%     Charge has the same two tiers for the same reason. This is how real
%     protection ICs stage over-current, and it is what removes the need to
%     disable the discharge trip to run a pulse test.

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
        I_sign      double = 1    % +1, or -1 if your model reports discharge as positive
        %  +1 is correct for Simscape Battery packs, including everything the
        %  Battery Model Builder generates: those components declare their cell
        %  current "positive in", which is positive while CHARGING, which is
        %  this package's convention already. Earlier versions of this file
        %  defaulted to -1 on the opposite belief, and the symptom was
        %  unmistakable -- the BMS read a large POSITIVE current during a
        %  discharge pulse, latched an over-current-CHARGE fault inside the
        %  confirmation window and opened the contactor part-way through the
        %  first pulse. Check it once against a known discharge (pack current
        %  must read negative) and then leave it alone.

        SOC_in_percent logical = false  % true if the SOC array is 0..100

        % --- protection: voltage ---------------------------------------------
        V_ov_trip  double = 4.25   % per-cell over-voltage trip [V]
        %  ABOVE the cell's 4.20 V charge cutoff on purpose, and this is not a
        %  typo. A trip is a fault threshold, not an operating limit. Set it AT
        %  the CV target and every charge that succeeds trips protection at the
        %  moment it succeeds: the highest cell reaches 4.200 V, the trip fires,
        %  charging is inhibited, and the run looks like a protection bug when
        %  it is a threshold that left no room. 4.25 V is also the conventional
        %  cell-level over-charge threshold for 4.2 V NMC. bcp.Project.check()
        %  flags the mistake if you set them equal.

        V_ov_clear double = 4.15   % OV recovery threshold [V]
        %  100 mV of hysteresis, the usual figure for a 4.25 V trip.

        V_uv_trip  double = 2.50   % per-cell under-voltage trip [V]
        %  AT the datasheet end-of-discharge voltage, not below it. The cutoff
        %  is already specified under load, so a trip beneath it is not margin,
        %  it is permission to over-discharge. What keeps a transient sag from
        %  firing it is t_v_trip, not a lower threshold.

        V_uv_clear double = 3.00   % UV recovery threshold [V]
        t_v_trip   double = 0.50   % voltage fault confirmation time [s]

        % --- protection: current ----------------------------------------------
        I_chg_max_A double = 4.35  % charge current the BMS PERMITS [A]
        %  THE CHARGE-RATE KNOB. Published to the charger on I_chg_limit every
        %  sample. Raise it to charge faster; the two trips below move with it
        %  when you go through setChargeLimit(), fromPack() or the UI.

        I_chg_trip   double = 5.44  % sustained charge over-current trip [A]
        I_chg_peak_A double = 6.96  % fast charge over-current trip [A]
        I_dch_trip   double = 248   % sustained discharge over-current trip [A]
        I_dch_peak_A double = 372   % fast discharge over-current trip [A]

        t_i_trip   double = 0.10   % fast-tier confirmation time [s]
        t_i_cont_s double = 10.0   % sustained-tier confirmation time [s]
        %  t_i_cont_s must be longer than the longest pulse you intend the pack
        %  to deliver, and shorter than the time an over-draw would do damage.
        %  Ten seconds suits a pulse test; shorten it for a pack whose load is
        %  meant to be continuous.

        OC_trip_margin double = 1.25  % sustained trip / permitted current
        OC_peak_margin double = 1.60  % fast trip / permitted current

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

            assert(obj.I_chg_max_A > 0, 'bcp:BmsConfig:I', ...
                'I_chg_max_A must be a positive current.');
            assert(obj.I_chg_trip > 0 && obj.I_dch_trip > 0, 'bcp:BmsConfig:I', ...
                'Current trips must be positive magnitudes.');
            assert(obj.I_chg_trip > obj.I_chg_max_A, 'bcp:BmsConfig:ChgTrip', ...
                ['The charge over-current trip (%.3f A) must sit ABOVE the charge ', ...
                 'current the BMS itself permits (%.3f A), or every charge faults ', ...
                 'out at the moment it reaches its setpoint. Use setChargeLimit ', ...
                 'to move both together.'], obj.I_chg_trip, obj.I_chg_max_A);
            assert(obj.I_chg_peak_A >= obj.I_chg_trip, 'bcp:BmsConfig:Tiers', ...
                ['The fast charge trip (%.3f A) must be at or above the sustained ', ...
                 'trip (%.3f A). The fast tier is the higher current confirmed ', ...
                 'over the shorter time.'], obj.I_chg_peak_A, obj.I_chg_trip);
            assert(obj.I_dch_peak_A >= obj.I_dch_trip, 'bcp:BmsConfig:Tiers', ...
                ['The fast discharge trip (%.1f A) must be at or above the ', ...
                 'sustained trip (%.1f A).'], obj.I_dch_peak_A, obj.I_dch_trip);
            assert(obj.t_i_cont_s >= obj.t_i_trip, 'bcp:BmsConfig:Dwell', ...
                ['t_i_cont_s (%g s) must be at least t_i_trip (%g s). The ', ...
                 'sustained tier is the lower current confirmed over the longer ', ...
                 'time; swapping them makes one tier unreachable.'], ...
                obj.t_i_cont_s, obj.t_i_trip);
            assert(obj.OC_trip_margin > 1 && obj.OC_peak_margin >= obj.OC_trip_margin, ...
                'bcp:BmsConfig:Margin', ...
                'Need OC_peak_margin >= OC_trip_margin > 1.');

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

            if ~obj.AutoRecover && ~obj.UseResetPort
                warning('bcp:BmsConfig:NoRecovery', ...
                    ['AutoRecover is off and there is no reset port, so the first ', ...
                     'latched fault ends the run. Set UseResetPort = true or ', ...
                     'AutoRecover = true.']);
            end
        end

        % -----------------------------------------------------------------
        function obj = setChargeLimit(obj, I_A)
        %SETCHARGELIMIT  Change the charge rate and move both trips with it.
        %
        %   b = b.setChargeLimit(13.5)
        %
        %   This is the whole charge-rate story on the BMS side. It sets the
        %   current the BMS permits and re-derives the sustained and fast
        %   over-current trips from OC_trip_margin and OC_peak_margin, so
        %   protection stays in the same relationship to the operating point
        %   instead of becoming a ceiling you have to remember to raise too.
            arguments
                obj
                I_A (1,1) double {mustBePositive}
            end
            obj.I_chg_max_A  = I_A;
            obj.I_chg_trip   = round(I_A * obj.OC_trip_margin, 3);
            obj.I_chg_peak_A = round(I_A * obj.OC_peak_margin, 3);
            obj = obj.validate();
        end

        % -----------------------------------------------------------------
        function obj = fromPack(obj, spec)
        %FROMPACK  Fill the topology- and cell-dependent fields from a pack spec.
        %
        %   Every protection threshold below comes off the cell datasheet.
        %   Nothing to do with arbitration timing is touched -- that is about
        %   your load, not about your cells.
            arguments
                obj
                spec (1,1) bcp.PackSpec
            end
            c = spec.Cell;
            obj.SeriesCount = spec.S;

            % --- voltage ------------------------------------------------------
            %  The over-voltage trip brackets the operating window from above;
            %  the under-voltage trip sits ON the datasheet end-of-discharge
            %  voltage, because that cutoff is already specified under load and
            %  anything below it is over-discharge. Recovery thresholds are the
            %  conventional ones for 4.2 V NMC: 4.15 V and 3.00 V.
            obj.V_ov_trip   = c.V_max + 0.05;
            obj.V_ov_clear  = c.V_max - 0.05;
            obj.V_uv_trip   = c.V_min;
            obj.V_uv_clear  = c.V_min + 0.50;
            obj.V_recharge  = c.V_max - 0.15;

            % --- charge current ------------------------------------------------
            %  The DEFAULT operating rate is the datasheet STANDARD charge, not
            %  the maximum: the maximum is qualified by a temperature cutoff
            %  this package cannot enforce until UseTemperature is on and a real
            %  temperature signal is wired in. Both trips follow from whatever
            %  rate you end up choosing, so raising the rate later is one call.
            obj = obj.setChargeLimit(round(spec.I_chg_std_A, 3));

            % --- discharge current ---------------------------------------------
            %  The load is not ours to limit, so both tiers come straight off
            %  the cell's two datasheet ratings with 10% of measurement margin.
            %  The sustained tier is the continuous rating and is confirmed over
            %  t_i_cont_s; the fast tier is the pulse rating over t_i_trip. That
            %  pairing is what lets a pack deliver the pulses it is rated for
            %  without its own protection stopping it -- which is exactly the
            %  case a single trip at 1.1x continuous gets wrong.
            obj.I_dch_trip   = round(spec.I_dch_A       * 1.10, 1);
            obj.I_dch_peak_A = round(spec.I_dch_pulse_A * 1.10, 1);

            % --- temperature ----------------------------------------------------
            %  Straight off the datasheet operating ranges. The cold-charge
            %  inhibit is the low end of the CHARGE range, which is the limit
            %  that matters: plating lithium at 0 degC is permanent, and most
            %  cells that will discharge at -40 degC will not accept charge
            %  below 0.
            obj.T_ot_trip   = c.T_dch_max_C;
            obj.T_ot_clear  = c.T_dch_max_C - 10;
            obj.T_ut_trip   = c.T_chg_min_C;

            obj = obj.validate();
        end

        function P = protectionParams(obj)
        %PROTECTIONPARAMS  Flatten to the struct bcp_protection expects.
            P = struct( ...
                'Ts',          obj.Ts, ...
                'V_ov_trip',   obj.V_ov_trip,  'V_ov_clear', obj.V_ov_clear, ...
                'V_uv_trip',   obj.V_uv_trip,  'V_uv_clear', obj.V_uv_clear, ...
                't_v_trip',    obj.t_v_trip, ...
                'I_chg_trip',  obj.I_chg_trip, 'I_chg_peak', obj.I_chg_peak_A, ...
                'I_dch_trip',  obj.I_dch_trip, 'I_dch_peak', obj.I_dch_peak_A, ...
                't_i_trip',    obj.t_i_trip,   't_i_cont',   obj.t_i_cont_s, ...
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
                'I_chg_max_A',      obj.I_chg_max_A, ...
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
            fprintf('     charge rate: %.2f A permitted (I_chg_limit to the charger)\n', ...
                obj.I_chg_max_A);
            fprintf('     charge trips:    %.2f A held %.1f s   |  %.2f A held %.2f s\n', ...
                obj.I_chg_trip, obj.t_i_cont_s, obj.I_chg_peak_A, obj.t_i_trip);
            fprintf('     discharge trips: %.1f A held %.1f s   |  %.1f A held %.2f s\n', ...
                obj.I_dch_trip, obj.t_i_cont_s, obj.I_dch_peak_A, obj.t_i_trip);
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
