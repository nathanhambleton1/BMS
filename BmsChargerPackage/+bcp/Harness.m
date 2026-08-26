classdef Harness < handle
%BCP.HARNESS  A throwaway model that exercises both blocks without a real pack.
%
%       p = bcp.Project();
%       h = bcp.Harness(p);
%       h.build();
%       out = h.simulate(600);
%       h.plot(out);
%
%   WHY THIS EXISTS
%     Wiring two new blocks into a Simscape battery model means debugging the
%     blocks, the wiring, the sign conventions and the solver settings at the
%     same time, with a two-minute simulation between each attempt. This builds
%     a model containing the same two blocks and a crude resistive battery
%     stand-in, runs in about a second, needs no Simscape licence, and answers
%     the questions that are about the blocks rather than about your pack:
%
%       does the load waveform come out the way the preview said?
%       does the charger actually stay off while the load is pulsing?
%       does CC hand over to CV, and does the taper terminate?
%       does an over-voltage latch, and does a discharge clear it?
%
%     Get those right here, then install into the real model with the wiring
%     already proven. bcp_harness_plant is emphatic about what it is not.
%
%   SOLVER
%     Fixed-step discrete, single-tasking, with the plant ten times faster than
%     the BMS. Fixed-step on purpose: it is the case where sample-time mismatch
%     actually bites, so if your rates are wrong you find out here rather than
%     in the model you care about.

    properties
        Project      % bcp.Project
        ModelName char = 'bcp_harness'
        PlantRatio double = 10   % plant runs this many times faster than the BMS
        SOC_init   double = 0.40 % mean starting SOC of the stand-in pack
        SOC_spread double = 0.02 % cell-to-cell initial SOC spread (peak-to-peak)
        R_spread   double = 0.10 % cell-to-cell resistance spread (fraction)
        Seed       double = 7    % fixed, so a run is reproducible

        CellTables = bcp.CellTables.empty
        %  Optional bcp.CellTables. Empty (the default) gives the stand-in a
        %  generic NMC OCV curve and the flat datasheet resistance from
        %  PackSpec.Cell -- fine for proving the blocks, useless for comparing
        %  against a Simscape run. Supply the tables read out of your pack's
        %  generated .ssc and the harness and the real model are then computing
        %  from the same cell, so a disagreement between them is a finding
        %  rather than an artefact of two different curves.
    end

    properties (SetAccess = private)
        Built logical = false
    end

    methods
        function obj = Harness(project, varargin)
            arguments
                project (1,1) bcp.Project
            end
            arguments (Repeating)
                varargin
            end
            obj.Project = project;
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
        end

        % -----------------------------------------------------------------
        function model = build(obj)
        %BUILD  Create the harness model from scratch, replacing any old copy.
            model = obj.ModelName;
            if bdIsLoaded(model)
                close_system(model, 0);
            end
            new_system(model);
            open_system(model);

            % The PackSpec is authoritative for capacity, because that is what
            % every SOC percentage in the report is computed against. If the
            % tables were read from a different cell than the spec describes,
            % the run is comparing two packs and every SOC number is off by the
            % ratio -- silently, because nothing else can see both.
            if ~isempty(obj.CellTables) && ...
                    abs(obj.CellTables.Q_Ah - obj.Project.Pack.Cell.Q_Ah) > 1e-6
                warning('bcp:Harness:CapacityMismatch', ...
                    ['CellTables says %.4f Ah and PackSpec.Cell says %.4f Ah. The ' ...
                     'plant will use the PackSpec value. Build the spec with ' ...
                     'ct.toCellLibrary() so the two cannot disagree.'], ...
                    obj.CellTables.Q_Ah, obj.Project.Pack.Cell.Q_Ah);
            end

            Ts_bms   = obj.Project.Bms.Ts;
            Ts_plant = Ts_bms / obj.PlantRatio;

            obj.configureSolver(model, Ts_plant);
            obj.buildPlant(model, Ts_plant);

            paths = obj.Project.insertInto(model, ...
                'BmsPosition', [520 100 700 380], ...
                'ChargerPosition', [520 470 700 630]);

            obj.wirePlantToBms(model, paths);
            obj.addScopes(model);

            Simulink.BlockDiagram.arrangeSystem(model);
            obj.Built = true;

            fprintf(['[bcp] Harness "%s" built. Plant %g s, BMS %g s. ', ...
                     'Simulate with h.simulate(stopTime).\n'], ...
                model, Ts_plant, Ts_bms);
        end

        % -----------------------------------------------------------------
        function out = simulate(obj, stopTime)
        %SIMULATE  Run the harness. Returns a Simulink.SimulationOutput.
            if nargin < 2, stopTime = 600; end
            assert(bdIsLoaded(obj.ModelName), 'bcp:Harness:NotBuilt', ...
                'Run build() first.');
            set_param(obj.ModelName, 'StopTime', num2str(stopTime, '%.12g'));
            t0 = tic;
            out = sim(obj.ModelName);
            fprintf('[bcp] Harness simulated %g s in %.1f s wall clock.\n', ...
                stopTime, toc(t0));
        end

        % -----------------------------------------------------------------
        function f = plot(obj, out)
        %PLOT  The four panels that answer the questions this harness is for.
            g = @(n) out.logsout.getElement(n).Values;
            tt = @(s) s.Time;
            dd = @(s) squeeze(s.Data);

            Vc   = g('plant_V_cell');
            meas = g('bms_pack_meas');
            load = g('bms_P_load_cmd');
            net  = g('bms_P_net_cmd');
            diag = g('bms_diag');
            faults = g('bms_faults');

            M = dd(meas);
            if size(M,1) == bcp.Signals.NUM, M = M'; end
            D = dd(diag);
            if size(D,1) == 10, D = D'; end

            f = figure('Name',[obj.ModelName ' -- harness'],'Color','w', ...
                       'Position',[80 60 1000 820]);

            % --- 1. power: what was asked for, and what the pack got ---------
            ax1 = subplot(4,1,1);
            plot(ax1, tt(load), dd(load), 'LineWidth',1.2); hold(ax1,'on');
            plot(ax1, tt(net), dd(net), 'LineWidth',1.0);
            yline(ax1, 0, 'k:');
            grid(ax1,'on'); ylabel(ax1,'Power [W]');
            legend(ax1, {'P\_load\_cmd','P\_net\_cmd (load - charge)'}, ...
                'Location','best');
            title(ax1, sprintf('%s  --  %s load, %s %dS%dP', obj.ModelName, ...
                obj.Project.Load.Waveform, obj.Project.Pack.Cell.Name, ...
                obj.Project.Pack.S, obj.Project.Pack.P), 'Interpreter','none');

            % --- 2. cell voltages against the trips --------------------------
            ax2 = subplot(4,1,2);
            plot(ax2, tt(Vc), dd(Vc), 'LineWidth',0.8); hold(ax2,'on');
            yline(ax2, obj.Project.Bms.V_ov_trip, 'r--', 'OV trip');
            yline(ax2, obj.Project.Bms.V_uv_trip, 'r--', 'UV trip');
            yline(ax2, obj.Project.Charger.V_cv_cell, 'b:', 'CV target');
            grid(ax2,'on'); ylabel(ax2,'V_{cell} [V]');

            % --- 3. SOC and charge current -----------------------------------
            ax3 = subplot(4,1,3);
            yyaxis(ax3,'left');
            plot(ax3, tt(meas), M(:,bcp.Signals.SOC_PACK)*100, 'LineWidth',1.3);
            ylabel(ax3,'SOC [%]');
            yyaxis(ax3,'right');
            plot(ax3, tt(meas), M(:,bcp.Signals.I_PACK), 'LineWidth',1.0);
            ylabel(ax3,'I_{pack} [A]  (+ = charge)');
            yline(ax3, 0, 'k:');
            grid(ax3,'on');

            % --- 4. the arbitration story ------------------------------------
            ax4 = subplot(4,1,4);
            stairs(ax4, tt(diag), D(:,2), 'LineWidth',1.3); hold(ax4,'on');
            stairs(ax4, tt(diag), D(:,3), 'LineWidth',1.1);
            stairs(ax4, tt(faults), dd(faults), 'LineWidth',1.0);
            grid(ax4,'on'); xlabel(ax4,'Time [s]');
            ylabel(ax4,'code');
            legend(ax4, {'load\_active','arb\_reason','faults'}, 'Location','best');
            ylim(ax4, [-0.5 6]);

            linkaxes([ax1 ax2 ax3 ax4], 'x');
        end

        % -----------------------------------------------------------------
        function T = summary(obj, out)
        %SUMMARY  What actually happened, in words. Reading a scope is optional.
            g = @(n) out.logsout.getElement(n).Values;
            meas = g('bms_pack_meas');  M = squeeze(meas.Data);
            if size(M,1) == bcp.Signals.NUM, M = M'; end
            diag = g('bms_diag');       D = squeeze(diag.Data);
            if size(D,1) == 10, D = D'; end
            faults = squeeze(g('bms_faults').Data);

            % SOC read from the PLANT, not from the BMS. The BMS view is one
            % sample behind and its first sample is the input delay's initial
            % condition, so a summary built on bms_pack_meas reports whatever
            % that guess was as the starting SOC.
            socPlant = squeeze(g('plant_SOC_cell').Data);
            if size(socPlant,1) == obj.Project.Pack.S, socPlant = socPlant'; end
            socStart = mean(socPlant(1,:));
            socEnd   = mean(socPlant(end,:));
            loadDuty = mean(D(:,2));
            chgDuty  = mean(D(:,3) == 0);
            reasons  = unique(round(D(:,3)));
            rtxt = cell(numel(reasons),1);
            for k = 1:numel(reasons)
                rtxt{k} = sprintf('%d=%s (%.0f%%)', reasons(k), ...
                    bcp.Signals.arbReason(reasons(k)), ...
                    100*mean(round(D(:,3)) == reasons(k)));
            end

            fprintf('\n=== harness summary ===\n');
            fprintf('  SOC            %.1f%% -> %.1f%%\n', socStart*100, socEnd*100);
            fprintf('  cell voltage   %.3f .. %.3f V\n', ...
                min(M(:,bcp.Signals.V_MIN)), max(M(:,bcp.Signals.V_MAX)));
            fprintf('  pack current   %.1f .. %.1f A\n', ...
                min(M(:,bcp.Signals.I_PACK)), max(M(:,bcp.Signals.I_PACK)));
            fprintf('  load active    %.0f%% of the run\n', loadDuty*100);
            fprintf('  charge enabled %.0f%% of the run\n', chgDuty*100);
            fprintf('  arbitration    %s\n', strjoin(rtxt, ', '));
            fprintf('  faults latched %s\n', bcp.Signals.faultBits(max(faults)));
            fprintf('\n');

            T = table(socStart, socEnd, loadDuty, chgDuty, max(faults), ...
                'VariableNames', {'SOC_start','SOC_end','LoadDuty', ...
                                  'ChargeDuty','FaultMask'});
        end
    end

    % =====================================================================
    methods (Access = private)

        function configureSolver(~, model, Ts_plant)
            set_param(model, 'SolverType', 'Fixed-step');
            set_param(model, 'Solver', 'FixedStepDiscrete');
            set_param(model, 'FixedStep', num2str(Ts_plant, '%.12g'));
            set_param(model, 'StopTime', '600');
            % Single-tasking: the plant and the BMS run at different rates, and
            % in multitasking mode Simulink demands explicit Rate Transition
            % blocks between them. That is the right answer for generated
            % production code and pure noise for a test harness.
            for nv = {{'EnableMultiTasking','off'}, {'SolverMode','SingleTasking'}}
                try, set_param(model, nv{1}{1}, nv{1}{2}); break; catch, end
            end
            set_param(model, 'SignalLogging', 'on');
            set_param(model, 'SignalLoggingName', 'logsout');
        end

        % -----------------------------------------------------------------
        function buildPlant(obj, model, Ts_plant)
            spec = obj.Project.Pack;
            S = spec.S;

            % Reproducible spread. A pack whose cells are identical cannot tell
            % a per-cell CV loop from a pack-voltage one, so the spread is part
            % of the test, not decoration.
            rs = RandStream('twister','Seed',obj.Seed);
            soc0 = obj.SOC_init + obj.SOC_spread * (rand(rs, S, 1) - 0.5);
            soc0 = min(max(soc0, 0.02), 0.98);

            % Dimensionless per-element multiplier on whatever resistance curve
            % the plant ends up using, so the spread survives the switch from a
            % flat datasheet number to a real SOC-dependent table.
            R0scale = 1 + obj.R_spread * (rand(rs, S, 1) - 0.5);

            sys = bcp.Blocks.newSubsystem(model, 'Plant', [80 120 260 300]);

            core = bcp.Blocks.add(sys, 'MLFcn', 'Battery_standin', [300 80 500 260]);
            bcp.Blocks.setMLFcn(core, obj.plantCode(soc0, R0scale, Ts_plant), Ts_plant);
            bcp.Blocks.assertPorts(core, 1, 4);

            p = bcp.Blocks.inport(sys, 'P_net', 1, [180 130 200 150]);
            bcp.Blocks.link(sys, p, 1, core, 1);

            outs = {'V_cell','SOC_cell','I_cell','V_pack'};
            for k = 1:numel(outs)
                yy = 80 + 50*(k-1);
                o = bcp.Blocks.outport(sys, outs{k}, k, [600 yy 620 yy+20]);
                l = bcp.Blocks.link(sys, core, k, o, 1);
                bcp.Blocks.logSignal(l, ['plant_' outs{k}]);
            end
        end

        % -----------------------------------------------------------------
        function wirePlantToBms(~, model, paths)
            bms = get_param(paths.bms, 'Name');
            for k = 1:3
                add_line(model, sprintf('Plant/%d', k), ...
                                sprintf('%s/%d', bms, k), 'autorouting','on');
            end
            % The BMS closes the loop on the plant. P_net_cmd rather than
            % P_load_cmd, because the harness plant is bidirectional -- it is a
            % power sink that goes negative -- which is wiring option (a) from
            % docs/INSTALL.md and the one worth trying first.
            netIdx = bcp.Project.portIndex(model, bms, 'out', 'P_net_cmd');
            add_line(model, sprintf('%s/%d', bms, netIdx), 'Plant/1', ...
                'autorouting','on');
        end

        % -----------------------------------------------------------------
        function addScopes(~, model)
            % Nothing is wired to a scope. Every interesting line is already
            % marked for logging by the builders, and logsout survives the run
            % where a scope's buffer may not. bcp.Harness.plot reads logsout.
            set_param(model, 'ZoomFactor', 'FitSystem');
        end

        % -----------------------------------------------------------------
        function s = plantCode(obj, soc0, R0scale, Ts_plant)
            spec = obj.Project.Pack;

            if isempty(obj.CellTables)
                % OCV: a generic high-power NMC curve. Generic, not measured --
                % and that is fine when nothing in the run is a claim about a
                % cell. It is not fine the moment you compare against Simscape;
                % that is what the CellTables property is for.
                %
                % The bottom two breakpoints matter more than they look. An OCV
                % table that stops at 2.80 V cannot reach a 2.45 V under-voltage
                % trip no matter how hard you discharge it, because SOC clamps
                % at zero first -- so the protection layer tests as unreachable
                % and the whole under-voltage path goes unexercised. The cell's
                % discharge cutoff IS the voltage at 0% SOC by definition, so
                % the curve is carried down to 2.50 V through the knee at 2%.
                ocvSOC = [0.00 0.02 0.05 0.10 0.15 0.20 0.25 0.30 0.35 0.40 0.45 ...
                          0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95 1.00];
                ocvV   = [2.50 3.00 3.28 3.42 3.49 3.53 3.57 3.60 3.62 3.65 3.68 ...
                          3.71 3.75 3.79 3.84 3.89 3.95 4.00 4.06 4.11 4.16 4.20];
                % A two-point table holding the flat datasheet number. Same code
                % path as the real curve, so there is only one thing to be wrong.
                r0SOC = [0.00 1.00];
                r0TAB = (spec.Cell.R_dc_Ohm / spec.P) * [1 1];
            else
                ct     = obj.CellTables;
                ocvSOC = ct.SOC;
                ocvV   = ct.OCV_V;
                r0SOC  = ct.SOC;
                r0TAB  = ct.R0_Ohm / spec.P;   % P cells share the element current
            end

            P = struct( ...
                'Ts',       Ts_plant, ...
                'S',        spec.S, ...
                'Q_Ah',     spec.Cell.Q_Ah * spec.P, ...
                'R0_SOC',   r0SOC(:), ...
                'R0_TAB',   r0TAB(:), ...
                'R0_scale', R0scale(:), ...
                'SOC0',     soc0(:), ...
                'OCV_SOC',  ocvSOC(:), ...
                'OCV_V',    ocvV(:), ...
                'V_floor',  max(spec.V_min * 0.5, 1));

            s = sprintf([ ...
'function [Vcell, SOCcell, Icell, V_pack] = fcn(P_net)\n' ...
'%%#codegen\n' ...
'%%BATTERY_STANDIN  Generated by bcp.Harness. NOT A BATTERY MODEL.\n' ...
'%%\n' ...
'%%  A resistive first-order stand-in whose only job is to let the BMS and\n' ...
'%%  charger blocks be tested without a Simscape pack. See\n' ...
'%%  bcp_harness_plant for exactly what it does and does not represent.\n' ...
'%%\n' ...
'%%  One entry per SERIES ELEMENT with the parallel cells lumped, and the\n' ...
'%%  current array is DISCHARGE-positive -- both matching what a Battery\n' ...
'%%  Model Builder pack hands you, so that a sign or layout mistake in the\n' ...
'%%  default configuration surfaces here rather than in your real model.\n' ...
'\n' ...
'P = %s;\n' ...
'\n' ...
'[Vcell, SOCcell, Icell, V_pack] = bcp_harness_plant(P_net, P);\n' ...
'end\n'], bcp.Blocks.structLiteral(P, '        '));
        end
    end
end
