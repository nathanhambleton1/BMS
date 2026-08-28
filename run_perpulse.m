run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
warning('off','bcp:Project:Issues');
[~,~,~,out,p] = pulse195_model('Period_s',20, 'StopTime_s',300, 'SOC_init',0.08, ...
    'Model','deep_pp', 'LimiterOn', true, 'Rebuild', true);
g = @(n) squeeze(out.logsout.getElement(n).Values.Data);
tv = out.logsout.getElement('bms_pack_meas').Values.Time(:);
M = g('bms_pack_meas'); if size(M,1)==bcp.Signals.NUM, M=M.'; end
D = g('bms_diag');      if size(D,1)==bcp.Signals.DIAG_NUM, D=D.'; end
dn = bcp.Signals.diagNames();
dcl = D(:, strcmp(dn,'dcl_frac'));
Vmin = M(:, bcp.Signals.V_MIN);
Pl = g('bms_P_load_cmd');
tl = out.logsout.getElement('bms_P_load_cmd').Values.Time(:);
Pl = interp1(tl, Pl(:), tv, 'previous','extrap');
on = Pl > 15625;
d = diff([0; double(on); 0]);
i0 = find(d>0); i1 = find(d<0)-1;
fprintf('\n\n=== per-pulse behaviour, 31250 W every 20 s, real 195S1P from 8%% SOC ===\n');
fprintf('%5s %8s %10s %10s %10s %10s\n','pulse','t_start','minVcell','dcl@start','dcl@end','s below 2.50V');
for k = 1:numel(i0)
    r = i0(k):min(i1(k)+20, numel(tv));
    below = sum(Vmin(r) < 2.50) * median(diff(tv));
    fprintf('%5d %8.1f %10.4f %10.4f %10.4f %10.3f\n', k, tv(i0(k)), ...
        min(Vmin(r)), dcl(i0(k)), dcl(min(i1(k),numel(tv))), below);
end
fprintf('\nt_v_trip = %.2f s -- an excursion shorter than that cannot latch UV.\n', p.Bms.t_v_trip);
