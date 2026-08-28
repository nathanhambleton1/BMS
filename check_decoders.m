run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
fprintf('\n===== bcp.Signals.faultTable() =====\n');
bcp.Signals.faultTable();
fprintf('\n===== specific masks =====\n');
bcp.Signals.faultTable([4 5 8 10 12]);
fprintf('\n===== decoders =====\n');
for k = 0:5, fprintf('  bmsState(%d)   = %s\n', k, bcp.Signals.bmsState(k)); end
for k = 0:4, fprintf('  limitState(%d) = %s\n', k, bcp.Signals.limitState(k)); end
fprintf('\n  diagNames: %d entries, DIAG_NUM = %d\n', ...
    numel(bcp.Signals.diagNames()), bcp.Signals.DIAG_NUM);
fprintf('  diagUnits: %d entries\n', numel(bcp.Signals.diagUnits()));
fprintf('\n===== default project check() =====\n');
p = bcp.Project();
iss = p.check();
fprintf('  %d issue(s)\n', numel(iss));
for k=1:numel(iss), fprintf('   %d. %s\n', k, iss{k}); end
fprintf('\n===== pulse195 project check() =====\n');
q = pulse195_setup();
iss = q.check();
fprintf('  %d issue(s)\n', numel(iss));
for k=1:numel(iss), fprintf('   %d. %s\n', k, iss{k}); end
fprintf('\n===== pulse195 with a STEP edge, to show check() catching it =====\n');
q2 = q; q2.Load.Slew_W_per_s = 0; q2 = q2.sync();
iss = q2.check();
for k=1:numel(iss), fprintf('   %d. %s\n', k, iss{k}); end
