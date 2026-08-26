classdef tBcpAlgorithms < matlab.unittest.TestCase
%TBCPALGORITHMS  Unit tests for the five control functions, with no Simulink.
%
%   These are the tests that can run in a second and that catch the mistakes
%   that matter: a sign convention, a dwell timer that does not dwell, a
%   priority rule that lets the charger run through a pulse. Run them before
%   every build.
%
%       runtests('tBcpAlgorithms')
%
%   Every test clears the persistent state of the functions it exercises. Skip
%   that and tests pass or fail depending on the order they ran in, which is
%   worse than no tests.

    methods (TestMethodSetup)
        function resetState(~)
            clear bcp_load_scheduler bcp_protection bcp_arbiter bcp_charger
        end
    end

    methods (Static)
        function P = loadParams(varargin)
            P = struct('Ts',0.01, 'Waveform',3, 'StartTime_s',0, ...
                'StopTime_s',Inf, 'Offset_W',0, 'Amplitude_W',800, ...
                'Frequency_Hz',0.5, 'Phase_deg',0, 'Duty_pct',20, ...
                'Pmin_W',0, 'Pmax_W',5000, 'Slew_W_per_s',0, ...
                'IdleThreshold_W',5);
            for k = 1:2:numel(varargin), P.(varargin{k}) = varargin{k+1}; end
        end

        function P = protParams(varargin)
            P = bcp.BmsConfig().protectionParams();
            for k = 1:2:numel(varargin), P.(varargin{k}) = varargin{k+1}; end
        end

        function P = arbParams(varargin)
            P = bcp.BmsConfig().arbiterParams();
            for k = 1:2:numel(varargin), P.(varargin{k}) = varargin{k+1}; end
        end

        function P = chgParams(varargin)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
            P = bcp.ChargerConfig.fromPack(spec).params();
            for k = 1:2:numel(varargin), P.(varargin{k}) = varargin{k+1}; end
        end
    end

    % =====================================================================
    methods (Test)   % ---- load scheduler ----------------------------------

        function offMeansZero(tc)
            P = tc.loadParams('Waveform',0);
            for t = 0:0.1:5
                tc.verifyEqual(bcp_load_scheduler(t, P), 0, ...
                    'An "off" waveform must be exactly zero, not nearly zero.');
            end
        end

        function constantHoldsValue(tc)
            P = tc.loadParams('Waveform',1, 'Offset_W',250);
            [y, active] = bcp_load_scheduler(3, P);
            tc.verifyEqual(y, 250);
            tc.verifyEqual(active, 1);
        end

        function sineHasRightMeanAndPeak(tc)
            P = tc.loadParams('Waveform',2, 'Offset_W',300, 'Amplitude_W',200, ...
                'Frequency_Hz',1, 'Pmin_W',-1e6);
            t = (0:0.001:5)';
            y = zeros(size(t));
            for k = 1:numel(t), y(k) = bcp_load_scheduler(t(k), P); end
            tc.verifyEqual(mean(y), 300, 'AbsTol', 1);
            tc.verifyEqual(max(y), 500, 'AbsTol', 1);
            tc.verifyEqual(min(y), 100, 'AbsTol', 1);
        end

        function pulseDutyIsHonoured(tc)
            P = tc.loadParams('Waveform',3, 'Offset_W',0, 'Amplitude_W',1000, ...
                'Frequency_Hz',2, 'Duty_pct',25);
            t = (0:0.0001:5)';
            y = zeros(size(t));
            for k = 1:numel(t), y(k) = bcp_load_scheduler(t(k), P); end
            tc.verifyEqual(mean(y > 500), 0.25, 'AbsTol', 0.01, ...
                'A 25% duty pulse must be high a quarter of the time.');
            tc.verifyEqual(max(y), 1000);
            tc.verifyEqual(min(y), 0);
        end

        function windowGatesTheWaveform(tc)
            P = tc.loadParams('Waveform',1, 'Offset_W',400, ...
                'StartTime_s',2, 'StopTime_s',4);
            tc.verifyEqual(bcp_load_scheduler(1.99, P), 0);
            tc.verifyEqual(bcp_load_scheduler(2.00, P), 400);
            tc.verifyEqual(bcp_load_scheduler(3.99, P), 400);
            tc.verifyEqual(bcp_load_scheduler(4.00, P), 0, ...
                'StopTime_s is exclusive: the demand is off AT the stop time.');
        end

        function pulsePhaseIsRelativeToStart(tc)
            % tau is measured from StartTime_s, so a pulse that begins at t=2
            % starts its first ON period at t=2, not wherever the global clock
            % happens to be in its cycle.
            P = tc.loadParams('Waveform',3, 'Amplitude_W',1000, ...
                'Frequency_Hz',1, 'Duty_pct',50, 'StartTime_s',2.5);
            tc.verifyEqual(bcp_load_scheduler(2.5, P),  1000);
            tc.verifyEqual(bcp_load_scheduler(3.1, P),  0);
        end

        function clampLimitsTheDemand(tc)
            P = tc.loadParams('Waveform',1, 'Offset_W',9000, 'Pmax_W',2000);
            tc.verifyEqual(bcp_load_scheduler(1, P), 2000);
        end

        function slewLimitsTheEdge(tc)
            % 1000 W/s from 0 must take 0.5 s to reach 500 W, in 0.01 s steps.
            P = tc.loadParams('Waveform',1, 'Offset_W',500, 'Slew_W_per_s',1000);
            y = 0;
            for k = 1:50, y = bcp_load_scheduler(k*0.01, P); end
            tc.verifyEqual(y, 500, 'AbsTol', 11);
            clear bcp_load_scheduler
            y1 = bcp_load_scheduler(0.01, P);
            tc.verifyEqual(y1, 10, 'AbsTol', 1e-9, ...
                'One sample of a 1000 W/s slew at Ts=0.01 is 10 W.');
        end

        function idleThresholdSetsActive(tc)
            P = tc.loadParams('Waveform',1, 'Offset_W',3, 'IdleThreshold_W',5);
            [~, active] = bcp_load_scheduler(1, P);
            tc.verifyEqual(active, 0, ...
                'A demand below IdleThreshold_W must not count as an active load.');
        end
    end

    % =====================================================================
    methods (Test)   % ---- pack monitor -----------------------------------

        function bothArrayLayoutsAgree(tc)
        %BOTHARRAYLAYOUTSAGREE  The whole justification for mean()*S and sum()/S.
            S = 14; Pp = 5;
            vCell = 3.7; iPackTrue = 20;   % 20 A into the pack

            % layout A: one entry per cell, S*P entries
            Pa = struct('SeriesCount',S, 'I_sign',1, 'SOC_in_percent',false);
            mA = bcp_pack_monitor(repmat(vCell,S*Pp,1), repmat(0.5,S*Pp,1), ...
                                  repmat(iPackTrue/Pp,S*Pp,1), Pa);

            % layout B: one entry per series element, S entries
            mB = bcp_pack_monitor(repmat(vCell,S,1), repmat(0.5,S,1), ...
                                  repmat(iPackTrue,S,1), Pa);

            tc.verifyEqual(mA(bcp.Signals.V_PACK), S*vCell, 'AbsTol',1e-9);
            tc.verifyEqual(mB(bcp.Signals.V_PACK), S*vCell, 'AbsTol',1e-9);
            tc.verifyEqual(mA(bcp.Signals.I_PACK), iPackTrue, 'AbsTol',1e-9);
            tc.verifyEqual(mB(bcp.Signals.I_PACK), iPackTrue, 'AbsTol',1e-9);
        end

        function currentSignIsConverted(tc)
            P = struct('SeriesCount',10, 'I_sign',-1, 'SOC_in_percent',false);
            % A battery model reporting +5 A per element while discharging
            m = bcp_pack_monitor(repmat(3.6,10,1), repmat(0.5,10,1), ...
                                 repmat(5,10,1), P);
            tc.verifyEqual(m(bcp.Signals.I_PACK), -5, 'AbsTol',1e-9, ...
                'I_sign = -1 must turn a discharge-positive array into charge-negative.');
        end

        function percentSocIsScaled(tc)
            P = struct('SeriesCount',4, 'I_sign',1, 'SOC_in_percent',true);
            m = bcp_pack_monitor(repmat(3.6,4,1), [40;50;60;70], zeros(4,1), P);
            tc.verifyEqual(m(bcp.Signals.SOC_PACK), 0.55, 'AbsTol',1e-9);
            tc.verifyEqual(m(bcp.Signals.SOC_MIN),  0.40, 'AbsTol',1e-9);
            tc.verifyEqual(m(bcp.Signals.SOC_MAX),  0.70, 'AbsTol',1e-9);
        end

        function extremesTrackTheWorstCell(tc)
            P = struct('SeriesCount',4, 'I_sign',1, 'SOC_in_percent',false);
            m = bcp_pack_monitor([3.5;4.19;3.7;3.6], repmat(0.5,4,1), zeros(4,1), P);
            tc.verifyEqual(m(bcp.Signals.V_MIN), 3.50);
            tc.verifyEqual(m(bcp.Signals.V_MAX), 4.19);
        end
    end

    % =====================================================================
    methods (Test)   % ---- protection ------------------------------------

        function overVoltageNeedsTheDwell(tc)
            P = tc.protParams('Ts',0.01, 't_v_trip',0.5, 'V_ov_trip',4.20);
            n = round(0.4/P.Ts);
            for k = 1:n
                [~, chg_ok] = bcp_protection(3.6, 4.25, 25, 0, false, P);
            end
            tc.verifyEqual(chg_ok, 1, ...
                'An over-voltage below the confirmation time must not trip.');
            for k = 1:round(0.2/P.Ts)
                [~, chg_ok] = bcp_protection(3.6, 4.25, 25, 0, false, P);
            end
            tc.verifyEqual(chg_ok, 0, ...
                'Past t_v_trip the over-voltage must inhibit charging.');
        end

        function overVoltageInhibitsChargeButNotDischarge(tc)
        %OVERVOLTAGEINHIBITSCHARGEBUTNOTDISCHARGE  The directional-inhibit rule.
        %   Opening the contactor on an over-voltage removes the only thing that
        %   can fix it. The load is the cure.
            P = tc.protParams('t_v_trip',0.1);
            for k = 1:20
                [contactor, chg_ok, dch_ok, ~, faults] = ...
                    bcp_protection(3.6, 4.30, 25, 0, false, P);
            end
            tc.verifyEqual(chg_ok, 0);
            tc.verifyEqual(dch_ok, 1, ...
                'An over-voltage must leave the discharge path open.');
            tc.verifyEqual(contactor, 1, ...
                'A voltage fault must not isolate the pack.');
            tc.verifyEqual(bitand(uint32(faults), uint32(1)), uint32(1));
        end

        function underVoltageInhibitsDischargeButNotCharge(tc)
            P = tc.protParams('t_v_trip',0.1);
            for k = 1:20
                [~, chg_ok, dch_ok] = bcp_protection(2.40, 3.6, 25, 0, false, P);
            end
            tc.verifyEqual(dch_ok, 0);
            tc.verifyEqual(chg_ok, 1, ...
                'An under-voltage must leave the charge path open -- charging is the cure.');
        end

        function overCurrentIsolatesThePack(tc)
            P = tc.protParams('t_i_trip',0.05, 'I_chg_trip',25);
            for k = 1:20
                [contactor, chg_ok, dch_ok] = ...
                    bcp_protection(3.6, 3.7, 25, 40, false, P);
            end
            tc.verifyEqual(contactor, 0, ...
                'Over-current is a fault that must open the pack.');
            tc.verifyEqual(chg_ok, 0);
            tc.verifyEqual(dch_ok, 0);
        end

        function faultsClearOnlyInsideTheHysteresisBand(tc)
            P = tc.protParams('t_v_trip',0.1, 't_recover',0.2, ...
                'AutoRecover',true, 'V_ov_trip',4.20, 'V_ov_clear',4.10);
            for k = 1:20
                bcp_protection(3.6, 4.30, 25, 0, false, P);
            end
            % 4.15 V is below the trip but ABOVE the clear threshold: no recovery.
            for k = 1:100
                [~, chg_ok] = bcp_protection(3.6, 4.15, 25, 0, false, P);
            end
            tc.verifyEqual(chg_ok, 0, ...
                'Recovery must need the clear threshold, not merely the absence of a trip.');
            for k = 1:100
                [~, chg_ok] = bcp_protection(3.6, 4.05, 25, 0, false, P);
            end
            tc.verifyEqual(chg_ok, 1, 'Below V_ov_clear for t_recover, the fault clears.');
        end

        function latchedFaultSurvivesWithoutAutoRecover(tc)
            P = tc.protParams('t_v_trip',0.1, 'AutoRecover',false, 't_recover',0.1);
            for k = 1:20, bcp_protection(3.6, 4.30, 25, 0, false, P); end
            for k = 1:200
                [~, chg_ok] = bcp_protection(3.6, 3.60, 25, 0, false, P);
            end
            tc.verifyEqual(chg_ok, 0, 'Without AutoRecover the fault must latch.');
            % A rising edge on reset, with the pack now inside the clear band.
            bcp_protection(3.6, 3.60, 25, 1, true, P);
            [~, chg_ok] = bcp_protection(3.6, 3.60, 25, 1, true, P);
            tc.verifyEqual(chg_ok, 1, 'A reset edge inside the clear band must clear it.');
        end

        function stateReportsCurrentDirection(tc)
            P = tc.protParams();
            [~,~,~,state] = bcp_protection(3.6, 3.7, 25, 10, false, P);
            tc.verifyEqual(state, 2, 'Positive current is CHARGE.');
            [~,~,~,state] = bcp_protection(3.6, 3.7, 25, -10, false, P);
            tc.verifyEqual(state, 3, 'Negative current is DISCHARGE.');
            [~,~,~,state] = bcp_protection(3.6, 3.7, 25, 0, false, P);
            tc.verifyEqual(state, 1, 'No current is IDLE.');
        end
    end

    % =====================================================================
    methods (Test)   % ---- arbiter ---------------------------------------

        function activeLoadBlocksChargingImmediately(tc)
            P = tc.arbParams('t_quiet_s',1.0);
            [en, ~, reason] = bcp_arbiter(1, 0.50, 3.7, 1, 0, P);
            tc.verifyEqual(en, 0, 'An active load must revoke charge permission at once.');
            tc.verifyEqual(reason, 1);
        end

        function chargingWaitsOutTheQuietDwell(tc)
            P = tc.arbParams('t_quiet_s',0.5, 'Ts',0.01);
            % load active, then released
            bcp_arbiter(1, 0.50, 3.7, 1, 0, P);
            for k = 1:40                        % 0.4 s of quiet
                [en, ~, reason] = bcp_arbiter(0, 0.50, 3.7, 1, 0, P);
            end
            tc.verifyEqual(en, 0, 'Charging must not start before t_quiet_s.');
            tc.verifyEqual(reason, 2);
            for k = 1:20                        % past 0.5 s
                [en, ~, reason] = bcp_arbiter(0, 0.50, 3.7, 1, 0, P);
            end
            tc.verifyEqual(en, 1);
            tc.verifyEqual(reason, 0);
        end

        function pulseGapShorterThanDwellNeverCharges(tc)
        %PULSEGAPSHORTERTHANDWELLNEVERCHARGES  Documents the real trap: a dwell
        %   longer than the gap between pulses means the charger never runs, and
        %   nothing about the run looks broken.
            P = tc.arbParams('t_quiet_s',1.0, 'Ts',0.01);
            enabled = false;
            for cycle = 1:20
                for k = 1:20, bcp_arbiter(1, 0.5, 3.7, 1, 0, P); end   % 0.2 s on
                for k = 1:80                                            % 0.8 s off
                    en = bcp_arbiter(0, 0.5, 3.7, 1, 0, P);
                    enabled = enabled || en > 0.5;
                end
            end
            tc.verifyFalse(enabled, ...
                'A 0.8 s gap must never satisfy a 1.0 s quiet dwell.');
        end

        function concurrentModeIgnoresTheLoadButDerates(tc)
            P = tc.arbParams('AllowConcurrent',true, 'I_chg_headroom_A',5, ...
                'I_chg_trip',25, 'I_chg_margin',0.9);
            [en, lim] = bcp_arbiter(1, 0.50, 3.7, 1, 0, P);
            tc.verifyEqual(en, 1, 'Concurrent mode charges through an active load.');
            tc.verifyEqual(lim, 5, 'AbsTol',1e-9, ...
                'Under load, the ceiling must be the concurrent headroom.');
            [~, lim] = bcp_arbiter(0, 0.50, 3.7, 1, 0, P);
            tc.verifyEqual(lim, 22.5, 'AbsTol',1e-9, ...
                'With no load, the ceiling is I_chg_trip * I_chg_margin.');
        end

        function socStopLatchesWithHysteresis(tc)
            P = tc.arbParams('SOC_stop',0.95, 'SOC_restart',0.85, ...
                'V_recharge',4.05, 't_quiet_s',0);
            [en, ~, reason] = bcp_arbiter(0, 0.96, 4.19, 1, 0, P);
            tc.verifyEqual(en, 0);
            tc.verifyEqual(reason, 3);
            % Drop just below SOC_stop: the latch must hold, not chatter.
            [en] = bcp_arbiter(0, 0.94, 4.19, 1, 0, P);
            tc.verifyEqual(en, 0, ...
                'Falling barely below SOC_stop must not restart the charge.');
            % Below SOC_restart: re-arm.
            [en] = bcp_arbiter(0, 0.84, 3.95, 1, 0, P);
            tc.verifyEqual(en, 1, 'Below SOC_restart the charge must re-arm.');
        end

        function protectionOverridesEverything(tc)
            P = tc.arbParams('t_quiet_s',0);
            [en, ~, reason] = bcp_arbiter(0, 0.20, 3.5, 0, 0, P);
            tc.verifyEqual(en, 0);
            tc.verifyEqual(reason, 4);
        end

        function chargeDisabledIsReported(tc)
            P = tc.arbParams('ChargeEnabled',false, 't_quiet_s',0);
            [en, ~, reason] = bcp_arbiter(0, 0.20, 3.5, 1, 0, P);
            tc.verifyEqual(en, 0);
            tc.verifyEqual(reason, 5);
        end

        function chargerDoneSetsTheCompletionLatch(tc)
            P = tc.arbParams('t_quiet_s',0, 'SOC_restart',0.85, 'V_recharge',4.05);
            [en] = bcp_arbiter(0, 0.90, 4.19, 1, 1, P);
            tc.verifyEqual(en, 0, 'chg_done must set the completion latch.');
            [en] = bcp_arbiter(0, 0.90, 4.19, 1, 0, P);
            tc.verifyEqual(en, 0, 'and the latch must hold after done goes away.');
        end
    end

    % =====================================================================
    methods (Test)   % ---- charger ---------------------------------------

        function disabledMeansZero(tc)
            P = tc.chgParams();
            [I, Pw, mode] = bcp_charger(50, 3.6, 0, 0, 25, P);
            tc.verifyEqual(I, 0);
            tc.verifyEqual(Pw, 0);
            tc.verifyEqual(mode, 0);
        end

        function deeplyDischargedPackGetsATrickle(tc)
            P = tc.chgParams('V_precharge_cell',3.0);
            [I, ~, mode] = bcp_charger(38, 2.8, 0, 1, 25, P);
            tc.verifyEqual(mode, 1, 'Below V_precharge_cell the mode must be PRECHARGE.');
            tc.verifyEqual(I, P.I_precharge_A, 'AbsTol',1e-9);
            tc.verifyLessThan(I, P.I_cc_A, ...
                'Precharge must be gentler than the CC setpoint.');
        end

        function farFromTargetRunsAtTheCeiling(tc)
            P = tc.chgParams();
            [I, ~, mode] = bcp_charger(50, 3.70, 0, 1, 1e6, P);
            tc.verifyEqual(mode, 2, 'Well below the CV target the mode must be CC.');
            tc.verifyEqual(I, P.I_cc_A, 'AbsTol',1e-9);
        end

        function arbiterLimitDeratesTheCommand(tc)
            P = tc.chgParams();
            [I, ~, mode] = bcp_charger(50, 3.70, 0, 1, 4, P);
            tc.verifyEqual(I, 4, 'AbsTol',1e-9, ...
                'The arbiter''s ceiling must bind even in CC.');
            tc.verifyEqual(mode, 2);
        end

        function nearTargetTheVoltageLoopTakesOver(tc)
            P = tc.chgParams();
            [I, ~, mode] = bcp_charger(58.0, P.V_cv_cell - 0.002, 0, 1, 1e6, P);
            tc.verifyEqual(mode, 3, ...
                'A few millivolts from the target, the voltage loop must bind.');
            tc.verifyLessThan(I, P.I_cc_A);
            tc.verifyGreaterThanOrEqual(I, 0);
        end

        function theHighestCellIsWhatIsRegulated(tc)
        %THEHIGHESTCELLISWHATISREGULATED  A pack whose average is fine but whose
        %   worst cell is at the limit must still be held back. This is the test
        %   that distinguishes a per-cell CV loop from a pack-voltage one.
            P = tc.chgParams();
            packWellBelowTarget = P.V_cv_pack - 2.0;
            [I, ~, mode] = bcp_charger(packWellBelowTarget, P.V_cv_cell, 0, 1, 1e6, P);
            tc.verifyEqual(mode, 3, ...
                'The max cell at target must force CV even with the pack 2 V low.');
            tc.verifyLessThan(I, 0.1, ...
                'At the per-cell target the command must collapse to nearly zero.');
        end

        function oneSampleOfTaperDoesNotTerminate(tc)
        %ONESAMPLEOFTAPERDOESNOTTERMINATE  The dwell confirmation, tested directly.
            P = tc.chgParams('t_term_s',2.0, 'Ts',0.01);
            [~,~,~,~,~,done] = bcp_charger(58.0, P.V_cv_cell, 0, 1, 1e6, P);
            tc.verifyEqual(done, 0, ...
                'A single below-taper sample must not terminate the charge.');
        end

        function sustainedTaperDoesTerminate(tc)
            P = tc.chgParams('t_term_s',0.2, 'Ts',0.01);
            done = 0;
            for k = 1:100
                [~,~,mode,~,~,done] = bcp_charger(58.0, P.V_cv_cell, 0, 1, 1e6, P);
                if done > 0.5, break; end
            end
            tc.verifyEqual(done, 1, 'A taper held past t_term_s must terminate.');
            tc.verifyEqual(mode, 4, 'and the mode must report DONE.');
        end

        function terminationHoldsUntilThePackIsDrawnDown(tc)
            P = tc.chgParams('t_term_s',0.05, 'Ts',0.01, 'V_recharge_cell',4.05);
            for k = 1:50, bcp_charger(58.0, P.V_cv_cell, 0, 1, 1e6, P); end
            [~,~,mode,~,~,done] = bcp_charger(58.0, 4.15, 0, 1, 1e6, P);
            tc.verifyEqual(done, 1, ...
                'At 4.15 V, above the 4.05 V re-arm threshold, DONE must hold.');
            tc.verifyEqual(mode, 4);
            [I,~,mode,~,~,done] = bcp_charger(55.0, 4.00, 0, 1, 1e6, P);
            tc.verifyEqual(done, 0, 'Below V_recharge_cell the charger must re-arm.');
            tc.verifyGreaterThan(I, 0);
            tc.verifyEqual(mode, 2);
        end

        function interruptionByTheLoadResetsTheTaperClock(tc)
        %INTERRUPTIONBYTHELOADRESETSTHETAPERCLOCK  A charge paused by a pulse
        %   spends that time at zero current. That is not a taper, and counting
        %   it as one would declare a half-finished pack full.
            P = tc.chgParams('t_term_s',0.5, 'Ts',0.01);
            for k = 1:40                       % 0.4 s of genuine taper
                bcp_charger(58.0, P.V_cv_cell, 0, 1, 1e6, P);
            end
            for k = 1:10                       % load takes over: enable drops
                bcp_charger(58.0, P.V_cv_cell, 0, 0, 1e6, P);
            end
            for k = 1:40                       % 0.4 s more taper: still short of 0.5
                [~,~,~,~,~,done] = bcp_charger(58.0, P.V_cv_cell, 0, 1, 1e6, P);
            end
            tc.verifyEqual(done, 0, ...
                'The taper clock must restart after an interruption, not resume.');
        end

        function commandIsNeverNegative(tc)
        %COMMANDISNEVERNEGATIVE  The charger has no authority to discharge.
            P = tc.chgParams();
            for vmax = [4.30 4.50 5.00]
                [I, Pw] = bcp_charger(70, vmax, 0, 1, 1e6, P);
                tc.verifyGreaterThanOrEqual(I, 0, ...
                    'Above the CV target the command must clamp at zero, not reverse.');
                tc.verifyGreaterThanOrEqual(Pw, 0);
            end
        end
    end

    % =====================================================================
    methods (Test)   % ---- configuration and auto-fill ---------------------

        function packSpecDerivesPackNumbers(tc)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
            tc.verifyEqual(spec.Q_Ah, 22.5, 'AbsTol',1e-9);
            tc.verifyEqual(spec.V_max, 58.8, 'AbsTol',1e-9);
            tc.verifyEqual(spec.V_nom, 50.4, 'AbsTol',1e-9);
            tc.verifyEqual(spec.NCells, 70);
            tc.verifyEqual(spec.I_chg_std_A, 21.75, 'AbsTol',1e-9);
            tc.verifyEqual(spec.I_dch_A, 225, 'AbsTol',1e-9);
            tc.verifyEqual(spec.R_dc_Ohm, 0.012*14/5, 'AbsTol',1e-12);
            tc.verifyEqual(spec.Wh, 22.5*50.4, 'AbsTol',1e-6);
        end

        function autofillMatchesHandCalculation(tc)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
            c = bcp.ChargerConfig.fromPack(spec);
            tc.verifyEqual(c.I_cc_A, 21.75, 'AbsTol',1e-9, ...
                'Default CC is the datasheet standard charge times P.');
            tc.verifyEqual(c.I_taper_A, 22.5/20, 'AbsTol',1e-9, 'C/20 taper.');
            tc.verifyEqual(c.V_cv_cell, 4.20, 'AbsTol',1e-9);
            tc.verifyEqual(c.V_cv_pack, 58.80, 'AbsTol',1e-9);
            tc.verifyEqual(c.SeriesCount, 14);
            % The two loops must reach their targets together: Kp_pack is
            % Kp_cell / S by construction, because R_pack = R_cellLevel * S.
            tc.verifyEqual(c.Kp_pack, c.Kp_cell/14, 'RelTol',1e-9);
        end

        function autofillRespectsARequestedCRate(tc)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
            c = bcp.ChargerConfig.fromPack(spec, 'C_rate', 0.5);
            tc.verifyEqual(c.I_cc_A, 11.25, 'AbsTol',1e-9);
        end

        function autofillClampsAnImpossibleCRate(tc)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
            c = tc.verifyWarning( ...
                @() bcp.ChargerConfig.fromPack(spec, 'C_rate', 3), ...
                'bcp:ChargerConfig:OverCRate');
            tc.verifyEqual(c.I_cc_A, spec.I_chg_max_A, 'AbsTol',1e-9);
        end

        function bmsAutofillLeavesHeadroomAboveTheChargeCurrent(tc)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P50B(), 'S',20, 'P',4);
            b = bcp.BmsConfig().fromPack(spec);
            c = bcp.ChargerConfig.fromPack(spec);
            tc.verifyGreaterThan(b.I_chg_trip * b.I_chg_margin, c.I_cc_A, ...
                ['The over-current trip, derated by the arbiter margin, must still ', ...
                 'sit above the charge current -- otherwise the charger cannot ', ...
                 'reach CC without tripping.']);
            tc.verifyEqual(b.V_ov_trip, 4.25, 'AbsTol',1e-9, ...
                'The trip is the 4.20 V cutoff plus 50 mV of fault margin.');
            tc.verifyGreaterThan(b.V_ov_trip, c.V_cv_cell);
            tc.verifyEqual(b.SeriesCount, 20);
        end

        function projectDefaultsAreSelfConsistent(tc)
            p = bcp.Project();
            tc.verifyEmpty(p.check(), ...
                'The out-of-the-box configuration must have no consistency issues.');
        end

        function projectCatchesAChargeTargetAboveTheTrip(tc)
            p = bcp.Project();
            p.Charger.V_cv_cell = 4.30;      % above the 4.25 V OV trip
            issues = p.check();
            tc.verifyNotEmpty(issues);
            tc.verifyTrue(any(contains(issues, 'ABOVE the over-voltage trip')));
        end

        function projectCatchesATripWithNoMarginAboveTheTarget(tc)
        %PROJECTCATCHESATRIPWITHNOMARGINABOVETHETARGET  The mistake this package
        %   shipped with until the tests caught it: a trip set at the CV target
        %   fires on every charge that works.
            p = bcp.Project();
            p.Bms.V_ov_trip = p.Charger.V_cv_cell;   % no margin at all
            issues = p.check();
            tc.verifyTrue(any(contains(issues, 'only 0 mV above the CV target')));
        end

        function defaultTripsBracketTheOperatingWindow(tc)
            p = bcp.Project();
            tc.verifyGreaterThan(p.Bms.V_ov_trip, p.Charger.V_cv_cell, ...
                'The over-voltage trip must sit above the CV target.');
            tc.verifyLessThan(p.Bms.V_uv_trip, p.Pack.Cell.V_min + 1e-9, ...
                'The under-voltage trip must sit at or below the cell cutoff.');
        end

        function projectCatchesAConstantLoadThatBlocksCharging(tc)
            p = bcp.Project();
            p.Load = bcp.LoadSignal('Waveform','constant','Const_W',300);
            issues = p.check();
            tc.verifyTrue(any(contains(issues, 'never goes idle')));
        end

        function projectCatchesADwellLongerThanThePulseGap(tc)
            p = bcp.Project();
            p.Load = bcp.LoadSignal('Waveform','pulse', ...
                'Pulse_Amplitude_W',500, 'Pulse_Frequency_Hz',2, ...
                'Pulse_Duty_pct',50);      % 0.25 s gap
            p.Bms.t_quiet_s = 1.0;
            issues = p.check();
            tc.verifyTrue(any(contains(issues, 'never gets a window')));
        end

        function syncPropagatesTheSeriesCount(tc)
            p = bcp.Project();
            p = p.setPack(bcp.PackSpec('Cell',bcp.CellLibrary.P50B(),'S',20,'P',4));
            tc.verifyEqual(p.Bms.SeriesCount, 20);
            tc.verifyEqual(p.Charger.SeriesCount, 20);
        end

        function loadSignalPreviewUsesTheBlockCode(tc)
        %LOADSIGNALPREVIEWUSESTHEBLOCKCODE  The preview and the model must not be
        %   two implementations of the same waveform.
            sig = bcp.LoadSignal('Waveform','pulse', 'Pulse_Amplitude_W',700, ...
                'Pulse_Frequency_Hz',1, 'Pulse_Duty_pct',30);
            [t, y] = sig.sample(4, 0.001);
            tc.verifyEqual(max(y), 700, 'AbsTol',1e-9);
            tc.verifyEqual(mean(y > 350), 0.30, 'AbsTol',0.01);
            tc.verifyEqual(numel(t), numel(y));
            tc.verifyEqual(sig.meanDemand(), 210, 'AbsTol',1e-9);
        end

        function outputSignFlipsThePreview(tc)
            sig = bcp.LoadSignal('Waveform','constant','Const_W',250, ...
                'OutputSign',-1);
            [~, y] = sig.sample(1, 0.01);
            tc.verifyEqual(max(y), -250, 'AbsTol',1e-9);
        end
    end

    % =====================================================================
    methods (Test)   % ---- sample-time arithmetic --------------------------

        function dividesAcceptsExactMultiples(tc)
            tc.verifyTrue(bcp.Rate.divides(0.001, 0.01));
            tc.verifyTrue(bcp.Rate.divides(0.002, 0.01));
            tc.verifyTrue(bcp.Rate.divides(0.01, 0.01));
        end

        function dividesRejectsNonMultiples(tc)
            tc.verifyFalse(bcp.Rate.divides(0.003, 0.01));
            tc.verifyFalse(bcp.Rate.divides(0.0007, 0.01));
        end

        function dividesSurvivesBinaryFractions(tc)
        %DIVIDESSURVIVESBINARYFRACTIONS  0.1/0.01 is not exactly 10 in binary
        %   floating point. A naive mod() test rejects a perfectly legal rate.
            tc.verifyTrue(bcp.Rate.divides(0.01, 0.1));
            tc.verifyTrue(bcp.Rate.divides(0.05, 0.15));
            tc.verifyTrue(bcp.Rate.divides(1/3, 1));
        end

        function gcdHandlesDecimalRates(tc)
            tc.verifyEqual(bcp.Rate.gcdOf([0.01 0.02]), 0.01, 'AbsTol',1e-12);
            tc.verifyEqual(bcp.Rate.gcdOf([0.01 0.015]), 0.005, 'AbsTol',1e-12);
            tc.verifyEqual(bcp.Rate.gcdOf([0.002 0.005]), 0.001, 'AbsTol',1e-12);
        end
    end
end
