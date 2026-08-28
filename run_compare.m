run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
warning('off','bcp:Project:Issues');
function r = local_run(name, limiterOn, slew, uvAh)
    [p, ct] = pulse195_setup('Period_s',60);
    p.Load = bcp.LoadSignal('Waveform','constant', 'Const_W',20000, ...
        'Pmax_W',35000, 'Slew_W_per_s',slew, 'StartTime_s',2);
    p.Bms.ChargeEnabled  = false;
    p.Bms.UseLoadLimiter = limiterOn;
    p.Bms.Q_uv_reset_Ah  = uvAh;
    p = p.sync();
    h = bcp.Harness(p, 'CellTables', ct, 'ModelName', name, 'SOC_init', 0.12);
    h.build(); out = h.simulate(400);
    g = @(n) squeeze(out.logsout.getElement(n).Values.Data);
    D = g('bms_diag');   if size(D,1)==bcp.Signals.DIAG_NUM, D = D.'; end
    M = g('bms_pack_meas'); if size(M,1)==bcp.Signals.NUM, M = M.'; end
    F = g('bms_faults'); F = F(:);
    dn = bcp.Signals.diagNames(); c = @(n) D(:, strcmp(dn,n));
    r.name    = name;
    r.edges   = sum(diff(double(F>0))>0);
    r.Vmin    = min(M(:,bcp.Signals.V_MIN));
    r.dcl     = min(c('dcl_frac'));
    r.retry   = max(c('retry_count'));
    r.lockout = sum(c('lockout')>0.5);
    r.Pmin    = min(g('bms_P_load_cmd'));
    r.uvAh    = max(c('uv_charge_Ah'));
    close_system(name, 0);
end
res = [ local_run('cmp_legacy', false, 0,          0), ...
        local_run('cmp_uvAh',  false, 20000/0.05, 0.0225), ...
        local_run('cmp_on',    true,  20000/0.05, 0.0225) ];
fprintf('\n\n============ 20 kW constant load, 195S1P from 12%% SOC, no charger ============\n');
fprintf('%-10s %8s %10s %10s %8s %9s\n', 'run','faultUp','minVcell','min dcl','retries','lockoutN');
for r = res
    fprintf('%-10s %8d %10.4f %10.4f %8g %9d\n', r.name, r.edges, r.Vmin, r.dcl, r.retry, r.lockout);
end
fprintf('\nUV trip 2.500 V/cell;  foldback band 2.580 .. 2.780 V/cell\n');
fprintf('cmp_off  = limiter OFF, ramped edges  (the old behaviour)\n');
fprintf('cmp_soft = limiter OFF, step edges    (the oldest behaviour)\n');
fprintf('cmp_on   = limiter ON                 (the new default)\n');
