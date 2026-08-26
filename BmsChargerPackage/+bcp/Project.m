classdef Project
%BCP.PROJECT  The four configuration objects, kept consistent with each other.
%
%   A pack spec, a load waveform, a BMS config and a charger config. Three of
%   those four contain the series count, and two contain a per-cell voltage
%   limit; sync() is what stops them disagreeing. Everything the UI does goes
%   through this class, so a scripted run and a UI run cannot drift apart.
%
%       p = bcp.Project();                       % P45B 14S5P defaults
%       p = p.setPack(bcp.PackSpec('Cell',bcp.CellLibrary.P50B(),'S',20,'P',4));
%       p = p.autofillCharger();                 % from the pack, not by hand
%       p.insertInto('myBatteryModel');
%
%   OR, once, from the UI:
%
%       bcpApp
%
%   SAVE AND LOAD
%       p.save('configs/mypack.mat');
%       p = bcp.Project.load('configs/mypack.mat');
%
%   The saved file is the configuration, not the model. Rebuilding from it is a
%   second; keeping a hand-edited model as the record of what you meant is how
%   you end up unable to say what a result was run with.

    properties
        Pack    = bcp.PackSpec()
        Load    = bcp.LoadSignal()
        Bms     = bcp.BmsConfig()
        Charger = bcp.ChargerConfig()
        TargetModel char = ''
    end

    methods
        function obj = Project(varargin)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
            if isempty(varargin)
                obj = obj.autofillAll();
            end
        end

        % -----------------------------------------------------------------
        function obj = setPack(obj, spec)
        %SETPACK  Replace the pack spec and propagate the topology.
            arguments
                obj
                spec (1,1) bcp.PackSpec
            end
            obj.Pack = spec.validate();
            obj = obj.sync();
        end

        % -----------------------------------------------------------------
        function obj = autofillAll(obj)
        %AUTOFILLALL  Derive the BMS protection thresholds and every charge
        %   parameter from the pack. The load waveform is left alone -- it
        %   describes your test, not your pack.
            obj.Bms     = obj.Bms.fromPack(obj.Pack);
            obj.Charger = bcp.ChargerConfig.fromPack(obj.Pack, 'Ts', obj.Bms.Ts);
            obj = obj.sync();
        end

        % -----------------------------------------------------------------
        function obj = autofillCharger(obj, varargin)
        %AUTOFILLCHARGER  Re-derive only the charge parameters.
        %
        %   obj = obj.autofillCharger()
        %   obj = obj.autofillCharger('C_rate', 0.5)
        %
        %   Options are passed through to bcp.ChargerConfig.fromPack.
            args = varargin;
            if ~any(strcmp(args,'Ts'))
                args = [args, {'Ts', obj.Bms.Ts}];
            end
            obj.Charger = bcp.ChargerConfig.fromPack(obj.Pack, args{:});
            obj = obj.sync();
        end

        % -----------------------------------------------------------------
        function obj = sync(obj)
        %SYNC  Push the shared facts into every object that holds a copy.
        %
        %   SeriesCount lives in three places because each block needs it at
        %   run time and neither block can see the others. This is the one
        %   function allowed to write it, and it runs on every mutation.
            S = obj.Pack.S;
            obj.Bms.SeriesCount     = S;
            obj.Charger.SeriesCount = S;

            % V_cv_pack is the per-cell target restated at pack level, so a
            % change of S invalidates it outright -- a 14S target left behind on
            % a 20S pack is 26 V low, the pack loop binds permanently, and the
            % charge stops a quarter of the way up with nothing looking wrong.
            % Rescale rather than warn: there is no reading of the old number
            % that is still correct.
            expect = obj.Charger.V_cv_cell * S;
            if abs(obj.Charger.V_cv_pack - expect) > 0.05 * expect
                fprintf(['[bcp] Pack CV target rescaled %.2f V -> %.2f V for the ', ...
                         'new %dS topology.\n'], obj.Charger.V_cv_pack, expect, S);
                obj.Charger.V_cv_pack = expect;
            end
            obj.Bms     = obj.Bms.validate();
            obj.Charger = obj.Charger.validate();
            obj.Load    = obj.Load.validate();
        end

        % -----------------------------------------------------------------
        function issues = check(obj)
        %CHECK  Cross-object consistency. Returns a cellstr; empty means clean.
        %
        %   Each object validates itself on construction. What only this level
        %   can see is the combinations -- a charge current above the BMS trip,
        %   a load the pack cannot supply, a charge that cannot finish inside
        %   the simulation. Those are the ones that produce a run that looks
        %   fine and answers a different question than the one you asked.
            issues = {};
            p = obj.Pack; b = obj.Bms; c = obj.Charger; L = obj.Load;

            if c.I_cc_A > b.I_chg_trip * b.I_chg_margin + 1e-9
                issues{end+1} = sprintf( ...
                    ['Charger CC is %.2f A but the BMS will only permit %.2f A ', ...
                     '(%.0f%% of the %.1f A trip). The charge will be derated and ', ...
                     'never reach CC. Lower I_cc_A or raise I_chg_trip.'], ...
                    c.I_cc_A, b.I_chg_trip*b.I_chg_margin, b.I_chg_margin*100, ...
                    b.I_chg_trip);
            end
            if c.I_cc_A > p.I_chg_max_A + 1e-9
                issues{end+1} = sprintf( ...
                    ['Charger CC is %.2f A, above the %.1f A datasheet maximum for ', ...
                     '%s %dS%dP.'], c.I_cc_A, p.I_chg_max_A, p.Cell.Name, p.S, p.P);
            end
            if c.V_cv_cell <= b.V_ov_trip && b.V_ov_trip - c.V_cv_cell < 0.02
                issues{end+1} = sprintf( ...
                    ['The over-voltage trip (%.3f V) is only %.0f mV above the CV ', ...
                     'target (%.3f V). Every charge that succeeds will trip ', ...
                     'protection at the moment it succeeds. Leave 20-50 mV: a trip ', ...
                     'is a fault threshold, not the operating limit.'], ...
                    b.V_ov_trip, (b.V_ov_trip - c.V_cv_cell)*1000, c.V_cv_cell);
            elseif c.V_cv_cell > b.V_ov_trip
                issues{end+1} = sprintf( ...
                    ['The CV target (%.3f V) is ABOVE the over-voltage trip (%.3f V). ', ...
                     'Every charge ends in a fault.'], c.V_cv_cell, b.V_ov_trip);
            end
            if c.V_recharge_cell > b.V_recharge + 1e-9
                issues{end+1} = sprintf( ...
                    ['The charger re-arms below %.3f V/cell but the BMS only clears ', ...
                     'its completion latch below %.3f V/cell, so the BMS gate is the ', ...
                     'binding one and the charger threshold does nothing.'], ...
                    c.V_recharge_cell, b.V_recharge);
            end

            peakI = L.peakDemand() / max(p.V_min, 1);
            if peakI > b.I_dch_trip
                issues{end+1} = sprintf( ...
                    ['The load peaks at %.0f W, about %.0f A at the empty-pack voltage ', ...
                     'of %.1f V. That is above the %.0f A discharge trip, so the load ', ...
                     'will fault the pack out rather than test it.'], ...
                    L.peakDemand(), peakI, p.V_min, b.I_dch_trip);
            end
            if L.peakDemand() > p.P_dch_W
                issues{end+1} = sprintf( ...
                    ['The load peaks at %.0f W but %s %dS%dP is rated for about ', ...
                     '%.0f W continuous. Fine for a short pulse, not for a ', ...
                     'constant load.'], L.peakDemand(), p.Cell.Name, p.S, p.P, ...
                    p.P_dch_W);
            end

            if b.ChargeEnabled && ~b.AllowConcurrent && strcmp(L.Waveform,'constant') ...
                    && L.Const_W > L.IdleThreshold_W
                issues{end+1} = ...
                    ['A constant load never goes idle, and charging is set to strict ', ...
                     'load priority, so the charger can never run. That may be what ', ...
                     'you want; if not, use a pulse load or set AllowConcurrent.'];
            end
            if b.ChargeEnabled && strcmp(L.Waveform,'pulse') && ~b.AllowConcurrent
                gap = (1 - L.Pulse_Duty_pct/100) / max(L.Pulse_Frequency_Hz, eps);
                if gap <= b.t_quiet_s
                    issues{end+1} = sprintf( ...
                        ['The gap between pulses is %.3f s and the quiet dwell is ', ...
                         '%.3f s, so the charger never gets a window. Shorten ', ...
                         't_quiet_s below %.3f s, or lower the duty cycle.'], ...
                        gap, b.t_quiet_s, gap);
                end
            end
            if b.UseCharger && ~b.ChargeEnabled
                issues{end+1} = ...
                    ['The charger ports exist but ChargeEnabled is false, so the ', ...
                     'charger will sit at OFF for the whole run.'];
            end

            if abs(c.Ts - b.Ts) > 1e-12
                issues{end+1} = sprintf( ...
                    ['The BMS runs at %g s and the charger at %g s. Legal, but both ', ...
                     'must divide the model step and the charger then acts on ', ...
                     'stale permissions. Match them unless you have a reason.'], ...
                    b.Ts, c.Ts);
            end
        end

        % -----------------------------------------------------------------
        function report(obj)
        %REPORT  Everything, in the order you would explain it to someone.
            fprintf('\n=== bcp project ===\n');
            fprintf('%s', obj.Pack.summary());
            fprintf('\n');
            obj.Bms.report();
            fprintf('\n');
            obj.Charger.report();
            fprintf('\n');
            fprintf('Load: %s -- peak %.0f W, mean %.0f W, clamp [%.0f %.0f] W\n', ...
                obj.Load.Waveform, obj.Load.peakDemand(), obj.Load.meanDemand(), ...
                obj.Load.Pmin_W, obj.Load.Pmax_W);
            t = obj.Charger.estimatedChargeTime_h(obj.Pack) * 3600;
            fprintf('      CC-phase charge time from 20%% to 95%%: about %.0f s ', t);
            fprintf('(ignores the CV taper and any time the load steals)\n');

            issues = obj.check();
            if isempty(issues)
                fprintf('\nConsistency: clean.\n\n');
            else
                fprintf(2,'\nConsistency: %d issue(s):\n', numel(issues));
                for k = 1:numel(issues)
                    fprintf(2,'  %d. %s\n', k, issues{k});
                end
                fprintf('\n');
            end
        end

        % -----------------------------------------------------------------
        function paths = insertInto(obj, model, varargin)
        %INSERTINTO  Put both blocks into MODEL, replacing any earlier copies.
        %
        %   paths = obj.insertInto(model)
        %   paths = obj.insertInto(model, 'Charger', false)   % BMS only
        %
        %   Does NOT wire them to your battery model -- it cannot know which of
        %   your signals is which. It does wire the BMS and charger to each
        %   other, because that part is fixed. docs/INSTALL.md lists the five
        %   lines you draw.
            opt = struct('Charger', obj.Bms.UseCharger, 'Link', true, ...
                         'BmsPosition', [80 80 260 340], ...
                         'ChargerPosition', [80 420 260 580]);
            for k = 1:2:numel(varargin)
                assert(isfield(opt, varargin{k}), 'bcp:Project:Option', ...
                    'Unknown option "%s".', varargin{k});
                opt.(varargin{k}) = varargin{k+1};
            end

            issues = obj.check();
            if ~isempty(issues)
                warning('bcp:Project:Issues', ...
                    ['Inserting with %d unresolved consistency issue(s). Run ', ...
                     'p.report() to see them.'], numel(issues));
            end

            paths = struct('bms','','charger','');
            bb = bcp.BmsBuilder(obj.Bms, obj.Load);
            paths.bms = bb.insert(model, opt.BmsPosition);

            if opt.Charger
                cb = bcp.ChargerBuilder(obj.Charger);
                paths.charger = cb.insert(model, opt.ChargerPosition);
                if opt.Link
                    obj.linkBlocks(model, paths.bms, paths.charger);
                end
            end

            fprintf('\n[bcp] Now wire your battery model to the BMS block:\n');
            disp(bb.portMap());
            fprintf(['      ...and the BMS output P_load_cmd (or P_net_cmd) to your ', ...
                     'dynamic load.\n      Full procedure: docs/INSTALL.md\n\n']);
        end

        % -----------------------------------------------------------------
        function linkBlocks(obj, model, bmsPath, chgPath) %#ok<INUSL>
        %LINKBLOCKS  Wire the five lines between the BMS and the charger.
        %
        %   These five are fixed by the port contract, so there is no reason to
        %   ask you to draw them. Three go BMS -> charger (measurement,
        %   permission, ceiling) and two come back (charge power, done).
            b = get_param(bmsPath,'Name');
            c = get_param(chgPath,'Name');
            pairs = { ...
                {b,'pack_meas',   c,'pack_meas'}; ...
                {b,'chg_enable',  c,'enable'}; ...
                {b,'I_chg_limit', c,'I_limit'}; ...
                {c,'P_chg_cmd',   b,'P_chg'}; ...
                {c,'done',        b,'chg_done'}};
            n = 0;
            for k = 1:numel(pairs)
                p = pairs{k};
                try
                    add_line(model, ...
                        sprintf('%s/%d', p{1}, bcp.Project.portIndex(model, p{1}, 'out', p{2})), ...
                        sprintf('%s/%d', p{3}, bcp.Project.portIndex(model, p{3}, 'in',  p{4})), ...
                        'autorouting','on');
                    n = n + 1;
                catch ME
                    warning('bcp:Project:LinkFailed', ...
                        'Could not wire %s.%s -> %s.%s: %s', ...
                        p{1}, p{2}, p{3}, p{4}, ME.message);
                end
            end
            fprintf('[bcp] Wired %d of %d lines between the BMS and the charger.\n', ...
                n, numel(pairs));
        end

        % -----------------------------------------------------------------
        function info = verifyWiring(obj, model)
        %VERIFYWIRING  Compile the model and check the widths reaching the BMS.
        %
        %   This is the answer to "is my battery model's array one entry per
        %   cell or one per series element?". It compiles, reads the actual
        %   compiled port widths, and compares them against S*P and S. Nothing
        %   else in this package can tell you that, because before a compile
        %   nobody knows how wide those signals are.
        %
        %   Run it after wiring and before trusting a result.
            bmsPath = [model '/' 'BMS'];
            assert(getSimulinkBlockHandle(bmsPath) > 0, 'bcp:Project:NoBms', ...
                'No BMS block in "%s". Run insertInto first.', model);

            info = struct('ok', false, 'widths', [], 'layout', '', 'notes', {{}});
            cleanup = onCleanup(@() bcp.Project.terminateQuietly(model));
            feval(model, [], [], [], 'compile');
            w = get_param(bmsPath, 'CompiledPortWidths');
            info.widths = w.Inport;
            clear cleanup;

            nV = info.widths(1);
            info.layout = obj.Pack.classifyArray(nV);
            info.notes{end+1} = sprintf('V_cell arrives %d wide.', nV);

            switch info.layout
                case 'per-cell'
                    info.notes{end+1} = sprintf( ...
                        'That matches S*P = %d: one entry per cell. Correct.', ...
                        obj.Pack.NCells);
                    info.ok = true;
                case 'per-series'
                    info.notes{end+1} = sprintf( ...
                        ['That matches S = %d: one entry per series element, parallel ', ...
                         'strings lumped. Also correct -- mean()*S and sum()/S handle ', ...
                         'both layouts.'], obj.Pack.S);
                    info.ok = true;
                otherwise
                    info.notes{end+1} = sprintf( ...
                        ['That matches neither S*P = %d nor S = %d. SeriesCount is ', ...
                         'probably counting the wrong thing -- if these arrays are ', ...
                         'per-MODULE, set S and P to module counts and put the ', ...
                         'module''s parameters in PackSpec.Cell. Pack current is ', ...
                         'computed as sum(I)/S, so an S that counts the wrong thing ', ...
                         'scales every current in the BMS.'], ...
                        obj.Pack.NCells, obj.Pack.S);
            end

            if numel(info.widths) >= 3
                if ~isequal(info.widths(1), info.widths(2)) || ...
                   ~isequal(info.widths(1), info.widths(3))
                    info.ok = false;
                    info.notes{end+1} = sprintf( ...
                        ['V_cell, SOC_cell and I_cell arrive %d, %d and %d wide. ', ...
                         'They should all be the same width -- one of the three is ', ...
                         'wired to the wrong signal.'], info.widths(1:3));
                end
            end

            fprintf('\n=== BMS wiring check: %s ===\n', model);
            for k = 1:numel(info.notes)
                fprintf('  %s\n', info.notes{k});
            end
            if info.ok
                fprintf('  RESULT  ok\n\n');
            else
                fprintf(2,'  RESULT  check the notes above\n\n');
            end
        end

        % -----------------------------------------------------------------
        function save(obj, file)
        %SAVE  Write this configuration to a .mat file.
            bcpProject = obj; %#ok<NASGU>
            [d,~,~] = fileparts(file);
            if ~isempty(d) && ~isfolder(d), mkdir(d); end
            save(file, 'bcpProject');
            fprintf('[bcp] Configuration saved to %s\n', file);
        end
    end

    methods (Static)
        function obj = load(file)
        %LOAD  Read a configuration saved by save().
            assert(isfile(file), 'bcp:Project:NoFile', ...
                'No such file: %s', file);
            S = load(file, 'bcpProject');
            assert(isfield(S,'bcpProject'), 'bcp:Project:BadFile', ...
                '%s does not contain a bcp.Project.', file);
            obj = S.bcpProject;
        end

        function idx = portIndex(model, blockName, side, portName)
        %PORTINDEX  Find a subsystem port by NAME rather than by number.
        %
        %   The optional ports renumber when configuration changes, so wiring
        %   by index is wiring that silently moves. Names do not move.
            sys = [model '/' blockName];
            if strcmpi(side,'out')
                blocks = find_system(sys, 'SearchDepth',1, 'BlockType','Outport');
            else
                blocks = find_system(sys, 'SearchDepth',1, 'BlockType','Inport');
            end
            for k = 1:numel(blocks)
                if strcmp(get_param(blocks{k},'Name'), portName)
                    idx = str2double(get_param(blocks{k},'Port'));
                    return;
                end
            end
            error('bcp:Project:NoPort', ...
                'Block "%s" has no %sport named "%s".', blockName, lower(side), portName);
        end

        function terminateQuietly(model)
            try, feval(model, [], [], [], 'term'); catch, end
        end
    end
end
