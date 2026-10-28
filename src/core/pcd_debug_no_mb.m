function result = pcd_debug_no_mb(opts)
%PCD_DEBUG_NO_MB 未打微泡调试：CW 正弦，示波器 AUTO，RAW 读 CH1 做 FFT。
% 运行至 STOP FUS。期间可改「1. 采集」里的频率/电压（回车或点别处即下发）。
% opts.ui 为 UI 适配层（实现见 pcd_ui_html，约定接口见 pcd_ui_check）。
if nargin < 1
    opts = struct();
end

ui = [];
if isfield(opts, 'ui'), ui = opts.ui; end
ui = pcd_ui_check(ui);

cfg = rigol_instr_config();

L = pcd_param_limits();
freq = getf(opts, 'freq_mhz', 1.5);
volt = getf(opts, 'volt_mVpp', 20);
npts = getf(opts, 'npts', 20000);
npts = max(L.npts_min, min(round(npts), L.npts_max));
Fs   = getf(opts, 'fs_target', 40e6);

global pcd_abort fgen
pcd_abort = false;
token = pcd_visa('token');
liveStop = onCleanup(@() pcd_debug_live('stop')); %#ok<NASGU>
rfStop = onCleanup(@() pcd_visa('rf_off_if', token)); %#ok<NASGU>

outdir = fullfile(pcd_root(), 'data');
if isfield(opts, 'outdir') && ~isempty(opts.outdir)
    outdir = opts.outdir;
end
if ~isfolder(outdir), mkdir(outdir); end
started_at = datestr(now, 'yyyy-mm-ddTHH:MM:SS');

trig = max(1e-3, 0.2 * (volt / 1000));
burst = isfield(opts, 'drive') && strcmpi(opts.drive, 'burst');
burst_s = [];
view_s = [];
if burst
    burst_s = opts.n_cycle / (freq * 1e6);
    % 采集长度就是这一发。回读和 PCD 都从触发点起裁这么长，不再截成示波器刚好能看的前半段。
    view_s = burst_s;
end
scope = pcd_visa('scope');
L = pcd_scope_labels();
if L.manual
    fgen = [];
    ui.status('手动信号源：连续测试只采示波器，频率和电压请在发生器上改。');
else
    fgen = pcd_visa('fgen');
end
if burst
    ui.status(sprintf('连续测试 脉冲  %.3f ms，正在设置示波器', burst_s * 1e3));
    info = rigol_dho814_setup(scope, Fs, npts, cfg.scope_pcd_channel, trig, 'SINGle', view_s, freq * 1e6);
    if isfield(info, 'acq_n') && isfinite(info.acq_n) && info.acq_n >= 256
        npts = round(info.acq_n);
    end
    ui.status(sprintf('连续测试 脉冲  %.3f ms  %d 周期  PRF %.3g Hz  两路从触发对齐', ...
        burst_s * 1e3, round(opts.n_cycle), getf(opts, 'prf_hz', 2)));
else
    info = rigol_dho814_setup(scope, Fs, npts, cfg.scope_pcd_channel, trig, 'AUTO');
end
scTx = max(0.05, (volt / 1000) / 1.4);
scPcd = scTx;
[freq, volt] = pcd_debug_live('start', ui, freq, volt);

if ~L.manual
    rigol_dg2052_output_set(fgen, true);
