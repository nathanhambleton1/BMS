classdef CellVariation < handle
%BCP.CELLVARIATION  Give a Simscape battery pack cell-to-cell spread, in any model.
%
%   USAGE
%       v = bcp.CellVariation();                 % 2% SOC, 10% R, 3% capacity
%       T = v.apply('myBatteryModel')            % returns what it set, per element
%       v.revert()                               % put every parameter back
%
%       v = bcp.CellVariation('SOC_spread_pct',3, 'R_spread_pct',15, ...
%                             'Q_spread_pct',4,  'Seed',42);
%       v.apply('myBatteryModel/NewPack')        % or scope it to one subsystem
%
%   WHY THIS IS A SEPARATE TOOL AND NOT A BMS SETTING
%     Cell spread belongs to the BATTERY, not to the BMS, so it has to be
%     applied to whatever pack you happen to have -- including one in a model
%     this package has never seen, months after you copied the blocks across.
%     So it takes a model name and goes looking, rather than being a field on a
%     configuration object that only exists inside this project.
%
%   WHY SPREAD IS WORTH THE TROUBLE
%     A pack whose cells are identical cannot tell a per-cell CV loop from a
%     pack-voltage one: min, mean and max cell voltage are the same number, the
%     per-cell over-voltage trip is unreachable, and balancing has nothing to
%     balance. Every one of those is a whole class of bug that tests as passing.
%     bcp.Harness has always given its stand-in plant a spread for exactly this
%     reason; this is the same idea applied to a real Simscape pack.
%
%   WHAT IT VARIES, AND WHY THOSE THREE
%     initial SOC  the state each element starts in. This is what produces a
%                  real min/max cell spread from the first sample, and it is
%                  what the CV loop and any balancing logic actually see.
%     resistance   R0 scaled per element. Under load this turns into a voltage
%                  spread that grows with current -- the pulse-test case.
%     capacity     AH per element. This is what makes the spread DIVERGE over
%                  cycles instead of staying put: a smaller cell reaches the
%                  ends of its range first, every time.
%
%     Not varied: the OCV curve. Cell-to-cell OCV variation at a given SOC is
%     small compared with these three, and shifting a table per element makes
%     the reported SOC and the reported voltage disagree about which cell is
%     which, which is worse than leaving it alone.
%
%   THE LUMPED-PACK LIMIT -- READ THIS IF apply() FINDS ONLY ONE ELEMENT
%     Battery Model Builder generates packs at a chosen model resolution. At
%     "Lumped" resolution -- which is the default, and what the +Batteries
%     package in this repo uses -- a Module component contains ONE cell model
%     standing in for all S*P cells, with equations that force every parallel
%     assembly to the same voltage and the same SOC. There is no per-cell state
%     to vary, because there are no per-cell equations.
%
%     What that means in practice:
%       * Variation is applied per COMPONENT INSTANCE. On a lumped pack of 15
%         modules that is module-to-module spread: real, useful, and coarser
%         than cell-to-cell.
%       * On a pack built at "Detailed" resolution, the same code varies every
%         cell, because every cell is its own instance.
%
%     apply() counts what it found and says which of the two you have got. It
%     does not pretend a lumped pack has cell spread.
%
%   A DETAILED BLOCK IS ONE INSTANCE, NOT ONE CELL
%     "Cell state of charge" on a Detailed-resolution block is a per-cell
%     VECTOR sized to that block's "Number of cells in battery" -- Simscape
%     asserts the two match at compile time. apply() applies one spread value
%     per matched block and broadcasts it across every entry of that vector,
%     rather than one independent draw per physical cell, so it never changes
%     a vector's length. Do not mistake "N elements found" for "N cells
%     varied": the report line printed by apply() says both -- how many
%     blocks it touched, and how many physical cells those blocks represent
%     in total -- exactly because those two numbers can differ.
%
%   REVERT IS EXACT, NOT APPROXIMATE
%     Every parameter string is stored verbatim before it is written, and
%     revert() puts those strings back. It does not recompute a "nominal"
%     value, because the value it found is the nominal value -- including any
%     earlier edit of yours that this had no business rounding off.

    properties
        SOC_spread_pct double = 2.0
        %  Peak-to-peak spread in initial SOC, in SOC percentage points. 2 means
        %  the elements are spread across a 2-point band -- 59% to 61% on a pack
        %  starting at 60%. Typical for matched cells out of the same batch;
        %  raise it to 5-10 for a used pack or a deliberately unmatched one.

        R_spread_pct double = 10.0
        %  Peak-to-peak spread in element resistance, as a percentage of the
        %  nominal curve. The whole R0(SOC) table is scaled, so the spread
        %  survives at every state of charge instead of only near the middle.

        Q_spread_pct double = 3.0
        %  Peak-to-peak spread in element capacity, as a percentage. This is the
        %  one that makes the pack diverge over cycles rather than merely start
        %  uneven.

        SOC_base double = []
        %  Initial SOC to centre the spread on, 0..1. Empty (the default) means
        %  centre it on whatever each element is already set to, which is what
        %  you want when something else -- a test script, a model callback --
        %  owns the starting SOC.

        Distribution char = 'uniform'
        %  'uniform'  spread is the full peak-to-peak width. Predictable, and
        %             every element is inside the band you asked for.
        %  'normal'   spread is +/- 3 sigma, truncated there. More like a real
        %             batch, at the cost of most elements sitting near nominal.

        Seed double = 7
        %  Fixed, so a run is reproducible and two runs are comparable. Change
        %  it to draw a different pack from the same distribution -- that is the
        %  useful experiment, not re-running the same one.
    end

    properties (SetAccess = private)
        Applied logical = false
        Target  char = ''
        Saved   struct = struct('block',{}, 'param',{}, 'value',{})
        Elements cell = {}
    end

    methods
        function obj = CellVariation(varargin)
            for k = 1:2:numel(varargin)
                assert(isprop(obj, varargin{k}), 'bcp:CellVariation:Option', ...
                    'Unknown option "%s".', varargin{k});
                obj.(varargin{k}) = varargin{k+1};
            end
            obj.validate();
        end

        function validate(obj)
            assert(obj.SOC_spread_pct >= 0 && obj.R_spread_pct >= 0 && ...
                   obj.Q_spread_pct >= 0, 'bcp:CellVariation:Spread', ...
                'Spreads must be >= 0. Zero is legal and means "do not vary this".');
            assert(any(strcmpi(obj.Distribution, {'uniform','normal'})), ...
                'bcp:CellVariation:Dist', ...
                'Distribution must be ''uniform'' or ''normal''.');
            if ~isempty(obj.SOC_base)
                assert(obj.SOC_base > 0 && obj.SOC_base <= 1, ...
                    'bcp:CellVariation:SOCBase', ...
                    'SOC_base must lie in (0,1], or be empty to keep what is there.');
            end
        end

        % -----------------------------------------------------------------
        function T = apply(obj, target, varargin)
        %APPLY  Write the spread into every battery element under TARGET.
        %
        %   T = v.apply('myModel')
        %   T = v.apply('myModel/NewPack')
        %   T = v.apply('myModel', 'DryRun', true)   % report, change nothing
        %
        %   TARGET is a loaded model, or the path of a subsystem inside one.
        %   Returns a table with one row per element: its path, the SOC it was
        %   given, and the capacity and resistance multipliers.
            opt = struct('DryRun', false);
            for k = 1:2:numel(varargin)
                assert(isfield(opt, varargin{k}), 'bcp:CellVariation:Option', ...
                    'Unknown option "%s".', varargin{k});
                opt.(varargin{k}) = varargin{k+1};
            end
            obj.validate();
            target = char(target);
            model  = strtok(target, '/');
            assert(bdIsLoaded(model), 'bcp:CellVariation:NotLoaded', ...
                'Model "%s" is not open. load_system(''%s'') first.', model, model);

            blks = obj.findElements(target);
            n = numel(blks);
            assert(n > 0, 'bcp:CellVariation:NoCells', ...
                ['Found no battery elements under "%s".\n' ...
                 'This looks for blocks carrying a socCell, AHCell or R0_vecCell ' ...
                 'parameter, which is what Simscape Battery components (and the ' ...
                 'ones Battery Model Builder generates) expose. If your pack is ' ...
                 'modelled some other way, this tool cannot see it.'], target);

            if obj.Applied
                obj.revert();
            end

            totalCells = 0;
            for k = 1:n
                totalCells = totalCells + obj.cellCount(blks{k});
            end

            [socF, qF, rF] = obj.draws(n);

            paths = cell(n,1); socOut = zeros(n,1);
            qMul  = zeros(n,1); rMul  = zeros(n,1);
            failed = {};

            for k = 1:n
                b = blks{k};
                paths{k} = b;
                qMul(k)  = 1 + qF(k);
                rMul(k)  = 1 + rF(k);
                try
                    socOut(k) = obj.applyOne(b, socF(k), qMul(k), rMul(k), opt.DryRun);
                catch ME
                    failed{end+1} = sprintf('%s: %s', b, ME.message); %#ok<AGROW>
                    socOut(k) = NaN;
                end
            end

            if ~opt.DryRun
                obj.Applied  = true;
                obj.Target   = target;
                obj.Elements = paths;
            end

            T = table(paths, socOut, qMul, rMul, ...
                'VariableNames', {'Element','SOC_init','Capacity_x','Resistance_x'});

            obj.report(target, n, totalCells, T, opt.DryRun, failed);
        end

        % -----------------------------------------------------------------
        function revert(obj)
        %REVERT  Put every parameter back to the string it held before apply().
            if isempty(obj.Saved)
                fprintf('[bcp] Nothing to revert.\n');
                obj.Applied = false;
                return;
            end
            n = 0;
            for k = numel(obj.Saved):-1:1
                s = obj.Saved(k);
                try
                    set_param(s.block, s.param, s.value);
                    n = n + 1;
                catch
                    % A block that has since been deleted is not an error worth
                    % stopping a revert over -- keep going and say so at the end.
                end
            end
            fprintf('[bcp] Reverted %d of %d parameter(s) on %d element(s).\n', ...
                n, numel(obj.Saved), numel(obj.Elements));
            obj.Saved    = struct('block',{}, 'param',{}, 'value',{});
            obj.Elements = {};
            obj.Applied  = false;
        end

        % -----------------------------------------------------------------
        function n = count(~, target)
        %COUNT  How many battery elements are under TARGET, without changing any.
            n = numel(bcp.CellVariation.findElements(target));
        end
    end

    % =====================================================================
    methods (Access = private)

        function [socF, qF, rF] = draws(obj, n)
        %DRAWS  Three reproducible zero-mean spreads, one value per element.
        %
        %   Zero-mean by construction, not by luck: the raw draws are centred
        %   before they are scaled. Without that, a small pack gets a random
        %   offset in its MEAN capacity as well as a spread, and a comparison
        %   between two seeds silently compares two different pack sizes.
            rs = RandStream('twister', 'Seed', obj.Seed);
            socF = obj.oneDraw(rs, n, obj.SOC_spread_pct/100);
            qF   = obj.oneDraw(rs, n, obj.Q_spread_pct/100);
            rF   = obj.oneDraw(rs, n, obj.R_spread_pct/100);
        end

        function f = oneDraw(obj, rs, n, width)
            if width <= 0 || n == 0
                f = zeros(n,1);
                return;
            end
            if strcmpi(obj.Distribution, 'normal')
                u = randn(rs, n, 1);
                u = min(max(u, -3), 3) / 3;      % truncate at 3 sigma, scale to +/-1
            else
                u = 2*rand(rs, n, 1) - 1;        % uniform on [-1, 1]
            end
            if n > 1
                u = u - mean(u);                 % zero-mean, exactly
            else
                u = 0;                           % one element has no spread
            end
            f = (width/2) * u;
        end

        % -----------------------------------------------------------------
        function socSet = applyOne(obj, blk, socDelta, qMul, rMul, dry)
        %APPLYONE  Write one element's three parameters.
        %
        %   socCell and AHCell are scalar on a Lumped-resolution block, but on
        %   a Detailed-resolution one (every physical cell modelled, which is
        %   what Battery Model Builder's own "detailed / percentage deviation"
        %   option produces) they are vectors sized to that block's "Number of
        %   cells in battery". Simscape asserts that length at compile time, so
        %   this tool must never change it -- readAny/writeAny below apply the
        %   same delta or multiplier to every entry and write it back in
        %   whatever shape it already had, scalar or vector. Collapsing a
        %   vector down to a single value here is exactly what used to make a
        %   perfectly good pack fail to compile after a call to apply().
            dp = get_param(blk, 'DialogParameters');
            socSet = NaN;

            % --- initial SOC ---------------------------------------------
            %  Touched when there is a spread to apply, and also when a base SOC
            %  was named -- setting every element to the same starting SOC with
            %  zero spread is a legitimate thing to ask for.
            wantSOC = isfield(dp, 'socCell') && ...
                      (obj.SOC_spread_pct > 0 || ~isempty(obj.SOC_base));
            if wantSOC
                if ~isempty(obj.SOC_base)
                    base = obj.SOC_base;
                else
                    base = obj.readAny(blk, 'socCell');
                    if isempty(base), base = 1; end
                end
                setVal = min(max(base + socDelta, 0.01), 1.0);
                socSet = setVal(1);
                if ~dry
                    obj.stash(blk, 'socCell');
                    obj.writeAny(blk, 'socCell', setVal, 6);
                    % Setting the value is NOT enough. Every Simscape variable
                    % target has a companion _specify flag that ships 'off', and
                    % with it off the value reads back correctly from get_param,
                    % shows in the dialog, and is ignored -- the solver picks its
                    % own consistent initial condition instead. The pack then
                    % starts somewhere else entirely while the parameter says
                    % what you asked for, which is worse than an error.
                    obj.stashAndSet(blk, dp, 'socCell_specify', 'on');
                    obj.stashAndSet(blk, dp, 'socCell_priority', 'High');
                end
            end

            % --- capacity -------------------------------------------------
            if isfield(dp, 'AHCell') && obj.Q_spread_pct > 0
                base = obj.readAny(blk, 'AHCell');
                if ~isempty(base) && ~dry
                    obj.stash(blk, 'AHCell');
                    obj.writeAny(blk, 'AHCell', base * qMul, 10);
                end
            end

            % --- resistance -----------------------------------------------
            %  The whole R0(SOC) table is scaled rather than a single point, so
            %  the spread holds at every state of charge. Scaling one number
            %  would put the variation only where the curve happened to be flat.
            if isfield(dp, 'R0_vecCell') && obj.R_spread_pct > 0
                base = obj.readVector(blk, 'R0_vecCell');
                if ~isempty(base) && ~dry
                    obj.stash(blk, 'R0_vecCell');
                    set_param(blk, 'R0_vecCell', mat2str(base * rMul, 10));
                end
            end
        end

        function stash(obj, blk, param)
            obj.Saved(end+1) = struct('block', blk, 'param', param, ...
                                      'value', get_param(blk, param));
        end

        function stashAndSet(obj, blk, dp, param, value)
            if ~isfield(dp, param), return; end
            obj.stash(blk, param);
            set_param(blk, param, value);
        end

        function v = readVector(~, blk, param)
            s = get_param(blk, param);
            v = str2num(s); %#ok<ST2NM>  vectors need str2num, not str2double
            if ~isnumeric(v) || isempty(v)
                v = [];
            end
        end

        function v = readAny(~, blk, param)
        %READANY  Read a parameter that may be a scalar OR a vector, as
        %   whichever it turns out to be -- str2double first (cheap, and the
        %   common case), str2num as a fallback for a vector/matrix literal.
        %   Returns [] for anything that parses as neither, e.g. a parameter
        %   written as an expression rather than a literal; the caller decides
        %   what "not found" should mean rather than this guessing at it.
            s = get_param(blk, param);
            v = str2double(s);
            if ~isnan(v), return; end
            v = str2num(s); %#ok<ST2NM>
            if ~isnumeric(v) || isempty(v)
                v = [];
            end
        end

        function writeAny(~, blk, param, v, sig)
        %WRITEANY  Write V back in whatever literal form matches its size, so
        %   a parameter's length is never altered by this tool: a plain number
        %   for a scalar (what most of these are, on a Lumped-resolution
        %   block), an explicit array literal for a vector (what a
        %   Detailed-resolution block's per-cell state looks like). SIG is
        %   significant digits.
            if isscalar(v)
                set_param(blk, param, num2str(v, sprintf('%%.%dg', sig)));
            else
                set_param(blk, param, mat2str(v, sig));
            end
        end

        function n = cellCount(~, blk)
        %CELLCOUNT  How many physical cells this one matched block instance
        %   represents: 1 on a Lumped-resolution block, or the vector length
        %   Simscape checks against "Number of cells in battery" on a
        %   Detailed one. socCell is the only parameter this can be read from
        %   -- AHCell and R0_vecCell are per-cell-TYPE curves/values shared by
        %   every cell in the block, not one entry per physical cell, so their
        %   length says nothing about cell count.
            n = 1;
            try
                dp = get_param(blk, 'DialogParameters');
            catch
                return;
            end
            if ~isfield(dp, 'socCell')
                return;
            end
            s = get_param(blk, 'socCell');
            if ~isnan(str2double(s))
                return;
            end
            v = str2num(s); %#ok<ST2NM>
            if isnumeric(v) && ~isempty(v)
                n = numel(v);
            end
        end

        % -----------------------------------------------------------------
        function report(obj, target, n, totalCells, T, dry, failed)
            if dry
                head = 'would apply';
            else
                head = 'applied';
            end
            fprintf('\n=== bcp cell variation: %s ===\n', target);
            if totalCells > n
                fprintf(['  %s to %d battery element(s) -- %d physical cell(s) ', ...
                         'total -- seed %d, %s distribution\n'], ...
                    head, n, totalCells, obj.Seed, lower(obj.Distribution));
            else
                fprintf('  %s to %d battery element(s), seed %d, %s distribution\n', ...
                    head, n, obj.Seed, lower(obj.Distribution));
            end
            if totalCells == 1
                fprintf(2, ['  ONLY ONE ELEMENT. A single component cannot have ', ...
                    'cell-to-cell spread --\n  this pack is lumped down to one ', ...
                    'cell model. Rebuild it at a finer\n  model resolution in ', ...
                    'Battery Model Builder if you need spread.\n']);
            else
                fprintf(['  spread: SOC %.2f points, capacity %.1f%%, ', ...
                         'resistance %.1f%% (peak to peak)\n'], ...
                    obj.SOC_spread_pct, obj.Q_spread_pct, obj.R_spread_pct);
                soc = T.SOC_init(~isnan(T.SOC_init));
                if ~isempty(soc)
                    fprintf('  initial SOC now spans %.2f%% to %.2f%%\n', ...
                        min(soc)*100, max(soc)*100);
                end
                fprintf('  resistance spans %.3fx to %.3fx nominal\n', ...
                    min(T.Resistance_x), max(T.Resistance_x));
                if totalCells > n
                    fprintf(['  NOTE: each of the %d element(s) above is a Detailed-', ...
                             'resolution block covering more\n        than one ', ...
                             'physical cell (%d total). This tool applies one spread ', ...
                             'value per\n        BLOCK INSTANCE and broadcasts it to ', ...
                             'every cell inside that block, so cells\n        within ', ...
                             'the same instance will not diverge from each other.\n'], ...
                        n, totalCells);
                else
                    fprintf(['  NOTE: these are per COMPONENT INSTANCE. On a lumped ', ...
                             'pack each instance is a\n        whole module, so this ', ...
                             'is module-to-module spread, not cell-to-cell.\n']);
                end
            end
            for k = 1:numel(failed)
                fprintf(2, '  FAILED %s\n', failed{k});
            end
            if ~dry
                fprintf('  v.revert() puts every one of them back.\n');
            end
            fprintf('\n');
        end
    end

    % =====================================================================
    methods (Static)
        function blks = findElements(target)
        %FINDELEMENTS  Every block under TARGET that carries battery cell parameters.
        %
        %   Identified by their PARAMETERS rather than by block type or name,
        %   because the generated Simscape components are named after your pack
        %   and their types are whatever Battery Model Builder called them.
        %   socCell / AHCell / R0_vecCell are the contract those components
        %   actually publish, and they are stable across the tool's versions in
        %   a way a block path is not.
            target = char(target);
            all = find_system(target, 'LookUnderMasks','all', ...
                              'FollowLinks','on', 'Type','Block');
            keep = false(numel(all),1);
            for k = 1:numel(all)
                try
                    dp = get_param(all{k}, 'DialogParameters');
                catch
                    continue;
                end
                if isempty(dp), continue; end
                keep(k) = isfield(dp,'socCell') || isfield(dp,'AHCell') || ...
                          isfield(dp,'R0_vecCell');
            end
            blks = sort(all(keep));   % sorted, so the seed maps to the same
                                      % element on every run and every machine
        end
    end
end
