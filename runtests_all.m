run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
tot = struct('p',0,'f',0,'i',0);
for suite = {'tBcpAlgorithms','tBcpBuild','tBcpApp'}
    r = runtests(suite{1});
    fprintf('\n=== %s: %d passed, %d failed, %d incomplete ===\n', ...
        suite{1}, sum([r.Passed]), sum([r.Failed]), sum([r.Incomplete]));
    for k = 1:numel(r)
        if r(k).Failed, fprintf(2,'  FAIL %s\n', r(k).Name); end
    end
    tot.p = tot.p + sum([r.Passed]);
    tot.f = tot.f + sum([r.Failed]);
    tot.i = tot.i + sum([r.Incomplete]);
end
fprintf('\n##### TOTAL: %d passed, %d failed, %d incomplete #####\n', tot.p, tot.f, tot.i);
fprintf('\n##### harness pulse test #####\n');
ok = pulse195_harness('Period_s',60, 'StopTime_s',310, 'SOC_init',0.60);
fprintf('\n##### HARNESS pulse195 ok = %d #####\n', ok);
