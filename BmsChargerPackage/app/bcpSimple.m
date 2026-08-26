classdef bcpSimple < handle
%BCPSIMPLE  The short version of the UI: six numbers and a Run button.
%
%       bcpSimple
%
%   bcpApp exposes every field of bcp.Project, which is the right thing when
%   you are tuning a protection threshold and the wrong thing when you want to
%   ask "what does a 31 kW pulse do to this pack?". This window asks only for
%   what you have to decide, derives the rest, and shows you what your numbers
%   imply BEFORE you run anything:
%
%     Pack     cell, series count, parallel count
%     Load     pulse power, pulse length, repeat period
%     Charge   current, stop SOC
%     Run      starting SOC, run length, which plant
%
%   Everything else -- every trip threshold, every loop gain, the taper, the
%   precharge, the dwell timers -- comes from bcp.Project.autofillAll(), which
%   is the same path the Auto-fill all button in bcpApp takes. Nothing here is
%   a different configuration mechanism; it is a smaller set of questions.
%
%   THE LOAD IS DESCRIBED AS LENGTH AND PERIOD, NOT DUTY AND FREQUENCY
%     bcp.LoadSignal stores a pulse as Pulse_Frequency_Hz and Pulse_Duty_pct,
%     because that is what the waveform generator needs. Nobody specifies a
%     test that way. "2 s every 600 s" is 0.001667 Hz at 0.333% duty, and
%     typing either of those numbers wrong by a decimal place produces a run
%     that looks fine. This window takes the two numbers you actually have and
%     converts them.
%
%   THE DERIVED LINES ARE THE POINT
%     Under each group is a line saying what those numbers mean for this pack --
%     the current the pulse will really draw, the SOC it costs, how long the
%     charger needs to put it back and how long it has. They update as you type.
%     A load that the pack cannot deliver, or a gap too short to recharge in,
%     is visible before you spend a run finding out.

    properties
        Proj                    % bcp.Project
        Tables                  % bcp.CellTables, or empty
    end

    properties (Access = private)
        Fig
        Ctl     struct = struct()
        LogBox
        Harness
        LastOut
        Painting logical = false
    end

    % =====================================================================
    methods
        function obj = bcpSimple(varargin)
        %BCPSIMPLE  Open the window.
        %
        %   bcpSimple()                       cell tables from ./+Batteries if present
        %   bcpSimple('Tables', ct)           supply bcp.CellTables directly
        %   bcpSimple('BatteryPackage', dir)  look for +Batteries somewhere else
            opt = struct('Tables',[], 'BatteryPackage','+Batteries');
            for k = 1:2:numel(varargin)
                assert(isfield(opt, varargin{k}), 'bcp:Simple:Option', ...
                    'Unknown option "%s".', varargin{k});
                opt.(varargin{k}) = varargin{k+1};
            end

            obj.Tables = opt.Tables;
            if isempty(obj.Tables)
                try
                    obj.Tables = bcp.CellTables.fromPackage(opt.BatteryPackage);
                catch
                    obj.Tables = bcp.CellTables.empty;   % fall back to datasheet scalars
                end
            end

            obj.Proj = obj.defaultProject();
            obj.build();
            obj.refresh();

            if isempty(obj.Tables)
                obj.log(['No +Batteries package found, so the derived lines use ' ...
                         'the datasheet resistance rather than your cell''s real ' ...
                         'SOC-dependent curve. Expect a few percent on the currents.']);
            else
                obj.log('Cell curves read from %s.', obj.Tables.Source);
            end
            obj.log('Set the six numbers, then press Run.');
        end

        function delete(obj)
            if ~isempty(obj.Fig) && isvalid(obj.Fig), delete(obj.Fig); end
        end
    end

    % =====================================================================
    methods (Hidden)   % inspection surface, so this is testable without clicking
        function set(obj, name, value)
        %SET  Change one field exactly as editing its control would.
            obj.Ctl.(name).Value = value;
            obj.onEdit();
        end

        function v = get(obj, name)
            v = obj.Ctl.(name).Value;
        end

        function s = derived(obj)
        %DERIVED  The numbers shown under each group, as a struct.
            s = obj.computeDerived();
        end

        function [ok, T, out] = run(obj)
            [ok, T, out] = obj.doRun();
        end
    end

    % =====================================================================
    methods (Access = private)

        function p = defaultProject(obj)
            if isempty(obj.Tables)
                c = bcp.CellLibrary.P45B();
            else
                c = obj.Tables.toCellLibrary();
            end
            p = bcp.Project('Pack', bcp.PackSpec('Cell', c, 'S', 195, 'P', 1));
            p = p.autofillAll();
            p = obj.applyLoad(p, 31250, 2, 600, 5);
            % A pulse this size is not a continuous load, and the auto-filled
            % discharge trip is derived from the continuous rating. See
            % pulse195_setup for the whole argument; the short form is that a
            % trip at 1.1x continuous fires on any pulse worth testing.
            p.Bms.I_dch_trip = 60;
            p = p.sync();
        end

        function p = applyLoad(~, p, watts, len_s, period_s, start_s)
            p.Load = bcp.LoadSignal( ...
                'Waveform','pulse', ...
                'Pulse_Base_W',0, ...
                'Pulse_Amplitude_W', watts, ...
                'Pulse_Frequency_Hz', 1/period_s, ...
                'Pulse_Duty_pct', 100*len_s/period_s, ...
                'StartTime_s', start_s, ...
                'Pmin_W', 0, ...
                'Pmax_W', 1.12*watts, ...
                'IdleThreshold_W', 5, ...
                'OutputSign', 1);
            p = p.sync();
        end

        % -----------------------------------------------------------------
        function build(obj)
            obj.Fig = uifigure('Name','BMS pulse test', 'Position',[120 80 700 760]);
            g = uigridlayout(obj.Fig, [6 1]);
            g.RowHeight = {150, 150, 120, 130, '1x', 30};
            g.Padding = [10 10 10 10];

            obj.buildPack(g);
            obj.buildLoad(g);
            obj.buildCharge(g);
            obj.buildRun(g);

            obj.LogBox = uitextarea(g, 'Editable','off', ...
                'FontName','Consolas', 'Value',{''});

            obj.Ctl.Status = uilabel(g, 'Text','', 'FontWeight','bold');
        end

        function buildPack(obj, parent)
            pnl = uipanel(parent, 'Title','Pack');
            gg = uigridlayout(pnl, [3 1]);
            gg.RowHeight = {26, 26, '1x'};

            r = uigridlayout(gg, [1 6]);
            r.ColumnWidth = {40, 220, 40, 70, 40, '1x'};
            r.Padding = [0 0 0 0];
            uilabel(r, 'Text','Cell');
            obj.Ctl.Cell = uidropdown(r, 'Items', obj.cellItems(), ...
                'Value', obj.Proj.Pack.Cell.Name, ...
                'ValueChangedFcn', @(~,~) obj.onCell());
            uilabel(r, 'Text','Series');
            obj.Ctl.S = uieditfield(r, 'numeric', 'Value', obj.Proj.Pack.S, ...
                'Limits',[1 Inf], 'RoundFractionalValues','on', ...
                'ValueChangedFcn', @(~,~) obj.onEdit());
            uilabel(r, 'Text','Parallel');
            obj.Ctl.P = uieditfield(r, 'numeric', 'Value', obj.Proj.Pack.P, ...
                'Limits',[1 Inf], 'RoundFractionalValues','on', ...
                'ValueChangedFcn', @(~,~) obj.onEdit());

            obj.Ctl.PackLine = uilabel(gg, 'Text','', 'FontWeight','bold');
            obj.Ctl.PackNote = uilabel(gg, 'Text','', 'WordWrap','on', ...
                'FontAngle','italic');
        end

        function buildLoad(obj, parent)
            pnl = uipanel(parent, 'Title','Load pulse');
            gg = uigridlayout(pnl, [2 1]);
            gg.RowHeight = {84, '1x'};

            f = uigridlayout(gg, [3 3]);
            f.ColumnWidth = {150, 110, '1x'};
            f.RowHeight = {26, 26, 26};
            f.Padding = [0 0 0 0];
            f.RowSpacing = 2;

            obj.num(f, 'Power',        'Pw',     31250, 'W', ...
                'Watts drawn while the pulse is on. Constant power, not constant current.');
            obj.num(f, 'Pulse length', 'Len',    2,     's', ...
                'How long each pulse lasts.');
            obj.num(f, 'Repeat every', 'Period', 600,   's', ...
                'Period from the start of one pulse to the start of the next.');

            obj.Ctl.LoadNote = uilabel(gg, 'Text','', 'WordWrap','on');
        end

        function buildCharge(obj, parent)
            pnl = uipanel(parent, 'Title','Charge between pulses');
            gg = uigridlayout(pnl, [2 1]);
            gg.RowHeight = {58, '1x'};

            f = uigridlayout(gg, [2 3]);
            f.ColumnWidth = {150, 110, '1x'};
            f.RowHeight = {26, 26};
            f.Padding = [0 0 0 0];
            f.RowSpacing = 2;

            obj.num(f, 'Charge current', 'Icc',     4.35, 'A', ...
                'Constant-current setpoint. Defaults to the cell datasheet standard charge.');
            obj.num(f, 'Stop at SOC',    'SOCstop', 95,   '%', ...
                'Charging stops here and does not restart until SOC falls well below it.');

            obj.Ctl.ChargeNote = uilabel(gg, 'Text','', 'WordWrap','on');
        end

        function buildRun(obj, parent)
            pnl = uipanel(parent, 'Title','Run');
            gg = uigridlayout(pnl, [2 1]);
            gg.RowHeight = {58, 34};

            f = uigridlayout(gg, [2 3]);
            f.ColumnWidth = {150, 110, '1x'};
            f.RowHeight = {26, 26};
            f.Padding = [0 0 0 0];
            f.RowSpacing = 2;

            obj.num(f, 'Start SOC',    'SOC0', 60,  '%', 'State of charge the pack starts at.');
            obj.num(f, 'Simulate for', 'Stop', 310, 's', 'Length of the run.');

            r = uigridlayout(gg, [1 4]);
            r.ColumnWidth = {90, 300, 110, '1x'};
            r.Padding = [0 2 0 2];

            uilabel(r, 'Text','Plant');
            obj.Ctl.Plant = uidropdown(r, ...
                'Items', {'fast stand-in (seconds)', 'Simscape pack (slower, real)'}, ...
                'ItemsData', {'harness','simscape'}, ...
                'Value','harness');
            obj.Ctl.RunBtn = uibutton(r, 'Text','Run', ...
                'ButtonPushedFcn', @(~,~) obj.onRun());
            obj.Ctl.PlotBtn = uibutton(r, 'Text','Plot last run', 'Enable','off', ...
                'ButtonPushedFcn', @(~,~) obj.onPlot());
        end

        function num(obj, parent, label, key, value, unit, tip)
            uilabel(parent, 'Text', label, 'Tooltip', tip);
            obj.Ctl.(key) = uieditfield(parent, 'numeric', 'Value', value, ...
                'Tooltip', tip, 'ValueChangedFcn', @(~,~) obj.onEdit());
            uilabel(parent, 'Text', unit, 'Tooltip', tip);
        end

        function items = cellItems(obj)
            items = bcp.CellLibrary.names();
            items(strcmp(items,'Custom')) = [];
            if ~isempty(obj.Tables)
                items = [{obj.Tables.toCellLibrary().Name}, items];
            end
        end

        % =================================================================
        function onCell(obj)
            if obj.Painting, return; end
            name = obj.Ctl.Cell.Value;
            try
                if ~isempty(obj.Tables) && strcmp(name, obj.Tables.toCellLibrary().Name)
                    c = obj.Tables.toCellLibrary();
                else
                    c = bcp.CellLibrary.byName(name);
                end
                obj.Proj = obj.Proj.setPack(bcp.PackSpec('Cell', c, ...
                    'S', obj.Ctl.S.Value, 'P', obj.Ctl.P.Value));
                obj.Proj = obj.Proj.autofillAll();
                obj.Ctl.Icc.Value = obj.Proj.Charger.I_cc_A;
                obj.Proj.Bms.I_dch_trip = 60;
                obj.Proj = obj.Proj.sync();
            catch ME
                obj.log('REJECTED cell change: %s', ME.message);
            end
            obj.onEdit();
        end

        function onEdit(obj)
        %ONEDIT  Push every control into the project, then repaint.
        %
        %   The whole project is rebuilt from the controls rather than patched
        %   field by field, because auto-fill depends on the pack and the pack
        %   can change. A partial update is how a 14S charge target survives
        %   onto a 195S pack.
            if obj.Painting, return; end
            before = obj.Proj;
            try
                c = obj.Proj.Pack.Cell;
                p = bcp.Project('Pack', bcp.PackSpec('Cell', c, ...
                        'S', obj.Ctl.S.Value, 'P', obj.Ctl.P.Value));
                p = p.autofillAll();
                p = obj.applyLoad(p, obj.Ctl.Pw.Value, obj.Ctl.Len.Value, ...
                                     obj.Ctl.Period.Value, 5);
                p.Charger.I_cc_A  = obj.Ctl.Icc.Value;
                p.Bms.SOC_stop    = obj.Ctl.SOCstop.Value / 100;
                p.Bms.SOC_restart = min(p.Bms.SOC_stop - 0.10, p.Bms.SOC_stop*0.9);
                p.Bms.I_dch_trip  = 60;
                obj.Proj = p.sync();
            catch ME
                obj.Proj = before;
                obj.log('REJECTED: %s', ME.message);
            end
            obj.refresh();
        end

        % =================================================================
        function d = computeDerived(obj)
        %COMPUTEDERIVED  What the entered numbers mean for this pack.
        %
        %   Solves the constant-power operating point rather than dividing
        %   watts by nominal volts. Under a constant-power load the sag feeds
        %   back -- more sag means more current means more sag -- and at 31 kW
        %   on this pack the naive division is 10% low, which is the difference
        %   between clearing the discharge trip and not.
            p = obj.Proj;
            S = p.Pack.S; P = p.Pack.P;
            d = struct();
            d.watts  = p.Load.Pulse_Amplitude_W;
            d.len    = p.Load.Pulse_Duty_pct/100 / p.Load.Pulse_Frequency_Hz;
            d.period = 1 / p.Load.Pulse_Frequency_Hz;
            d.gap    = d.period - d.len;
            d.Q      = p.Pack.Cell.Q_Ah * P;

            socs = [obj.Ctl.SOC0.Value/100, p.Bms.SOC_stop];
            d.I = nan(size(socs)); d.V = d.I;
            for k = 1:numel(socs)
                [ocvC, rC] = obj.cellAt(socs(k));
                Voc = ocvC*S; R = rC*S/P;
                disc = Voc^2 - 4*R*d.watts;
                if disc < 0
                    d.I(k) = NaN; d.V(k) = NaN;
                    d.Pmax = Voc^2/(4*R);
                else
                    d.I(k) = (Voc - sqrt(disc))/(2*R);
                    d.V(k) = Voc - d.I(k)*R;
                end
            end
            d.deliverable = all(isfinite(d.I));
            d.Ah_per_pulse  = max(d.I) * d.len / 3600;
            d.SOC_per_pulse = 100 * d.Ah_per_pulse / d.Q;
            d.recharge_s    = d.Ah_per_pulse * 3600 / max(p.Charger.I_cc_A, eps);
            d.trip          = p.Bms.I_dch_trip;
            d.headroom      = 100*(d.trip / max(d.I) - 1);
        end

        function [ocvC, rC] = cellAt(obj, soc)
            if isempty(obj.Tables)
                c = obj.Proj.Pack.Cell;
                ocvC = c.V_min + (c.V_max - c.V_min) * (0.25 + 0.75*soc);
                rC   = c.R_dc_Ohm;
            else
                ocvC = obj.Tables.ocv(soc);
                rC   = obj.Tables.r0(soc);
            end
        end

        % =================================================================
        function refresh(obj)
            obj.Painting = true;
            c = onCleanup(@() obj.clearPainting());

            p = obj.Proj;
            obj.Ctl.PackLine.Text = sprintf( ...
                '%d cells   %.2f Ah   %.0f V nominal   %.0f Wh', ...
                p.Pack.NCells, p.Pack.Q_Ah, p.Pack.V_nom, p.Pack.Wh);
            obj.Ctl.PackNote.Text = sprintf( ...
                ['Protection is derived from this: cell trips %.2f V high / %.2f V low, ' ...
                 'charge trip %.1f A, discharge trip %.0f A.'], ...
                p.Bms.V_ov_trip, p.Bms.V_uv_trip, p.Bms.I_chg_trip, p.Bms.I_dch_trip);

            d = obj.computeDerived();
            if ~d.deliverable
                obj.Ctl.LoadNote.Text = sprintf( ...
                    ['THIS PACK CANNOT DELIVER %.0f W. The most it can put into any ' ...
                     'load is about %.0f W, at which point it is half-sagged. ' ...
                     'Lower the power or add cells in parallel.'], d.watts, d.Pmax);
                obj.Ctl.LoadNote.FontColor = [0.7 0 0];
            else
                obj.Ctl.LoadNote.FontColor = [0 0 0];
                obj.Ctl.LoadNote.Text = sprintf( ...
                    ['%.1f A at the start, %.1f A when full -- pack sags to %.0f V ' ...
                     '(%.3f V per cell). Costs %.3f%% SOC per pulse. Discharge trip ' ...
                     'is %.0f A, so %.0f%% headroom.'], ...
                    d.I(1), d.I(2), min(d.V), min(d.V)/p.Pack.S, ...
                    d.SOC_per_pulse, d.trip, d.headroom);
                if d.headroom < 10
                    obj.Ctl.LoadNote.FontColor = [0.7 0.35 0];
                end
            end

            if d.recharge_s > d.gap
                obj.Ctl.ChargeNote.FontColor = [0.7 0 0];
                obj.Ctl.ChargeNote.Text = sprintf( ...
                    ['Needs %.0f s to replace one pulse but only %.0f s between them. ' ...
                     'The pack will run down. Raise the current or lengthen the gap.'], ...
                    d.recharge_s, d.gap);
            else
                obj.Ctl.ChargeNote.FontColor = [0 0 0];
                obj.Ctl.ChargeNote.Text = sprintf( ...
                    ['Replaces one pulse in %.0f s and has %.0f s between them, so the ' ...
                     'pack climbs about %.2f%% SOC per cycle until it reaches %.0f%%.'], ...
                    d.recharge_s, d.gap, ...
                    100*(p.Charger.I_cc_A*d.gap/3600)/d.Q - d.SOC_per_pulse, ...
                    p.Bms.SOC_stop*100);
            end

            issues = p.check();
            if isempty(issues)
                obj.Ctl.Status.Text = 'Configuration consistent.';
                obj.Ctl.Status.FontColor = [0 0.45 0];
            else
                obj.Ctl.Status.Text = sprintf('%d consistency note(s) -- see the log.', ...
                    numel(issues));
                obj.Ctl.Status.FontColor = [0.7 0.35 0];
            end
        end

        function clearPainting(obj)
            obj.Painting = false;
        end

        % =================================================================
        function onRun(obj)
            obj.Ctl.RunBtn.Enable = 'off';
            r = onCleanup(@() set(obj.Ctl.RunBtn, 'Enable', 'on'));
            try
                obj.doRun();
            catch ME
                obj.log('Run failed: %s', ME.message);
            end
        end

        function [ok, T, out] = doRun(obj)
            p = obj.Proj;
            d = obj.computeDerived();
            stop = obj.Ctl.Stop.Value;
            soc0 = obj.Ctl.SOC0.Value/100;

            issues = p.check();
            for k = 1:numel(issues)
                obj.log('note %d: %s', k, issues{k});
            end

            if strcmp(obj.Ctl.Plant.Value, 'simscape')
                obj.log('Running the Simscape pack for %g s. This takes a while.', stop);
                drawnow;
                [ok, T, ~, out] = pulse195_model('Period_s', d.period, ...
                    'Pulse_s', d.len, 'P_load_W', d.watts, ...
                    'StopTime_s', stop, 'SOC_init', soc0);
                obj.Harness = [];
            else
                obj.log('Running the fast stand-in for %g s...', stop);
                drawnow;
                obj.Harness = bcp.Harness(p, 'CellTables', obj.Tables, 'SOC_init', soc0);
                obj.Harness.build();
                out = obj.Harness.simulate(stop);
                obj.LastOut = out;
                [ok, T] = pulse195_verify(out, p, obj.tablesOrDefault(), ...
                    'Period_s', d.period, 'Pulse_s', d.len, ...
                    'P_load_W', d.watts, 'Start_s', p.Load.StartTime_s, ...
                    'SOC_init', soc0, 'Verbose', false);
                obj.Ctl.PlotBtn.Enable = 'on';
            end

            obj.log('---- %d checks, %d failed ----', height(T), sum(~T.Passed));
            for k = 1:height(T)
                if T.Passed(k), tag = 'ok  '; else, tag = 'FAIL'; end
                obj.log('%s %s: %s', tag, T.Check{k}, T.Detail{k});
            end
            if ok
                obj.Ctl.Status.Text = sprintf('Run complete -- all %d checks passed.', height(T));
                obj.Ctl.Status.FontColor = [0 0.45 0];
            else
                obj.Ctl.Status.Text = sprintf('Run complete -- %d check(s) FAILED.', sum(~T.Passed));
                obj.Ctl.Status.FontColor = [0.7 0 0];
            end
        end

        function ct = tablesOrDefault(obj)
            if isempty(obj.Tables)
                % pulse195_verify needs an ocv/r0 source for the predicted
                % operating point; synthesise a two-point one from the spec.
                c  = obj.Proj.Pack.Cell;
                ct = bcp.CellTables('SOC',[0 1], 'OCV_V',[c.V_min c.V_max], ...
                    'R0_Ohm',[c.R_dc_Ohm c.R_dc_Ohm], 'Q_Ah',c.Q_Ah, ...
                    'Name',c.Name, 'Source','synthesised from datasheet scalars');
            else
                ct = obj.Tables;
            end
        end

        function onPlot(obj)
        %ONPLOT  The four-panel harness figure: power, cell voltages against the
        %   trips, SOC and current, and the arbitration story.
            if isempty(obj.Harness) || isempty(obj.LastOut)
                obj.log(['Nothing to plot. The Simscape run writes to the model''s ' ...
                         'own scope; run the fast stand-in for these panels.']);
                return;
            end
            try
                obj.Harness.plot(obj.LastOut);
            catch ME
                obj.log('Plot failed: %s', ME.message);
            end
        end

        function log(obj, fmt, varargin)
            msg = sprintf(fmt, varargin{:});
            if isempty(obj.LogBox) || ~isvalid(obj.LogBox)
                fprintf('%s\n', msg); return;
            end
            v = obj.LogBox.Value;
            if ischar(v), v = {v}; end
            obj.LogBox.Value = [v(:); strsplit(msg, newline).'];
            try, scroll(obj.LogBox, 'bottom'); catch, end
        end
    end
end
