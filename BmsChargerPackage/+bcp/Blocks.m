classdef Blocks
%BCP.BLOCKS  Library paths, tolerant parameter setting, and wiring helpers.
%
%   Everything in this package is plain Simulink -- signal domain only, no
%   Simscape physical ports. That is a deliberate constraint: it means the BMS
%   and charger blocks can be dropped into a model built by any battery tool,
%   they need no Simscape licence of their own, and wiring them is ordinary
%   add_line with named ports rather than conserving-port handles.
%
%   Two things are still resolved at run time rather than hard-coded:
%
%     path(key)      library paths move between releases
%     safeSet(...)   dialog parameter NAMES are not a documented API
%
%   Both fail loudly with the list of what was actually available, so a release
%   change shows up as a clear build error instead of a model that compiles and
%   is subtly wrong.

    methods (Static)

        % ---------------------------------------------------------------
        function p = path(key)
        %PATH  Resolve a library block path for a logical key.
            persistent CACHE
            if isempty(CACHE)
                CACHE = containers.Map('KeyType','char','ValueType','char');
            end
            if CACHE.isKey(key), p = CACHE(key); return; end

            if ~bdIsLoaded('simulink'), load_system('simulink'); end
            cands = bcp.Blocks.candidates(key);
            assert(~isempty(cands), 'bcp:Blocks:NoKey', ...
                'No library candidates registered for key "%s".', key);

            p = '';
            for k = 1:numel(cands)
                if getSimulinkBlockHandle(cands{k}) > 0
                    p = cands{k}; break;
                end
            end
            % 'built-in/...' paths return -1 from getSimulinkBlockHandle because
            % built-in blocks are not members of a loaded library model, even
            % though add_block accepts them. Fall back to the first built-in
            % candidate rather than failing.
            if isempty(p)
                bi = cands(startsWith(cands,'built-in/'));
                if ~isempty(bi), p = bi{1}; end
            end

            assert(~isempty(p), 'bcp:Blocks:NotFound', ...
                ['Could not resolve a library block for "%s". Tried:\n  %s\n', ...
                 'Add the correct path to bcp.Blocks.candidates().'], ...
                key, strjoin(cands, sprintf('\n  ')));
            CACHE(key) = p;
        end

        % ---------------------------------------------------------------
        function c = candidates(key)
        %CANDIDATES  Ordered list of plausible library paths. Real path first,
        %   'built-in/' form as the fallback.
            switch key
                case 'Subsystem',    c = {'simulink/Ports & Subsystems/Subsystem', ...
                                          'built-in/Subsystem'};
                case 'Inport',       c = {'simulink/Ports & Subsystems/In1', ...
                                          'built-in/Inport'};
                case 'Outport',      c = {'simulink/Ports & Subsystems/Out1', ...
                                          'built-in/Outport'};
                case 'Constant',     c = {'simulink/Sources/Constant', ...
                                          'built-in/Constant'};
                case 'Clock',        c = {'simulink/Sources/Clock', ...
                                          'built-in/Clock'};
                case 'DigitalClock', c = {'simulink/Sources/Digital Clock', ...
                                          'built-in/DigitalClock'};
                case 'Terminator',   c = {'simulink/Sinks/Terminator', ...
                                          'built-in/Terminator'};
                case 'Gain',         c = {'simulink/Math Operations/Gain', ...
                                          'built-in/Gain'};
                case 'Sum',          c = {'simulink/Math Operations/Sum', ...
                                          'built-in/Sum'};
                case 'Saturation',   c = {'simulink/Discontinuities/Saturation', ...
                                          'built-in/Saturate'};
                case 'UnitDelay',    c = {'simulink/Discrete/Unit Delay', ...
                                          'built-in/UnitDelay'};
                case 'Selector',     c = {'simulink/Signal Routing/Selector', ...
                                          'built-in/Selector'};
                case 'Mux',          c = {'simulink/Signal Routing/Mux', ...
                                          'built-in/Mux'};
                case 'Demux',        c = {'simulink/Signal Routing/Demux', ...
                                          'built-in/Demux'};
                case 'Scope',        c = {'simulink/Sinks/Scope', 'built-in/Scope'};
                case 'MLFcn',        c = {'simulink/User-Defined Functions/MATLAB Function'};
                otherwise,           c = {};
            end
        end

        % ---------------------------------------------------------------
        function b = add(sys, key, name, pos, varargin)
        %ADD  add_block with a library key, returning the full block path.
            b = getfullname(add_block(bcp.Blocks.path(key), ...
                [sys '/' name], 'Position', pos, varargin{:}));
        end

        % ---------------------------------------------------------------
        function b = inport(sys, name, idx, pos)
            b = bcp.Blocks.add(sys, 'Inport', name, pos, 'Port', num2str(idx));
        end

        function b = outport(sys, name, idx, pos)
            b = bcp.Blocks.add(sys, 'Outport', name, pos, 'Port', num2str(idx));
        end

        % ---------------------------------------------------------------
        function ok = safeSet(blk, candidateNames, value)
        %SAFESET  Set the first dialog parameter that exists on BLK.
            if ischar(candidateNames) || isstring(candidateNames)
                candidateNames = cellstr(candidateNames);
            end
            if ~ischar(value), value = bcp.Blocks.literal(value); end
            ok = false;
            avail = fieldnames(get_param(blk,'DialogParameters'));
            for k = 1:numel(candidateNames)
                if any(strcmp(avail, candidateNames{k}))
                    set_param(blk, candidateNames{k}, value);
                    ok = true;
                    return;
                end
            end
            warning('bcp:Blocks:ParamMiss', ...
                ['None of {%s} is a dialog parameter of "%s".\n  Available: %s'], ...
                strjoin(candidateNames,', '), get_param(blk,'Name'), ...
                strjoin(avail', ', '));
        end

        % ---------------------------------------------------------------
        function setMLFcn(blk, code, sampleTime)
        %SETMLFCN  Write the body of a MATLAB Function block, and pin its rate.
        %
        %   MATLAB Function blocks are backed by Stateflow EM charts, so the
        %   script is set through sfroot. This needs no Stateflow licence -- EM
        %   charts are part of Simulink.
        %
        %   SETTING THE RATE IS NOT OPTIONAL HERE. Every generated block in this
        %   package holds persistent state and multiplies by Ts to turn samples
        %   into seconds. Left to inherit, the chart picks up the rate of
        %   whatever drives it -- for a Simscape-fed input that is the solver's
        %   variable step -- and then a "0.5 second" trip confirmation is
        %   however long 50 arbitrary steps happen to take. The block would run,
        %   log plausible traces, and time everything wrong.
            rt = sfroot;
            ch = rt.find('-isa','Stateflow.EMChart','Path', blk);
            assert(~isempty(ch), 'bcp:Blocks:NoEMChart', ...
                ['Could not find the EM chart behind "%s". Confirm the block came ', ...
                 'from simulink/User-Defined Functions/MATLAB Function.'], blk);
            ch(1).Script = code;

            if nargin >= 3 && ~isempty(sampleTime)
                ch(1).ChartUpdate = 'DISCRETE';
                ch(1).SampleTime  = bcp.Blocks.literal(sampleTime);
            end
        end

        % ---------------------------------------------------------------
        function s = literal(v)
        %LITERAL  Numeric value -> MATLAB source literal for code generation.
            if islogical(v)
                if isscalar(v)
                    if v, s = 'true'; else, s = 'false'; end
                else
                    s = mat2str(v);
                end
            elseif ischar(v)
                s = ['''' strrep(v,'''','''''') ''''];
            elseif isscalar(v)
                if isinf(v)
                    if v > 0, s = 'Inf'; else, s = '-Inf'; end
                else
                    s = sprintf('%.12g', v);
                end
            else
                s = mat2str(v, 12);
            end
        end

        % ---------------------------------------------------------------
        function s = structLiteral(st, indent)
        %STRUCTLITERAL  Emit a struct(...) call that code generation can fold.
        %
        %   The generated blocks carry their constants as a literal struct
        %   rather than reading base-workspace variables. That costs a rebuild
        %   when you change a threshold, and buys a model that means the same
        %   thing on someone else's machine with an empty workspace.
            if nargin < 2, indent = '    '; end
            f = fieldnames(st);
            parts = cell(numel(f),1);
            for k = 1:numel(f)
                parts{k} = sprintf('''%s'', %s', f{k}, ...
                    bcp.Blocks.literal(st.(f{k})));
            end
            s = sprintf('struct( ...\n%s%s)', indent, ...
                strjoin(parts, sprintf(', ...\n%s', indent)));
        end

        % ---------------------------------------------------------------
        function s = embedAlgFunctions(names)
        %EMBEDALGFUNCTIONS  Local-function text block: alg/*.m, verbatim, banner-wrapped.
        %
        %   A generated MATLAB Function block used to CALL these by name and lean
        %   on BmsChargerPackage/alg being on the MATLAB path (bcp_setup). That is
        %   fine inside this repo, but it is exactly what broke "copy the BMS and
        %   Charger blocks into a new project and delete this folder": the copy
        %   compiled nowhere until the whole alg/ folder came with it.
        %
        %   MATLAB resolves a call to a name defined later in the SAME file as a
        %   local function before it ever consults the path, so pasting the alg
        %   source in after the block's main fcn makes the block find its own
        %   dependencies first, wherever it is copied. alg/ stays the place you
        %   edit and unit-test the algorithm in isolation -- coreCode() just
        %   copies the current text in at build time, so the two can never drift.
        %
        %   NAMES is a cellstr of alg/*.m filenames (without the extension). Order
        %   does not matter: MATLAB collects every local function in a file before
        %   resolving calls between them, so bcp_protection can call bcp_tick
        %   whichever one is pasted in first.
            parts = cell(numel(names) + 1, 1);
            parts{1} = sprintf([ ...
                '\n' ...
                '%%%% ===== EMBEDDED FROM BmsChargerPackage/alg -- do not edit here =====\n' ...
                '%%%%  Copied verbatim at build time (bcp.Blocks.embedAlgFunctions) so this\n' ...
                '%%%%  block has no dependency on BmsChargerPackage/alg being on the path.\n' ...
                '%%%%  Edit the algorithm there and re-insert the block; this copy is\n' ...
                '%%%%  overwritten by the next insert().\n' ...
                '%%%% ====================================================================\n']);
            for k = 1:numel(names)
                parts{k+1} = bcp.Blocks.algSource(names{k});
            end
            s = strjoin(parts, newline);
        end

        % ---------------------------------------------------------------
        function s = algSource(name)
        %ALGSOURCE  Verbatim text of one alg/*.m file, for embedAlgFunctions.
            pkgDir = fileparts(fileparts(mfilename('fullpath')));   % .../BmsChargerPackage
            f = fullfile(pkgDir, 'alg', [name '.m']);
            assert(exist(f,'file') == 2, 'bcp:Blocks:NoAlgFile', ...
                'No alg/%s.m next to the bcp package at "%s".', name, pkgDir);
            s = fileread(f);
        end

        % ---------------------------------------------------------------
        function h = port(blk, side, idx)
        %PORT  A single Simulink signal port handle.
            if nargin < 3, idx = 1; end
            ph = get_param(blk,'PortHandles');
            switch lower(side)
                case {'in','i'},  arr = ph.Inport;  fld = 'input';
                case {'out','o'}, arr = ph.Outport; fld = 'output';
                otherwise
                    error('bcp:Blocks:BadSide','Side must be "in" or "out".');
            end
            assert(numel(arr) >= idx, 'bcp:Blocks:NoPort', ...
                'Block "%s" has %d %s port(s); index %d requested.', ...
                get_param(blk,'Name'), numel(arr), fld, idx);
            h = arr(idx);
        end

        % ---------------------------------------------------------------
        function l = link(sys, fromBlk, fromIdx, toBlk, toIdx)
        %LINK  Connect an output port to an input port by index.
            l = add_line(sys, bcp.Blocks.port(fromBlk,'out',fromIdx), ...
                              bcp.Blocks.port(toBlk,'in',toIdx), ...
                         'autorouting','on');
        end

        % ---------------------------------------------------------------
        function assertPorts(blk, nIn, nOut)
        %ASSERTPORTS  Fail at build time if a generated block is not the shape
        %   the wiring code assumes. For MATLAB Function blocks the port count
        %   comes from the function signature, so this catches a code-generation
        %   mistake at the point it happened rather than three steps later.
            ph = get_param(blk,'PortHandles');
            actual = [numel(ph.Inport) numel(ph.Outport)];
            want   = [nIn nOut];
            assert(isequal(actual, want), 'bcp:Blocks:PortMismatch', ...
                ['Block "%s" has [in out] = %s, expected %s.\n', ...
                 'For a MATLAB Function block this means the generated signature ', ...
                 'does not match the wiring code.'], ...
                get_param(blk,'Name'), mat2str(actual), mat2str(want));
        end

        % ---------------------------------------------------------------
        function logSignal(l, name)
        %LOGSIGNAL  Name a line and turn on signal logging for it.
        %
        %   Logging is a property of the SOURCE OUTPUT PORT, not of the line.
        %   set_param(line,'DataLogging','on') errors with "line does not have a
        %   parameter named DataLogging". The line carries only the Name.
            set_param(l, 'Name', name);
            p = get_param(l, 'SrcPortHandle');
            if isempty(p) || p < 0
                warning('bcp:Blocks:NoSrcPort', ...
                    'Line "%s" has no resolvable source port; not logged.', name);
                return;
            end
            set_param(p, 'DataLogging', 'on');
            set_param(p, 'DataLoggingNameMode', 'Custom');
            set_param(p, 'DataLoggingName', name);
        end

        % ---------------------------------------------------------------
        function blk = newSubsystem(model, name, pos)
        %NEWSUBSYSTEM  An empty subsystem: added, then stripped of its default
        %   In1 -> Out1 pass-through.
            blk = bcp.Blocks.add(model, 'Subsystem', name, pos);
            try
                delete_line(blk, 'In1/1', 'Out1/1');
                delete_block([blk '/In1']);
                delete_block([blk '/Out1']);
            catch
                % Some releases add an empty subsystem with no default contents.
            end
        end

        % ---------------------------------------------------------------
        function removeIfPresent(path)
        %REMOVEIFPRESENT  Delete a block and every line touching it, if it exists.
        %   Used by the builders to make insert() repeatable: re-inserting is
        %   how you apply a configuration change, so it must not accumulate.
            if getSimulinkBlockHandle(path) <= 0, return; end
            ph = get_param(path,'PortHandles');
            for h = [ph.Inport(:); ph.Outport(:)]'
                l = get_param(h,'Line');
                if ~isempty(l) && l > 0
                    try, delete_line(l); catch, end
                end
            end
            delete_block(path);
        end
    end
end