end
t0 = tic;
pulse = 0;
n_clip = 0;
clip_retry = 0;
peaks = [];
datamat = [];
txmat = [];
try
    while pcd_visa('alive', token)
        [freq, volt] = pcd_debug_live('get');
        if burst
            [chPcd, ~, realFs, chTx] = rigol_dho814_acquire_block( ...
                scope, npts, cfg.scope_pcd_channel, 'single', [], [], view_s);
        else
            [chPcd, ~, realFs, chTx] = rigol_dho814_acquire_block(scope, npts, cfg.scope_pcd_channel, 'live');
        end
        if ~pcd_visa('alive', token)
            break;
        end
        pkTx = 0;  if ~isempty(chTx),  pkTx = max(abs(chTx));   end
        pkPcd = 0; if ~isempty(chPcd), pkPcd = max(abs(chPcd)); end
        clipped = rigol_dho814_clipped(chTx, scTx) || rigol_dho814_clipped(chPcd, scPcd);
        % 每发按峰值预留 4× 余量（K_DIV=1.0）。削顶会造假谐波，入库会把谱带歪：
        % 贴轨帧不写入 datamat，扩量程后重采，连续最多 3 次。
        scTx0 = scTx;    % 记下仪器**当前真正在用**的量程，供下面的 8% 滞后比较
        scPcd0 = scPcd;
        K_DIV = 1.0;
        if pkTx > 1e-4
            scTx = min(10, max(0.005, pkTx / K_DIV));
        end
        if pkPcd > 1e-4
            scPcd = min(10, max(0.005, pkPcd / K_DIV));
        end
        if clipped
            scTx  = min(10, 1.5 * scTx);
            scPcd = min(10, 1.5 * scPcd);
            n_clip = n_clip + 1;
        end
        % 与 set_ranges 同一套 8% 滞后：每帧无条件写两路量程、又无条件让几何缓存失效，
        % 会把缓存带来的帧率收益在调试路径上原样还回去（实测每帧多付约 0.35 s）。
        % 没写就退回旧值，保证 scTx/scPcd 始终等于仪器真正在用的量程 ——
        % 上面第 75 行的削顶判定就是拿它们当满量程的。
        if abs(scTx - scTx0) / max(scTx0, 1e-6) > 0.08
            writeline(scope, sprintf(':CHANnel%d:SCALe %.6g', cfg.scope_tx_channel, scTx));
            rigol_dho814_wf_geom('stale');
        else
            scTx = scTx0;
        end
        if abs(scPcd - scPcd0) / max(scPcd0, 1e-6) > 0.08
            writeline(scope, sprintf(':CHANnel%d:SCALe %.6g', cfg.scope_pcd_channel, scPcd));
            rigol_dho814_wf_geom('stale');
        else
            scPcd = scPcd0;
        end
        if clipped
            if clip_retry < 3
                clip_retry = clip_retry + 1;
                ui.status(sprintf('连续测试  削顶已丢弃，扩量程重采（第 %d/3 次）', clip_retry));
                pause(0.05);
                continue;
            end
            clip_retry = 0;
            ui.status('连续测试  连续削顶仍丢弃（不入库），下一发再试');
            pause(0.05);
            continue;
        end
        clip_retry = 0;
        if isempty(chTx) || max(abs(chTx)) == 0
            ui.status('连续测试  这一帧没读到波形，丢掉重采');
            pause(0.05);
            continue;
        end
        pulse = pulse + 1;
        % 采样失败时 acquire_block 返回 []，帧长也可能和上一帧不同：
        % 先整形成定长行，否则下面的矩阵赋值会因维度不一致直接中断整轮调试。
        datamat(pulse, :) = pcd_fitrow(chPcd, npts); %#ok<AGROW>
        txmat(pulse, :) = pcd_fitrow(chTx, npts); %#ok<AGROW>
        % 两路上时域+频谱：CH1 正弦截窗，CH2 整段底噪。峰位仍取 CH1（调试看驱动）。
        tags = pcd_scope_labels();
        % 脉冲要把整段窗口画出来。正弦那种只截 16 个周期的图，脉冲和连续波看起来一样。
        wv = struct('ch', 'tx', 'fft', true);
        if burst
            wv.kind = 'broad';
        end
        [fpk, dpk] = ui.waveform(chTx, realFs, freq, '回读', wv);
        if ~isempty(chPcd)
            ui.waveform(chPcd, realFs, freq, 'PCD', struct('ch', 'pcd', 'fft', true));
        end
        peaks(pulse, :) = [fpk, dpk]; %#ok<AGROW>
        ok = isfinite(fpk) && abs(fpk - freq) < 0.25;
        pp1 = 0;
        if ~isempty(chTx)
            pp1 = (max(chTx) - min(chTx)) * 1e3;
        end
        if pp1 < 0.2 * volt
            ok = false;
        end
        msg = sprintf('连续测试 %s  设定 %.3g MHz  %.4g mVpp  %s %.2f mVpp @ %s  #%d  （停止结束）', ...
            tern(burst, '脉冲', '连续波'), freq, volt, tags.txTag, pp1, ...
            tern(ok && isfinite(fpk), sprintf('%.3f MHz OK', fpk), ...
            tern(isfinite(fpk), sprintf('%.3f MHz', fpk), '无峰')), pulse);
        if pp1 < 0.2 * volt
            msg = [msg '  【' tags.txTag ' 回读过弱，检查接线/探头】']; %#ok<AGROW>
        end
        if ~isfinite(fpk)
            mx = 0;
            if ~isempty(chTx), mx = max(abs(chTx)); end
            msg = sprintf('连续测试 %s 无有效峰（时域 max=%.3g V，p-p=%.2f mV）  #%d', tags.txTag, mx, pp1, pulse);
        end
        ui.status(msg);
        fprintf('%s\n', msg);
        pause(0.05);
    end
