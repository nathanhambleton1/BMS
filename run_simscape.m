run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
fprintf('\n########## SIMSCAPE 195S1P, 5 pulses from 60%% SOC ##########\n');
[ok, T] = pulse195_model('Period_s',60, 'StopTime_s',310, 'SOC_init',0.60);
fprintf('\nSIMSCAPE RESULT: ok = %d  (%d of %d checks passed)\n', ok, sum(T.Passed), height(T));
if ~ok
    for k = 1:height(T)
        if ~T.Passed(k), fprintf(2,'  FAIL %s :: %s\n', T.Check{k}, T.Detail{k}); end
    end
end
