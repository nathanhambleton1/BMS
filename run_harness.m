run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
fprintf('\n########## HARNESS, deep discharge to under-voltage ##########\n');
%  A long constant load with no charger: the exact scenario that used to
%  chatter. Nothing is asserted here -- it is printed so the traces can be read.
[p, ct] = pulse195_setup('Period_s',60);
p.Load = bcp.LoadSignal('Waveform','constant', 'Const_W',20000, ...
    'Pmax_W',35000, 'Slew_W_per_s',20000/0.05, 'StartTime_s',2);
p.Bms.ChargeEnabled = false;
p = p.sync();
issues = p.check();
fprintf('check(): %d issue(s)\n', numel(issues));
for k=1:numel(issues), fprintf('  %d. %s\n', k, issues{k}); end
h = bcp.Harness(p, 'CellTables', ct, 'ModelName','deep_dch', 'SOC_init', 0.12);
h.build(); out = h.simulate(400);
D = squeeze(out.logsout.getElement('bms_diag').Values.Data);
if size(D,1)==bcp.Signals.DIAG_NUM, D = D.'; end
M = squeeze(out.logsout.getElement('bms_pack_meas').Values.Data);
if size(M,1)==bcp.Signals.NUM, M = M.'; end
F = squeeze(out.logsout.getElement('bms_faults').Values.Data);
dn = bcp.Signals.diagNames();
c = @(n) D(:, strcmp(dn,n));
fprintf('\n--- deep discharge summary ---\n');
fprintf('fault rising edges        : %d\n', sum(diff(double(F(:)>0))>0));
fprintf('final fault mask          : %g (%s)\n', F(end), bcp.Signals.faultBits(F(end)));
fprintf('min cell voltage          : %.4f V (trip %.3f, fold band %.3f..%.3f)\n', ...
    min(M(:,bcp.Signals.V_MIN)), p.Bms.V_uv_trip, p.Bms.V_fold_end(), p.Bms.V_fold_start());
fprintf('min dcl_frac              : %.4f\n', min(c('dcl_frac')));
fprintf('peak retry count          : %g\n', max(c('retry_count')));
fprintf('lockout samples           : %d\n', sum(c('lockout')>0.5));
fprintf('min raw (unclamped) SOC   : %.4f%%\n', 100*min(c('soc_raw_min')));
fprintf('min clamped SOC           : %.4f%%\n', 100*min(M(:,bcp.Signals.SOC_MIN)));
fprintf('limit states seen         : %s\n', mat2str(unique(round(c('limit_state'))).'));
