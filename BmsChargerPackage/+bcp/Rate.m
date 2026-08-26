classdef Rate
%BCP.RATE  Sample-time reconciliation between these blocks and your model.
%
%   "Sample time mismatch", "the sample time of this block is not an integer
%   multiple of the fixed step" and their relatives are all the same problem:
%   a discrete block asked to run at a rate the solver cannot land on. This
%   class finds that out before you press play, and says which number to change.
%
%       bcp.Rate.audit('myBatteryModel', [0.01 0.01])   % report only
%       bcp.Rate.align('myBatteryModel', [0.01 0.01])   % report and fix
%
%   THE RULE
%     With a VARIABLE-STEP solver, any positive Ts works. The solver adds each
%     block's sample hits to its own list of times it must land on exactly.
%     This is the normal case for a Simscape battery model, and if that is your
%     setup you will probably never see a rate error.
%
%     With a FIXED-STEP solver, every discrete Ts must be an exact integer
%     multiple of the fundamental step. 0.01 on a 0.001 step is fine (10x);
%     0.01 on a 0.003 step is not (3.33x) and is rejected at compile time.
%
%   THE SIMSCAPE LOCAL SOLVER IS A SEPARATE CLOCK
%     A Solver Configuration block with "Use local solver" ticked runs the
%     physical network at its OWN step, independently of the model's step and of
%     these blocks. It is a third rate to reconcile, and it is the one people
%     forget, so audit() reports it explicitly. Its step should divide, or be
%     divided by, your BMS Ts -- otherwise the BMS is reading the plant at times
%     the plant has not been solved at yet, and the results are quietly
%     interpolated rather than wrong-looking.
%
%   WHY NOT JUST INHERIT (Ts = -1)?
%     Because both blocks hold persistent state -- dwell timers, PI
%     integrators, latches -- and every one of them multiplies by Ts to convert
%     samples into seconds. An inherited rate makes Ts a lie: the code believes
%     it is running at the configured period while the solver calls it whenever
%     it likes, so a "0.5 second" trip confirmation becomes however long 50
%     variable steps happen to take. Explicit rates only.

    methods (Static)

        function info = audit(model, Ts_list, quiet)
        %AUDIT  Report on solver settings versus the rates these blocks need.
        %
        %   info = bcp.Rate.audit(model, [Ts_bms Ts_charger])
        %
        %   Returns a struct and, unless QUIET, prints it. info.ok is true when
        %   nothing needs changing. Does not modify the model.
            if nargin < 3, quiet = false; end
            Ts_list = Ts_list(Ts_list > 0);
            bcp.Rate.assertLoaded(model);

            info = struct();
            info.model      = char(model);
            info.solverType = get_param(model,'SolverType');
            info.solver     = get_param(model,'Solver');
            info.stopTime   = get_param(model,'StopTime');
            info.fixedStep  = get_param(model,'FixedStep');
            info.Ts         = Ts_list;
            info.localSolvers = bcp.Rate.localSolvers(model);
            info.problems   = {};
            info.advice     = {};

            isFixed = strcmp(info.solverType,'Fixed-step');

            if isFixed
                h = str2double(info.fixedStep);
                info.fundamental = h;
                if isnan(h)
                    % 'auto' -- Simulink will pick the fastest discrete rate,
                    % which is these blocks. That works, but it also means the
                    % continuous Simscape network gets stepped at the BMS rate,
                    % which is usually far coarser than the plant needs.
                    info.problems{end+1} = ...
                        'FixedStep is "auto", so the solver step will be set by these blocks.';
                    info.advice{end+1} = sprintf( ...
                        ['Set FixedStep explicitly to something the plant can live ', ...
                         'with (%g or smaller) so the pack is not solved at the BMS rate.'], ...
                        min(Ts_list)/10);
                else
                    for k = 1:numel(Ts_list)
                        [okMult, ratio] = bcp.Rate.divides(h, Ts_list(k));
                        if ~okMult
                            info.problems{end+1} = sprintf( ...
                                'Ts = %g is %.4f fixed steps of %g -- not an integer multiple.', ...
                                Ts_list(k), ratio, h);
                            info.advice{end+1} = sprintf( ...
                                'Use Ts = %g (%d steps) or Ts = %g (%d steps).', ...
                                h*floor(ratio), floor(ratio), h*ceil(ratio), ceil(ratio));
                        end
                    end
                end
            else
                info.fundamental = NaN;
            end

            % --- Simscape local solvers ------------------------------------
            for k = 1:numel(info.localSolvers)
                ls = info.localSolvers(k);
                if ~ls.useLocal, continue; end
                for j = 1:numel(Ts_list)
                    [okMult, ratio] = bcp.Rate.divides(ls.step, Ts_list(j));
                    [okOther, ~]    = bcp.Rate.divides(Ts_list(j), ls.step);
                    if ~okMult && ~okOther
                        info.problems{end+1} = sprintf( ...
                            ['Simscape local solver in "%s" steps at %g s; Ts = %g is ', ...
                             '%.4f of that. Neither divides the other.'], ...
                            ls.block, ls.step, Ts_list(j), ratio);
                        info.advice{end+1} = sprintf( ...
                            ['Make the BMS/charger Ts an integer multiple of the local ', ...
                             'solver step (%g, %g, %g ...), or untick "Use local solver".'], ...
                            ls.step, ls.step*2, ls.step*10);
                    end
                end
            end

            info.ok = isempty(info.problems);
            if ~quiet
                bcp.Rate.print(info);
            end
        end

        % -----------------------------------------------------------------
        function info = align(model, Ts_list)
        %ALIGN  Audit, then set FixedStep so the requested rates are legal.
        %
        %   Only touches FixedStep, and only when the solver is fixed-step. Sets
        %   it to the greatest common divisor of the requested rates divided by
        %   10, so the continuous plant still gets ten steps per BMS sample.
        %   Never changes solver type, stop time, or a local solver -- those are
        %   decisions about your model, not about these blocks.
            Ts_list = Ts_list(Ts_list > 0);
            info = bcp.Rate.audit(model, Ts_list, true);

            if ~strcmp(info.solverType,'Fixed-step')
                fprintf(['[bcp] "%s" uses a variable-step solver; any positive Ts is ', ...
                         'legal and nothing needs aligning.\n'], model);
                bcp.Rate.print(info);
                return;
            end

            g = bcp.Rate.gcdOf(Ts_list);
            h = g / 10;
            set_param(model, 'FixedStep', num2str(h, '%.12g'));
            fprintf('[bcp] "%s": FixedStep set to %g s (was %s).\n', ...
                model, h, info.fixedStep);
            fprintf('       %s are now %s fixed steps.\n', ...
                mat2str(Ts_list), mat2str(round(Ts_list/h)));

            info = bcp.Rate.audit(model, Ts_list, true);
            if ~info.ok
                fprintf(2, ['[bcp] Some problems remain -- they are not FixedStep ', ...
                            'problems. Full report:\n']);
                bcp.Rate.print(info);
            end
        end

        % -----------------------------------------------------------------
        function assertCompatible(model, Ts_list)
        %ASSERTCOMPATIBLE  Error before building if the rates cannot work.
        %
        %   Called by the builders. Fails with the audit text rather than
        %   letting Simulink report it later, out of context, at compile time.
            info = bcp.Rate.audit(model, Ts_list, true);
            if info.ok, return; end
            msg = sprintf('Sample-time problems in "%s":\n', model);
            for k = 1:numel(info.problems)
                msg = [msg sprintf('  * %s\n    -> %s\n', ...
                    info.problems{k}, info.advice{k})]; %#ok<AGROW>
            end
            msg = [msg sprintf(['  Run bcp.Rate.align(''%s'', %s) to fix the ', ...
                                'FixedStep ones automatically.\n'], ...
                                model, mat2str(Ts_list))];
            error('bcp:Rate:Incompatible', '%s', msg);
        end

        % -----------------------------------------------------------------
        function print(info)
        %PRINT  Human-readable audit.
            fprintf('\n=== sample-time audit: %s ===\n', info.model);
            fprintf('  solver        %s (%s)\n', info.solver, info.solverType);
            if strcmp(info.solverType,'Fixed-step')
                fprintf('  fixed step    %s\n', info.fixedStep);
            end
            fprintf('  stop time     %s s\n', info.stopTime);
            fprintf('  block rates   %s s\n', mat2str(info.Ts));
            for k = 1:numel(info.localSolvers)
                ls = info.localSolvers(k);
                if ls.useLocal
                    fprintf('  local solver  %s: %s at %g s\n', ...
                        ls.block, ls.type, ls.step);
                else
                    fprintf('  local solver  %s: off (global solver)\n', ls.block);
                end
            end
            if info.ok
                fprintf('  RESULT        ok -- nothing to change.\n\n');
                return;
            end
            fprintf(2,'  RESULT        %d problem(s):\n', numel(info.problems));
            for k = 1:numel(info.problems)
                fprintf(2,'    * %s\n', info.problems{k});
                fprintf('      -> %s\n', info.advice{k});
            end
            fprintf('\n');
        end

        % -----------------------------------------------------------------
        function ls = localSolvers(model)
        %LOCALSOLVERS  Every Solver Configuration block and its local-solver setting.
            ls = struct('block',{},'useLocal',{},'step',{},'type',{});
            blocks = find_system(model, 'LookUnderMasks','all', ...
                'FollowLinks','on', 'MaskType','Solver Configuration');
            if isempty(blocks)
                blocks = find_system(model, 'LookUnderMasks','all', ...
                    'FollowLinks','on', 'ReferenceBlock', ...
                    'nesl_utility/Solver Configuration');
            end
            for k = 1:numel(blocks)
                b = blocks{k};
                e = struct('block', get_param(b,'Name'), ...
                           'useLocal', false, 'step', NaN, 'type', '');
                try
                    e.useLocal = strcmp(get_param(b,'UseLocalSolver'),'on');
                catch
                end
                if e.useLocal
                    try, e.step = bcp.Rate.evalIn(model, get_param(b,'LocalSolverSampleTime')); catch, end
                    try, e.type = get_param(b,'LocalSolverChoice'); catch, end
                end
                ls(end+1) = e; %#ok<AGROW>
            end
        end

        % -----------------------------------------------------------------
        function [ok, ratio] = divides(h, Ts)
        %DIVIDES  Is TS an integer multiple of H, to floating-point tolerance?
            if ~(h > 0) || ~(Ts > 0) || ~isfinite(h) || ~isfinite(Ts)
                ok = false; ratio = NaN; return;
            end
            ratio = Ts / h;
            ok = abs(ratio - round(ratio)) <= 1e-9 * max(1, ratio);
        end

        % -----------------------------------------------------------------
        function g = gcdOf(Ts_list)
        %GCDOF  Greatest common divisor of a list of sample times.
        %
        %   Integer gcd on the values scaled to nanoseconds. Sample times are
        %   decimal fractions of a second and gcd() needs integers; nanosecond
        %   resolution is finer than any rate anyone runs a BMS at, so the
        %   rounding is not a real limit.
            if isempty(Ts_list), g = 0.001; return; end
            ns = round(Ts_list(:) * 1e9);
            g  = ns(1);
            for k = 2:numel(ns)
                g = gcd(g, ns(k));
            end
            g = double(g) / 1e9;
        end

        % -----------------------------------------------------------------
        function v = evalIn(model, expr)
        %EVALIN  Evaluate a block parameter expression in the model's workspace.
        %   Block dialogs hold expressions, not numbers -- 'Ts_local' is a
        %   perfectly normal value for a sample time field.
            v = str2double(expr);
            if ~isnan(v), return; end
            v = slResolve(expr, model);
            v = double(v);
        end

        % -----------------------------------------------------------------
        function assertLoaded(model)
            if ~bdIsLoaded(model)
                error('bcp:Rate:NotLoaded', ...
                    ['Model "%s" is not open. Open it first:  open_system(''%s'')'], ...
                    model, model);
            end
        end
    end
end
