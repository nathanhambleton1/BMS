classdef CellTables
%BCP.CELLTABLES  The cell's real lookup tables, read out of a generated .ssc file.
%
%   The Battery Model Builder writes the OCV, resistance and capacity tables it
%   parameterised your pack with into the generated ParallelAssembly component.
%   Those tables ARE your cell, as far as your Simscape model is concerned.
%   bcp.CellLibrary, by contrast, holds datasheet scalars typed in by hand.
%
%   The two disagree, and the disagreement is not small. For the Molicel P45B
%   in +Batteries: the datasheet entry says 4.20 V full and 12 mOhm flat, and
%   the generated table says 4.168 V at 100% SOC and a resistance that runs
%   from 9.5 to 21 mOhm depending on where you are on the curve. A harness
%   result computed from the first cannot be compared against a Simscape result
%   computed from the second.
%
%   So: read the tables, and use them in both places.
%
%       ct   = bcp.CellTables.fromPackage('+Batteries');
%       cell = ct.toCellLibrary();                  % for PackSpec / auto-fill
%       h    = bcp.Harness(p, 'CellTables', ct);    % for the fast plant
%
%   WHAT THIS DOES NOT DO
%     It does not read the pack topology. How many of these are in series, and
%     how they are grouped into modules, is a property of the pack model and
%     not of the cell component -- compile the model and look at the array
%     widths (bcp.Project.verifyWiring) rather than guessing from a file.

    properties
        SOC     double = []      % breakpoints, 0..1
        OCV_V   double = []      % open-circuit voltage at each breakpoint [V]
        R0_Ohm  double = []      % series resistance at each breakpoint [Ohm]
        Q_Ah    double = NaN     % cell capacity [Ah]
        Name    char   = ''      % part number, from the file's header comment
        Source  char   = ''      % which file this came from
    end

    methods
        function obj = CellTables(varargin)
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k+1};
            end
            obj = obj.validate();
        end

        function obj = validate(obj)
            assert(~isempty(obj.SOC), 'bcp:CellTables:Empty', 'SOC is empty.');
            assert(numel(obj.SOC) == numel(obj.OCV_V), 'bcp:CellTables:Size', ...
                'SOC has %d entries and OCV_V has %d.', numel(obj.SOC), numel(obj.OCV_V));
            assert(numel(obj.SOC) == numel(obj.R0_Ohm), 'bcp:CellTables:Size', ...
                'SOC has %d entries and R0_Ohm has %d.', numel(obj.SOC), numel(obj.R0_Ohm));
            assert(all(diff(obj.SOC) > 0), 'bcp:CellTables:Monotonic', ...
                'SOC breakpoints must be strictly increasing.');
            assert(obj.Q_Ah > 0, 'bcp:CellTables:Q', 'Q_Ah must be positive.');
            obj.SOC    = obj.SOC(:).';
            obj.OCV_V  = obj.OCV_V(:).';
            obj.R0_Ohm = obj.R0_Ohm(:).';
        end

        function v = ocv(obj, soc)
        %OCV  Open-circuit voltage at a state of charge, clamped at both ends.
            v = interp1(obj.SOC, obj.OCV_V, min(max(soc, obj.SOC(1)), obj.SOC(end)));
        end

        function r = r0(obj, soc)
        %R0  Series resistance at a state of charge, clamped at both ends.
            r = interp1(obj.SOC, obj.R0_Ohm, min(max(soc, obj.SOC(1)), obj.SOC(end)));
        end

        function c = toCellLibrary(obj, varargin)
        %TOCELLLIBRARY  A bcp.CellLibrary entry backed by these tables.
        %
        %   Capacity and resistance come from the table. The current and cutoff
        %   limits do not exist in the table -- they are datasheet facts about
        %   how hard you may drive the cell, not model parameters -- so they
        %   default to the library's P45B values and can be overridden.
        %
        %   R_dc_Ohm is the table value at the SOC given by 'R_at_SOC' (default
        %   0.5). It is a single number because that is all the charge-parameter
        %   auto-fill can use; the harness plant gets the whole curve.
            opt = struct('R_at_SOC',0.5, 'V_nom',3.60, 'V_max',4.20, 'V_min',2.50, ...
                         'I_chg_std_A',4.35, 'I_chg_max_A',4.35, ...
                         'I_dch_cont_A',45, 'Mass_kg',0.070);
            for k = 1:2:numel(varargin)
                assert(isfield(opt, varargin{k}), 'bcp:CellTables:Option', ...
                    'Unknown option "%s". Valid: %s.', varargin{k}, ...
                    strjoin(fieldnames(opt).', ', '));
                opt.(varargin{k}) = varargin{k+1};
            end
            nm = obj.Name;
            if isempty(nm), nm = 'cell from .ssc tables'; end
            c = bcp.CellLibrary( ...
                'Name',         sprintf('%s (model tables)', nm), ...
                'Chemistry',    'NMC', ...
                'Q_Ah',         obj.Q_Ah, ...
                'V_nom',        opt.V_nom, ...
                'V_max',        opt.V_max, ...
                'V_min',        opt.V_min, ...
                'R_dc_Ohm',     obj.r0(opt.R_at_SOC), ...
                'I_chg_std_A',  opt.I_chg_std_A, ...
                'I_chg_max_A',  opt.I_chg_max_A, ...
                'I_dch_cont_A', opt.I_dch_cont_A, ...
                'Mass_kg',      opt.Mass_kg, ...
                'Source',       obj.Source);
        end

        function report(obj)
            fprintf('Cell tables: %s\n', obj.Name);
            fprintf('  %d breakpoints, capacity %.4f Ah\n', numel(obj.SOC), obj.Q_Ah);
            fprintf('  OCV   %.4f V at 0%%  ->  %.4f V at 100%%\n', ...
                obj.OCV_V(1), obj.OCV_V(end));
            fprintf('  R0    %.2f .. %.2f mOhm  (%.2f mOhm at 50%% SOC)\n', ...
                min(obj.R0_Ohm)*1000, max(obj.R0_Ohm)*1000, obj.r0(0.5)*1000);
            fprintf('  from  %s\n', obj.Source);
        end
    end

    methods (Static)
        function obj = fromFile(sscFile)
        %FROMFILE  Read the tables out of one generated .ssc component file.
            assert(isfile(sscFile), 'bcp:CellTables:NoFile', ...
                'No such file: %s', sscFile);
            txt = fileread(sscFile);
            obj = bcp.CellTables( ...
                'SOC',    bcp.CellTables.readVector(txt, 'SOC_vecCell'), ...
                'OCV_V',  bcp.CellTables.readVector(txt, 'V0_vecCell'), ...
                'R0_Ohm', bcp.CellTables.readVector(txt, 'R0_vecCell'), ...
                'Q_Ah',   bcp.CellTables.readScalar(txt, 'AHCell'), ...
                'Name',   bcp.CellTables.readPartNumber(txt), ...
                'Source', sscFile);
        end

        function obj = fromPackage(pkgDir)
        %FROMPACKAGE  Find the ParallelAssembly component inside a +Batteries folder.
            if nargin < 1 || isempty(pkgDir), pkgDir = '+Batteries'; end
            pat = fullfile(pkgDir, '+ParallelAssemblies', '*.ssc');
            f = dir(pat);
            assert(~isempty(f), 'bcp:CellTables:NoPackage', ...
                ['No ParallelAssembly component under "%s".\n' ...
                 'Expected something matching %s -- that folder is written next ' ...
                 'to the model by the Battery Model Builder.'], pkgDir, pat);
            obj = bcp.CellTables.fromFile(fullfile(f(1).folder, f(1).name));
        end
    end

    methods (Static, Access = private)
        function v = readVector(txt, name)
            tok = regexp(txt, [name '\s*=\s*\{\s*\[([^\]]*)\]'], 'tokens', 'once');
            assert(~isempty(tok), 'bcp:CellTables:NotFound', ...
                'No "%s" vector in the .ssc file.', name);
            v = sscanf(regexprep(tok{1}, '[\s,;]+', ' '), '%f').';
            assert(~isempty(v), 'bcp:CellTables:Parse', ...
                '"%s" was found but parsed to nothing.', name);
        end

        function s = readScalar(txt, name)
            tok = regexp(txt, [name '\s*=\s*\{\s*([0-9.eE+-]+)'], 'tokens', 'once');
            assert(~isempty(tok), 'bcp:CellTables:NotFound', ...
                'No "%s" scalar in the .ssc file.', name);
            s = str2double(tok{1});
        end

        function n = readPartNumber(txt)
            tok = regexp(txt, 'Part number:\s*(\S+)', 'tokens', 'once');
            if isempty(tok), n = ''; else, n = strrep(tok{1}, '_', '-'); end
        end
    end
end
