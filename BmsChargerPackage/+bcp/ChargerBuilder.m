classdef ChargerBuilder < handle
%BCP.CHARGERBUILDER  Insert the charger block into an existing battery model.
%
%   USAGE
%       spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
%       c    = bcp.ChargerBuilder(bcp.ChargerConfig.fromPack(spec));
%       c.insert('myBatteryModel');
%
%   Like bcp.BmsBuilder, insert() replaces any previous block of the same name,
%   so re-inserting is the normal way to apply a configuration change.
%
%   PORTS
%     In    1 pack_meas   7-vector from the BMS block's pack_meas output
%           2 enable      from the BMS block's chg_enable output
%           3 I_limit     from the BMS block's I_chg_limit output
%
%     Out   1 I_chg_cmd   commanded charge current [A], >= 0
%           2 P_chg_cmd   commanded charge power [W], >= 0  ->  back to the BMS
%           3 mode        0 OFF | 1 PRECHARGE | 2 CC | 3 CV | 4 DONE
%           4 V_set       the voltage the supply is programmed to [V]
%           5 I_set       the current the supply is programmed to [A]
%           6 done        1 once the taper has terminated  ->  back to the BMS
%
%   THE CHARGER TAKES ITS PERMISSION, IT DOES NOT TAKE ITS TURN
%     There is no load-priority logic in here. The BMS owns that decision and
%     expresses it as enable and I_limit, and this block does what it is told.
%     Two blocks both deciding when to charge is how you get a charger that
%     runs during a pulse because each one thought the other had yielded.
%
%   WHERE THE CURRENT ACTUALLY GOES
%     This block emits a command, not a current. Two ways to make it physical,
%     both in docs/INSTALL.md:
%
%       (a) Wire the BMS block's P_net_cmd -- which is already load minus
%           charge -- to a load block that can source as well as sink. One
%           wire, nothing else to build. Start here.
%
%       (b) Wire I_chg_cmd to a Controlled Current Source across the pack
%           terminals, through a Simulink-PS Converter. More faithful, because
%           the charger then has its own physical port and its own losses, and
%           necessary if your load block cannot source.
%
%     Either way the loop back to this block's pack_meas input is closed
%     through the battery, and the Unit Delays inside the block are what make
%     it solvable.

    properties
        Cfg        % bcp.ChargerConfig
        BlockName  char = 'Charger'
    end

    properties (SetAccess = private)
        Path  char = ''
        Model char = ''
    end

    methods
        function obj = ChargerBuilder(chargerCfg, blockName)
            arguments
                chargerCfg (1,1) bcp.ChargerConfig
                blockName        char = 'Charger'
            end
            obj.Cfg       = chargerCfg.validate();
            obj.BlockName = blockName;
        end

        % -----------------------------------------------------------------
        function path = insert(obj, model, position)
        %INSERT  Add (or replace) the charger block in MODEL.
            arguments
                obj
                model    char
                position double = [80 400 260 560]
            end
            assert(bdIsLoaded(model), 'bcp:ChargerBuilder:NotLoaded', ...
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
                fprintf('[bcp] Charger block REPLACED in "%s" -- redraw its wires.\n', model);
            else
                fprintf('[bcp] Charger block inserted into "%s".\n', model);
            end
            obj.Cfg.report();
            path = obj.Path;
        end
    end

    % =====================================================================
    methods (Access = private)

        function buildContents(obj)
            sys = obj.Path;
            Ts  = obj.Cfg.Ts;

            core = bcp.Blocks.add(sys, 'MLFcn', 'Charger_core', [420 80 620 300]);
            bcp.Blocks.setMLFcn(core, obj.coreCode(), Ts);
            bcp.Blocks.assertPorts(core, 3, 6);

            % --- inputs ------------------------------------------------------
            %  pack_meas is the measurement, so it is the one that closes the
            %  loop through the battery and the one that needs the delay.
            p1 = bcp.Blocks.inport(sys, 'pack_meas', 1, [180 100 200 120]);
            if obj.Cfg.BreakFeedbackLoops
                d = bcp.Blocks.add(sys, 'UnitDelay', 'pack_meas_z1', [280 95 340 130]);
                bcp.Blocks.safeSet(d, {'SampleTime','sampletime'}, ...
                    bcp.Blocks.literal(Ts));
                % Initial condition is the pack the charger believes in before
                % its first conversion. A zeros vector would read as a shorted
                % pack, and the precharge branch would fire for one sample on
                % every run; seeding it at the nominal full voltage means the
                % first sample commands nothing, which is the safe default for
                % a charger.
                bcp.Blocks.safeSet(d, {'InitialCondition','X0'}, ...
                    obj.initialMeasLiteral());
                bcp.Blocks.link(sys, p1, 1, d, 1);
                bcp.Blocks.link(sys, d, 1, core, 1);
            else
                bcp.Blocks.link(sys, p1, 1, core, 1);
            end

            % enable and I_limit come from the BMS, which already ran this
            % sample. They are commands, not measurements: no delay.
            p2 = bcp.Blocks.inport(sys, 'enable',  2, [180 190 200 210]);
            bcp.Blocks.link(sys, p2, 1, core, 2);
            p3 = bcp.Blocks.inport(sys, 'I_limit', 3, [180 250 200 270]);
            bcp.Blocks.link(sys, p3, 1, core, 3);

            % --- outputs -----------------------------------------------------
            outs = {'I_chg_cmd','P_chg_cmd','mode','V_set','I_set','done'};
            for k = 1:numel(outs)
                yy = 80 + 45*(k-1);
                o = bcp.Blocks.outport(sys, outs{k}, k, [740 yy 760 yy+20]);
                l = bcp.Blocks.link(sys, core, k, o, 1);
                if obj.Cfg.LogSignals
                    bcp.Blocks.logSignal(l, ['chg_' outs{k}]);
                else
                    set_param(l, 'Name', outs{k});
                end
            end
        end

        % -----------------------------------------------------------------
        function s = initialMeasLiteral(obj)
        %INITIALMEASLITERAL  A believable pack at t=0, in bcp.Signals order.
            c = obj.Cfg;
            v = [c.V_cv_pack; c.V_cv_cell; c.V_cv_cell; 1; 1; 1; 0];
            s = bcp.Blocks.literal(v);
        end

        % -----------------------------------------------------------------
        function annotate(obj)
            c = obj.Cfg;
            txt = sprintf([ ...
                'Charger  (bcp.ChargerBuilder, Ts = %g s)\\n' ...
                'CC %.2f A -> CV %.3f V/cell (%.1f V pack), terminate < %.2f A for %.1f s\\n' ...
                'Inputs come from the BMS block. It decides when; this decides how much.\\n' ...
                'P_chg_cmd and done go BACK to the BMS block.'], ...
                c.Ts, c.I_cc_A, c.V_cv_cell, c.V_cv_pack, c.I_taper_A, c.t_term_s);
            try
                pos = get_param(obj.Path,'Position');
                a = Simulink.Annotation([obj.Model '/Charger_notes']);
                a.Text = strrep(txt, '\n', newline);
                a.Position = [pos(1), pos(4)+20];
            catch
            end
        end

        % =================================================================
        function s = coreCode(obj)
            p = bcp.Blocks.structLiteral(obj.Cfg.params(), '        ');
            s = sprintf([ ...
'function [I_chg_cmd, P_chg_cmd, mode, V_set, I_set, done] = ...\n' ...
'        fcn(pack_meas, enable, I_limit)\n' ...
'%%#codegen\n' ...
'%%CHARGER_CORE  Generated by bcp.ChargerBuilder. Do not edit here.\n' ...
'%%\n' ...
'%%  Edit bcp.ChargerConfig (or the Charger tab of bcpApp) and re-insert the\n' ...
'%%  block. Changes made in this window are overwritten by the next insert.\n' ...
'%%\n' ...
'%%  pack_meas indices are fixed by bcp.Signals:\n' ...
'%%    1 V_pack  2 V_cell_min  3 V_cell_max  4 SOC_pack  5 SOC_min\n' ...
'%%    6 SOC_max 7 I_pack (charge-positive)\n' ...
'\n' ...
'P = %s;\n' ...
'\n' ...
'%%  The CV loop is handed the HIGHEST cell, not the pack average. On a pack\n' ...
'%%  with real cell spread those are different constraints, and the per-cell\n' ...
'%%  one is what keeps a cell out of over-voltage. See bcp_charger.\n' ...
'[I_chg_cmd, P_chg_cmd, mode, V_set, I_set, done] = bcp_charger( ...\n' ...
'    pack_meas(1), pack_meas(3), pack_meas(7), enable, I_limit, P);\n' ...
'\n' ...
'%%  Supply power ceiling, applied last so it cannot be reasoned around by the\n' ...
'%%  control law: a real supply simply cannot deliver more than this.\n' ...
'if P_chg_cmd > %s\n' ...
'    P_chg_cmd = %s;\n' ...
'    if pack_meas(1) > 1\n' ...
'        I_chg_cmd = P_chg_cmd / pack_meas(1);\n' ...
'    end\n' ...
'end\n' ...
'end\n'], p, ...
                bcp.Blocks.literal(obj.Cfg.P_chg_max_W), ...
                bcp.Blocks.literal(obj.Cfg.P_chg_max_W));
        end
    end
end
