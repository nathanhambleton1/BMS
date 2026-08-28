run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
%  And exercise the new harness-summary branches: a run where the limiter
%  engages, the raw SOC hits its floor, and (with the limiter off) the latch
%  cycles -- so every conditional line gets printed at least once.
warning('off','bcp:Project:Issues');
for lim = [true false]
    [q, ct] = pulse195_setup('Period_s',60);
    q.Load = bcp.LoadSignal('Waveform','constant', 'Const_W',20000, ...
        'Pmax_W',35000, 'Slew_W_per_s',20000/0.05, 'StartTime_s',2);
    q.Bms.ChargeEnabled  = false;
    q.Bms.UseLoadLimiter = lim;
    if ~lim, q.Bms.Q_uv_reset_Ah = 0; end
    q = q.sync();
    h = bcp.Harness(q, 'CellTables', ct, 'ModelName', sprintf('dg_sum_%d',lim), ...
        'SOC_init', 0.10);
    h.build();
    out = h.simulate(400);
    fprintf('\n\n########## harness summary, UseLoadLimiter = %d ##########', lim);
    h.summary(out);
    close_system(sprintf('dg_sum_%d',lim), 0);
end
