run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
tot = struct('p',0,'f',0);
for suite = {'tBcpAlgorithms','tBcpBuild','tBcpApp'}
    r = runtests(suite{1});
    fprintf('\n@@@ %s: %d passed, %d failed, %d incomplete\n', suite{1}, ...
        sum([r.Passed]), sum([r.Failed]), sum([r.Incomplete]));
    for k = 1:numel(r)
        if r(k).Failed, fprintf(2,'  FAIL %s\n', r(k).Name); end
    end
    tot.p = tot.p + sum([r.Passed]); tot.f = tot.f + sum([r.Failed]);
end
fprintf('\n@@@ TESTS TOTAL: %d passed, %d failed\n', tot.p, tot.f);
STAGES = [1 4];
run(fullfile(pwd,'RUN_PULSE_TEST.m'));
