%BCP_SETUP  Put this package on the MATLAB path. The single definition of it.
%
%   Run this once per MATLAB session, before opening a model that contains a
%   generated BMS or charger block. Both blocks call functions in alg/ from
%   inside their MATLAB Function blocks, so without the path the model does not
%   compile -- the error names the missing function, which is a good error, but
%   only if you know why it is missing.
%
%   START_HERE.m calls this for you. So does bcpApp on launch.
%
%   Duplicating these addpath calls anywhere else is how two copies of the path
%   drift apart, so nothing else in this project calls addpath.

bcpRoot = fileparts(mfilename('fullpath'));

addpath(bcpRoot);                            % +bcp package parent
addpath(fullfile(bcpRoot, 'alg'));           % algorithms called by the blocks
addpath(fullfile(bcpRoot, 'app'));           % the UI
addpath(fullfile(bcpRoot, 'tests'));         % unit tests

clear bcpRoot;
