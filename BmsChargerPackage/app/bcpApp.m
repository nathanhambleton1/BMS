classdef bcpApp < handle
%BCPAPP  The UI for the BMS and charger blocks.
%
%       bcpApp
%
%   Five tabs, in the order you would fill them in:
%
%     Pack     which cell, how many in series and parallel. Everything else can
%              be derived from this, so it comes first.
%     Load     the dynamic-load waveform -- off, constant, sine or pulse -- with
%              a live preview that shades the windows where the charger will be
%              locked out. Those unshaded gaps are where charging can happen.
%     BMS      protection thresholds, the execution rate, and the rule that
%              arbitrates between the load and the charger.
%     Charger  CC/CV parameters, normally produced by Auto-fill rather than
%              typed. CC and CV are not modes you pick -- see the tab.
%     Install  put the blocks into your model, check the sample times, check the
%              wiring, or prove it all on a throwaway harness first.
%
%   This window is a view over bcp.Project. Every control writes to that object
%   and nothing else, so a UI run and a scripted run cannot produce different
%   models -- and any configuration built here can be saved, reloaded and
%   rebuilt from a script months later.
%
%   Validation is live, and a rejected value is REVERTED rather than left on
%   screen. A window that disagrees with the object is worse than an error,
%   because the next Insert builds whichever one you were not looking at. The
%   real reason appears in the log at the bottom.

    properties
        Proj = bcp.Project()
    end

    properties (Access = private)
        Fig
        Tabs
        LogBox
        Ctl     struct = struct()   % named one-off controls
        Bound   struct = struct('h',{},'path',{})   % control <-> property binding
        WavePanels struct = struct()
        PreviewAxes
        Harness
        Painting logical = false    % suppress callbacks while repainting
    end

    % =====================================================================
    methods
        function obj = bcpApp()
            obj.build();
            obj.refreshAll();
            obj.log('Ready. Start on the Pack tab -- everything else can be derived from it.');
            obj.log('Never installed these blocks before? Install tab, "Build test harness".');
        end

        function delete(obj)
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                delete(obj.Fig);
            end
        end
    end

    % =====================================================================
    methods (Hidden)   % inspection surface, used by tBcpApp
        function T = bindings(obj)
        %BINDINGS  Every bound control: its property path, the value the object
        %   holds, and the value the control is showing.
        %
        %   These last two must always be equal. When they are not, the window
        %   and the object disagree and the next Insert builds whichever one you
        %   were not looking at -- so it is worth being able to assert on it
        %   rather than trusting that the repaint covered every control.
            n = numel(obj.Bound);
            path = cell(n,1); inObject = zeros(n,1); onScreen = zeros(n,1);
            for k = 1:n
                path{k}     = obj.Bound(k).path;
                inObject(k) = double(obj.getProp(obj.Bound(k).path));
                onScreen(k) = double(obj.Bound(k).h.Value);
            end
            T = table(path, inObject, onScreen, ...
                'VariableNames', {'Path','InObject','OnScreen'});
        end

        function ok = poke(obj, path, value)
        %POKE  Change a field exactly as editing its control would, including
        %   the validate-and-revert and the full repaint.
            ok = obj.trySetProp(path, value);
            obj.refreshAll();
        end

        function setWaveform(obj, w)
        %SETWAVEFORM  Drive the waveform selector as the dropdown would.
            obj.onWaveform(w);
        end

        function names = visibleWavePanels(obj)
            names = {};
            f = fieldnames(obj.WavePanels);
            for k = 1:numel(f)
                if strcmp(obj.WavePanels.(f{k}).Visible, 'on')
                    names{end+1} = f{k}; %#ok<AGROW>
                end
            end
        end
    end

    % =====================================================================
    methods (Access = private)

        function build(obj)
            obj.Fig = uifigure('Name', ...
                'BMS and charger for a Simulink battery model', ...
                'Position',[80 50 1240 900]);
            g = uigridlayout(obj.Fig, [3 1]);
            g.RowHeight = {38, '1x', 160};

            obj.buildToolbar(g);
            obj.Tabs = uitabgroup(g);
            obj.buildPackTab();
            obj.buildLoadTab();
            obj.buildBmsTab();
            obj.buildChargerTab();
            obj.buildInstallTab();

            obj.LogBox = uitextarea(g, 'Editable','off', ...
                'FontName','Consolas', 'Value',{''});
        end

        % -----------------------------------------------------------------
        function buildToolbar(obj, parent)
            p = uigridlayout(parent, [1 6]);
            p.ColumnWidth = {'1x', 120, 110, 100, 90, 90};
            p.Padding = [6 2 6 2];

            obj.Ctl.PackSummary = uilabel(p, 'Text','', 'FontWeight','bold');

            uibutton(p, 'Text','Auto-fill all', ...
                'Tooltip',['Re-derive the BMS thresholds and every charge ' ...
                           'parameter from the Pack tab. Overwrites both.'], ...
                'ButtonPushedFcn', @(~,~) obj.onAutofillAll());
            uibutton(p, 'Text','Check config', ...
                'Tooltip','Cross-check every tab against every other tab.', ...
                'ButtonPushedFcn', @(~,~) obj.onCheck());
            uibutton(p, 'Text','Report', ...
                'Tooltip','Print the whole configuration to the command window.', ...
                'ButtonPushedFcn', @(~,~) obj.Proj.report());
            uibutton(p, 'Text','Save', ...
                'ButtonPushedFcn', @(~,~) obj.onSave());
            uibutton(p, 'Text','Load', ...
                'ButtonPushedFcn', @(~,~) obj.onLoad());
        end

        % =================================================================
        function buildPackTab(obj)
            t = uitab(obj.Tabs, 'Title','Pack');
            g = uigridlayout(t, [7 1]);
            g.RowHeight = {'fit','fit','fit','fit','fit','fit','1x'};

            obj.note(g, ['The cell and the two counts. Every pack number below ' ...
                'is derived from them, and the charger''s Auto-fill reads those ' ...
                'derived numbers -- so this is the tab where a wrong series count ' ...
                'becomes a wrong CV target.']);

            % --- cell -----------------------------------------------------
            c = uigridlayout(g, [1 3]);
            c.ColumnWidth = {220, 240, '1x'};
            c.RowHeight = {26};
            uilabel(c, 'Text','Cell');
            obj.Ctl.CellName = uidropdown(c, 'Items', bcp.CellLibrary.names(), ...
                'Value', obj.Proj.Pack.Cell.Name, ...
                'ValueChangedFcn', @(s,~) obj.onCellChanged(s.Value));
            obj.Ctl.CellSource = uilabel(c, 'Text','', 'FontAngle','italic');

            % --- topology -------------------------------------------------
            f = obj.fieldGrid(g, 2);
            obj.numField(f, 'Series count  S', 'Pack.S', '', ...
                ['Cells (or modules) in series. Sets the pack voltage, and ' ...
                 'through it the CV target. It must count the same thing your ' ...
                 'battery model''s output arrays count -- if those arrays are ' ...
                 'per-module, put module counts here and the module''s parameters ' ...
                 'in the cell fields. "Verify wiring" on the Install tab tells ' ...
                 'you which layout your model actually produces.']);
            obj.numField(f, 'Parallel count  P', 'Pack.P', '', ...
                'Cells (or modules) in parallel. Sets the capacity and every current limit.');

            obj.note(g, 'Derived', true);

            d = uigridlayout(g, [6 2]);
            d.ColumnWidth = {200, '1x'};
            d.RowHeight = repmat({24}, 1, 6);
            obj.roRow(d, 'PackQ',    'Capacity');
            obj.roRow(d, 'PackV',    'Voltage');
            obj.roRow(d, 'PackWh',   'Energy');
            obj.roRow(d, 'PackR',    'DC resistance');
            obj.roRow(d, 'PackIch',  'Charge current');
            obj.roRow(d, 'PackIdch', 'Discharge');

            obj.note(g, ['Capacity, cutoffs and current limits are datasheet ' ...
                'values. The resistance is a datasheet impedance figure, not a ' ...
                'pulse measurement of your cells -- DC pulse resistance typically ' ...
                'runs 30-50%% higher. That barely affects the charge parameters, ' ...
                'which come from the cutoffs and the capacity. It matters a great ' ...
                'deal if you use this model to predict voltage sag under a pulse ' ...
                'load: measure your own cells before treating sag as evidence.']);
        end

        % =================================================================
        function buildLoadTab(obj)
            t = uitab(obj.Tabs, 'Title','Load');
            g = uigridlayout(t, [3 2]);
            g.RowHeight = {'fit', 'fit', '1x'};
            g.ColumnWidth = {560, '1x'};

            n = obj.note(g, ['The waveform your dynamic-load block is asked to ' ...
                'draw, in watts. Positive watts come OUT of the pack. One ' ...
                'waveform is live at a time and the other three keep their ' ...
                'settings, so switching back and forth costs nothing.']);
            n.Layout.Row = 1; n.Layout.Column = [1 2];

            % --- left column: selector + per-waveform panels ---------------
            left = uigridlayout(g, [4 1]);
            left.Layout.Row = 2; left.Layout.Column = 1;
            left.RowHeight = {30, 'fit', 'fit', 'fit'};

            sel = uigridlayout(left, [1 4]);
            sel.ColumnWidth = {90, 130, 70, '1x'};
            sel.RowHeight = {26};
            uilabel(sel, 'Text','Waveform');
            obj.Ctl.Wave = uidropdown(sel, ...
                'Items', {'off','constant','sine','pulse'}, ...
                'Value', obj.Proj.Load.Waveform, ...
                'ValueChangedFcn', @(s,~) obj.onWaveform(s.Value));
            uilabel(sel, 'Text','Preset');
            uidropdown(sel, ...
                'Items', [{'-- pick --'}, bcp.LoadSignal.presetNames()], ...
                'ValueChangedFcn', @(s,~) obj.onLoadPreset(s.Value));

            pc = uipanel(left, 'Title','constant');
            f = obj.fieldGrid(pc, 1);
            obj.numField(f, 'Draw', 'Load.Const_W', 'W', ...
                'Steady power drawn from the pack.');
            obj.WavePanels.constant = pc;

            ps = uipanel(left, 'Title','sine');
            f = obj.fieldGrid(ps, 4);
            obj.numField(f, 'Mean draw', 'Load.Sine_Offset_W', 'W', ...
                'The average the sine oscillates about.');
            obj.numField(f, 'Amplitude', 'Load.Sine_Amplitude_W', 'W', ...
                ['Peak deviation from the mean. If mean minus amplitude goes ' ...
                 'below zero the load would have to SOURCE power; the minimum ' ...
                 'clamp blocks that unless you lower it deliberately.']);
            obj.numField(f, 'Frequency', 'Load.Sine_Frequency_Hz', 'Hz', ...
                'Cycles per second.');
            obj.numField(f, 'Phase', 'Load.Sine_Phase_deg', 'deg', ...
                'Measured from the start time, not from t = 0.');
            obj.WavePanels.sine = ps;

            pp = uipanel(left, 'Title','pulse');
            f = obj.fieldGrid(pp, 5);
            obj.numField(f, 'Base draw between pulses', 'Load.Pulse_Base_W', 'W', ...
                'Held between pulses. Zero is a genuine idle.');
            obj.numField(f, 'Pulse amplitude', 'Load.Pulse_Amplitude_W', 'W', ...
                'Added to the base during each pulse.');
            obj.numField(f, 'Frequency', 'Load.Pulse_Frequency_Hz', 'Hz', ...
                'Pulses per second.');
            obj.numField(f, 'Duty cycle', 'Load.Pulse_Duty_pct', '%', ...
                ['Percentage of each period at the pulse level. The GAP -- ' ...
                 '(100-duty)/frequency seconds -- is the only window the charger ' ...
                 'will ever get, so compare it against the BMS quiet dwell.']);
            obj.numField(f, 'Phase', 'Load.Pulse_Phase_deg', 'deg', ...
                'Measured from the start time, not from t = 0.');
            obj.WavePanels.pulse = pp;

            % --- right column: window, clamps, conditioning ----------------
            right = uigridlayout(g, [2 1]);
            right.Layout.Row = 2; right.Layout.Column = 2;
            right.RowHeight = {'fit','fit'};

            obj.note(right, 'Window, clamps and conditioning', true);
            f = obj.fieldGrid(right, 7);
            obj.numField(f, 'Start time', 'Load.StartTime_s', 's', ...
                'Demand is exactly zero before this.');
            obj.numField(f, 'Stop time', 'Load.StopTime_s', 's', ...
                'Demand is exactly zero from this time on. Inf for never.');
            obj.numField(f, 'Minimum (clamp)', 'Load.Pmin_W', 'W', ...
                ['Zero blocks accidental regen. Go negative only if your load ' ...
                 'block can genuinely source power.']);
            obj.numField(f, 'Maximum (clamp)', 'Load.Pmax_W', 'W', ...
                ['What your load can actually sink. A clamp below the waveform ' ...
                 'peak flattens the top of every pulse -- the preview shows it, ' ...
                 'and a warning appears in the log.']);
            obj.numField(f, 'Slew limit', 'Load.Slew_W_per_s', 'W/s', ...
                ['0 = hard edges. A finite rate turns each pulse edge into a ramp ' ...
                 'the solver can walk across, which can rescue a stiff pack model ' ...
                 'that will not converge. It is a modelling aid rather than ' ...
                 'physics, so switch it on only if you actually need it -- and say ' ...
                 'so when you report results.']);
            obj.numField(f, 'Idle threshold', 'Load.IdleThreshold_W', 'W', ...
                ['Above this the load counts as ACTIVE and the charger is locked ' ...
                 'out. Raise it above your base draw if a small constant load ' ...
                 'should not block charging entirely.']);
            obj.numField(f, 'Output sign', 'Load.OutputSign', '+1/-1', ...
                ['-1 if your dynamic-load block wants negative watts for a draw. ' ...
                 'Set it once; everything else stays draw-positive.']);

            % --- preview ----------------------------------------------------
            pv = uigridlayout(g, [2 1]);
            pv.Layout.Row = 3; pv.Layout.Column = [1 2];
            pv.RowHeight = {28, '1x'};

            bar = uigridlayout(pv, [1 4]);
            bar.ColumnWidth = {130, 90, 140, '1x'};
            bar.RowHeight = {24};
            uilabel(bar, 'Text','Preview span [s]');
            obj.Ctl.PreviewSpan = uieditfield(bar, 'numeric', 'Value', 30, ...
                'ValueChangedFcn', @(~,~) obj.refreshPreview());
            uibutton(bar, 'Text','Refresh preview', ...
                'ButtonPushedFcn', @(~,~) obj.refreshPreview());
            uilabel(bar, 'FontAngle','italic', 'Text', ...
                ['Shaded = load active = charger locked out. The unshaded gaps ' ...
                 'are the only time charging can happen.']);

            obj.PreviewAxes = uiaxes(pv);
        end

        % =================================================================
        function buildBmsTab(obj)
            t = uitab(obj.Tabs, 'Title','BMS');
            g = uigridlayout(t, [1 2]);
            g.ColumnWidth = {'1x','1x'};

            % --- left column -----------------------------------------------
            L = uigridlayout(g, [9 1]);
            L.RowHeight = [{'fit'}, repmat({'fit'},1,8)];

            obj.note(L, ['Protection thresholds, the execution rate, and the rule ' ...
                'that arbitrates between the load and the charger.']);

            obj.note(L, 'Execution', true);
            f = obj.fieldGrid(L, 2);
            obj.numField(f, 'Sample period  Ts', 'Bms.Ts', 's', ...
                ['How often the BMS runs. It must divide your model''s fixed step ' ...
                 'exactly -- "Audit sample times" on the Install tab checks it. ' ...
                 'This is the single most common reason a block that worked in one ' ...
                 'model refuses to compile in another.']);
            obj.chkField(f, 'Break feedback loops', 'Bms.BreakFeedbackLoops', ...
                ['LEAVE THIS ON. It puts a Unit Delay on every measurement input, ' ...
                 'inside the block. The BMS reads the voltage and current that its ' ...
                 'own load command produces, so without the delay that is an ' ...
                 'algebraic loop and Simulink either refuses to compile or solves ' ...
                 'it iteratively every step. One sample of sensor delay is also ' ...
                 'the honest model: a real BMS acts on the previous conversion.']);

            obj.note(L, 'Battery model interface', true);
            f = obj.fieldGrid(L, 5);
            obj.numField(f, 'Current sign', 'Bms.I_sign', '+1/-1', ...
                ['+1 for Simscape Battery packs, including everything Battery ' ...
                 'Model Builder generates: those components declare cell current ' ...
                 '"positive in", which is positive while CHARGING, matching this ' ...
                 'package. Use -1 only for a model that reports discharge as ' ...
                 'positive. Get it wrong and the BMS over-current-trips on a ' ...
                 'discharge pulse and never trips on a real charge. Check it once: ' ...
                 'pack current must read NEGATIVE while the load runs.']);
            obj.chkField(f, 'SOC array is in percent', 'Bms.SOC_in_percent', ...
                'Tick if your model reports 0..100 rather than 0..1.');
            obj.chkField(f, 'Temperature input port', 'Bms.UseTemperature', ...
                ['Off wires an internal 25 degC constant instead of a T_cell port, ' ...
                 'so the over- and under-temperature paths are present and visibly ' ...
                 'inert rather than pretending to be a thermal model. Turn it on ' ...
                 'once your battery model exports temperature.']);
            obj.chkField(f, 'Charger ports', 'Bms.UseCharger', ...
                ['Off removes the P_chg and chg_done inports. Turn it OFF for your ' ...
                 'first installation: prove the load path drives the pack the way ' ...
                 'you expect, then add the charger. Debugging one block beats ' ...
                 'debugging two.']);
            obj.chkField(f, 'Reset input port', 'Bms.UseResetPort', ...
                'Adds an inport whose rising edge clears latched faults.');

            obj.note(L, 'Fault handling', true);
            f = obj.fieldGrid(L, 2);
            obj.chkField(f, 'Auto-recover', 'Bms.AutoRecover', ...
                ['Clear a latched fault automatically once the pack has been ' ...
                 'inside the clear band for the recovery dwell. Off means the ' ...
                 'fault holds until the reset port is pulsed -- which requires ' ...
                 'that port to exist, so turn both on together.']);
            obj.numField(f, 'Recovery dwell', 'Bms.t_recover', 's', ...
                'How long the pack must stay inside the clear band before recovery.');

            % --- right column ----------------------------------------------
            R = uigridlayout(g, [8 1]);
            R.RowHeight = repmat({'fit'},1,8);

            obj.note(R, 'Voltage protection, per cell', true);
            f = obj.fieldGrid(R, 5);
            obj.numField(f, 'Over-voltage trip', 'Bms.V_ov_trip', 'V', ...
                ['Set this ABOVE the charger''s CV target, by 20-50 mV. At the ' ...
                 'target, every charge that succeeds trips protection at the ' ...
                 'moment it succeeds. An over-voltage inhibits CHARGING only -- ' ...
                 'the discharge path stays open, because the load is the cure.']);
            obj.numField(f, 'Over-voltage clear', 'Bms.V_ov_clear', 'V', ...
                'Must be below the trip. Trip and clear must never share a value.');
            obj.numField(f, 'Under-voltage trip', 'Bms.V_uv_trip', 'V', ...
                ['Inhibits DISCHARGING only -- the charge path stays open, because ' ...
                 'charging is the cure.']);
            obj.numField(f, 'Under-voltage clear', 'Bms.V_uv_clear', 'V', ...
                'Must be above the trip.');
            obj.numField(f, 'Voltage confirm time', 'Bms.t_v_trip', 's', ...
                ['An excursion must persist this long to trip. Near zero, ' ...
                 'protection chatters against the solver: it trips, the command ' ...
                 'is cut, voltage recovers, it clears, and the model crawls.']);

            obj.note(R, ['Charge rate, and current protection. Over-current is ' ...
                'two tiers per direction: a lower current confirmed over a long ' ...
                'dwell (the continuous rating) and a higher one over a short dwell ' ...
                '(the pulse rating). One tier cannot honour both -- set it at the ' ...
                'continuous rating and every pulse the pack was built for trips ' ...
                'protection; set it at the pulse rating and a sustained over-draw ' ...
                'runs forever.'], true);
            f = obj.fieldGrid(R, 7);
            obj.numField(f, 'Charge current permitted', 'Bms.I_chg_max_A', 'A', ...
                ['THE CHARGE RATE. Published to the charger on I_chg_limit, and ' ...
                 'the charger commands the lower of it and its own supply rating. ' ...
                 'Changing it here does NOT move the two trips below with it -- ' ...
                 'that is what Project.setChargeCurrent (and the simple window) ' ...
                 'does. Check config will tell you if you have left them behind.']);
            obj.numField(f, 'Charge trip, sustained', 'Bms.I_chg_trip', 'A', ...
                ['A FAULT threshold, confirmed over the long dwell. It must sit ' ...
                 'above the charge current permitted above, or every charge faults ' ...
                 'out at the moment it reaches its setpoint.']);
            obj.numField(f, 'Charge trip, fast', 'Bms.I_chg_peak_A', 'A', ...
                'The higher current, confirmed over the short dwell.');
            obj.numField(f, 'Discharge trip, sustained', 'Bms.I_dch_trip', 'A', ...
                ['Magnitude. The cell''s CONTINUOUS rating. A pulse shorter than ' ...
                 'the long dwell never reaches it.']);
            obj.numField(f, 'Discharge trip, fast', 'Bms.I_dch_peak_A', 'A', ...
                ['Magnitude. The cell''s PULSE rating. This is the tier that ' ...
                 'catches a genuine fault; compare it against the peak current ' ...
                 'your load implies.']);
            obj.numField(f, 'Fast confirm time', 'Bms.t_i_trip', 's', ...
                'Shorter than the voltage dwell: over-current does damage faster.');
            obj.numField(f, 'Sustained confirm time', 'Bms.t_i_cont_s', 's', ...
                ['Longer than the longest pulse you intend the pack to deliver, ' ...
                 'and shorter than the time an over-draw would do damage.']);

            obj.note(R, 'Load versus charge arbitration', true);
            f = obj.fieldGrid(R, 7);
            obj.chkField(f, 'Charging enabled', 'Bms.ChargeEnabled', ...
                'Off runs the load only; the charger sits at OFF for the whole run.');
            obj.chkField(f, 'Allow concurrent charging', 'Bms.AllowConcurrent', ...
                ['Off is strict load priority: no charging at all while the load ' ...
                 'is active. On lets the charger run through the load, derated to ' ...
                 'the headroom below -- which changes what the pack experiences, ' ...
                 'so it is a different experiment rather than a refinement.']);
            obj.numField(f, 'Quiet dwell before charging', 'Bms.t_quiet_s', 's', ...
                ['How long the load must stay idle before the charger is trusted ' ...
                 'to have a window. Longer than the gap inside a pulse burst, ' ...
                 'shorter than the gap between bursts. Set it longer than every ' ...
                 'gap and the charger never runs -- and nothing about the run will ' ...
                 'look broken. "Check config" catches that case.']);
            obj.numField(f, 'Stop charging at SOC', 'Bms.SOC_stop', '0..1', ...
                'Charging stops here, and latches.');
            obj.numField(f, 'Resume charging below SOC', 'Bms.SOC_restart', '0..1', ...
                ['Must be below the stop value. Equal values make the charger ' ...
                 'chatter on and off at the threshold.']);
            obj.numField(f, 'Re-arm below cell voltage', 'Bms.V_recharge', 'V', ...
                'The other way the completion latch clears.');
            obj.numField(f, 'Concurrent headroom', 'Bms.I_chg_headroom_A', 'A', ...
                'The ceiling while the load is running, if concurrent charging is on.');
        end

        % =================================================================
        function buildChargerTab(obj)
            t = uitab(obj.Tabs, 'Title','Charger');
            g = uigridlayout(t, [11 1]);
            g.RowHeight = repmat({'fit'},1,11);

            obj.note(g, ['CC and CV are not modes you select. One PI loop runs ' ...
                'against two voltage targets and a current ceiling, and the mode ' ...
                'output reports which one is binding: at the ceiling is CC, below ' ...
                'it is CV. The handover is automatic because it is not a decision ' ...
                '-- it is which constraint is active.']);

            bar = uigridlayout(g, [1 6]);
            bar.ColumnWidth = {110, 80, 30, 190, 180, '1x'};
            bar.RowHeight = {28};
            uilabel(bar, 'Text','Charge rate');
            obj.Ctl.CRate = uieditfield(bar, 'numeric', 'Value', 0, ...
                'Tooltip',['C-rate for the auto-fill. 0 means "use the cell''s ' ...
                           'datasheet standard charge", which for the Molicel ' ...
                           'P-series is about 1C.']);
            uilabel(bar, 'Text','C');
            uibutton(bar, 'Text','Auto-fill from pack', ...
                'Tooltip',['Derive every field below from the Pack tab. This is ' ...
                           'the intended way to fill this tab -- every number ' ...
                           'here is implied by the cell datasheet and your S/P.'], ...
                'ButtonPushedFcn', @(~,~) obj.onAutofillCharger());
            uibutton(bar, 'Text','Estimate charge time', ...
                'ButtonPushedFcn', @(~,~) obj.onChargeTime());
            obj.Ctl.ChargerSummary = uilabel(bar, 'Text','', 'FontAngle','italic');

            obj.note(g, 'Execution', true);
            f = obj.fieldGrid(g, 2);
            obj.numField(f, 'Sample period  Ts', 'Charger.Ts', 's', ...
                ['Usually the same as the BMS rate. It need not be, but both must ' ...
                 'divide the model step, and a slower charger acts on staler ' ...
                 'permissions.']);
            obj.chkField(f, 'Break feedback loops', 'Charger.BreakFeedbackLoops', ...
                ['LEAVE THIS ON. The charger reads the pack voltage that its own ' ...
                 'current command produces -- the same algebraic loop as the BMS, ' ...
                 'and the same cure.']);

            obj.note(g, 'Current', true);
            f = obj.fieldGrid(g, 4);
            obj.numField(f, 'Supply current rating', 'Charger.I_cc_A', 'A', ...
                ['NOT the charge rate. The charge rate is the BMS field "Charge ' ...
                 'current permitted", which arrives here on I_limit; this block ' ...
                 'commands the lower of the two. This is what the power supply ' ...
                 'itself can source, so auto-fill sets it to the pack datasheet ' ...
                 'MAXIMUM -- the supply should not be the thing quietly limiting ' ...
                 'a test. Lower it to model a smaller supply.']);
            obj.numField(f, 'Termination current', 'Charger.I_taper_A', 'A', ...
                ['The charge ends when the command tapers below this AND stays ' ...
                 'there for the confirm time. C/20 is the usual criterion.']);
            obj.numField(f, 'Precharge current', 'Charger.I_precharge_A', 'A', ...
                ['Trickle for a pack below the precharge voltage. Pushing 1C into ' ...
                 'a deeply discharged cell is how it becomes a damaged cell.']);
            obj.numField(f, 'Supply power ceiling', 'Charger.P_chg_max_W', 'W', ...
                ['Applied after the control law, because a real supply simply ' ...
                 'cannot exceed it however the loop reasons about it. The other ' ...
                 'half of the supply rating: leave it below the current limit ' ...
                 'times the full-pack voltage and it, not the current, is what ' ...
                 'ends the charge. Check config says so.']);

            obj.note(g, 'Voltage', true);
            f = obj.fieldGrid(g, 4);
            obj.numField(f, 'CV target, per cell', 'Charger.V_cv_cell', 'V', ...
                ['The loop regulates the HIGHEST cell against this, not the pack ' ...
                 'average. On a pack with real cell spread those are different ' ...
                 'problems: pack-average CV will happily push the highest cell ' ...
                 'past its trip while the average still looks fine. That is the ' ...
                 'most common way a programmatically built charger destroys cells.']);
            obj.numField(f, 'CV target, pack', 'Charger.V_cv_pack', 'V', ...
                ['The second constraint. Whichever of the two binds first, binds. ' ...
                 'Auto-fill keeps it at S times the per-cell target; a value far ' ...
                 'from that makes one of the two loops permanently inert.']);
            obj.numField(f, 'Precharge below', 'Charger.V_precharge_cell', 'V', ...
                'Below this cell voltage, trickle instead of full CC.');
            obj.numField(f, 'Re-arm below', 'Charger.V_recharge_cell', 'V', ...
                ['A finished charge re-arms when the highest cell falls below this ' ...
                 '-- that is, when the load has actually taken charge back out. It ' ...
                 'does NOT re-arm merely because the charger was paused, or every ' ...
                 'gap between two pulses would restart a completed charge.']);

            obj.note(g, 'Loop tuning and termination', true);
            f = obj.fieldGrid(g, 7);
            obj.numField(f, 'Kp, cell loop', 'Charger.Kp_cell', 'A/V', ...
                ['Auto-fill sets this to a fraction of 1/R, because the plant a CV ' ...
                 'loop sees is nearly resistive: dI amps raises the terminal by ' ...
                 'dI*R. Large by design -- it should saturate for any error above ' ...
                 'a few tens of millivolts.']);
            obj.numField(f, 'Ki, cell loop', 'Charger.Ki_cell', 'A/(V s)', ...
                'Kp divided by the closed-loop time constant.');
            obj.numField(f, 'Kp, pack loop', 'Charger.Kp_pack', 'A/V', ...
                'The same rule applied to the whole-pack resistance, so both loops arrive together.');
            obj.numField(f, 'CC/CV mode hysteresis', 'Charger.Mode_Hyst_frac', '0..1', ...
                ['How far below the current ceiling the command must fall before ' ...
                 'the mode output reports CV, as a fraction of that ceiling. Zero ' ...
                 'is what makes the mode toggle every sample at the knee -- a ' ...
                 'limit cycle in the reported mode, which used to drag the ' ...
                 'termination clock along with it.']);
            obj.numField(f, 'Minimum time in a mode', 'Charger.t_mode_min_s', 's', ...
                ['A mode change waits this long before another is allowed. The ' ...
                 'hysteresis band stops chatter driven by the command; this stops ' ...
                 'chatter driven by a ceiling that is itself moving.']);
            obj.numField(f, 'Termination voltage band', 'Charger.V_term_band', 'V', ...
                ['How close to the CV target the highest cell must be before a ' ...
                 'small command counts as a taper. Termination is keyed off this ' ...
                 'and the current, never off the reported mode -- so a CC phase ' ...
                 'derated by the BMS cannot be mistaken for a finished charge.']);
            obj.numField(f, 'Termination confirm time', 'Charger.t_term_s', 's', ...
                ['NOT OPTIONAL. At the CC-to-CV handover the command dips to near ' ...
                 'zero for a moment while the integrator winds up from empty. ' ...
                 'Terminate on that dip and every charge ends at the knee with the ' ...
                 'pack nowhere near full -- and the phase sequence looks perfect ' ...
                 'on a scope. A genuine taper persists; the transient does not.']);

            obj.note(g, ['Nothing on this tab sets the charge RATE. It is the BMS ' ...
                'field "Charge current permitted" -- one number, published to this ' ...
                'block on I_limit, with both charge over-current trips derived ' ...
                'from it. Auto-fill defaults that rate to the datasheet STANDARD ' ...
                'charge, never the maximum: maxima are qualified by a ' ...
                'cell-temperature cutoff and this package cannot enforce one until ' ...
                'a real temperature signal is wired into the BMS.']);
        end

        % =================================================================
        function buildInstallTab(obj)
            t = uitab(obj.Tabs, 'Title','Install');
            g = uigridlayout(t, [6 1]);
            g.RowHeight = {'fit','fit','fit','fit','fit','1x'};

            obj.note(g, ['Two ways in. If you have never installed these blocks, ' ...
                'build the test harness first: it puts the same two blocks in a ' ...
                'throwaway model with a crude battery stand-in, runs in about a ' ...
                'second, needs no Simscape licence, and lets you get the load ' ...
                'priority and the charge behaviour right before touching the model ' ...
                'you care about.']);

            h = uipanel(g, 'Title','1.  Prove it on a throwaway model');
            gh = uigridlayout(h, [1 5]);
            gh.ColumnWidth = {170, 170, 90, 120, '1x'};
            gh.RowHeight = {30};
            uibutton(gh, 'Text','Build test harness', ...
                'ButtonPushedFcn', @(~,~) obj.onBuildHarness());
            uibutton(gh, 'Text','Simulate harness', ...
                'ButtonPushedFcn', @(~,~) obj.onSimulateHarness());
            obj.Ctl.HarnessStop = uieditfield(gh, 'numeric', 'Value', 600, ...
                'Tooltip','Stop time in seconds for the harness run.');
            uilabel(gh, 'Text','s stop time');
            uilabel(gh, 'Text','');

            m = uipanel(g, 'Title','2.  Install into your battery model');
            gm = uigridlayout(m, [2 5]);
            gm.ColumnWidth = {110, 230, 130, 170, '1x'};
            gm.RowHeight = {30, 30};

            uilabel(gm, 'Text','Target model');
            obj.Ctl.Model = uidropdown(gm, 'Items', {''}, 'Editable','on', ...
                'Tooltip','An OPEN model. Open yours in Simulink, then press Refresh list.');
            uibutton(gm, 'Text','Refresh list', ...
                'ButtonPushedFcn', @(~,~) obj.refreshModelList());
            uibutton(gm, 'Text','Insert blocks', ...
                'Tooltip',['Adds, or replaces, the BMS and charger blocks and ' ...
                           'wires the five lines between them. It does not wire ' ...
                           'them to your battery -- it cannot know which of your ' ...
                           'signals is which.'], ...
                'ButtonPushedFcn', @(~,~) obj.onInsert());
            uilabel(gm, 'Text','');

            uilabel(gm, 'Text','Checks');
            uibutton(gm, 'Text','Audit sample times', ...
                'Tooltip',['Solver type, fixed step, and any Simscape local ' ...
                           'solver, against both block rates.'], ...
                'ButtonPushedFcn', @(~,~) obj.onRateAudit());
            uibutton(gm, 'Text','Align fixed step', ...
                'Tooltip','Sets FixedStep so the block rates are legal. Touches nothing else.', ...
                'ButtonPushedFcn', @(~,~) obj.onRateAlign());
            uibutton(gm, 'Text','Verify wiring', ...
                'Tooltip',['Compiles the model and reports how wide the arrays ' ...
                           'reaching the BMS actually are. Before a compile, ' ...
                           'nothing can tell you whether your battery model is ' ...
                           'per-cell or per-series-element.'], ...
                'ButtonPushedFcn', @(~,~) obj.onVerifyWiring());
            uilabel(gm, 'Text','');

            w = uipanel(g, 'Title','The lines you draw yourself');
            gw = uigridlayout(w, [1 1]);
            uilabel(gw, 'FontName','Consolas', 'WordWrap','off', 'Text', { ...
                'battery cell voltage array  ->  BMS.V_cell'; ...
                'battery cell SOC array      ->  BMS.SOC_cell'; ...
                'battery cell current array  ->  BMS.I_cell'; ...
                ''; ...
                'BMS.P_net_cmd   ->  dynamic load     (load minus charge -- use this if your load block can source)'; ...
                'BMS.P_load_cmd  ->  dynamic load     (load only -- then wire Charger.I_chg_cmd to its own current source)'; ...
                ''; ...
                'Use P_net_cmd OR P_load_cmd, never both.  Full procedure: docs/INSTALL.md'});

            obj.note(g, ['The generated blocks call functions in this package''s ' ...
                'alg/ folder, so bcp_setup must have run in the session before ' ...
                'your model will compile. START_HERE.m does that. If you send the ' ...
                'model to a colleague, send this folder with it.']);
        end

        % =================================================================
        %  Layout helpers
        % =================================================================
        function l = note(~, parent, text, isHeading)
        %NOTE  A full-width paragraph or heading in a single-column parent grid.
        %   Kept out of the field grids on purpose: mixing a column-spanning
        %   label with auto-placed controls in one uigridlayout puts the fields
        %   in the wrong cells.
            if nargin < 4, isHeading = false; end
            if isHeading
                l = uilabel(parent, 'Text', text, 'FontWeight','bold');
            else
                l = uilabel(parent, 'Text', text, 'WordWrap','on', ...
                    'FontAngle','italic');
            end
        end

        function f = fieldGrid(~, parent, nRows)
        %FIELDGRID  A label / control / unit grid, pure auto-placement.
            f = uigridlayout(parent, [nRows 3]);
            f.ColumnWidth = {230, 120, '1x'};
            f.RowHeight = repmat({26}, 1, nRows);
            f.Padding = [4 2 4 2];
            f.RowSpacing = 2;
        end

        function numField(obj, parent, label, path, unit, tip)
            uilabel(parent, 'Text', label, 'Tooltip', tip);
            h = uieditfield(parent, 'numeric', 'Tooltip', tip, ...
                'Value', double(obj.getProp(path)), ...
                'ValueChangedFcn', @(s,~) obj.onNumeric(path, s));
            uilabel(parent, 'Text', unit, 'Tooltip', tip);
            obj.Bound(end+1) = struct('h', h, 'path', path);
        end

        function chkField(obj, parent, label, path, tip)
            uilabel(parent, 'Text', label, 'Tooltip', tip);
            h = uicheckbox(parent, 'Text','', 'Tooltip', tip, ...
                'Value', logical(obj.getProp(path)), ...
                'ValueChangedFcn', @(s,~) obj.onCheckbox(path, s));
            uilabel(parent, 'Text','');
            obj.Bound(end+1) = struct('h', h, 'path', path);
        end

        function roRow(obj, parent, key, label)
            uilabel(parent, 'Text', label);
            obj.Ctl.(key) = uilabel(parent, 'Text','', 'FontWeight','bold');
        end

        % =================================================================
        %  Property access
        % =================================================================
        function v = getProp(obj, path)
            parts = strsplit(path, '.');
            v = obj.Proj;
            for k = 1:numel(parts)
                v = v.(parts{k});
            end
        end

        function ok = trySetProp(obj, path, val)
        %TRYSETPROP  Write a field, validate, roll back if it does not hold.
            ok = false;
            before = obj.Proj;
            parts = strsplit(path, '.');
            try
                switch numel(parts)
                    case 1, obj.Proj.(parts{1}) = val;
                    case 2, obj.Proj.(parts{1}).(parts{2}) = val;
                    otherwise
                        error('bcp:App:Depth', 'Unsupported path "%s".', path);
                end
                obj.Proj = obj.Proj.sync();
                ok = true;
            catch ME
                obj.Proj = before;
                obj.log('REJECTED  %s = %s', path, obj.valueText(val));
                obj.log('          %s', ME.message);
            end
        end

        function s = valueText(~, v)
            if islogical(v)
                if v, s = 'true'; else, s = 'false'; end
            else
                s = sprintf('%g', v);
            end
        end

        % =================================================================
        %  Callbacks
        % =================================================================
        function onNumeric(obj, path, src)
            if obj.Painting, return; end
            if ~obj.trySetProp(path, src.Value)
                src.Value = double(obj.getProp(path));
            end
            obj.refreshAll();
        end

        function onCheckbox(obj, path, src)
            if obj.Painting, return; end
            if ~obj.trySetProp(path, src.Value)
                src.Value = logical(obj.getProp(path));
            end
            obj.refreshAll();
        end

        function onCellChanged(obj, name)
            try
                obj.Proj = obj.Proj.setPack(bcp.PackSpec( ...
                    'Cell', bcp.CellLibrary.byName(name), ...
                    'S', obj.Proj.Pack.S, 'P', obj.Proj.Pack.P));
                obj.log(['Cell set to %s. The thresholds and charge parameters ' ...
                         'still describe the OLD cell -- press "Auto-fill all" to ' ...
                         're-derive them.'], name);
            catch ME
                obj.log('Could not set the cell: %s', ME.message);
            end
            obj.refreshAll();
        end

        function onWaveform(obj, w)
            if ~obj.trySetProp('Load.Waveform', w)
                obj.Ctl.Wave.Value = obj.Proj.Load.Waveform;
            end
            obj.refreshAll();
        end

        function onLoadPreset(obj, name)
            if startsWith(name, '--'), return; end
            try
                obj.Proj.Load = bcp.LoadSignal.preset(name);
                obj.Proj = obj.Proj.sync();
                obj.log('Load preset "%s" applied.', name);
            catch ME
                obj.log('Preset failed: %s', ME.message);
            end
            obj.refreshAll();
        end

        function onAutofillAll(obj)
            try
                obj.Proj = obj.Proj.autofillAll();
                obj.log(['Auto-filled the BMS thresholds and every charge ' ...
                         'parameter from %s %dS%dP.'], ...
                    obj.Proj.Pack.Cell.Name, obj.Proj.Pack.S, obj.Proj.Pack.P);
            catch ME
                obj.log('Auto-fill failed: %s', ME.message);
            end
            obj.refreshAll();
            obj.onCheck();
        end

        function onAutofillCharger(obj)
            args = {};
            if obj.Ctl.CRate.Value > 0
                args = {'C_rate', obj.Ctl.CRate.Value};
            end
            try
                obj.Proj = obj.Proj.autofillCharger(args{:});
                obj.log('Charger auto-filled: %s', obj.Proj.Charger.DerivedFrom);
            catch ME
                obj.log('Charger auto-fill failed: %s', ME.message);
            end
            obj.refreshAll();
            obj.onCheck();
        end

        function onChargeTime(obj)
            I = obj.Proj.chargeCurrent();
            t = (0.95 - 0.20) * obj.Proj.Pack.Q_Ah / I * 3600;
            obj.log('CC-phase charge from 20%% to 95%%: about %.0f s (%.2f h) at %.2f A into %.1f Ah.', ...
                t, t/3600, I, obj.Proj.Pack.Q_Ah);
            obj.log(['  Ignores the CV taper (add 20-30%%) and any time the load ' ...
                     'steals. Compare it against your simulation stop time.']);
            meanW = obj.Proj.Load.meanDemand();
            if meanW > 0
                meanA = meanW / max(obj.Proj.Pack.V_nom, 1);
                obj.log('  The load averages %.0f W, about %.1f A.', meanW, meanA);
                if meanA >= obj.Proj.chargeCurrent()
                    obj.log(['  That is at or above the charge current, so this ' ...
                             'pack will never fill. It will settle wherever load ' ...
                             'and charge balance.']);
                end
            end
        end

        function onCheck(obj)
            issues = obj.Proj.check();
            if isempty(issues)
                obj.log('Configuration is consistent.');
                return;
            end
            obj.log('%d consistency issue(s):', numel(issues));
            for k = 1:numel(issues)
                obj.log('  %d. %s', k, issues{k});
            end
        end

        function onSave(obj)
            [f, p] = uiputfile('*.mat', 'Save configuration', ...
                fullfile(obj.configDir(), 'bcp_config.mat'));
            if isequal(f, 0), return; end
            try
                obj.Proj.save(fullfile(p, f));
                obj.log('Saved to %s', fullfile(p, f));
            catch ME
                obj.log('Save failed: %s', ME.message);
            end
        end

        function onLoad(obj)
            [f, p] = uigetfile('*.mat', 'Load configuration', obj.configDir());
            if isequal(f, 0), return; end
            try
                obj.Proj = bcp.Project.load(fullfile(p, f)).sync();
                obj.log('Loaded %s', fullfile(p, f));
            catch ME
                obj.log('Load failed: %s', ME.message);
            end
            obj.refreshAll();
        end

        % --- install ---------------------------------------------------------
        function onBuildHarness(obj)
            try
                obj.Harness = bcp.Harness(obj.Proj);
                m = obj.Harness.build();
                obj.log('Harness "%s" built and open. Press "Simulate harness".', m);
                obj.refreshModelList();
            catch ME
                obj.log('Harness build failed: %s', ME.message);
            end
        end

        function onSimulateHarness(obj)
            if isempty(obj.Harness)
                obj.log('Build the harness first.');
                return;
            end
            try
                out = obj.Harness.simulate(obj.Ctl.HarnessStop.Value);
                obj.Harness.summary(out);
                obj.Harness.plot(out);
                obj.log(['Harness run complete. Summary in the command window, ' ...
                         'plots in a new figure.']);
            catch ME
                obj.log('Harness simulation failed: %s', ME.message);
            end
        end

        function onInsert(obj)
            m = obj.targetModel();
            if isempty(m), return; end
            try
                obj.Proj.insertInto(m);
                obj.log(['Blocks inserted into "%s". Now draw the lines listed ' ...
                         'below the buttons.'], m);
            catch ME
                obj.log('Insert failed: %s', ME.message);
            end
        end

        function onRateAudit(obj)
            m = obj.targetModel();
            if isempty(m), return; end
            try
                info = bcp.Rate.audit(m, [obj.Proj.Bms.Ts obj.Proj.Charger.Ts]);
                if info.ok
                    obj.log('Sample times in "%s" are fine.', m);
                else
                    obj.log('%d sample-time problem(s) in "%s":', ...
                        numel(info.problems), m);
                    for k = 1:numel(info.problems)
                        obj.log('  * %s', info.problems{k});
                        obj.log('    -> %s', info.advice{k});
                    end
                end
            catch ME
                obj.log('Audit failed: %s', ME.message);
            end
        end

        function onRateAlign(obj)
            m = obj.targetModel();
            if isempty(m), return; end
            try
                bcp.Rate.align(m, [obj.Proj.Bms.Ts obj.Proj.Charger.Ts]);
                obj.log('Fixed step aligned in "%s". Details in the command window.', m);
            catch ME
                obj.log('Align failed: %s', ME.message);
            end
        end

        function onVerifyWiring(obj)
            m = obj.targetModel();
            if isempty(m), return; end
            try
                info = obj.Proj.verifyWiring(m);
                for k = 1:numel(info.notes)
                    obj.log('  %s', info.notes{k});
                end
            catch ME
                obj.log('Wiring check failed: %s', ME.message);
                obj.log(['  It has to compile the model to see the array widths, ' ...
                         'so a compile error shows up here first.']);
            end
        end

        function m = targetModel(obj)
            m = strtrim(char(obj.Ctl.Model.Value));
            if isempty(m)
                obj.log(['Pick a target model first. Open it in Simulink, then ' ...
                         'press "Refresh list".']);
                return;
            end
            if ~bdIsLoaded(m)
                obj.log('Model "%s" is not open. Open it in Simulink first.', m);
                m = '';
            end
        end

        % =================================================================
        %  Refresh
        % =================================================================
        function refreshAll(obj)
            obj.repaintFields();
            obj.refreshDerived();
            obj.refreshWavePanels();
            obj.refreshPreview();
        end

        function repaintFields(obj)
        %REPAINTFIELDS  Push the object back into every bound control.
        %
        %   Auto-fill and sync() change fields nobody touched, so the whole
        %   window is repainted after any mutation rather than only the control
        %   that fired. Painting is guarded so the repaint does not re-trigger
        %   the callbacks it is answering.
            obj.Painting = true;
            for k = 1:numel(obj.Bound)
                b = obj.Bound(k);
                if ~isvalid(b.h), continue; end
                v = obj.getProp(b.path);
                if isa(b.h, 'matlab.ui.control.CheckBox')
                    b.h.Value = logical(v);
                else
                    b.h.Value = double(v);
                end
            end
            if isfield(obj.Ctl,'Wave') && isvalid(obj.Ctl.Wave)
                obj.Ctl.Wave.Value = obj.Proj.Load.Waveform;
            end
            if isfield(obj.Ctl,'CellName') && isvalid(obj.Ctl.CellName)
                nm = obj.Proj.Pack.Cell.Name;
                if any(strcmp(obj.Ctl.CellName.Items, nm))
                    obj.Ctl.CellName.Value = nm;
                end
            end
            obj.Painting = false;
        end

        function refreshDerived(obj)
            p = obj.Proj.Pack;
            obj.setText('PackSummary', sprintf( ...
                '%s   %dS%dP   %.1f Ah   %.1f V nominal   %.0f Wh', ...
                p.Cell.Name, p.S, p.P, p.Q_Ah, p.V_nom, p.Wh));
            obj.setText('PackQ', sprintf('%.2f Ah   (%d cells)', p.Q_Ah, p.NCells));
            obj.setText('PackV', sprintf('%.2f V nominal     %.2f V full     %.2f V empty', ...
                p.V_nom, p.V_max, p.V_min));
            obj.setText('PackWh', sprintf('%.0f Wh', p.Wh));
            obj.setText('PackR', sprintf('%.1f mOhm   (datasheet estimate, not measured)', ...
                p.R_dc_Ohm*1000));
            obj.setText('PackIch', sprintf( ...
                '%.1f A standard (%.2fC)     %.1f A maximum (%.2fC)', ...
                p.I_chg_std_A, p.Cell.C_rate_chg(), ...
                p.I_chg_max_A, p.Cell.C_rate_chg_max()));
            obj.setText('PackIdch', sprintf( ...
                '%.0f A continuous (%.0f W)     %.0f A pulse (%.0f W)', ...
                p.I_dch_A, p.P_dch_W, p.I_dch_pulse_A, p.P_dch_pulse_W));
            obj.setText('CellSource', p.Cell.Source);
            obj.setText('ChargerSummary', obj.Proj.Charger.DerivedFrom);
        end

        function setText(obj, key, text)
            if isfield(obj.Ctl, key) && isvalid(obj.Ctl.(key))
                obj.Ctl.(key).Text = text;
            end
        end

        function refreshWavePanels(obj)
            live = obj.Proj.Load.Waveform;
            names = fieldnames(obj.WavePanels);
            for k = 1:numel(names)
                h = obj.WavePanels.(names{k});
                if ~isvalid(h), continue; end
                if strcmp(names{k}, live)
                    h.Visible = 'on';
                else
                    h.Visible = 'off';
                end
            end
        end

        function refreshPreview(obj)
            if isempty(obj.PreviewAxes) || ~isvalid(obj.PreviewAxes), return; end
            span = obj.Ctl.PreviewSpan.Value;
            if ~(span > 0)
                span = obj.Proj.Load.suggestedPreviewSpan();
                obj.Ctl.PreviewSpan.Value = span;
            end
            try
                obj.Proj.Load.preview(span, obj.PreviewAxes);
            catch ME
                cla(obj.PreviewAxes);
                title(obj.PreviewAxes, ['preview unavailable: ' ME.message]);
            end
        end

        function refreshModelList(obj)
            all = find_system('type','block_diagram');
            keep = {};
            for k = 1:numel(all)
                if strcmp(get_param(all{k},'BlockDiagramType'), 'model')
                    keep{end+1} = all{k}; %#ok<AGROW>
                end
            end
            if isempty(keep), keep = {''}; end
            current = obj.Ctl.Model.Value;
            obj.Ctl.Model.Items = keep;
            if any(strcmp(keep, current))
                obj.Ctl.Model.Value = current;
            else
                obj.Ctl.Model.Value = keep{1};
            end
            obj.log('%d open model(s): %s', numel(keep), strjoin(keep, ', '));
        end

        % =================================================================
        function log(obj, fmt, varargin)
            msg = sprintf(fmt, varargin{:});
            if isempty(obj.LogBox) || ~isvalid(obj.LogBox)
                fprintf('%s\n', msg);
                return;
            end
            v = obj.LogBox.Value;
            if ischar(v), v = {v}; end
            obj.LogBox.Value = [v(:); strsplit(msg, newline)'];
            try, scroll(obj.LogBox, 'bottom'); catch, end
        end

        function d = configDir(~)
            d = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'configs');
            if ~isfolder(d), d = pwd; end
        end
    end
end
