run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
r = runtests('tBcpBuild');
for k = 1:numel(r)
    if r(k).Failed, tag='FAIL'; elseif r(k).Incomplete, tag='SKIP'; else, tag='pass'; end
    fprintf('[%s] %s (%.1f s)\n', tag, r(k).Name, r(k).Duration);
end
fprintf('\n=== %d passed, %d failed, %d incomplete ===\n', sum([r.Passed]), sum([r.Failed]), sum([r.Incomplete]));
