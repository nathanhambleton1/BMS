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
            clear bcp_load_limiter
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

        function P = limParams(varargin)
            P = bcp.BmsConfig().limiterParams();
            for k = 1:2:numel(varargin), P.(varargin{k}) = varargin{k+1}; end
        end

        function P = monParams(varargin)
            P = bcp.BmsConfig().monitorParams();
            for k = 1:2:numel(varargin), P.(varargin{k}) = varargin{k+1}; end
        end

        function [f, y] = runLimiter(P, n, vmin, ipack, dch_ok)
        %RUNLIMITER  Drive bcp_load_limiter n times at a fixed operating point.
        %   Returns the final fraction and the final load command, for a demand
        %   of exactly 1000 W so the two are trivially comparable.
            f = NaN; y = NaN;
            for k = 1:n
                [y, f] = bcp_load_limiter(1000, vmin, ipack, dch_ok, P);
            end
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
        %
        %   The params come from tc.monParams rather than a struct literal here.
        %   A literal is a copy of the monitor's parameter list that goes stale
        %   the next time the monitor gains a field -- which is exactly what
        %   happened when SOC_clamp was added, and four tests failed on a
        %   missing field rather than on anything they were testing.
            S = 14; Pp = 5;
            vCell = 3.7; iPackTrue = 20;   % 20 A into the pack

            % layout A: one entry per cell, S*P entries
            Pa = tc.monParams('SeriesCount',S, 'I_sign',1);
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
            P = tc.monParams('SeriesCount',10, 'I_sign',-1);
            % A battery model reporting +5 A per element while discharging
            m = bcp_pack_monitor(repmat(3.6,10,1), repmat(0.5,10,1), ...
                                 repmat(5,10,1), P);
            tc.verifyEqual(m(bcp.Signals.I_PACK), -5, 'AbsTol',1e-9, ...
                'I_sign = -1 must turn a discharge-positive array into charge-negative.');
        end

        function simscapePolarityNeedsNoFlip(tc)
        %SIMSCAPEPOLARITYNEEDSNOFLIP  The package default, tested as a default.
        %
        %   Simscape Battery components declare cell current "positive in",
        %   which is positive while CHARGING -- the same convention this package
        %   uses. So I_sign = +1 passes the array through unchanged, and a
        %   discharge arrives negative. The opposite default is what made the
        %   BMS latch an over-current-CHARGE fault during a discharge pulse.
            P = bcp.BmsConfig().monitorParams();
            tc.verifyEqual(P.I_sign, 1, ...
                'The shipped default must be +1: Simscape packs are charge-positive.');
            m = bcp_pack_monitor(repmat(3.6,14,1), repmat(0.5,14,1), ...
                                 repmat(-42,14,1), P);
            tc.verifyEqual(m(bcp.Signals.I_PACK), -42, 'AbsTol',1e-9, ...
                'A discharging Simscape pack must read NEGATIVE at the BMS.');
        end

        function percentSocIsScaled(tc)
            P = tc.monParams('SeriesCount',4, 'SOC_in_percent',true);
            m = bcp_pack_monitor(repmat(3.6,4,1), [40;50;60;70], zeros(4,1), P);
            tc.verifyEqual(m(bcp.Signals.SOC_PACK), 0.55, 'AbsTol',1e-9);
            tc.verifyEqual(m(bcp.Signals.SOC_MIN),  0.40, 'AbsTol',1e-9);
            tc.verifyEqual(m(bcp.Signals.SOC_MAX),  0.70, 'AbsTol',1e-9);
        end

        function extremesTrackTheWorstCell(tc)
            P = tc.monParams('SeriesCount',4);
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

        function faultMasksAreSumsNotSeparateCodes(tc)
        %FAULTMASKSARESUMSNOTSEPARATECODES  Why a run reports 10 and then asks
        %   what fault code 10 is. It is not a code -- it is 8 + 2.
        %
        %   And the ORDER is diagnostic. Over-current confirms in t_i_trip and a
        %   voltage fault in t_v_trip, so a discharge over-draw big enough to
        %   also breach the voltage limit shows 8 alone first and picks up the
        %   2 later. Nothing changed state in between; a slower confirmation
        %   finished.
            P = tc.protParams('Ts',0.01, 't_i_trip',0.10, 't_v_trip',0.50, ...
                'I_dch_peak',300, 'V_uv_trip',2.50, 'AutoRecover',false);

            % 400 A of discharge at 2.4 V/cell: over the fast discharge tier and
            % under the under-voltage threshold at the same instant.
            for k = 1:round(0.20/P.Ts)
                [~,~,~,~,faults] = bcp_protection(2.40, 3.6, 25, -400, false, P);
            end
            tc.verifyEqual(faults, 8, ...
                'At 0.2 s only the fast over-current tier has confirmed.');

            for k = 1:round(0.40/P.Ts)
                [~,~,~,~,faults] = bcp_protection(2.40, 3.6, 25, -400, false, P);
            end
            tc.verifyEqual(faults, 10, ...
                'By 0.6 s the under-voltage dwell has completed too, and 8+2 = 10.');

            tc.verifyEqual(bcp.Signals.faultBits(10), 'UV + OC_discharge', ...
                'faultBits is what turns the mask back into words.');
            tc.verifyEqual(bcp.Signals.faultBits(5), 'OV + OC_charge', ...
                'The charge-direction equivalent: 4 + 1.');
        end
    end

    % =====================================================================
    methods (Test)   % ---- protection: recovery that cannot re-trip -------

        function underVoltageWillNotClearOnARestAlone(tc)
        %UNDERVOLTAGEWILLNOTCLEARONARESTALONE  The mechanism that breaks the
        %   cyclic fault chain at its source.
        %
        %   A cell that returns to 3.0 V the instant the load is removed has
        %   stopped losing energy, not gained any. Recovering on that reading is
        %   what lets the trip re-arm into the same load, and the next sag is
        %   deeper because the lap cost charge.
            P = tc.protParams('t_v_trip',0.1, 't_recover',0.2, ...
                'AutoRecover',true, 'Q_uv_reset_Ah',0.02);
            for k = 1:20
                bcp_protection(2.40, 3.6, 25, -50, false, P);
            end

            % Resting inside the clear band for fifty times the recovery dwell,
            % with no current at all. Nothing has been put back.
            for k = 1:1000
                [~, ~, dch_ok] = bcp_protection(3.20, 3.6, 25, 0, false, P);
            end
            tc.verifyEqual(dch_ok, 0, ...
                ['A rest is not a recovery. The under-voltage latch must hold ', ...
                 'until charge has actually gone back in.']);
        end

        function underVoltageClearsOnceEnoughChargeHasGoneIn(tc)
        %UNDERVOLTAGECLEARSONCEENOUGHCHARGEHASGONEIN  The other half: the latch
        %   is not permanent, it is conditional. 10 A for 7.2 s is 0.02 Ah.
            % The charge trips are raised because this test pushes 10 A in, and
            % the DEFAULT charge trips are sized for a 14S5P cell pack at 4.35 A.
            % Leaving them alone latches an over-current-charge fault at 0.1 s and
            % the test would be measuring that instead.
            P = tc.protParams('t_v_trip',0.1, 't_recover',0.2, ...
                'AutoRecover',true, 'Q_uv_reset_Ah',0.02, ...
                'I_chg_trip',100, 'I_chg_peak',200);
            for k = 1:20
                bcp_protection(2.40, 3.6, 25, -50, false, P);
            end

            n = round(0.02*3600/10 / P.Ts);          % 720 samples at 10 A
            for k = 1:n-100
                [~, ~, dch_ok, ~, ~, ~, info] = ...
                    bcp_protection(3.20, 3.6, 25, 10, false, P);
            end
            tc.verifyEqual(dch_ok, 0, 'Short of the requirement it must still hold.');
            tc.verifyLessThan(info(3), 0.02, ...
                'info(3) is the Ah counted so far, and it should not be there yet.');

            for k = 1:200
                [~, ~, dch_ok] = bcp_protection(3.20, 3.6, 25, 10, false, P);
            end
            tc.verifyEqual(dch_ok, 1, ...
                'Past the requirement, with the pack in the clear band, it clears.');
        end

        function onlyChargeCountsTowardTheUnderVoltageRequirement(tc)
        %ONLYCHARGECOUNTSTOWARDTHEUNDERVOLTAGEREQUIREMENT  Net would be wrong:
        %   a pack oscillating around zero current would accumulate credit it
        %   never earned. The accumulator takes max(I, 0) for that reason.
            P = tc.protParams('t_v_trip',0.1, 'Q_uv_reset_Ah',0.02, ...
                'AutoRecover',true, 't_recover',0.2);
            for k = 1:20, bcp_protection(2.40, 3.6, 25, -50, false, P); end
            for k = 1:500
                [~,~,~,~,~,~, info] = bcp_protection(3.20, 3.6, 25, -10, false, P);
            end
            tc.verifyEqual(info(3), 0, ...
                'Discharging while under-voltage must count for nothing.');
        end

        function eachRecoveryDemandsALongerDwell(tc)
        %EACHRECOVERYDEMANDSALONGERDWELL  The exponential backoff, read off
        %   info(4) rather than inferred from timing.
            P = tc.protParams('t_v_trip',0.1, 't_recover',0.5, ...
                'AutoRecover',true, 'Retry_Backoff_x',3, ...
                't_recover_max_s',60, 't_retry_window_s',30, ...
                'Q_uv_reset_Ah',0, 'V_ov_trip',4.20, 'V_ov_clear',4.10);

            dwell = zeros(3,1);
            for r = 1:3
                for k = 1:20, bcp_protection(3.6, 4.30, 25, 0, false, P); end
                [~,~,~,~,~,~, info] = bcp_protection(3.6, 4.30, 25, 0, false, P);
                dwell(r) = info(4);
                % Sit in the clear band long enough for whatever this recovery
                % now costs, but not long enough to reset the retry counter.
                for k = 1:round(min(info(4)+0.5, 25)/P.Ts)
                    bcp_protection(3.6, 3.60, 25, 0, false, P);
                end
            end

            tc.verifyEqual(dwell(1), 0.5, 'AbsTol', 1e-9, ...
                'The first recovery costs t_recover.');
            tc.verifyEqual(dwell(2), 1.5, 'AbsTol', 1e-9, ...
                'The second costs Retry_Backoff_x times that.');
            tc.verifyEqual(dwell(3), 4.5, 'AbsTol', 1e-9, ...
                'And the third again -- each lap of a cycle gets slower.');
        end

        function enoughRetriesWithdrawsAutoRecovery(tc)
        %ENOUGHRETRIESWITHDRAWSAUTORECOVERY  Past N_retry_max the pack stops
        %   reconnecting itself, reports state 5, and waits for a human.
            P = tc.protParams('t_v_trip',0.1, 't_recover',0.2, ...
                'AutoRecover',true, 'Retry_Backoff_x',1, 'N_retry_max',2, ...
                't_retry_window_s',1000, 'Q_uv_reset_Ah',0, ...
                'V_ov_trip',4.20, 'V_ov_clear',4.10);

            for r = 1:3
                for k = 1:20, bcp_protection(3.6, 4.30, 25, 0, false, P); end
                for k = 1:60,  bcp_protection(3.6, 3.60, 25, 0, false, P); end
            end
            for k = 1:20, bcp_protection(3.6, 4.30, 25, 0, false, P); end
            for k = 1:500
                [~, chg_ok, ~, state, ~, ~, info] = ...
                    bcp_protection(3.6, 3.60, 25, 0, false, P);
            end
            tc.verifyEqual(info(2), 1, 'The lockout latch must be set.');
            tc.verifyEqual(state, 5, ...
                'And state must say LOCKOUT rather than FAULT, so it is visible.');
            tc.verifyEqual(chg_ok, 0, ...
                'A lockout is still a latched fault: no automatic clearing.');

            % A reset edge answers the lockout, the backoff and the charge
            % requirement -- but not the clear band, which is already satisfied.
            bcp_protection(3.6, 3.60, 25, 1, true, P);
            [~, chg_ok, ~, ~, ~, ~, info] = ...
                bcp_protection(3.6, 3.60, 25, 1, true, P);
            tc.verifyEqual(chg_ok, 1, 'A reset edge must clear a lockout.');
            tc.verifyEqual(info(1), 0, 'and reset the retry counter with it.');
        end

        function theRetryCounterResetsAfterACleanSpell(tc)
        %THERETRYCOUNTERRESETSAFTERACLEANSPELL  Otherwise two unrelated faults
        %   an hour apart would eventually lock out a healthy pack.
            P = tc.protParams('t_v_trip',0.1, 't_recover',0.2, ...
                'AutoRecover',true, 'Retry_Backoff_x',3, ...
                't_retry_window_s',2.0, 'Q_uv_reset_Ah',0, ...
                'V_ov_trip',4.20, 'V_ov_clear',4.10);

            for k = 1:20, bcp_protection(3.6, 4.30, 25, 0, false, P); end
            for k = 1:50, bcp_protection(3.6, 3.60, 25, 0, false, P); end
            [~,~,~,~,~,~, info] = bcp_protection(3.6, 3.60, 25, 0, false, P);
            tc.verifyEqual(info(1), 1, 'One recovery, so one retry counted.');

            for k = 1:400, bcp_protection(3.6, 3.60, 25, 0, false, P); end
            [~,~,~,~,~,~, info] = bcp_protection(3.6, 3.60, 25, 0, false, P);
            tc.verifyEqual(info(1), 0, ...
                'After t_retry_window_s of running clean, the count is stale.');
        end

        function aCleanSpellAlsoForgivesTheLockout(tc)
        %ACLEANSPELLALSOFORGIVESTHELOCKOUT  The lockout is armed one sample AFTER
        %   the Nth successful clear, so there is a moment when nothing is
        %   latched and it is already set. If a clean retry window does not clear
        %   it too, a pack that recovered N times, then ran perfectly for the
        %   whole window, is refused its next automatic recovery for the rest of
        %   the run -- for a fault it demonstrably recovered from.
        %
        %   This cannot be exploited by a pack that is genuinely cycling: a
        %   locked-out fault holds the latch, which pins the clean-time counter
        %   at zero, so the window never expires while it matters.
            P = tc.protParams('t_v_trip',0.1, 't_recover',0.2, ...
                'AutoRecover',true, 'Retry_Backoff_x',1, 'N_retry_max',2, ...
                't_retry_window_s',1.0, 'Q_uv_reset_Ah',0, ...
                'V_ov_trip',4.20, 'V_ov_clear',4.10);

            % Two recoveries back to back, which arms the lockout.
            for r = 1:2
                for k = 1:20, bcp_protection(3.6, 4.30, 25, 0, false, P); end
                for k = 1:40, bcp_protection(3.6, 3.60, 25, 0, false, P); end
            end
            [~,~,~,~,~,~, info] = bcp_protection(3.6, 3.60, 25, 0, false, P);
            tc.verifyEqual(info(2), 1, ...
                'Precondition: two recoveries at N_retry_max = 2 arms the lockout.');

            % Now run clean for longer than the window.
            for k = 1:200, bcp_protection(3.6, 3.60, 25, 0, false, P); end
            [~,~,~,~,~,~, info] = bcp_protection(3.6, 3.60, 25, 0, false, P);
            tc.verifyEqual(info(2), 0, ...
                'A clean retry window must clear the lockout as well as the count.');

            % ...and the next fault recovers automatically again.
            for k = 1:20, bcp_protection(3.6, 4.30, 25, 0, false, P); end
            for k = 1:60
                [~, chg_ok, ~, state] = bcp_protection(3.6, 3.60, 25, 0, false, P);
            end
            tc.verifyEqual(chg_ok, 1, ...
                'The forgiven pack must be allowed to recover on its own again.');
            tc.verifyNotEqual(state, 5, 'and must not report LOCKOUT.');
        end
    end

    % =====================================================================
    methods (Test)   % ---- load limiter ------------------------------------

        function limiterPassesTheDemandWhenThereIsMargin(tc)
            P = tc.limParams();
            [~, f] = bcp_load_limiter(1000, 3.60, -20, 1, P);
            tc.verifyEqual(f, 1, ...
                'With the pack nowhere near a limit, nothing should be derated.');
        end

        function voltageFoldbackClosesTheLimit(tc)
        %VOLTAGEFOLDBACKCLOSESTHELIMIT  Below V_fold_end the limit closes, and
        %   the load command follows it down.
            P = tc.limParams();
            f0 = tc.runLimiter(P, 1,  P.V_fold_end - 0.05, -200, 1);
            f1 = tc.runLimiter(P, 50, P.V_fold_end - 0.05, -200, 1);
            tc.verifyLessThan(f1, f0, 'The limit must close while the cell is low.');
            [y, f] = bcp_load_limiter(1000, P.V_fold_end - 0.05, -200, 1, P);
            tc.verifyEqual(y, 1000*f, 'AbsTol', 1e-12, ...
                'And the command must be exactly the fraction times the demand.');
        end

        function theRateOfClosingScalesWithHowFarOutsideTheBand(tc)
        %THERATEOFCLOSINGSCALESWITHHOWFAROUTSIDETHEBAND  A proportional rate,
        %   capped -- which is what makes the loop stable near the pack's
        %   maximum power point, where dV/dP is unbounded.
            P = tc.limParams();
            n = 3;              % short enough that nothing reaches Fold_Floor
            near = 1 - tc.runLimiter(P, n, P.V_fold_end - 0.01, -200, 1);
            clear bcp_load_limiter
            far  = 1 - tc.runLimiter(P, n, P.V_fold_end - 0.50, -200, 1);
            tc.verifyGreaterThan(far, 3*near, ...
                'Deeper below the band must close the limit substantially faster.');

            % ...but never faster than the cap, however absurd the error. This is
            % the property the stability argument rests on: the step per sample
            % is bounded by rate*Ts whatever dV/dP has become.
            clear bcp_load_limiter
            capped = 1 - tc.runLimiter(P, n, P.V_fold_end - 50, -200, 1);
            tc.verifyEqual(capped, far, 'AbsTol', 1e-12, ...
                'A hundredfold larger error must not close the limit any faster.');
            tc.verifyEqual(capped, n * P.Fold_Fall_per_s * P.Ts, 'AbsTol', 1e-12, ...
                'and the cap is exactly Fold_Fall_per_s.');
        end

        function theLimitHoldsStillInsideTheDeadband(tc)
        %THELIMITHOLDSSTILLINSIDETHEDEADBAND  What stops the integrator hunting.
            P = tc.limParams();
            tc.runLimiter(P, 10, P.V_fold_end - 0.05, -200, 1);     % close it to about 0.5
            mid = 0.5*(P.V_fold_end + P.V_fold_start);
            fa = tc.runLimiter(P, 1,   mid, -200, 1);
            fb = tc.runLimiter(P, 500, mid, -200, 1);
            tc.verifyEqual(fb, fa, 'AbsTol', 1e-12, ...
                'Between the two thresholds the limit must not move at all.');
        end

        function theLimitReopensOnlyWhileCurrentIsFlowing(tc)
        %THELIMITREOPENSONLYWHILECURRENTISFLOWING  An open-circuit voltage is
        %   not evidence the pack can deliver power -- it is exactly the reading
        %   that misled the bang-bang trip.
            P = tc.limParams();
            tc.runLimiter(P, 10, P.V_fold_end - 0.05, -200, 1);
            atRest = tc.runLimiter(P, 500, 4.00, 0, 1);
            tc.verifyLessThan(atRest, 0.99, ...
                'A relaxed cell at zero current must not reopen the limit.');

            underLoad = tc.runLimiter(P, 500, 4.00, -2*P.I_learn_A, 1);
            tc.verifyGreaterThan(underLoad, atRest, ...
                'With current actually flowing, the limit reopens.');
        end

        function chargingAlsoCountsAsEvidence(tc)
        %CHARGINGALSOCOUNTSASEVIDENCE  Charge is replacing what the load took,
        %   so it is a reason to reopen. This is what stops a limit that closed
        %   near empty from staying closed after the pack is topped back up.
            P = tc.limParams();
            tc.runLimiter(P, 10, P.V_fold_end - 0.05, -200, 1);
            before = tc.runLimiter(P, 1,   4.00, 2*P.I_learn_A, 1);
            after  = tc.runLimiter(P, 300, 4.00, 2*P.I_learn_A, 1);
            tc.verifyGreaterThan(after, before, ...
                'Positive current must reopen the limit as readily as negative.');
        end

        function closingIsFasterThanReopening(tc)
            P = tc.limParams();
            tc.verifyGreaterThan(P.Fold_Fall_per_s, P.Fold_Rise_per_s, ...
                ['Cells sag in milliseconds and recover over seconds. A limiter ', ...
                 'that reopened as fast as it closed is the trip again.']);
        end

        function currentFoldbackIsKeyedToTheFastTier(tc)
        %CURRENTFOLDBACKISKEYEDTOTHEFASTTIER  Not the sustained tier: that one
        %   exists to be exceeded briefly by a pulse the pack is rated for, so
        %   folding back against it would derate the designed test.
            b = bcp.BmsConfig();
            P = b.limiterParams();
            tc.verifyEqual(P.I_fold_end, b.I_dch_peak_A, ...
                'Full derate must coincide with the FAST trip, not the sustained one.');
            tc.verifyGreaterThan(P.I_fold_start, b.I_dch_trip, ...
                ['Current foldback must start above the sustained trip, or every ', ...
                 'rated pulse is derated.']);

            % Above the start point the limit closes even with the voltage fine.
            f = tc.runLimiter(P, 100, 3.60, -(P.I_fold_end + 10), 1);
            tc.verifyLessThan(f, 0.99, ...
                'Past the fast tier the current margin must close the limit.');
        end

        function inhibitFreezesTheLimitRatherThanResettingIt(tc)
        %INHIBITFREEZESTHELIMITRATHERTHANRESETTINGIT  The pre-trip limit was
        %   demonstrably too high, and that is the one useful thing the failed
        %   attempt established. Throwing it away on recovery restarts the cycle.
            P = tc.limParams();
            held = tc.runLimiter(P, 10, P.V_fold_end - 0.05, -200, 1);
            tc.verifyLessThan(held, 0.99, 'Precondition: the limit closed.');

            for k = 1:200
                [y, f] = bcp_load_limiter(1000, 4.00, 0, 0, P);
            end
            tc.verifyEqual(y, 0, 'An inhibit means zero load, whatever the limit is.');
            tc.verifyEqual(f, 0, 'and dcl_frac reports zero, not the frozen value.');

            [~, ~, ~, fold] = bcp_load_limiter(1000, 4.00, 0, 0, P);
            tc.verifyEqual(fold, held, 'AbsTol', 1e-9, ...
                'But the underlying limit must be frozen at what it had learned.');
        end

        function softStartRampsTheLoadBackAfterAnInhibit(tc)
            P = tc.limParams('t_softstart_s',0.5);
            bcp_load_limiter(1000, 4.00, 0, 0, P);          % inhibited
            [~, f1, st] = bcp_load_limiter(1000, 4.00, 0, 1, P);
            tc.verifyLessThan(f1, 0.1, ...
                'The first sample after permission returns must be near zero.');
            tc.verifyEqual(st, 3, 'and limit_state must say soft-start.');

            for k = 1:round(P.t_softstart_s/P.Ts) + 5
                [~, f2] = bcp_load_limiter(1000, 4.00, 0, 1, P);
            end
            tc.verifyEqual(f2, 1, 'AbsTol', 1e-9, ...
                'and the ramp must reach full demand in t_softstart_s.');
        end

        function limitStateNamesTheBindingConstraint(tc)
            P = tc.limParams('t_softstart_s',0);
            [~,~,st] = bcp_load_limiter(1000, 3.60, -20, 1, P);
            tc.verifyEqual(st, 0, 'Nothing binding.');
            [~,~,st] = bcp_load_limiter(1000, 3.60, -20, 0, P);
            tc.verifyEqual(st, 4, 'Held off by protection.');
            tc.verifyEqual(bcp.Signals.limitState(1), 'voltage foldback');
            tc.verifyEqual(bcp.Signals.limitState(2), 'current foldback');
        end

        function disablingTheLimiterRestoresTheOldHardGate(tc)
        %DISABLINGTHELIMITERRESTORESTHEOLDHARDGATE  Bit for bit, because it is
        %   the configuration every result from before the limiter was produced
        %   under, and a reproduction that is nearly the same is not one.
            P = tc.limParams('Enabled',false);
            for k = 1:200
                [y, f, st] = bcp_load_limiter(1000, 1.00, -1e6, 1, P);
            end
            tc.verifyEqual(y, 1000, ...
                'Disabled, the demand passes untouched however bad the pack looks.');
            tc.verifyEqual(f, 1);
            tc.verifyEqual(st, 0);

            [y, f, st] = bcp_load_limiter(1000, 3.60, -20, 0, P);
            tc.verifyEqual(y, 0, 'And the inhibit is still a hard gate.');
            tc.verifyEqual(f, 0);
            tc.verifyEqual(st, 4);
        end
    end

    % =====================================================================
    methods (Test)   % ---- SOC clamping ------------------------------------

        function negativeSocIsClampedButStillReported(tc)
        %NEGATIVESOCISCLAMPEDBUTSTILLREPORTED  A Simscape table_battery
        %   integrates coulombs with no floor, so a pack taken past empty
        %   reports a negative SOC indefinitely. Every SOC comparison in this
        %   package is written against 0..1, so the clamp is load-bearing -- and
        %   the raw value has to survive it or the modelling problem is hidden.
            P = tc.monParams('SeriesCount',3, 'I_sign',1, 'SOC_clamp',true);
            [meas, raw] = bcp_pack_monitor([3.2;3.2;3.2], [-0.004;0.01;0.02], ...
                                           [-5;-5;-5], P);
            tc.verifyEqual(meas(bcp.Signals.SOC_MIN), 0, ...
                'The reported minimum must be clamped to zero.');
            tc.verifyEqual(raw(1), -0.004, 'AbsTol', 1e-12, ...
                'and the unclamped value must still be published.');
            tc.verifyGreaterThanOrEqual(meas(bcp.Signals.SOC_PACK), 0, ...
                'The mean must be computed from clamped values, not clamped after.');
        end

        function socClampCanBeTurnedOff(tc)
            P = tc.monParams('SeriesCount',3, 'SOC_clamp',false);
            meas = bcp_pack_monitor([3.2;3.2;3.2], [-0.004;0.01;0.02], ...
                                    [-5;-5;-5], P);
            tc.verifyEqual(meas(bcp.Signals.SOC_MIN), -0.004, 'AbsTol', 1e-12, ...
                'Off, the battery model''s value passes through untouched.');
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
                'I_chg_max_A',22.5);
            [en, lim] = bcp_arbiter(1, 0.50, 3.7, 1, 0, P);
            tc.verifyEqual(en, 1, 'Concurrent mode charges through an active load.');
            tc.verifyEqual(lim, 5, 'AbsTol',1e-9, ...
                'Under load, the ceiling must be the concurrent headroom.');
            [~, lim] = bcp_arbiter(0, 0.50, 3.7, 1, 0, P);
            tc.verifyEqual(lim, 22.5, 'AbsTol',1e-9, ...
                ['With no load, the ceiling is the configured charge rate itself ', ...
                 '-- not a derated fault threshold.']);
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
        %FARFROMTARGETRUNSATTHECEILING  In CC the command sits on whichever
        %   ceiling is lower, and in the real system that is the BMS's -- the
        %   charge rate it publishes on I_limit. P.I_cc_A is the supply's own
        %   rating and is sized at the pack maximum, so it is deliberately NOT
        %   the binding one. Passing a realistic limit here is the honest test;
        %   an unbounded one exercises a configuration that cannot occur.
            P = tc.chgParams();
            bmsCeiling = bcp.BmsConfig().fromPack( ...
                bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5)).I_chg_max_A;
            tc.assumeLessThan(bmsCeiling, P.I_cc_A, ...
                'The supply must be the larger of the two for this test to mean anything.');
            [I, ~, mode] = bcp_charger(50, 3.70, 0, 1, bmsCeiling, P);
            tc.verifyEqual(mode, 2, 'Well below the CV target the mode must be CC.');
            tc.verifyEqual(I, bmsCeiling, 'AbsTol',1e-9, ...
                'and the command must sit on the BMS ceiling, not on the supply rating.');
        end

        function arbiterLimitDeratesTheCommand(tc)
            P = tc.chgParams();
            [I, ~, mode] = bcp_charger(50, 3.70, 0, 1, 4, P);
            tc.verifyEqual(I, 4, 'AbsTol',1e-9, ...
                'The arbiter''s ceiling must bind even in CC.');
            tc.verifyEqual(mode, 2);
        end

        function nearTargetTheVoltageLoopTakesOver(tc)
        %NEARTARGETTHEVOLTAGELOOPTAKESOVER  The mode change has to wait out
        %   t_mode_min_s -- one sample is not enough, deliberately. A mode that
        %   can flip on any single sample is a mode that chatters every sample
        %   while the command sits on the ceiling.
            P = tc.chgParams();
            n = ceil(P.t_mode_min_s / P.Ts) + 5;
            for k = 1:n
                [I, ~, mode] = bcp_charger(58.0, P.V_cv_cell - 0.002, 0, 1, 1e6, P);
            end
            tc.verifyEqual(mode, 3, ...
                'A few millivolts from the target, the voltage loop must bind.');
            tc.verifyLessThan(I, P.I_cc_A);
            tc.verifyGreaterThanOrEqual(I, 0);
        end

        function modeDoesNotChatterAtTheKnee(tc)
        %MODEDOESNOTCHATTERATTHEKNEE  The limit cycle this hysteresis exists for.
        %
        %   Hold the pack exactly where the command sits on the current ceiling
        %   and jitter the measured cell voltage by a fraction of a millivolt,
        %   which is what a real solver does. With a bare comparison against the
        %   ceiling the mode output flips on most samples. It must not.
            P = tc.chgParams();
            Icc = 5;                       % a realistic BMS ceiling, not 1e6
            V = P.V_cv_cell - Icc / P.Kp_cell;   % the voltage that commands Icc
            modes = zeros(400,1);
            for k = 1:400
                jitter = 2e-5 * sin(k/3);   % +/- 20 microvolts
                [~,~,modes(k)] = bcp_charger(58.0, V + jitter, 0, 1, Icc, P);
            end
            flips = sum(diff(modes(50:end)) ~= 0);
            tc.verifyLessThanOrEqual(flips, 2, ...
                sprintf(['The reported mode changed %d times while the pack sat ', ...
                         'still at the CC/CV knee. That is the limit cycle the ', ...
                         'hysteresis band and the minimum dwell exist to stop.'], flips));
        end

        function theHighestCellIsWhatIsRegulated(tc)
        %THEHIGHESTCELLISWHATISREGULATED  A pack whose average is fine but whose
        %   worst cell is at the limit must still be held back. This is the test
        %   that distinguishes a per-cell CV loop from a pack-voltage one.
            P = tc.chgParams();
            packWellBelowTarget = P.V_cv_pack - 2.0;
            n = ceil(P.t_mode_min_s / P.Ts) + 5;
            for k = 1:n
                [I, ~, mode] = bcp_charger(packWellBelowTarget, P.V_cv_cell, ...
                                           0, 1, 1e6, P);
            end
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
            % Which of PRECHARGE / CC / CV it re-enters depends on how far below
            % the target the pack has fallen and on the ceiling it is given, and
            % none of those is what this test is about. What matters is that it
            % is charging again rather than still reporting DONE.
            tc.verifyTrue(any(mode == [1 2 3]), ...
                'A re-armed charger must report an active charging mode, not DONE.');
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
            tc.verifyEqual(spec.R_dc_Ohm, 0.015*14/5, 'AbsTol',1e-12);
            tc.verifyEqual(spec.I_chg_max_A, 67.5, 'AbsTol',1e-9, ...
                'The datasheet MAXIMUM charge current is 13.5 A per cell, not the standard 4.35 A.');
            tc.verifyEqual(spec.I_dch_pulse_A, 337.5, 'AbsTol',1e-9);
            tc.verifyEqual(spec.Wh, 22.5*50.4, 'AbsTol',1e-6);
        end

        function autofillMatchesHandCalculation(tc)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',14, 'P',5);
            c = bcp.ChargerConfig.fromPack(spec);
            tc.verifyEqual(c.I_cc_A, 67.5, 'AbsTol',1e-9, ...
                ['I_cc_A is the SUPPLY rating, and auto-fill sizes it at the pack ', ...
                 'datasheet maximum so the supply is never the thing quietly ', ...
                 'limiting a test. The charge RATE is bcp.BmsConfig.I_chg_max_A.']);
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
            % 5C is 112.5 A on this pack, above its 67.5 A datasheet maximum.
            c = tc.verifyWarning( ...
                @() bcp.ChargerConfig.fromPack(spec, 'C_rate', 5), ...
                'bcp:ChargerConfig:OverCRate');
            tc.verifyEqual(c.I_cc_A, spec.I_chg_max_A, 'AbsTol',1e-9);
        end

        function bmsAutofillDefaultsTheRateToTheStandardCharge(tc)
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P50B(), 'S',20, 'P',4);
            b = bcp.BmsConfig().fromPack(spec);
            c = bcp.ChargerConfig.fromPack(spec);
            tc.verifyEqual(b.I_chg_max_A, spec.I_chg_std_A, 'AbsTol',1e-9, ...
                ['The default charge RATE is the datasheet standard charge. The ', ...
                 'P50B maximum is 5C, qualified by a temperature cutoff this ', ...
                 'package cannot enforce, so it is a ceiling and not a default.']);
            tc.verifyGreaterThan(b.I_chg_trip, b.I_chg_max_A, ...
                ['The over-current trip must sit above the rate the BMS itself ', ...
                 'permits, or every charge faults out at the moment it works.']);
            tc.verifyGreaterThanOrEqual(c.I_cc_A, b.I_chg_max_A, ...
                'The supply must be able to source the rate the BMS permits.');
            tc.verifyEqual(b.V_ov_trip, 4.25, 'AbsTol',1e-9, ...
                'The trip is the 4.20 V cutoff plus 50 mV of fault margin.');
            tc.verifyEqual(b.V_uv_trip, 2.50, 'AbsTol',1e-9, ...
                ['The under-voltage trip sits ON the datasheet end-of-discharge ', ...
                 'voltage. Below it is not margin, it is over-discharge.']);
            tc.verifyGreaterThan(b.V_ov_trip, c.V_cv_cell);
            tc.verifyEqual(b.SeriesCount, 20);
        end

        function overCurrentIsStagedInTwoTiers(tc)
        %OVERCURRENTISSTAGEDINTWOTIERS  The reason a pulse test no longer needs
        %   its discharge trip raised by hand.
            spec = bcp.PackSpec('Cell', bcp.CellLibrary.P45B(), 'S',195, 'P',1);
            b = bcp.BmsConfig().fromPack(spec);
            tc.verifyGreaterThan(b.I_dch_peak_A, b.I_dch_trip, ...
                'The fast tier must sit above the sustained tier.');
            tc.verifyGreaterThan(b.t_i_cont_s, b.t_i_trip, ...
                'and confirm over a shorter time, not a longer one.');

            % A 2 s pulse at 55 A: above the continuous rating, well inside the
            % pulse rating. It must reach neither tier.
            P = b.protectionParams();
            faults = 0;
            for k = 1:round(2 / P.Ts)
                [~,~,~,~,faults] = bcp_protection(3.2, 3.4, 25, -55, false, P);
            end
            tc.verifyEqual(faults, 0, ...
                ['A 2 s pulse above the CONTINUOUS rating must not trip: the ', ...
                 'sustained tier needs ten seconds of dwell and the fast tier is ', ...
                 'far higher. This is the case one trip cannot get right.']);

            % The same current that never stops does have to latch.
            clear bcp_protection
            for k = 1:round(12 / P.Ts)
                [~,~,~,~,faults] = bcp_protection(3.2, 3.4, 25, -55, false, P);
            end
            tc.verifyNotEqual(faults, 0, ...
                'Held past t_i_cont_s, the same current is a sustained over-draw.');
        end

        function setChargeCurrentMovesEverythingThatMatters(tc)
        %SETCHARGECURRENTMOVESEVERYTHINGTHATMATTERS  One call, and nothing left
        %   behind to clip the new rate in some other block.
            p = bcp.Project();
            p = p.setChargeCurrent(3 * p.Bms.I_chg_max_A);
            I = p.Bms.I_chg_max_A;
            tc.verifyGreaterThan(p.Bms.I_chg_trip,   I, 'sustained trip follows');
            tc.verifyGreaterThan(p.Bms.I_chg_peak_A, p.Bms.I_chg_trip, 'fast trip follows');
            tc.verifyGreaterThanOrEqual(p.Charger.I_cc_A, I, 'supply current follows');
            tc.verifyGreaterThanOrEqual(p.Charger.P_chg_max_W, I * p.Pack.V_max, ...
                ['The supply POWER ceiling has to follow too. It is the second ', ...
                 'thing that silently clipped a raised charge rate.']);
            % check() will note that a rate above the datasheet standard charge
            % is unenforced without a temperature input, which is true and is
            % the point of saying it. What must NOT survive is any complaint
            % about the supply or its power ceiling binding first.
            issues = p.check();
            tc.verifyFalse(any(contains(issues, 'supply')), ...
                ['Nothing in the charger may be left behind clipping the new ', ...
                 'rate. That was the whole failure this call exists to prevent.']);
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
