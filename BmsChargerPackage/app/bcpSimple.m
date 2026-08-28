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
%     Blocks   starting SOC, run length, and Copy models
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
%
%   COPY MODELS IS THE OUTPUT OF THIS WINDOW
%     The blocks are meant to end up in YOUR simulation, so that button is on
%     the main panel and the built-in test harness sits behind Additional
%     settings. Copy models builds the BMS and the charger from the numbers
%     above, wired to each other, and either stages them for Ctrl+C or inserts
%     them straight into a model you have open. Every threshold is compiled into
%     the blocks as a literal, so they mean the same thing in your model as they
%     do here -- there are no base-workspace variables to carry across.
%
%   CHARGE CURRENT IS ONE NUMBER, ALL THE WAY DOWN
%     Typing in the Charge current field calls bcp.Project.setChargeCurrent,
%     which moves the BMS charge limit, both charge over-current trips and the
%     supply's current and power ceilings together. In the pasted BMS block the
%     same number appears once, as I_CHG_MAX_A at the top of BMS_core, with the
%     trips computed from it three lines later.

    properties
        Proj                    % bcp.Project
        Tables                  % bcp.CellTables, or empty

        Variation               % bcp.CellVariation, once Apply to pack has run
        %  Public so the spread can be undone from the command line:
        %
        %      s = bcpSimple;  ...  s.Variation.revert()
        %
        %  It holds every parameter string it overwrote, so revert is exact
        %  rather than a recomputed guess at what was there.
    end

    properties (Access = private)
        Fig
        Ctl     struct = struct()
        LogBox
        Harness
        LastOut
        Painting logical = false
    end

    properties (Constant, Access = private)
        ExtrasCollapsedH = 1    % the Additional settings row when it is shut
        ExtrasExpandedH  = 150  % ...and when it is open
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
            obj.log(['Set the numbers above, then press Copy models to put the ' ...
                     'BMS and charger into your own simulation.']);
            obj.log(['Additional settings has the built-in test harness and the ' ...
                     'cell-variation tool.']);
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

        function press(obj, which)
        %PRESS  Fire a button's callback, exactly as clicking it would.
        %
        %   The same reason set() exists: a button whose behaviour can only be
        %   reached by clicking is a button nothing tests, and Copy models is
        %   now the thing this window is for.
            switch lower(char(which))
                case 'copy',      obj.onCopy();
                case 'extras',    obj.toggleExtras();
                case 'variation', obj.onVariation();
                case 'models',    obj.refreshModelList();
                case 'run',       obj.onRun();
                case 'plot',      obj.onPlot();
                otherwise
                    error('bcp:Simple:NoButton', ...
                        ['Unknown button "%s". One of: copy, extras, variation, ', ...
                         'models, run, plot.'], char(which));
            end
        end

        function target(obj, model)
        %TARGET  Choose the destination model, as the dropdown would.
            obj.refreshModelList();
            assert(any(strcmp(obj.Ctl.CopyTarget.ItemsData, model)), ...
                'bcp:Simple:NoTarget', ...
                'Model "%s" is not in the destination list. Is it open?', model);
            obj.Ctl.CopyTarget.Value = model;
        end

        function s = logText(obj)
        %LOGTEXT  Everything the log pane holds, as one string.
            s = strjoin(string(obj.LogBox.Value), newline);
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
            % No discharge-trip override here any more. The auto-filled
            % protection is two-tiered -- the continuous rating confirmed over
            % ten seconds and the pulse rating over a tenth of one -- so a two
            % second pulse above the continuous rating passes on its own merits
            % rather than because a threshold was quietly raised to let it.
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
            obj.Fig = uifigure('Name','BMS pulse test', 'Position',[120 80 700 800]);
            g = uigridlayout(obj.Fig, [7 1]);
            g.RowHeight = {150, 150, 120, 96, obj.ExtrasCollapsedH, '1x', 30};
            g.Padding = [10 10 10 10];
            obj.Ctl.Grid = g;

            obj.buildPack(g);
            obj.buildLoad(g);
            obj.buildCharge(g);
            obj.buildRun(g);
            obj.buildExtras(g);

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
                ['The ONE number that sets the charge rate. Defaults to the cell ', ...
                 'datasheet standard charge; the datasheet maximum is shown below. ', ...
                 'Both charge over-current trips move with it.']);
            obj.num(f, 'Stop at SOC',    'SOCstop', 95,   '%', ...
                'Charging stops here and does not restart until SOC falls well below it.');

            obj.Ctl.ChargeNote = uilabel(gg, 'Text','', 'WordWrap','on');
        end

        function buildRun(obj, parent)
        %BUILDRUN  Starting conditions, and the button most people came for.
        %
        %   Copy models is first because it is what this window is FOR: the
        %   simulation people actually care about is their own, and these blocks
        %   are meant to end up in it. Running the built-in harness is how you
        %   check the configuration before you copy it, which is a step you take
        %   sometimes -- so it lives under Additional settings, one click away
        %   rather than competing for the same row.
            pnl = uipanel(parent, 'Title','Blocks');
            gg = uigridlayout(pnl, [2 1]);
            gg.RowHeight = {32, 34};
            gg.RowSpacing = 2;

            f = uigridlayout(gg, [1 6]);
            f.ColumnWidth = {80, 70, 20, 90, 70, '1x'};
            f.Padding = [0 0 0 0];
            uilabel(f, 'Text','Start SOC', ...
                'Tooltip','State of charge the pack starts at.');
            obj.Ctl.SOC0 = uieditfield(f, 'numeric', 'Value', 60, ...
                'ValueChangedFcn', @(~,~) obj.onEdit());
            uilabel(f, 'Text','%');
            uilabel(f, 'Text','Simulate for', 'Tooltip','Length of the run.');
            obj.Ctl.Stop = uieditfield(f, 'numeric', 'Value', 310, ...
                'ValueChangedFcn', @(~,~) obj.onEdit());
            uilabel(f, 'Text','s');

            r = uigridlayout(gg, [1 3]);
            r.ColumnWidth = {150, 220, '1x'};
            r.Padding = [0 2 0 2];
            obj.Ctl.CopyBtn = uibutton(r, 'Text','Copy models', ...
                'Tooltip', ['Build the BMS and charger from these numbers, wired ', ...
                            'to each other, ready to paste into your own model.'], ...
                'ButtonPushedFcn', @(~,~) obj.onCopy());
            obj.Ctl.CopyTarget = uidropdown(r, ...
                'Items', {'to a scratch model (Ctrl+C, Ctrl+V)'}, ...
                'ItemsData', {''}, ...
                'Tooltip', ['Where the blocks go. Any other model you have open ', ...
                            'is listed here, and picking it inserts them directly.'], ...
                'DropDownOpeningFcn', @(~,~) obj.refreshModelList());
            obj.Ctl.ExtrasBtn = uibutton(r, 'Text', ...
                [char(9656) ' Additional settings'], ...
                'Tooltip', ['Run the built-in test harness, plot the last run, ', ...
                            'and add cell-to-cell variation to a pack.'], ...
                'ButtonPushedFcn', @(~,~) obj.toggleExtras());
        end

        % -----------------------------------------------------------------
        function buildExtras(obj, parent)
        %BUILDEXTRAS  The drawer: simulate here, and vary a pack's cells.
            pnl = uipanel(parent, 'Title','Additional settings', 'Visible','off');
            obj.Ctl.Extras = pnl;
            gg = uigridlayout(pnl, [3 1]);
            gg.RowHeight = {30, 30, '1x'};
            gg.RowSpacing = 4;

            r = uigridlayout(gg, [1 4]);
            r.ColumnWidth = {60, 260, 90, '1x'};
            r.Padding = [0 0 0 0];
            uilabel(r, 'Text','Plant');
            obj.Ctl.Plant = uidropdown(r, ...
                'Items', {'fast stand-in (seconds)', 'Simscape pack (slower, real)'}, ...
                'ItemsData', {'harness','simscape'}, ...
                'Value','harness');
            obj.Ctl.RunBtn = uibutton(r, 'Text','Run', ...
                'ButtonPushedFcn', @(~,~) obj.onRun());
            obj.Ctl.PlotBtn = uibutton(r, 'Text','Plot last run', 'Enable','off', ...
                'ButtonPushedFcn', @(~,~) obj.onPlot());

            v = uigridlayout(gg, [1 8]);
            v.ColumnWidth = {90, 55, 70, 55, 80, 55, 130, '1x'};
            v.Padding = [0 0 0 0];
            uilabel(v, 'Text','Cell spread', ...
                'Tooltip', ['Cell-to-cell variation applied to a Simscape battery ', ...
                            'pack in the model you pick above. Peak-to-peak.']);
            obj.Ctl.VarSOC = uieditfield(v, 'numeric', 'Value', 2, ...
                'Tooltip','Spread in initial SOC, in SOC percentage points.');
            uilabel(v, 'Text','pts SOC');
            obj.Ctl.VarR = uieditfield(v, 'numeric', 'Value', 10, ...
                'Tooltip','Spread in element resistance, percent of nominal.');
            uilabel(v, 'Text','% R,  seed');
            obj.Ctl.VarSeed = uieditfield(v, 'numeric', 'Value', 7, ...
                'RoundFractionalValues','on', ...
                'Tooltip','Change the seed to draw a different pack from the same spread.');
            obj.Ctl.VarBtn = uibutton(v, 'Text','Apply to pack', ...
                'Tooltip', ['Writes the spread into the battery blocks of the ', ...
                            'model selected in the dropdown above.'], ...
                'ButtonPushedFcn', @(~,~) obj.onVariation());

            obj.Ctl.ExtrasNote = uilabel(gg, 'WordWrap','on', 'FontAngle','italic', ...
                'Text', ['Cell spread applies to the BATTERY, not to these blocks, ', ...
                         'so it goes into whichever model you selected next to ', ...
                         'Copy models. Nothing to undo by hand: bcp.CellVariation ', ...
                         'stores every parameter it touches and revert() puts them back.']);
        end

        % -----------------------------------------------------------------
        function toggleExtras(obj)
            open = strcmp(obj.Ctl.Extras.Visible, 'off');
            obj.Ctl.Extras.Visible = matlab.lang.OnOffSwitchState(open);
            h = obj.Ctl.Grid.RowHeight;
            if open
                h{5} = obj.ExtrasExpandedH;
                obj.Ctl.ExtrasBtn.Text = [char(9662) ' Additional settings'];
            else
                h{5} = obj.ExtrasCollapsedH;
                obj.Ctl.ExtrasBtn.Text = [char(9656) ' Additional settings'];
            end
            obj.Ctl.Grid.RowHeight = h;
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
                obj.Ctl.Icc.Value = obj.Proj.Bms.I_chg_max_A;
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
                % One call for the charge rate. It moves the BMS limit, both
                % charge over-current trips and the supply ceiling together, so
                % the field on this window is genuinely the only thing that has
                % to change to charge faster.
                p = p.setChargeCurrent(obj.Ctl.Icc.Value);
                p.Bms.SOC_stop    = obj.Ctl.SOCstop.Value / 100;
                p.Bms.SOC_restart = min(p.Bms.SOC_stop - 0.10, p.Bms.SOC_stop*0.9);
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
            d.recharge_s    = d.Ah_per_pulse * 3600 / max(p.chargeCurrent(), eps);
            % Headroom is measured against the FAST discharge trip, because that
            % is the tier a pulse can actually reach: the sustained trip confirms
            % over t_i_cont_s, longer than any pulse this window describes.
            d.trip          = p.Bms.I_dch_peak_A;
            d.trip_cont     = p.Bms.I_dch_trip;
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
                ['Protection derived from the datasheet: cell trips %.2f V high / ' ...
                 '%.2f V low; charge %.2f A over %.0f s or %.2f A over %.2f s; ' ...
                 'discharge %.0f A over %.0f s or %.0f A over %.2f s.'], ...
                p.Bms.V_ov_trip, p.Bms.V_uv_trip, ...
                p.Bms.I_chg_trip, p.Bms.t_i_cont_s, p.Bms.I_chg_peak_A, p.Bms.t_i_trip, ...
                p.Bms.I_dch_trip, p.Bms.t_i_cont_s, p.Bms.I_dch_peak_A, p.Bms.t_i_trip);

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
                     '(%.3f V per cell). Costs %.3f%% SOC per pulse. The pulse ' ...
                     'discharge trip is %.0f A, so %.0f%% headroom.'], ...
                    d.I(1), d.I(2), min(d.V), min(d.V)/p.Pack.S, ...
                    d.SOC_per_pulse, d.trip, d.headroom);
                if d.headroom < 10
                    obj.Ctl.LoadNote.FontColor = [0.7 0.35 0];
                end
            end

            chgMax = p.Pack.I_chg_max_A;
            if p.Bms.I_chg_max_A > chgMax + 1e-9
                obj.Ctl.ChargeNote.FontColor = [0.7 0 0];
                obj.Ctl.ChargeNote.Text = sprintf( ...
                    ['%.2f A is above the %.1f A datasheet MAXIMUM charge current ', ...
                     'for this pack. Lower it, or add cells in parallel.'], ...
                    p.Bms.I_chg_max_A, chgMax);
            elseif d.recharge_s > d.gap
                obj.Ctl.ChargeNote.FontColor = [0.7 0 0];
                obj.Ctl.ChargeNote.Text = sprintf( ...
                    ['Needs %.0f s to replace one pulse but only %.0f s between them. ' ...
                     'The pack will run down. Raise the current or lengthen the gap.'], ...
                    d.recharge_s, d.gap);
            else
                obj.Ctl.ChargeNote.FontColor = [0 0 0];
                obj.Ctl.ChargeNote.Text = sprintf( ...
                    ['Replaces one pulse in %.0f s and has %.0f s between them, so the ' ...
                     'pack climbs about %.2f%% SOC per cycle until it reaches %.0f%%. ' ...
                     'Datasheet limits: %.2f A standard, %.1f A maximum.'], ...
                    d.recharge_s, d.gap, ...
                    100*(p.chargeCurrent()*d.gap/3600)/d.Q - d.SOC_per_pulse, ...
                    p.Bms.SOC_stop*100, p.Pack.I_chg_std_A, chgMax);
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
        function refreshModelList(obj)
        %REFRESHMODELLIST  Repopulate the destination dropdown from what is open.
        %
        %   Rebuilt every time the list is opened rather than at startup, because
        %   the whole point is to offer the model you have just opened -- and the
        %   order people do things in is: open this window, realise they want the
        %   blocks, then open their own model.
            items = {'to a scratch model (Ctrl+C, Ctrl+V)'};
            data  = {''};
            try
                open = find_system('type','block_diagram');
            catch
                open = {};
            end
            skip = {'bcp_blocks','bcp_harness','simulink'};
            for k = 1:numel(open)
                nm = open{k};
                if any(strcmpi(nm, skip)) || strncmpi(nm, 'tb_', 3)
                    continue;
                end
                items{end+1} = sprintf('insert into %s', nm); %#ok<AGROW>
                data{end+1}  = nm;                            %#ok<AGROW>
            end
            keep = obj.Ctl.CopyTarget.Value;
            obj.Ctl.CopyTarget.Items     = items;
            obj.Ctl.CopyTarget.ItemsData = data;
            if any(strcmp(data, keep))
                obj.Ctl.CopyTarget.Value = keep;
            end
        end

        % -----------------------------------------------------------------
        function onCopy(obj)
        %ONCOPY  Build the two blocks from the current numbers, ready to paste.
        %
        %   Both blocks, wired to each other, with this configuration compiled
        %   into them as literals. That last part matters: the blocks carry their
        %   own constants, so they mean the same thing in your model as they do
        %   here, on a machine with an empty base workspace.
            obj.Ctl.CopyBtn.Enable = 'off';
            r = onCleanup(@() set(obj.Ctl.CopyBtn, 'Enable', 'on'));
            target = obj.Ctl.CopyTarget.Value;
            try
                issues = obj.Proj.check();
                for k = 1:numel(issues)
                    obj.log('note %d: %s', k, issues{k});
                end

                if isempty(target)
                    m = obj.Proj.stageBlocks();
                    obj.log(['Staged the BMS and charger in "%s" with both blocks ' ...
                             'selected. Ctrl+C there, Ctrl+V in your model.'], m);
                else
                    obj.Proj.insertInto(target);
                    try, open_system(target); catch, end
                    obj.log('Inserted the BMS and charger into "%s".', target);
                end
                obj.log(['Charge rate is %.2f A. In the pasted BMS block it is ' ...
                         'I_CHG_MAX_A at the top of BMS_core -- one number, and ' ...
                         'the over-current trips follow it.'], obj.Proj.Bms.I_chg_max_A);
                obj.log(['Both blocks need bcp_setup on the MATLAB path to ' ...
                         'compile. Wire your battery to the BMS inports and the ' ...
                         'BMS load command out to your load; docs/INSTALL.md has ' ...
                         'the list.']);
            catch ME
                obj.log('Copy failed: %s', ME.message);
            end
        end

        % -----------------------------------------------------------------
        function onVariation(obj)
        %ONVARIATION  Put cell-to-cell spread into the selected model's pack.
            target = obj.Ctl.CopyTarget.Value;
            if isempty(target)
                obj.log(['Pick the model holding your battery in the dropdown ' ...
                         'next to Copy models first -- cell spread goes into the ' ...
                         'pack, not into these blocks.']);
                return;
            end
            obj.Ctl.VarBtn.Enable = 'off';
            r = onCleanup(@() set(obj.Ctl.VarBtn, 'Enable', 'on'));
            try
                obj.Variation = bcp.CellVariation( ...
                    'SOC_spread_pct', obj.Ctl.VarSOC.Value, ...
                    'R_spread_pct',   obj.Ctl.VarR.Value, ...
                    'Q_spread_pct',   obj.Ctl.VarR.Value / 3, ...
                    'SOC_base',       obj.Ctl.SOC0.Value / 100, ...
                    'Seed',           obj.Ctl.VarSeed.Value);
                T = obj.Variation.apply(target);
                obj.log('Cell variation applied to %d element(s) in "%s".', ...
                    height(T), target);
                if height(T) == 1
                    obj.log(['Only one element: that pack is lumped to a single ' ...
                             'cell model, so it has no per-cell state to vary. ' ...
                             'Rebuild it at Detailed resolution in Battery Model ' ...
                             'Builder if you need real cell spread.']);
                else
                    obj.log('  initial SOC now spans %.2f%% to %.2f%%, R spans %.3fx to %.3fx.', ...
                        min(T.SOC_init)*100, max(T.SOC_init)*100, ...
                        min(T.Resistance_x), max(T.Resistance_x));
                end
                obj.log(['  To undo: keep this window in a variable (s = bcpSimple) ' ...
                         'and call s.Variation.revert(), or just reload the model.']);
            catch ME
                obj.log('Cell variation failed: %s', ME.message);
            end
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
