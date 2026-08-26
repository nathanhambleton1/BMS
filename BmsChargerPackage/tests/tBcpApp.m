classdef tBcpApp < matlab.unittest.TestCase
%TBCPAPP  Tests for the UI's wiring to bcp.Project.
%
%   Not tests of how the window looks -- tests of the one thing a UI over a
%   configuration object can get wrong without anybody noticing: the window and
%   the object disagreeing. A control bound to the wrong property, a repaint
%   that misses a field, a rejected value left on screen. Each of those produces
%   a model built from settings you were not looking at.
%
%       runtests('tBcpApp')

    properties
        App
    end

    methods (TestMethodSetup)
        function makeApp(tc)
            tc.App = bcpApp();
            tc.addTeardown(@() delete(tc.App));
        end
    end

    methods (Test)

        function everyControlIsBoundToARealProperty(tc)
        %EVERYCONTROLISBOUNDTOAREALPROPERTY  A path that does not resolve throws
        %   inside bindings(), so this passing at all is the assertion.
            T = tc.App.bindings();
            tc.verifyGreaterThan(height(T), 30, ...
                'The tabs should bind a few dozen fields.');
            tc.verifyEqual(numel(unique(T.Path)), height(T), ...
                'Two controls bound to the same property would fight each other.');
        end

        function windowAgreesWithTheObject(tc)
            T = tc.App.bindings();
            tc.verifyEqual(T.OnScreen, T.InObject, 'AbsTol', 1e-9, ...
                'Every control must show what the object holds.');
        end

        function autofillRepaintsFieldsNobodyTouched(tc)
        %AUTOFILLREPAINTSFIELDSNOBODYTOUCHED  The reason the whole window is
        %   repainted after any mutation rather than only the control that fired.
            tc.App.poke('Pack.S', 20);
            tc.App.poke('Pack.P', 4);
            tc.App.Proj = tc.App.Proj.autofillAll();
            tc.App.poke('Bms.Ts', tc.App.Proj.Bms.Ts);   % forces a repaint

            T = tc.App.bindings();
            tc.verifyEqual(T.OnScreen, T.InObject, 'AbsTol', 1e-9, ...
                'After auto-fill, every control must still match the object.');
        end

        function changingSeriesCountRescalesThePackCVTarget(tc)
            tc.App.poke('Pack.S', 20);
            T = tc.App.bindings();
            row = strcmp(T.Path, 'Charger.V_cv_pack');
            tc.verifyEqual(T.OnScreen(row), 20 * tc.App.Proj.Charger.V_cv_cell, ...
                'AbsTol', 1e-9, ...
                ['A 14S pack target left behind on a 20S pack would bind the pack ' ...
                 'loop permanently and stop the charge a quarter of the way up.']);
        end

        function rejectedValueIsRevertedNotLeftOnScreen(tc)
        %REJECTEDVALUEISREVERTEDNOTLEFTONSCREEN  SOC_restart above SOC_stop is
        %   invalid, so it must not survive anywhere -- object or window.
            before = tc.App.Proj.Bms.SOC_restart;
            ok = tc.App.poke('Bms.SOC_restart', 0.99);
            tc.verifyFalse(ok, 'A restart SOC above the stop SOC must be rejected.');
            tc.verifyEqual(tc.App.Proj.Bms.SOC_restart, before, ...
                'The object must be rolled back.');

            T = tc.App.bindings();
            tc.verifyEqual(T.OnScreen, T.InObject, 'AbsTol', 1e-9, ...
                'and the window must be rolled back with it.');
        end

        function invalidSampleTimeIsRejected(tc)
            ok = tc.App.poke('Bms.Ts', 0);
            tc.verifyFalse(ok);
            tc.verifyGreaterThan(tc.App.Proj.Bms.Ts, 0);
        end

        function waveformSelectorShowsOnlyTheLivePanel(tc)
            tc.App.setWaveform('pulse');
            tc.verifyEqual(tc.App.visibleWavePanels(), {'pulse'});
            tc.App.setWaveform('sine');
            tc.verifyEqual(tc.App.visibleWavePanels(), {'sine'});
            tc.App.setWaveform('off');
            tc.verifyEmpty(tc.App.visibleWavePanels(), ...
                'The "off" waveform has no parameters, so no panel is shown.');
        end

        function switchingWaveformKeepsTheOtherSettings(tc)
        %SWITCHINGWAVEFORMKEEPSTHEOTHERSETTINGS  The promise made on the tab.
            tc.App.setWaveform('pulse');
            tc.App.poke('Load.Pulse_Amplitude_W', 1234);
            tc.App.setWaveform('sine');
            tc.App.setWaveform('pulse');
            tc.verifyEqual(tc.App.Proj.Load.Pulse_Amplitude_W, 1234, ...
                'Pulse settings must survive a trip through the sine tab.');
        end

        function previewMatchesWhatTheBlockWillDo(tc)
            tc.App.setWaveform('pulse');
            tc.App.poke('Load.Pulse_Base_W', 100);
            tc.App.poke('Load.Pulse_Amplitude_W', 700);
            tc.App.poke('Load.Pulse_Duty_pct', 25);
            tc.App.poke('Load.Pulse_Frequency_Hz', 1);

            [~, y] = tc.App.Proj.Load.sample(10, 0.001);
            tc.verifyEqual(max(y), 800, 'AbsTol', 1e-9);
            tc.verifyEqual(min(y), 100, 'AbsTol', 1e-9);
            tc.verifyEqual(tc.App.Proj.Load.meanDemand(), 275, 'AbsTol', 1e-9);
        end

        function configSurvivesASaveAndLoadRoundTrip(tc)
            f = fullfile(tempdir, 'bcp_app_roundtrip.mat');
            tc.addTeardown(@() delete(f));

            tc.App.setWaveform('sine');
            tc.App.poke('Load.Sine_Amplitude_W', 321);
            tc.App.poke('Bms.t_quiet_s', 2.5);
            tc.App.Proj.save(f);

            p = bcp.Project.load(f);
            tc.verifyEqual(p.Load.Sine_Amplitude_W, 321);
            tc.verifyEqual(p.Bms.t_quiet_s, 2.5);
            tc.verifyEqual(p.Load.Waveform, 'sine');
            tc.verifyEmpty(p.check(), ...
                'A round-tripped configuration must still be self-consistent.');
        end
    end
end
