classdef LoadSignal
%BCP.LOADSIGNAL  The dynamic-load demand waveform, as configured on the Load tab.
%
%   One active waveform at a time -- off, constant, sine or pulse -- plus the
%   parameters for each. The parameters for the three inactive waveforms are
%   kept, not cleared, so switching from pulse to sine and back does not lose
%   the pulse settings you spent ten minutes on.
%
%       sig = bcp.LoadSignal('Waveform','pulse', ...
%                            'Pulse_Amplitude_W', 800, ...
%                            'Pulse_Frequency_Hz', 0.5, ...
%                            'Pulse_Duty_pct', 20);
%       sig.preview(30);
%
%   SIGN CONVENTION
%     Positive watts are DRAWN FROM the pack. The whole package is
%     charge-positive internally, and this is the one object that talks in
%     load-positive terms because that is how a dynamic load block is
%     configured. OutputSign flips the polarity at the block's output port if
%     your load block wants negative watts for a draw -- set it once, then
%     forget it.
%
%   WHY THERE IS NO SEGMENT TABLE
%     Deliberately. One waveform covers the pulse testing this was built for,
%     and a schedule of overlapping segments is the next feature, not this one.
%     If you need a composed profile now, run the sample() output through a From
%     Workspace block instead -- toTimeseries() gives you exactly that.

    properties
        % --- which waveform is live ----------------------------------------
        Waveform  char = 'pulse'      % 'off' | 'constant' | 'sine' | 'pulse'

        % --- window (applies to every waveform) -----------------------------
        StartTime_s double = 0        % demand is zero before this
        StopTime_s  double = Inf      % demand is zero from this time on

        % --- constant -------------------------------------------------------
        Const_W double = 200          % steady draw [W]

        % --- sine -----------------------------------------------------------
        Sine_Offset_W    double = 300 % mean draw [W]
        Sine_Amplitude_W double = 200 % peak deviation [W]
        Sine_Frequency_Hz double = 0.2
        Sine_Phase_deg   double = 0

        % --- pulse ----------------------------------------------------------
        Pulse_Base_W      double = 0    % draw between pulses [W]
        Pulse_Amplitude_W double = 800  % additional draw during a pulse [W]
        Pulse_Frequency_Hz double = 0.5 % pulses per second
        Pulse_Duty_pct    double = 20   % percentage of each period that is on
        Pulse_Phase_deg   double = 0

        % --- limits and conditioning ----------------------------------------
        Pmin_W          double = 0      % clamp: 0 blocks accidental regen
        Pmax_W          double = 5000   % clamp: what the load can actually sink
        Slew_W_per_s    double = 0      % 0 = hard edges; see bcp_load_scheduler
        IdleThreshold_W double = 5      % above this the load counts as ACTIVE
        OutputSign      double = 1      % +1, or -1 if your load wants negative W
    end

    methods
        function obj = LoadSignal(varargin)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
            obj = obj.validate();
        end

        function obj = validate(obj)
            assert(any(strcmp(obj.Waveform, {'off','constant','sine','pulse'})), ...
                'bcp:LoadSignal:Waveform', ...
                'Waveform must be off, constant, sine or pulse (got "%s").', obj.Waveform);
            assert(obj.StartTime_s >= 0 && isfinite(obj.StartTime_s), ...
                'bcp:LoadSignal:Start', 'StartTime_s must be finite and >= 0.');
            assert(obj.StopTime_s > obj.StartTime_s, 'bcp:LoadSignal:Stop', ...
                'StopTime_s (%g) must be later than StartTime_s (%g).', ...
                obj.StopTime_s, obj.StartTime_s);
            assert(obj.Pmax_W > obj.Pmin_W, 'bcp:LoadSignal:Clamp', ...
                'Pmax_W (%g) must exceed Pmin_W (%g).', obj.Pmax_W, obj.Pmin_W);
            assert(obj.Slew_W_per_s >= 0, 'bcp:LoadSignal:Slew', ...
                'Slew_W_per_s must be >= 0 (0 disables the limiter).');
            assert(obj.IdleThreshold_W >= 0, 'bcp:LoadSignal:Idle', ...
                'IdleThreshold_W must be >= 0.');
            assert(obj.OutputSign == 1 || obj.OutputSign == -1, ...
                'bcp:LoadSignal:Sign', 'OutputSign must be +1 or -1.');

            switch obj.Waveform
                case 'sine'
                    assert(obj.Sine_Frequency_Hz > 0, 'bcp:LoadSignal:Freq', ...
                        'A sine load needs Sine_Frequency_Hz > 0.');
                case 'pulse'
                    assert(obj.Pulse_Frequency_Hz > 0, 'bcp:LoadSignal:Freq', ...
                        'A pulse load needs Pulse_Frequency_Hz > 0.');
                    assert(obj.Pulse_Duty_pct >= 0 && obj.Pulse_Duty_pct <= 100, ...
                        'bcp:LoadSignal:Duty', 'Pulse_Duty_pct must be 0..100.');
            end

            % A clamp that removes the waveform is almost always a mistake, and
            % it presents as "my load block does nothing" rather than as an error.
            pk = obj.peakDemand();
            if pk > obj.Pmax_W + 1e-9
                warning('bcp:LoadSignal:Clipped', ...
                    ['This waveform peaks at %.0f W but Pmax_W is %.0f W, so ', ...
                     'the top of every pulse is flat. Raise Pmax_W or lower the ', ...
                     'amplitude.'], pk, obj.Pmax_W);
            end
        end

        function w = code(obj)
        %CODE  Waveform name -> the integer bcp_load_scheduler switches on.
            switch obj.Waveform
                case 'off',      w = 0;
                case 'constant', w = 1;
                case 'sine',     w = 2;
                case 'pulse',    w = 3;
                otherwise,       w = 0;
            end
        end

        function p = peakDemand(obj)
        %PEAKDEMAND  Highest instantaneous demand this waveform asks for [W].
            switch obj.Waveform
                case 'off',      p = 0;
                case 'constant', p = obj.Const_W;
                case 'sine',     p = obj.Sine_Offset_W + abs(obj.Sine_Amplitude_W);
                case 'pulse',    p = obj.Pulse_Base_W + obj.Pulse_Amplitude_W;
                otherwise,       p = 0;
            end
        end

        function p = meanDemand(obj)
        %MEANDEMAND  Cycle-average demand [W]. This is what sets your run time:
        %   a pack empties at the mean, not at the peak.
            switch obj.Waveform
                case 'off',      p = 0;
                case 'constant', p = obj.Const_W;
                case 'sine',     p = obj.Sine_Offset_W;
                case 'pulse',    p = obj.Pulse_Base_W + ...
                                     obj.Pulse_Amplitude_W * obj.Pulse_Duty_pct/100;
                otherwise,       p = 0;
            end
            p = min(max(p, obj.Pmin_W), obj.Pmax_W);
        end

        function P = params(obj, Ts)
        %PARAMS  Flatten to the struct bcp_load_scheduler expects.
        %
        %   The active waveform's parameters are mapped onto the generic
        %   Offset/Amplitude/Frequency/Phase/Duty fields here, so the generated
        %   block code carries four numbers rather than fifteen and switching
        %   waveform changes literals rather than structure.
            switch obj.Waveform
                case 'constant'
                    off = obj.Const_W;  amp = 0;   f = 0;
                    ph  = 0;            duty = 100;
                case 'sine'
                    off = obj.Sine_Offset_W;  amp = obj.Sine_Amplitude_W;
                    f   = obj.Sine_Frequency_Hz;  ph = obj.Sine_Phase_deg;
                    duty = 100;
                case 'pulse'
                    off = obj.Pulse_Base_W;   amp = obj.Pulse_Amplitude_W;
                    f   = obj.Pulse_Frequency_Hz; ph = obj.Pulse_Phase_deg;
                    duty = obj.Pulse_Duty_pct;
                otherwise
                    off = 0; amp = 0; f = 0; ph = 0; duty = 100;
            end
            P = struct( ...
                'Ts',              Ts, ...
                'Waveform',        obj.code(), ...
                'StartTime_s',     obj.StartTime_s, ...
                'StopTime_s',      obj.StopTime_s, ...
                'Offset_W',        off, ...
                'Amplitude_W',     amp, ...
                'Frequency_Hz',    f, ...
                'Phase_deg',       ph, ...
                'Duty_pct',        duty, ...
                'Pmin_W',          obj.Pmin_W, ...
                'Pmax_W',          obj.Pmax_W, ...
                'Slew_W_per_s',    obj.Slew_W_per_s, ...
                'IdleThreshold_W', obj.IdleThreshold_W);
        end

        function [t, y, active] = sample(obj, stopTime, Ts)
        %SAMPLE  Render the waveform, using the same code the model will run.
        %
        %   This calls bcp_load_scheduler in a loop rather than reimplementing
        %   the waveform maths. A preview that agrees with the block only
        %   because two copies of the formula happen to match is worthless the
        %   first time one of them changes.
            if nargin < 3 || isempty(Ts), Ts = 0.001; end
            obj.validate();
            P = obj.params(Ts);
            t = (0:Ts:stopTime)';
            y = zeros(size(t));
            active = zeros(size(t));
            clear bcp_load_scheduler          % drop persistent slew state
            for k = 1:numel(t)
                [y(k), active(k)] = bcp_load_scheduler(t(k), P);
            end
            clear bcp_load_scheduler
            y = y * obj.OutputSign;
        end

        function ts = toTimeseries(obj, stopTime, Ts)
        %TOTIMESERIES  For driving a From Workspace block instead of this package's
        %   generated code -- e.g. to compose several profiles offline.
            if nargin < 3, Ts = 0.001; end
            [t, y] = obj.sample(stopTime, Ts);
            ts = timeseries(y, t, 'Name','P_load_cmd');
        end

        function ax = preview(obj, stopTime, ax)
        %PREVIEW  Plot the demand, with the active/idle bands the arbiter sees.
            if nargin < 2 || isempty(stopTime)
                stopTime = obj.suggestedPreviewSpan();
            end
            if nargin < 3 || isempty(ax)
                figure('Name','Load demand preview','Color','w');
                ax = axes();
            end
            [t, y, active] = obj.sample(stopTime, min(0.001, stopTime/2000));

            cla(ax);
            % Shade where the arbiter will refuse to charge. This is the whole
            % point of the preview: you are looking for the gaps.
            hold(ax,'on');
            obj.shadeActive(ax, t, active);
            plot(ax, t, y, 'LineWidth', 1.4);
            yline(ax, 0, 'k:');
            yline(ax, obj.meanDemand()*obj.OutputSign, '--', 'mean', ...
                'LabelHorizontalAlignment','left');
            hold(ax,'off');
            grid(ax,'on');
            xlabel(ax,'Time [s]');
            ylabel(ax,'Load demand [W]');
            title(ax, sprintf('%s  --  peak %.0f W, mean %.0f W%s', ...
                obj.Waveform, obj.peakDemand(), obj.meanDemand(), ...
                obj.shadeNote(active)), 'Interpreter','none');
            xlim(ax, [0 stopTime]);
        end

        function s = suggestedPreviewSpan(obj)
        %SUGGESTEDPREVIEWSPAN  Enough time to see about six cycles, or 30 s.
            f = 0;
            switch obj.Waveform
                case 'sine',  f = obj.Sine_Frequency_Hz;
                case 'pulse', f = obj.Pulse_Frequency_Hz;
            end
            if f > 0
                s = obj.StartTime_s + 6/f;
            else
                s = 30;
            end
            s = min(s, 600);
        end
    end

    methods (Access = private)
        function shadeActive(~, ax, t, active)
            d = diff([0; active(:); 0]);
            starts = find(d > 0);
            stops  = find(d < 0) - 1;
            yl = [-1e9 1e9];
            for k = 1:numel(starts)
                x = [t(starts(k)) t(stops(k)) t(stops(k)) t(starts(k))];
                patch(ax, x, [yl(1) yl(1) yl(2) yl(2)], [1 0.85 0.85], ...
                    'EdgeColor','none', 'FaceAlpha',0.6, ...
                    'HandleVisibility','off');
            end
            ylim(ax,'auto');
        end

        function s = shadeNote(~, active)
            duty = mean(active);
            if duty >= 0.999
                s = '  (load never idle -- no charging window)';
            elseif duty <= 0.001
                s = '';
            else
                s = sprintf('  (load active %.0f%% of the time)', duty*100);
            end
        end
    end

    methods (Static)
        function obj = preset(name)
        %PRESET  Starting points. Copy one, then edit it on the Load tab.
            switch lower(char(name))
                case 'off'
                    obj = bcp.LoadSignal('Waveform','off');
                case 'constant 200 w'
                    obj = bcp.LoadSignal('Waveform','constant','Const_W',200);
                case 'pulse burst'
                    obj = bcp.LoadSignal('Waveform','pulse', ...
                        'Pulse_Base_W',0, 'Pulse_Amplitude_W',800, ...
                        'Pulse_Frequency_Hz',0.5, 'Pulse_Duty_pct',20);
                case 'heavy pulse'
                    obj = bcp.LoadSignal('Waveform','pulse', ...
                        'Pulse_Base_W',100, 'Pulse_Amplitude_W',2000, ...
                        'Pulse_Frequency_Hz',0.2, 'Pulse_Duty_pct',10, ...
                        'Pmax_W',4000);
                case 'sine ripple'
                    obj = bcp.LoadSignal('Waveform','sine', ...
                        'Sine_Offset_W',300, 'Sine_Amplitude_W',200, ...
                        'Sine_Frequency_Hz',0.2);
                otherwise
                    error('bcp:LoadSignal:Preset', ...
                        'Unknown load preset "%s". Try: %s', name, ...
                        strjoin(bcp.LoadSignal.presetNames(), ', '));
            end
        end

        function n = presetNames()
            n = {'off','constant 200 W','pulse burst','heavy pulse','sine ripple'};
        end
    end
end
