run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
r = runtests('tBcpAlgorithms');
disp(table(r));
fprintf('\n=== %d passed, %d failed, %d incomplete ===\n', sum([r.Passed]), sum([r.Failed]), sum([r.Incomplete]));
if any([r.Failed])
    f = r([r.Failed]);
    for k = 1:numel(f)
        fprintf(2, '\n---- FAILED: %s\n', f(k).Name);
    end
end
exit(double(any([r.Failed])));