catch err
    pcd_visa('rf_off_if', token);
    rethrow(err);
end
pcd_visa('rf_off_if', token);

S = struct();
S.datamat = datamat;
S.txmat = txmat;
S.peaks_mhz_db = peaks;
S.realFs = info.realFs;
S.freq_MHz = freq;
S.volt_mVpp = volt;
S.duration_s = toc(t0);
S.npts = npts;
if burst
    S.note = 'continuous test burst; live V/f from GUI; CH1 FFT, CH2 PCD; RAW snapshot';
else
    S.note = 'continuous test CW; live V/f from GUI; CH1 FFT, CH2 PCD; RAW snapshot';
end
S.n_clip_expand = n_clip;        % 削顶丢弃并重采的次数（未写入 datamat）
S.pcd_scale_vdiv = scPcd;        % CH2 最终量程 (V/div)
S.waveform_format = info.waveform_format;
% 与正式实验同一套 params；debug 是 CW，PRF/周期数只作当时界面留档。
src = struct();
try, src.raw = ui.raw(); catch, src.raw = struct(); end
if isfield(opts, 'raw') && isstruct(opts.raw)
    src.raw = opts.raw;
end
src.volt_out_mVpp = volt;
src.dbg_freq = freq;
src.dbg_volt = volt;
src.npts = npts;
src.fs_target = Fs;
src.realFs = info.realFs;
src.prf_hz = getf(opts, 'prf_hz', NaN);
src.n_cycle = getf(opts, 'n_cycle', NaN);
src.pcd_scale_vdiv = scPcd;
src.tx_scale_vdiv = scTx;
src.waveform_format = info.waveform_format;
src.trig_v = trig;
src.drive = tern(burst, 'burst', 'cw');
src.sweep = tern(burst, 'SINGle', 'AUTO');
src.started_at = started_at;
src.scope_tx_channel = info.scope_tx_channel;
src.scope_pcd_channel = info.scope_pcd_channel;
S.params = pcd_save_params('debug', src);
ui.status('正在保存…');
fp = pcd_save_acquisition(outdir, 'cont', S);
result.file = fp;
result.n_pulse = pulse;
if ~isempty(peaks)
    result.median_peak_mhz = median(peaks(:,1), 'omitnan');
else
    result.median_peak_mhz = NaN;
end
ui.status(sprintf('已保存  %d 帧  %s', pulse, fp));
fprintf('连续测试结束：%d 帧，%s 谱峰中位 %.3f MHz\n%s\n', pulse, pcd_scope_labels().txTag, result.median_peak_mhz, fp);
end

function v = getf(s, name, def)
if isfield(s, name) && ~isempty(s.(name)) && all(isfinite(s.(name)))
    v = s.(name);
else
    v = def;
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
