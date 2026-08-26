classdef BmsBuilder < handle
%BCP.BMSBUILDER  Insert the BMS block into an existing battery model.
%
%   USAGE
%       b = bcp.BmsBuilder(bmsCfg, loadSignal);
%       b.insert('myBatteryModel');
%
%   insert() IS REPEATABLE. It deletes any previous BMS block of the same name
%   first, so changing a threshold and re-inserting is the normal edit cycle --
%   it will not accumulate copies. It does mean re-inserting drops the wires you
%   drew to the block, which is why the ports are stable: same names, same
%   order, so redrawing five lines is the whole cost of a reconfiguration.
%
%   WHAT GOES IN THE BLOCK
%     One MATLAB Function block, BMS_core, running at Ts. Its signature is
%     FIXED regardless of configuration -- optional inputs become internal
%     constants rather than changing the signature -- so there is exactly one
%     code path to get right, and enabling the temperature input is a wiring
%     change instead of a code-generation change.
%
%     Around it: a Digital Clock at Ts driving the load waveform, and a Unit
%     Delay on every measurement input.
%
%   THE UNIT DELAYS ARE THE POINT, NOT AN IMPLEMENTATION DETAIL
%     This block reads pack voltage and current, and commands the load power
%     that determines them. Wired directly, that is an algebraic loop:
%     Simulink either refuses to compile ("cannot be solved... algebraic loop")
%     or solves it iteratively at every step, which is slow and can fail to
%     converge on a stiff pack model. A Unit Delay at each measurement input
%     cuts the loop at the sensor, which is also where a real BMS cuts it: a
%     controller acts on the previous conversion, never on the present instant.
%
%     They live INSIDE the block on purpose. Delays you have to remember to add
%     outside are delays someone forgets, and the failure shows up as a compile
%     error three weeks later in a model nobody has touched.
%
%   PORTS
%     In    1 V_cell     vector  per-cell voltage [V]
%           2 SOC_cell   vector  per-cell state of charge
%           3 I_cell     vector  per-cell current [A] (your model's polarity)
%           4 T_cell     vector  temperature [degC]     -- if UseTemperature
%           5 P_chg      scalar  charge power from the charger [W] -- if UseCharger
%           6 chg_done   scalar  charger termination flag         -- if UseCharger
%           7 reset      scalar  rising edge clears latched faults -- if UseResetPort
%
%     Out   1 P_load_cmd  load demand [W]  ->  your dynamic load block
%           2 P_net_cmd   load minus charge [W]  ->  a bidirectional load block
%           3 chg_enable  ->  charger
%           4 I_chg_limit ->  charger
%           5 pack_meas   7-vector, see bcp.Signals  ->  charger and scopes
%           6 contactor
%           7 state       0 INIT | 1 IDLE | 2 CHARGE | 3 DISCHARGE | 4 FAULT
%           8 faults      latched bitmask: 1 OV, 2 UV, 4 OCc, 8 OCd, 16 OT, 32 UTc
%           9 diag        10-vector, see bcp.Signals.diagNames()
%
%     Use output 1 OR output 2, not both. Output 1 is the load demand on its
%     own, for a load block that can only sink; wire the charger to its own
%     current source in that case. Output 2 already has the charge power
%     subtracted, for a block that can source and sink -- one wire does
%     everything, and it is the simpler installation.

    properties
        Cfg        % bcp.BmsConfig
        Load       % bcp.LoadSignal
        BlockName  char = 'BMS'
    end

    properties (SetAccess = private)
        Path      char = ''      % full path of the inserted block
        Model     char = ''
    end

    methods
        function obj = BmsBuilder(bmsCfg, loadSignal, blockName)
            arguments
                bmsCfg     (1,1) bcp.BmsConfig
                loadSignal (1,1) bcp.LoadSignal
                blockName        char = 'BMS'
            end
            obj.Cfg       = bmsCfg.validate();
            obj.Load      = loadSignal.validate();
            obj.BlockName = blockName;
        end

        % -----------------------------------------------------------------
        function path = insert(obj, model, position)
        %INSERT  Add (or replace) the BMS block in MODEL.
            arguments
                obj
                model    char
                position double = [80 80 260 320]
            end
            assert(bdIsLoaded(model), 'bcp:BmsBuilder:NotLoaded', ...
                'Model "%s" is not open. open_system(''%s'') first.', model, model);

            bcp.Rate.assertCompatible(model, obj.Cfg.Ts);

            obj.Model = model;
            sys = [model '/' obj.BlockName];
            existed = getSimulinkBlockHandle(sys) > 0;
            if existed
                bcp.Blocks.removeIfPresent(sys);
            end

            obj.Path = bcp.Blocks.newSubsystem(model, obj.BlockName, position);
            obj.buildContents();
            obj.annotate();

            if existed
                fprintf('[bcp] BMS block REPLACED in "%s" -- redraw its wires.\n', model);
            else
                fprintf('[bcp] BMS block inserted into "%s".\n', model);
            end
            obj.Cfg.report();
            fprintf('     load: %s, peak %.0f W, mean %.0f W\n', ...
                obj.Load.Waveform, obj.Load.peakDemand(), obj.Load.meanDemand());
            path = obj.Path;
        end

        % -----------------------------------------------------------------
        function T = portMap(obj)
        %PORTMAP  Which inport index is which, for this configuration.
        %   The optional ports renumber when you enable or disable them, so this
        %   is the table to check before drawing lines rather than after.
            names = {'V_cell';'SOC_cell';'I_cell'};
            roles = {'per-cell voltage [V]'; 'per-cell SOC'; ...
                     'per-cell current [A], your model''s polarity'};
            if obj.Cfg.UseTemperature
                names{end+1} = 'T_cell';   roles{end+1} = 'per-cell temperature [degC]';
            end
            if obj.Cfg.UseCharger
                names{end+1} = 'P_chg';    roles{end+1} = 'from charger P_chg_cmd [W]';
                names{end+1} = 'chg_done'; roles{end+1} = 'from charger done';
            end
            if obj.Cfg.UseResetPort
                names{end+1} = 'reset';    roles{end+1} = 'rising edge clears faults';
            end
            T = table((1:numel(names))', names, roles, ...
                'VariableNames', {'Inport','Name','Meaning'});
        end
    end

    % =====================================================================
    methods (Access = private)

        function buildContents(obj)
            sys = obj.Path;
            c   = obj.Cfg;
            Ts  = c.Ts;

            % --- the core block first: its port count comes from the generated
            %     signature, so it must exist before anything is wired to it.
            core = bcp.Blocks.add(sys, 'MLFcn', 'BMS_core', [420 60 620 460]);
            bcp.Blocks.setMLFcn(core, obj.coreCode(), Ts);
            bcp.Blocks.assertPorts(core, 8, 9);

            % --- time base ---------------------------------------------------
            %  Digital Clock, not Clock. Clock is continuous, and driving a
            %  discrete chart from it makes the chart's rate a negotiation
            %  rather than a setting.
            clk = bcp.Blocks.add(sys, 'DigitalClock', 't', [300 60 340 90]);
            bcp.Blocks.safeSet(clk, {'SampleTime','sampletime'}, ...
                bcp.Blocks.literal(Ts));
            bcp.Blocks.link(sys, clk, 1, core, 1);

            % --- measurement inputs -----------------------------------------
            %  The initial conditions are DERIVED, not chosen. Whatever a delay
            %  holds at t=0 is what protection and arbitration see for the first
            %  sample, so an initial condition that resembles a fault produces a
            %  fault. Zero volts is the obvious trap: it reads as a dead short
            %  and starts the under-voltage dwell timer on every single run.
            %  See initialConditions() for how each one is pinned to the middle
            %  of a band that cannot latch anything.
            ic  = obj.initialConditions();
            idx = 0;
            y   = 130;
            idx = idx + 1;
            obj.measurementInput(sys, 'V_cell', idx, y, core, 2, ic.V);
            idx = idx + 1; y = y + 70;
            obj.measurementInput(sys, 'SOC_cell', idx, y, core, 3, ic.SOC);
            idx = idx + 1; y = y + 70;
            obj.measurementInput(sys, 'I_cell', idx, y, core, 4, '0');

            y = y + 70;
            if c.UseTemperature
                idx = idx + 1;
                obj.measurementInput(sys, 'T_cell', idx, y, core, 5, '25');
            else
                % Not a stub pretending to be a thermal model: a visible
                % constant, so the OT/UT paths are present and demonstrably
                % inert until something real drives them.
                k = bcp.Blocks.add(sys, 'Constant', 'T_held_25C', [300 y 360 y+30]);
                set_param(k, 'Value', '25');
                bcp.Blocks.link(sys, k, 1, core, 5);
            end

            y = y + 70;
            if c.UseCharger
                idx = idx + 1;
                obj.measurementInput(sys, 'P_chg', idx, y, core, 6, '0');
                idx = idx + 1; y = y + 70;
                obj.measurementInput(sys, 'chg_done', idx, y, core, 7, '0');
            else
                k = bcp.Blocks.add(sys, 'Constant', 'P_chg_none', [300 y 360 y+30]);
                set_param(k, 'Value', '0');
                bcp.Blocks.link(sys, k, 1, core, 6);
                k2 = bcp.Blocks.add(sys, 'Constant', 'chg_done_none', [300 y+70 360 y+100]);
                set_param(k2, 'Value', '0');
                bcp.Blocks.link(sys, k2, 1, core, 7);
                y = y + 70;
            end

            y = y + 70;
            if c.UseResetPort
                % No delay on reset. It is an operator command, not a
                % measurement, so it closes no loop -- and delaying an
                % acknowledgement is just latency.
                idx = idx + 1;
                p = bcp.Blocks.inport(sys, 'reset', idx, [180 y 200 y+20]);
                bcp.Blocks.link(sys, p, 1, core, 8);
            else
                k = bcp.Blocks.add(sys, 'Constant', 'no_reset', [300 y 360 y+30]);
                set_param(k, 'Value', '0');
                bcp.Blocks.link(sys, k, 1, core, 8);
            end

            % --- outputs -----------------------------------------------------
            outs = {'P_load_cmd','P_net_cmd','chg_enable','I_chg_limit', ...
                    'pack_meas','contactor','state','faults','diag'};
            for k = 1:numel(outs)
                yy = 60 + 45*(k-1);
                o = bcp.Blocks.outport(sys, outs{k}, k, [740 yy 760 yy+20]);
                l = bcp.Blocks.link(sys, core, k, o, 1);
                if obj.Cfg.LogSignals
                    bcp.Blocks.logSignal(l, ['bms_' outs{k}]);
                else
                    set_param(l, 'Name', outs{k});
                end
            end
        end

        % -----------------------------------------------------------------
        function ic = initialConditions(obj)
        %INITIALCONDITIONS  What the input delays hold before the first conversion.
        %
        %   Each one is placed in the middle of a band that provably cannot
        %   latch anything, so t=0 never manufactures a fault or a completed
        %   charge:
        %
        %     V   halfway between the OV and UV CLEAR thresholds. validate()
        %         already guarantees V_uv_clear < V_uv_trip is false and
        %         V_ov_clear < V_ov_trip, so the midpoint of the clear
        %         thresholds is inside the no-fault window by construction --
        %         for any cell chemistry, without this builder knowing which.
        %
        %     SOC below SOC_restart, so the arbiter's completion latch cannot
        %         arm on the first sample. A latch armed at t=0 needs the pack
        %         to be discharged below SOC_restart before it will ever charge,
        %         which on a full-ish pack means never.
        %
        %   Both are wrong by construction -- they are guesses standing in for a
        %   measurement that has not happened yet. They are wrong for exactly one
        %   sample, in a direction that does nothing.
            c = obj.Cfg;
            ic.V   = bcp.Blocks.literal((c.V_ov_clear + c.V_uv_clear) / 2);
            ic.SOC = bcp.Blocks.literal(min(0.5, 0.9 * c.SOC_restart));
        end

        % -----------------------------------------------------------------
        function measurementInput(obj, sys, name, portIdx, y, core, corePort, x0)
        %MEASUREMENTINPUT  An inport, optionally through a Unit Delay, into the core.
            p = bcp.Blocks.inport(sys, name, portIdx, [180 y 200 y+20]);
            if obj.Cfg.BreakFeedbackLoops
                d = bcp.Blocks.add(sys, 'UnitDelay', [name '_z1'], ...
                    [270 y-5 330 y+30]);
                bcp.Blocks.safeSet(d, {'SampleTime','sampletime'}, ...
                    bcp.Blocks.literal(obj.Cfg.Ts));
                % Scalar initial condition, scalar-expanded across the vector.
                % It is the value the BMS believes at t=0, before the first
                % conversion -- keep it plausible, because protection sees it.
                bcp.Blocks.safeSet(d, {'InitialCondition','X0'}, x0);
                bcp.Blocks.link(sys, p, 1, d, 1);
                bcp.Blocks.link(sys, d, 1, core, corePort);
            else
                bcp.Blocks.link(sys, p, 1, core, corePort);
            end
        end

        % -----------------------------------------------------------------
        function annotate(obj)
        %ANNOTATE  Leave the wiring contract on the canvas, next to the block.
            c = obj.Cfg;
            if c.AllowConcurrent
                pri = 'charger may run under load (derated)';
            else
                pri = sprintf('LOAD FIRST: no charge until %.2f s idle', c.t_quiet_s);
            end
            txt = sprintf([ ...
                'BMS  (bcp.BmsBuilder, Ts = %g s)\\n' ...
                '%s\\n' ...
                'Out 1 P_load_cmd  -> unidirectional load block\\n' ...
                'Out 2 P_net_cmd   -> bidirectional load block (load - charge)\\n' ...
                'Use one or the other, never both.\\n' ...
                'Needs bcp_setup on the MATLAB path to compile.'], ...
                c.Ts, pri);
            try
                pos = get_param(obj.Path,'Position');
                a = Simulink.Annotation([obj.Model '/BMS_notes']);
                a.Text = strrep(txt, '\n', newline);
                a.Position = [pos(1), pos(4)+20];
            catch
                % Annotations are a convenience. Never fail a build over one.
            end
        end

        % =================================================================
        function s = coreCode(obj)
        %CORECODE  The generated BMS_core script.
        %
        %   Fixed signature, whatever the configuration. Options are wiring:
        %   a disabled temperature input is a constant on port 5, not a
        %   different function. One signature means one thing to keep correct.
            c = obj.Cfg;
            mon  = bcp.Blocks.structLiteral(c.monitorParams(),    '        ');
            pro  = bcp.Blocks.structLiteral(c.protectionParams(), '        ');
            arb  = bcp.Blocks.structLiteral(c.arbiterParams(),    '        ');
            ldp  = bcp.Blocks.structLiteral(obj.Load.params(c.Ts),'        ');
            sgn  = bcp.Blocks.literal(obj.Load.OutputSign);

            s = sprintf([ ...
'function [P_load_cmd, P_net_cmd, chg_enable, I_chg_limit, pack_meas, ...\n' ...
'          contactor, state, faults, diag] = ...\n' ...
'        fcn(t, Vcell, SOCcell, Icell, Tmax, P_chg, chg_done, reset)\n' ...
'%%#codegen\n' ...
'%%BMS_CORE  Generated by bcp.BmsBuilder. Do not edit here.\n' ...
'%%\n' ...
'%%  Edit bcp.BmsConfig / bcp.LoadSignal (or the Load and BMS tabs of bcpApp)\n' ...
'%%  and re-insert the block. Changes made in this window are overwritten by\n' ...
'%%  the next insert, and are invisible to the tests.\n' ...
'%%\n' ...
'%%  Sign convention inside this function: POSITIVE CURRENT = CHARGING.\n' ...
'%%  Load power is DRAW-POSITIVE. The two meet at P_net_cmd.\n' ...
'\n' ...
'MON = %s;\n' ...
'PRO = %s;\n' ...
'ARB = %s;\n' ...
'LOAD = %s;\n' ...
'OUT_SIGN = %s;\n' ...
'\n' ...
'%%  1. Reduce the per-cell arrays to pack scalars.\n' ...
'pack_meas = bcp_pack_monitor(Vcell, SOCcell, Icell, MON);\n' ...
'\n' ...
'%%  2. What does the load waveform ask for at this instant?\n' ...
'[P_demand, demandPresent] = bcp_load_scheduler(t, LOAD);\n' ...
'\n' ...
'%%  3. Protection, on the pack extremes.\n' ...
'[contactor, chg_ok, dch_ok, state, faults, flags] = bcp_protection( ...\n' ...
'    pack_meas(2), pack_meas(3), Tmax, pack_meas(7), reset > 0.5, PRO);\n' ...
'\n' ...
'%%  4. A discharge inhibit has to inhibit the discharge. The load is the only\n' ...
'%%     discharge path in this model, so dch_ok gates the load command -- and\n' ...
'%%     the GATED value is what counts as "the load is active".\n' ...
'%%\n' ...
'%%     Order matters here. Feeding the ungated demand to the arbiter would\n' ...
'%%     mean an under-voltage fault holds the load flag high, the arbiter sees\n' ...
'%%     a busy load and refuses to charge, and the pack sits at its floor\n' ...
'%%     forever -- deadlocked by its own protection, with a charger idle beside\n' ...
'%%     it. The cure for under-voltage is a charge.\n' ...
'if dch_ok < 0.5\n' ...
'    P_load = 0;\n' ...
'else\n' ...
'    P_load = P_demand;\n' ...
'end\n' ...
'loadActive = double(abs(P_load) > LOAD.IdleThreshold_W);\n' ...
'\n' ...
'%%  5. Arbitrate. The load has already happened; this decides what is left.\n' ...
'[chg_enable, I_chg_limit, reason] = bcp_arbiter( ...\n' ...
'    loadActive, pack_meas(4), pack_meas(3), chg_ok, chg_done, ARB);\n' ...
'\n' ...
'%%  6. Shape the outputs.\n' ...
'P_load_cmd = OUT_SIGN * P_load;\n' ...
'P_net_cmd  = OUT_SIGN * (P_load - P_chg);\n' ...
'\n' ...
'diag = [demandPresent; loadActive; reason; dch_ok; flags];\n' ...
'end\n'], mon, pro, arb, ldp, sgn);
        end
    end
end
