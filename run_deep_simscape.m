run(fullfile(pwd,'BmsChargerPackage','bcp_setup.m'));
warning('off','bcp:Project:Issues');
%  The scenario the user reported: repeated high-demand pulses at LOW SOC, on
%  the real 195-element Simscape pack. 31250 W at 8% SOC sags the lowest cell
%  to about 2.4 V, which is under the 2.50 V trip -- so without the limiter this
%  is the run that chatters.
function s = local_dig(out, p, tag)
    g = @(n) squeeze(out.logsout.getElement(n).Values.Data);
    D = g('bms_diag');      if size(D,1)==bcp.Signals.DIAG_NUM, D = D.'; end
    M = g('bms_pack_meas'); if size(M,1)==bcp.Signals.NUM, M = M.'; end
    F = g('bms_faults'); F = F(:);
    dn = bcp.Signals.diagNames(); c = @(n) D(:, strcmp(dn,n));
    k0 = 20;
    raw = c('soc_raw_min');
    s.tag     = tag;
    s.edges   = sum(diff(double(F>0))>0);
    s.mask    = max(F);
    s.Vmin    = min(M(k0:end, bcp.Signals.V_MIN));
    s.dcl     = min(c('dcl_frac'));
    s.Ppk     = max(g('bms_P_load_cmd'));
    s.retry   = max(c('retry_count'));
    s.lock    = sum(c('lockout')>0.5);
    s.rawsoc  = min(raw(k0:end));
    s.states  = mat2str(unique(round(c('limit_state'))).');
end
res = {};
for limiterOn = [true false]
    if limiterOn, tag = 'limiter ON '; else, tag = 'limiter OFF'; end
    fprintf('\n\n########## %s ##########\n', tag);
    %  pulse195_model owns the build, so the limiter switch goes in through a
    %  rebuild with the flag set on the project it constructs. Easiest honest
    %  route: build with the model function, then re-insert with the flag.
    [~,~,~,out,p] = pulse195_model('Period_s',20, 'StopTime_s',300, ...
        'SOC_init',0.08, 'Model', sprintf('deep_sim_%d',limiterOn), ...
        'LimiterOn', limiterOn);
    res{end+1} = local_dig(out, p, tag);
end
fprintf('\n\n===== 31250 W pulses every 20 s, real Simscape 195S1P from 8%% SOC =====\n');
fprintf('%-12s %8s %6s %9s %8s %8s %8s %10s\n', ...
    'run','faultUp','mask','minVcell','min dcl','retries','lockN','rawSOCmin');
for k = 1:numel(res)
    r = res{k};
    fprintf('%-12s %8d %6g %9.4f %8.4f %8g %8d %9.3f%%\n', ...
        r.tag, r.edges, r.mask, r.Vmin, r.dcl, r.retry, r.lock, 100*r.rawsoc);
end
fprintf('\nUV trip 2.500 V/cell;  foldback band 2.580 .. 2.780 V/cell\n');
for k = 1:numel(res)
    fprintf('%s limit states: %s\n', res{k}.tag, res{k}.states);
end
