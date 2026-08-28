classdef tBcpBuild < matlab.unittest.TestCase
%TBCPBUILD  Build the blocks into a real model and simulate them.
%
%   These are the tests the algorithm suite cannot do: whether the generated
%   code compiles, whether the sample times reconcile, whether the loop-breaking
%   delays are enough, and whether the emergent behaviour of two interacting
%   blocks is what the design intended. They need Simulink and they take about a
%   minute -- run them before installing into a model you care about.
%
%       runtests('tBcpBuild')
%
%   Every test builds its own harness. Sharing one would be faster and would
%   couple the tests through the model's dirty state.

    properties
        Models cell = {}
    end

    methods (TestClassSetup)
        function requireSimulink(tc)
            tc.assumeNotEmpty(ver('simulink'), ...
                'These tests need Simulink. The algorithm suite does not.');
        end
    end

    methods (TestMethodTeardown)
        function closeModels(tc)
            for k = 1:numel(tc.Models)
                if bdIsLoaded(tc.Models{k})
                    close_system(tc.Models{k}, 0);
                end
            end
            tc.Models = {};
        end
    end

    methods
        function [h, p] = makeHarness(tc, name, project, varargin)
            p = project;
            h = bcp.Harness(p, 'ModelName', name, varargin{:});
            h.build();
            tc.Models{end+1} = name;
        end

        function s = sig(~, out, name)
            v = out.logsout.getElement(name).Values;
            s = squeeze(v.Data);
            if size(s,1) < size(s,2) && size(s,2) == numel(v.Time)
                s = s';
            end
        end
    end

    % =====================================================================
    methods (Test)

        function harnessBuildsCompilesAndRates(tc)
        %HARNESSBUILDSCOMPILESANDRATES  The end-to-end smoke test.
            p = bcp.Project();
            [~, p] = tc.makeHarness('tb_smoke', p);

            info = bcp.Rate.audit('tb_smoke', [p.Bms.Ts p.Charger.Ts], true);
            tc.verifyTrue(info.ok, ...
                sprintf('Rate audit failed: %s', strjoin(info.problems, '; ')));
            tc.verifyEqual(info.solverType, 'Fixed-step');

            w = tc.verifyWarningFree(@() p.verifyWiring('tb_smoke'));
            tc.verifyTrue(w.ok);
            tc.verifyEqual(w.layout, 'per-series', ...
                'The harness plant emits one entry per series element.');
        end

        function unitDelaysAreWhatMakeItSolvable(tc)
        %UNITDELAYSAREWHATMAKEITSOLVABLE  The algebraic loop, demonstrated.
        %
        %   The BMS reads cell voltage and commands the power that determines
        %   it; the plant's terminal voltage depends on its current within the
        %   same step. Direct feedthrough both ways is an algebraic loop, which
        %   is exactly the error this package's users hit before it existed.
        %   With BreakFeedbackLoops off the model must fail; with it on, the
        %   same model must run. Both halves matter -- a test that only checks
        %   the working case cannot tell you the delays are doing anything.
            p = bcp.Project();
            p.Bms.BreakFeedbackLoops = false;
            p.Charger.BreakFeedbackLoops = false;
            tc.makeHarness('tb_loop_open', p);
            tc.verifyError(@() sim('tb_loop_open'), ...
                ?MException, ...
                'Without the input delays the model must refuse to run.');

            p.Bms.BreakFeedbackLoops = true;
            p.Charger.BreakFeedbackLoops = true;
            h = tc.makeHarness('tb_loop_closed', p);
            out = h.simulate(20);
            tc.verifyNotEmpty(out.logsout, ...
                'With the input delays the same model must run.');
        end

        function chargerNeverRunsWhileTheLoadIsActive(tc)
        %CHARGERNEVERRUNSWHILETHELOADISACTIVE  The load-priority guarantee, on
        %   the real interacting blocks rather than on the arbiter alone.
            p = bcp.Project();
            p.Load = bcp.LoadSignal('Waveform','pulse', ...
                'Pulse_Amplitude_W',900, 'Pulse_Frequency_Hz',0.1, ...
                'Pulse_Duty_pct',40, 'Pmax_W',4000);
            p.Bms.t_quiet_s = 0.5;
            p = p.sync();
            h = tc.makeHarness('tb_priority', p, 'SOC_init', 0.50);
            out = h.simulate(200);

            D = tc.sig(out, 'bms_diag');
            I = tc.sig(out, 'chg_I_chg_cmd');
            loadActive = D(:,2) > 0.5;

            tc.verifyTrue(any(loadActive), 'The pulse load must actually run.');
            tc.verifyTrue(any(I > 1), 'The charger must actually charge somewhere.');
            tc.verifyLessThan(max(I(loadActive)), 1e-9, ...
                'The charger must command exactly zero while the load is active.');
        end

        function chargeReachesCVAndTerminatesOnTaper(tc)
        %CHARGEREACHESCVANDTERMINATESONTAPER  Automatic CC -> CV -> DONE.
        %   SOC_stop is raised out of the way so the charge is ended by the
        %   voltage taper rather than by the arbiter's SOC gate -- the taper is
        %   what is under test.
            p = bcp.Project();
            p.Load = bcp.LoadSignal('Waveform','off');
            p.Bms.SOC_stop    = 0.999;
            p.Bms.SOC_restart = 0.900;
            p.Bms.t_quiet_s   = 0;
            p = p.sync();
            h = tc.makeHarness('tb_ccv', p, 'SOC_init', 0.90);
            out = h.simulate(1200);

            mode = tc.sig(out, 'chg_mode');
            done = tc.sig(out, 'chg_done');
            Vc   = tc.sig(out, 'plant_V_cell');

            tc.verifyTrue(any(mode == 2), 'The charge must spend time in CC.');
            tc.verifyTrue(any(mode == 3), 'The charge must hand over to CV.');
            tc.verifyEqual(done(end), 1, ...
                'A completed CV taper must terminate the charge.');

            % The first sample commands zero amps, by design: the charger's
            % input delay is seeded with a full pack (see
            % ChargerBuilder.initialMeasLiteral) so that before its first real
            % conversion it asks for nothing. Assert that rather than working
            % around it -- a charger whose first act is to command current on a
            % pack it has not measured is the failure mode being avoided.
            I = tc.sig(out, 'chg_I_chg_cmd');
            tc.verifyEqual(I(1), 0, 'AbsTol',1e-12, ...
                'The first sample must command zero: nothing has been measured yet.');

            % CC before CV, judged on the sustained phases rather than on that
            % first sample.
            tc.verifyLessThan(find(mode == 2, 1, 'last'), ...
                              find(mode == 3, 1, 'last'), ...
                'CC must precede CV.');
            tc.verifyLessThan(find(mode == 2, 1, 'first'), ...
                              find(mode(2:end) == 3, 1, 'first') + 1, ...
                'Past the first sample, CC must come before CV.');

            tc.verifyLessThan(max(Vc(:)), p.Bms.V_ov_trip, ...
                ['No cell may exceed the over-voltage trip during a normal ', ...
                 'charge. If this fails, the CV loop overshot -- check the ', ...
                 'anti-windup, not the threshold.']);
            tc.verifyGreaterThan(max(Vc(:)), p.Charger.V_cv_cell - 0.02, ...
                'The charge must actually reach its target, not stop short.');
        end

        function chargerModeDoesNotChatterThroughTheKnee(tc)
        %CHARGERMODEDOESNOTCHATTERTHROUGHTHEKNEE  The limit cycle, on the real
        %   blocks rather than on the algorithm alone.
        %
        %   A CC-CV charge passes through the knee once. The mode output should
        %   therefore change a handful of times over the whole run -- OFF into
        %   CC, CC into CV, CV into DONE, plus whatever the arbiter's gaps add.
        %   Before the loop was given per-loop integrators and the mode a
        %   hysteresis band, it changed hundreds of times: the command
        %   oscillated between the ceiling and well below it while the pack sat
        %   quietly at its target.
            p = bcp.Project();
            p.Load = bcp.LoadSignal('Waveform','off');
            p.Bms.SOC_stop    = 0.999;
            p.Bms.SOC_restart = 0.900;
            p.Bms.t_quiet_s   = 0;
            p = p.sync();
            h = tc.makeHarness('tb_knee', p, 'SOC_init', 0.90);
            out = h.simulate(1200);

            mode = tc.sig(out, 'chg_mode');
            flips = sum(diff(mode) ~= 0);
            tc.verifyLessThanOrEqual(flips, 12, ...
                sprintf(['The charger reported %d mode changes in one CC-CV ', ...
                         'charge. A charge passes the knee once; anything in the ', ...
                         'hundreds is the CC/CV limit cycle back again.'], flips));

            % A limit cycle shows in the command before it shows in the mode, so
            % check the command too: during CV the current must fall, not
            % oscillate back up to the ceiling.
            I = tc.sig(out, 'chg_I_chg_cmd');
            cv = mode == 3;
            if any(cv)
                rises = sum(diff(I(cv)) > 0.05 * max(I));
                tc.verifyLessThanOrEqual(rises, 5, ...
                    ['During CV the command should taper. Repeated jumps back ', ...
                     'toward the ceiling are the loop hunting, not a taper.']);
            end
        end

        function diagOutputIsExactlyTenWide(tc)
        %DIAGOUTPUTISEXACTLYTENWIDE  The width contract, asserted where it is
        %   cheap. Get it wrong and the failure is a Simulink port mismatch
        %   reported against whatever the wire happened to reach -- classically
        %   the charger's 7-wide pack_meas input, which is the port next door on
        %   the BMS block and the easy one to hit by mistake.
            p = bcp.Project();
            h = tc.makeHarness('tb_diagwidth', p);
            out = h.simulate(1);
            D = tc.sig(out, 'bms_diag');
            tc.verifyEqual(size(D,2), bcp.Signals.DIAG_NUM, ...
                'diag must be exactly bcp.Signals.DIAG_NUM wide.');
            tc.verifyEqual(numel(bcp.Signals.diagNames()), bcp.Signals.DIAG_NUM, ...
                'and diagNames must name every channel of it.');

            M = tc.sig(out, 'bms_pack_meas');
            tc.verifyEqual(size(M,2), bcp.Signals.NUM, ...
                'pack_meas must be exactly bcp.Signals.NUM wide.');
        end

        function protectionDoesNotDeadlockAgainstItsOwnLoad(tc)
        %PROTECTIONDOESNOTDEADLOCKAGAINSTITSOWNLOAD  The reason the discharge
        %   inhibit is applied BEFORE the load-active flag is computed.
        %
        %   Run a pack into under-voltage under a heavy constant load. The
        %   inhibit stops the load; that makes the load idle; the arbiter then
        %   grants the charger a window and the pack recovers. Compute the flag
        %   from the ungated demand instead and the load reads busy forever, the
        %   charger never runs, and the pack sits at its floor for the rest of
        %   the simulation.
            p = bcp.Project();
            p.Load = bcp.LoadSignal('Waveform','constant', 'Const_W',2200, ...
                'Pmax_W',4000);
            p.Bms.t_quiet_s = 0.5;
            p = p.sync();
            h = tc.makeHarness('tb_deadlock', p, 'SOC_init', 0.08);
            out = h.simulate(400);

            faults = tc.sig(out, 'bms_faults');
            D      = tc.sig(out, 'bms_diag');
            I      = tc.sig(out, 'chg_I_chg_cmd');

            uv = bitand(uint32(round(faults)), uint32(2)) ~= 0;
            tc.verifyTrue(any(uv), ...
                'A 2200 W load on an 8%-SOC pack must reach under-voltage.');

            firstUV = find(uv, 1, 'first');
            tc.verifyTrue(any(D(firstUV:end,2) < 0.5), ...
                'The discharge inhibit must make the load read idle.');
            tc.verifyTrue(any(I(firstUV:end) > 1), ...
                ['After the inhibit the charger must get its window. If this ', ...
                 'fails the pack is deadlocked by its own protection.']);
        end

        function reinsertingReplacesRatherThanAccumulates(tc)
        %REINSERTINGREPLACESRATHERTHANACCUMULATES  Re-inserting is the edit cycle,
        %   so it has to be idempotent in block count.
            p = bcp.Project();
            tc.makeHarness('tb_reinsert', p);

            before = numel(find_system('tb_reinsert', 'SearchDepth',1, ...
                'BlockType','SubSystem'));
            p.Bms.t_quiet_s = 3.0;
            p = p.sync();
            p.insertInto('tb_reinsert');
            after = numel(find_system('tb_reinsert', 'SearchDepth',1, ...
                'BlockType','SubSystem'));

            tc.verifyEqual(after, before, ...
                'Re-inserting must replace the blocks, not add a second pair.');
        end

        function rateAlignFixesAMismatchedFixedStep(tc)
        %RATEALIGNFIXESAMISMATCHEDFIXEDSTEP  The step-size failure, and the fix.
            p = bcp.Project();
            tc.makeHarness('tb_rates', p);

            % 0.003 s does not divide 0.01 s: 3.33 steps per sample.
            set_param('tb_rates', 'FixedStep', '0.003');
            info = bcp.Rate.audit('tb_rates', p.Bms.Ts, true);
            tc.verifyFalse(info.ok, ...
                'A step that does not divide the block rate must be reported.');
            tc.verifyTrue(contains(info.problems{1}, 'not an integer multiple'));

            bcp.Rate.align('tb_rates', p.Bms.Ts);
            info = bcp.Rate.audit('tb_rates', p.Bms.Ts, true);
            tc.verifyTrue(info.ok, 'align() must leave the audit clean.');

            % assertCompatible is what the builders call, so it has to agree.
            set_param('tb_rates', 'FixedStep', '0.003');
            tc.verifyError(@() bcp.Rate.assertCompatible('tb_rates', p.Bms.Ts), ...
                'bcp:Rate:Incompatible');
        end

        function loadWaveformInTheModelMatchesThePreview(tc)
        %LOADWAVEFORMINTHEMODELMATCHESTHEPREVIEW  The UI's preview is only worth
        %   having if it is the same numbers the block produces.
            p = bcp.Project();
            p.Load = bcp.LoadSignal('Waveform','pulse', ...
                'Pulse_Base_W',50, 'Pulse_Amplitude_W',600, ...
                'Pulse_Frequency_Hz',0.5, 'Pulse_Duty_pct',30, 'Pmax_W',2000);
            p.Bms.ChargeEnabled = false;      % isolate the load path
            p = p.sync();
            h = tc.makeHarness('tb_waveform', p, 'SOC_init', 0.60);
            out = h.simulate(40);

            Pl = tc.sig(out, 'bms_P_load_cmd');
            tc.verifyEqual(max(Pl), 650, 'AbsTol', 1e-6, ...
                'Peak demand in the model must equal base + amplitude.');
            tc.verifyEqual(min(Pl), 50, 'AbsTol', 1e-6);

            tPreview = out.logsout.getElement('bms_P_load_cmd').Values.Time;
            [~, yPreview] = p.Load.sample(max(tPreview), p.Bms.Ts);
            tc.verifyEqual(mean(Pl), mean(yPreview), 'RelTol', 0.05, ...
                'The preview mean and the simulated mean must agree.');
        end
    end
end
