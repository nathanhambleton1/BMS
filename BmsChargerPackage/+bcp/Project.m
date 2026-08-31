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
        function obj = setChargeCurrent(obj, I_A)
        %SETCHARGECURRENT  Change the charge rate. One call, whole system.
        %
        %   p = p.setChargeCurrent(13.5)     % amps at the pack terminals
        %
        %   THIS IS THE ONLY THING YOU SHOULD HAVE TO CHANGE TO CHARGE FASTER.
        %   It used to take five: the charger's I_cc_A and P_chg_max_W, the
        %   BMS's I_chg_trip and I_chg_margin, and sometimes I_precharge_A --
        %   spread across two generated blocks, with no error if you missed one,
        %   just a charge that quietly stayed at the old rate.
        %
        %   What it sets:
        %     Bms.I_chg_max_A   the rate itself, published to the charger
        %     Bms.I_chg_trip    sustained over-current trip, OC_trip_margin above it
        %     Bms.I_chg_peak_A  fast over-current trip, OC_peak_margin above it
        %     Charger.I_cc_A    raised if this supply could not source the rate
        %     Charger.P_chg_max_W  raised to match, so the power ceiling cannot
        %                       clip the new current
        %     Charger.I_precharge_A  clamped to stay at or below I_cc_A
        %
        %   Protection is not weakened: the trips move WITH the operating point
        %   and keep the same relationship to it. What it does do is let you ask
        %   for a rate the cell cannot take, so check() compares the result
        %   against the pack's datasheet maximum and says so.
            arguments
                obj
                I_A (1,1) double {mustBePositive}
            end
            obj.Bms = obj.Bms.setChargeLimit(I_A);

            % The supply must be able to source what the BMS now permits, or
            % the rate change silently does nothing.
            if obj.Charger.I_cc_A < I_A
                obj.Charger.I_cc_A = I_A;
            end
            obj.Charger.P_chg_max_W = max(obj.Charger.P_chg_max_W, ...
                                          obj.Charger.I_cc_A * obj.Pack.V_max);
            obj.Charger.I_precharge_A = min(obj.Charger.I_precharge_A, ...
                                            obj.Charger.I_cc_A);
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

            if b.I_chg_max_A > c.I_cc_A + 1e-9
                issues{end+1} = sprintf( ...
                    ['The BMS permits %.2f A of charge but the supply is only rated ', ...
                     'for %.2f A, so the supply is what limits this charge. Raise ', ...
                     'Charger.I_cc_A, or go through p.setChargeCurrent(), which ', ...
                     'moves both.'], b.I_chg_max_A, c.I_cc_A);
            end
            if b.I_chg_max_A * p.V_max > c.P_chg_max_W + 1e-9
                issues{end+1} = sprintf( ...
                    ['The %.0f W supply power ceiling binds before the %.2f A current ', ...
                     'limit does (%.2f A at the %.1f V full-pack voltage needs ', ...
                     '%.0f W). The charge will taper for a reason that is not the ', ...
                     'cell.'], c.P_chg_max_W, b.I_chg_max_A, b.I_chg_max_A, ...
                    p.V_max, b.I_chg_max_A * p.V_max);
            end
            if b.I_chg_max_A > p.I_chg_max_A + 1e-9
                issues{end+1} = sprintf( ...
                    ['The BMS permits %.2f A of charge, above the %.1f A datasheet ', ...
                     'maximum for %s %dS%dP.'], b.I_chg_max_A, p.I_chg_max_A, ...
                    p.Cell.Name, p.S, p.P);
            elseif b.I_chg_max_A > p.I_chg_std_A + 1e-9 && ~b.UseTemperature
                issues{end+1} = sprintf( ...
                    ['Charging at %.2f A is above the %.1f A datasheet standard ', ...
                     'charge and the BMS has no temperature input, so the cutoff ', ...
                     'the datasheet qualifies that rate with is not being enforced. ', ...
                     'Legal in simulation; say so when you report the result.'], ...
                    b.I_chg_max_A, p.I_chg_std_A);
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
            if peakI > b.I_dch_peak_A
                issues{end+1} = sprintf( ...
                    ['The load peaks at %.0f W, about %.0f A at the empty-pack voltage ', ...
                     'of %.1f V. That is above the %.0f A FAST discharge trip, which ', ...
                     'confirms in %.2f s, so the load will fault the pack out rather ', ...
                     'than test it.'], ...
                    L.peakDemand(), peakI, p.V_min, b.I_dch_peak_A, b.t_i_trip);
            elseif peakI > b.I_dch_trip
                pulseLen = 0;
                if strcmp(L.Waveform,'pulse') && L.Pulse_Frequency_Hz > 0
                    pulseLen = (L.Pulse_Duty_pct/100) / L.Pulse_Frequency_Hz;
                end
                if pulseLen >= b.t_i_cont_s || ~strcmp(L.Waveform,'pulse')
                    issues{end+1} = sprintf( ...
                        ['The load draws about %.0f A, above the %.0f A sustained ', ...
                         'discharge trip, for longer than the %.1f s that trip ', ...
                         'confirms over. It will latch.'], ...
                        peakI, b.I_dch_trip, b.t_i_cont_s);
                end
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

            % --- the load limiter, and what it needs from the rest -------------
            if ~b.UseLoadLimiter
                issues{end+1} = ...
                    ['UseLoadLimiter is off, so the only thing limiting the ', ...
                     'discharge is the trip. On a constant-power load that is a ', ...
                     'bang-bang loop -- cutting the load removes the sag that ', ...
                     'tripped it, the fault clears, the load returns and sags ', ...
                     'deeper -- and near the end of discharge it does not settle. ', ...
                     'Turn it on unless you are reproducing an older result.'];
            else
                % The limiter can only act on the sample AFTER the demand
                % changes, and the measurement it acts on is a sample old
                % already, so a hard edge gets two samples of full demand
                % whatever the fall rate. On a pack near its maximum power point
                % two samples is enough to reach the trip.
                %
                % Only worth saying when the demand is large enough RELATIVE TO
                % THE PACK for two samples to matter. A 800 W pulse on an 11 kW
                % pack sags it by a couple of percent and a step edge is
                % harmless; a 31 kW pulse on the same 31 kW pack is a different
                % question, and it is the ratio that separates them.
                pk    = L.peakDemand();
                stiff = pk > 0.5 * p.P_dch_W;
                if L.Slew_W_per_s <= 0 && stiff
                    edgeSamples = 2;
                    issues{end+1} = sprintf( ...
                        ['The load has hard edges (Slew_W_per_s = 0) and peaks at ', ...
                         '%.0f W, which is %.0f%% of this pack''s %.0f W continuous ', ...
                         'discharge rating. The limiter reads a one-sample-old ', ...
                         'measurement and can only respond on the next sample, so ', ...
                         'a step gets %d samples (%.0f ms) of FULL demand before ', ...
                         'any derating happens -- which near the end of discharge ', ...
                         'is enough to reach the trip the limiter exists to avoid. ', ...
                         'Set Slew_W_per_s to about %.3g -- a five-sample ', ...
                         '(%.0f ms) edge -- so the limiter can walk down the ramp ', ...
                         'with it.'], ...
                        pk, 100*pk/p.P_dch_W, p.P_dch_W, ...
                        edgeSamples, 1000*edgeSamples*b.Ts, ...
                        pk/(5*b.Ts), 5000*b.Ts);
                elseif L.Slew_W_per_s > 0 && stiff
                    rise_s = pk / L.Slew_W_per_s;
                    if rise_s < 4*b.Ts
                        issues{end+1} = sprintf( ...
                            ['The load slew gives a %.1f ms edge. The limiter has ', ...
                             'two samples of loop latency (%.1f ms), so an edge ', ...
                             'shorter than four samples (%.1f ms) reaches full ', ...
                             'demand before it has responded to any part of it -- ', ...
                             'a step, as far as the limiter is concerned.'], ...
                            1000*rise_s, 2000*b.Ts, 4000*b.Ts);
                    end
                end
            end

            if b.Q_uv_reset_Ah > 0 && (~b.ChargeEnabled || ~b.UseCharger)
                issues{end+1} = sprintf( ...
                    ['An under-voltage latch needs %.4f Ah of charge before it will ', ...
                     'clear, and this configuration has no charger running ', ...
                     '(ChargeEnabled = %d, UseCharger = %d). So the first ', ...
                     'under-voltage event ends the discharge for the rest of the ', ...
                     'run. That is the correct end of a discharge test -- the pack ', ...
                     'is empty -- but if you wanted it to keep cycling, set ', ...
                     'Q_uv_reset_Ah to 0 or enable the charger.'], ...
                    b.Q_uv_reset_Ah, b.ChargeEnabled, b.UseCharger);
            end

            if isfinite(b.N_retry_max) && ~b.AutoRecover
                issues{end+1} = sprintf( ...
                    ['N_retry_max is %g but AutoRecover is off, so nothing ever ', ...
                     'recovers automatically and the retry counter can never ', ...
                     'advance. The lockout is unreachable and redundant here.'], ...
                    b.N_retry_max);
            end

            % The limiter regulates the lowest cell into the band just above the
            % under-voltage trip, so a charger that re-arms below the top of that
            % band would be fighting it.
            if b.UseLoadLimiter && c.V_recharge_cell < b.V_fold_start()
                issues{end+1} = sprintf( ...
                    ['The charger re-arms below %.3f V/cell, inside the load ', ...
                     'limiter''s foldback band (%.3f .. %.3f V). The limiter is ', ...
                     'holding the pack in that band on purpose during a deep ', ...
                     'discharge, so the two will interact. Usually harmless; ', ...
                     'mention it if the charge behaviour near empty looks odd.'], ...
                    c.V_recharge_cell, b.V_fold_end(), b.V_fold_start());
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
            % Computed from the current that will actually flow -- the lower
            % of what the BMS permits and what the supply can source.
            t = (0.95 - 0.20) * obj.Pack.Q_Ah / obj.chargeCurrent() * 3600;
            fprintf('Charge rate: %.2f A permitted by the BMS, %.2f A supply rating\n', ...
                obj.Bms.I_chg_max_A, obj.Charger.I_cc_A);
            fprintf('      CC-phase charge time from 20%% to 95%% at %.2f A: about %.0f s ', ...
                obj.chargeCurrent(), t);
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
        function I = chargeCurrent(obj)
        %CHARGECURRENT  The charge current this configuration will actually reach [A].
        %
        %   The BMS permits I_chg_max_A and the supply can source I_cc_A. The
        %   lower binds, and it is the lower one that every estimate here should
        %   be computed from -- reporting a charge time against a rate the
        %   hardware cannot deliver is how a run that behaved correctly looks
        %   like a failure.
            I = min(obj.Bms.I_chg_max_A, obj.Charger.I_cc_A);
        end

        % -----------------------------------------------------------------
        function model = stageBlocks(obj, modelName)
        %STAGEBLOCKS  Put both blocks, already wired to each other, in a scratch
        %   model, open it and select them -- ready for Ctrl+C.
        %
        %   model = p.stageBlocks()                 % 'bcp_blocks'
        %   model = p.stageBlocks('my_scratch')
        %
        %   This is the copy half of "copy the blocks into my own simulation".
        %   The paste half is Ctrl+V in your model, or p.insertInto(yourModel)
        %   if you would rather not leave MATLAB.
        %
        %   THE FIVE INTERNAL LINES COME WITH THEM, AND THAT IS THE POINT
        %     The BMS and charger talk to each other over five wires, three of
        %     which carry a vector or a limit that looks like any other number
        %     on the canvas. Copying the blocks separately and redrawing those by
        %     hand is where the diag output (17 wide) gets wired into the
        %     charger's pack_meas input (7 wide) and Simulink reports a width
        %     mismatch on a port neither block is really about. Copied as a pair,
        %     with the lines already drawn, there is nothing to get wrong: the
        %     only wires left are the ones to your battery and your load.
            if nargin < 2 || isempty(modelName), modelName = 'bcp_blocks'; end
            modelName = char(modelName);

            if bdIsLoaded(modelName), close_system(modelName, 0); end
            new_system(modelName);
            open_system(modelName);

            % A staging model is never simulated, but it still has to COMPILE
            % when it is pasted somewhere, and the blocks pin their own rates.
            % Matching the solver here means bcp.Rate.assertCompatible passes
            % during the insert instead of refusing it.
            set_param(modelName, 'SolverType','Fixed-step', ...
                      'Solver','FixedStepDiscrete', ...
                      'FixedStep', num2str(min(obj.Bms.Ts, obj.Charger.Ts), '%.12g'));

            paths = obj.insertInto(modelName, ...
                'BmsPosition',     [120  80 320 360], ...
                'ChargerPosition', [120 420 320 580]);

            try
                Simulink.BlockDiagram.arrangeSystem(modelName);
            catch
                % Cosmetic. Never fail a build over the auto-layout.
            end

            % Select the two blocks so Ctrl+C picks them up. Only the blocks --
            % a block_diagram has no Selected parameter of its own, and asking
            % for one is an error rather than a no-op.
            for f = {paths.bms, paths.charger}
                if ~isempty(f{1}) && getSimulinkBlockHandle(f{1}) > 0
                    set_param(f{1}, 'Selected', 'on');
                end
            end

            fprintf('\n[bcp] Both blocks are staged and selected in "%s".\n', modelName);
            fprintf('      Ctrl+C here, then Ctrl+V in your own model.\n');
            fprintf(['      The five BMS <-> charger lines come with them. What is ', ...
                     'left to draw\n      is your battery into the BMS, and the ', ...
                     'BMS load command out to your load.\n']);
            fprintf(['      Both blocks are self-contained: their alg/ code is ', ...
                     'pasted in as local\n      functions, so the model compiles ', ...
                     'with nothing else from this package on\n      the path.\n\n']);
            model = modelName;
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
