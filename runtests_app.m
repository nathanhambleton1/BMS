run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
r = runtests('tBcpApp');
for k = 1:numel(r)
    if r(k).Failed, tag='FAIL'; elseif r(k).Incomplete, tag='SKIP'; else, tag='pass'; end
    fprintf('[%s] %s\n', tag, r(k).Name);
end
fprintf('\n=== APP: %d passed, %d failed, %d incomplete ===\n', sum([r.Passed]), sum([r.Failed]), sum([r.Incomplete]));
