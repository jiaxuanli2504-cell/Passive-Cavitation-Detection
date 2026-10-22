function [chPcd, timeIntervalNanoSeconds, realFs, chTx, okTx, anchor_i, crop_mode] = rigol_dho814_acquire_block(dev, npts, ch, mode, timeout_s, live_wait_s, burst_s)
%RIGOL_DHO814_ACQUIRE_BLOCK
% 'single'：等一次触发后读 RAW。触发超时则 STOP 后仍读一屏。
% 'live'：RUN 约一个 PRF 再 STOP 读（回读太弱、边沿触发空等时用）。
%
% npts 是这一发要用来做频谱的**精确点数**（= rigol_dho814_capture_geometry 的 acq_n），
% 不是「最多多少点」。
%
% 锚点（这一发在记录里的起点）怎么定，取决于触发怎么给：
%   'trigger' —— 配了独立触发通道（发生器后面板 Trig Out → 某一路模拟 BNC）时，
%                触发时刻就是这一发的起点，位置由示波器几何直接给出：
%                    i0 = round(-XORigin / XINCrement) + 1
%                实测 6 帧零漂移、误差 64 ns。**不扫波形**，因此与回读幅度无关，
%                回读读失败也不影响取窗。
%   'span'    —— 靠回读通道的模拟边沿触发时，t0 在记录里的位置未知，只能在数据里
%                找包络上升沿。这条路有 20 µs 平滑窗带来的 ~12 µs 系统偏置，
%                且要求回读幅度足够大（≲20 mVpp 会找不到）。
% 第 6 个输出 anchor_i 是实际用的起点下标（没定出锚点时为 []），第 7 个 crop_mode
% 说明走了哪条路 / 是否退回 'fallback'。这两个值就是为了让上面的区别在日志里可见 ——
% 只看返回点数分不出 'trigger' 和 'span'，两者都会被 npts 夹成同样的长度。
cfg = rigol_instr_config();
if nargin < 3 || isempty(ch)
    ch = cfg.scope_pcd_channel;
end
if nargin < 4 || isempty(mode)
    mode = 'single';
end
if nargin < 5 || isempty(timeout_s)
    timeout_s = cfg.acquire_timeout_s;
end
if nargin < 6 || isempty(live_wait_s)
    live_wait_s = 0.22;
end
live_wait_s = max(0.12, min(1.2, live_wait_s));
if nargin < 7 || isempty(burst_s) || ~isfinite(burst_s) || burst_s <= 0
    burst_s = [];
end
tx = cfg.scope_tx_channel;
oldT = [];
try
    oldT = dev.Timeout;
    % 波形块偶尔传不完。最多等 8 秒，不要用连接上的 60 秒把界面冻住。
    dev.Timeout = 8;
catch
end

chPcd = [];
chTx = [];
xinc = NaN;
anchor_i = [];   % 先占住：里面有多处提前 return，不留到 catch 才算未定义
crop_mode = 'none';
% 配了独立触发通道 → 触发时刻就是这一发的起点，锚点可以算出来，不必扫波形。
% 判据与 rigol_dho814_setup 里 ttlTrig 同源：触发通道存在且不是回读通道。
hwTrig = false;
if isfield(cfg, 'scope_trig_channel') && isnumeric(cfg.scope_trig_channel) ...
        && isscalar(cfg.scope_trig_channel) && isfinite(cfg.scope_trig_channel)
    tc = round(double(cfg.scope_trig_channel));
    hwTrig = tc >= 1 && tc <= 4 && tc ~= tx;
end
try
    if strcmpi(mode, 'live')
        % RAW 只能在 STOP 后读。调试若只 STOP 不 RUN，第一帧用的是 setup 里
        % 已经采满的缓冲，看起来正常；第二帧起仪器一直停着，读到的还是同一屏，
        % 改完量程后 :WAVeform:DATA? 还可能一直等到超时 —— 界面就像卡在 #1。
        writeline(dev, ':RUN');
        if ~pause_or_abort(live_wait_s)
            restore_timeout(dev, oldT);
            realFs = 40e6;
            timeIntervalNanoSeconds = 1e9 / realFs;
            return;
        end
        writeline(dev, ':STOP');
        if ~pause_or_abort(0.05)
            try, writeline(dev, ':RUN'); catch, end
            restore_timeout(dev, oldT);
            realFs = 40e6;
            timeIntervalNanoSeconds = 1e9 / realFs;
            return;
        end
    else
        writeline(dev, ':SINGle');
        % 上一发读完仪器停在 STOP。立刻查 STATus 仍是 STOP，会把旧波形再读一遍
        % （调探头距离时表现为连续完全相同的脉冲）。先等到离开 STOP（已武装 WAIT），
        % 再等这次触发完成回到 STOP。不改 WORD/RAW。
        tArm = tic;
        tDraw = tic;
        while toc(tArm) < min(1.0, timeout_s)
            if scope_abort()
                writeline(dev, ':STOP');
                restore_timeout(dev, oldT);
                realFs = 40e6;
                timeIntervalNanoSeconds = 1e9 / realFs;
                return;
            end
            st = rigol_visa_query(dev, ':TRIGger:STATus?');
            if ~contains(st, 'STOP', 'IgnoreCase', true)
                break;
            end
            if toc(tDraw) > 0.2
                drawnow;
                tDraw = tic;
            end
            pause(0.01);
        end
        t0 = tic;
        while toc(t0) < timeout_s
            if scope_abort()
                writeline(dev, ':STOP');
                restore_timeout(dev, oldT);
                realFs = 40e6;
                timeIntervalNanoSeconds = 1e9 / realFs;
                return;
            end
            st = rigol_visa_query(dev, ':TRIGger:STATus?');
            if contains(st, 'STOP', 'IgnoreCase', true)
                break;
            end
            if toc(tDraw) > 0.2
                drawnow;
                tDraw = tic;
            end
            pause(0.01);
        end
        % 超时也 STOP 后读一屏：空返回会让网页一直停在上一实验的图。
        writeline(dev, ':STOP');
    end

    % 两路各读整段内存，再裁同一段。
    % 不写 STARt/STOP：这台固件一写就 -200，屏幕报远程指令执行错误。
    [chTx, xinc, xorigin] = read_raw(dev, tx, npts);
    [chPcd, x2, xo2] = read_raw(dev, ch, npts);
    if ~(isfinite(xinc) && xinc > 0) && isfinite(x2) && x2 > 0
        xinc = x2;
    end
    if ~(isfinite(xorigin)) && isfinite(xo2)
        xorigin = xo2;
    end
    % 锚点：这一发在记录里的起点下标。
    if hwTrig
        % 独立触发通道：触发时刻就是这一发起点。XORigin ≡ -记录/2，
        % 所以触发点下标 = round(-XORigin / XINCrement) + 1，一条除法就够。
        % 不扫波形 —— 与回读幅度无关，回读整段读失败也能取窗。
        if isfinite(xorigin) && isfinite(xinc) && xinc > 0
            anchor_i = round(-xorigin / xinc) + 1;
        end
        crop_mode = 'trigger';
    else
        % 靠回读通道的模拟边沿触发：t0 在记录里的位置未知，只能在数据里找包络。
        if ~isempty(chTx) && isfinite(xinc) && xinc > 0
            [s0, ~] = signal_span(chTx, xinc);
            anchor_i = s0;
        end
        crop_mode = 'span';
    end
    n_total = max(numel(chTx), numel(chPcd));
    if ~isempty(anchor_i) && anchor_i >= 1 && anchor_i + npts - 1 <= n_total
        [chTx, chPcd] = crop_at(chTx, chPcd, anchor_i, npts);
    else
        % 定不出锚点，或记录里装不下 npts 点：退回「按这一发长度裁」，
        % 并把 crop_mode 标成 fallback —— 这条路的窗起点不可信，日志要能看出来。
        if strcmp(crop_mode, 'trigger')
            anchor_i = [];
        end
        [chTx, chPcd] = crop_same(chTx, chPcd, xorigin, xinc, npts, burst_s);
        crop_mode = 'fallback';
    end
    if strcmpi(mode, 'live')
        % 读完重新跑起来，示波器屏幕才不会冻住，下一圈 :RUN 也有新数据可停。
        try, writeline(dev, ':RUN'); catch, end
    end
catch
    chPcd = [];
    chTx = [];
    crop_mode = 'error';
end

if ~(isfinite(xinc) && xinc > 0)
    xinc = 1 / 40e6;
end
okTx = ~isempty(chTx);
realFs = 1 / xinc;
timeIntervalNanoSeconds = xinc * 1e9;
restore_timeout(dev, oldT);
end

function [a, b] = crop_at(a, b, i0, want_n)
%CROP_AT 从给定锚点 i0 起取满 want_n 点，两路用同一组下标。
% 锚点由调用方定（'trigger' 走示波器几何、'span' 走包络检测），这里只按下标切，
% 不再自己找起点 —— 以前 crop_fixed 内部又扫一次 signal_span，等于把已经算准的锚点
% 重新用一个有 12 µs 偏置的启发式覆盖掉。
% 取不满 want_n 的那一路返回 []：上游按 okTx 判断，不要给一个长度不一的半截窗。
last = i0 + want_n - 1;
if numel(a) >= last
    a = a(i0:last);
else
    a = [];
end
if numel(b) >= last
    b = b(i0:last);
else
    b = [];
end
end

function [a, b] = crop_same(a, b, xorigin, xinc, npts, burst_s)
% 两路用同一段。优先从回读通道上这一发真正开始的地方裁到它结束。
% 找不到跳变时才退回触发点。最长不超过这一发，内存里不够就不补。
if isempty(a) && isempty(b)
    return
end
na = numel(a);
nb = numel(b);
n = max(na, nb);
if n < 256 || ~(isfinite(xinc) && xinc > 0)
    return
end
[i0, last] = signal_span(a, xinc);
if isempty(i0)
    if ~(isfinite(xorigin))
        i0 = floor(n / 2) + 1;
    else
        i0 = round((-xorigin) / xinc) + 1;
    end
    last = n;
end
if i0 < 1
    i0 = 1;
end
n_cap = last - i0 + 1;
if ~isempty(burst_s) && isfinite(burst_s) && burst_s > 0
    n_cap = min(n_cap, max(256, round(burst_s / xinc)));
end
if isfinite(npts) && npts >= 256
    n_cap = min(n_cap, npts);
end
last = i0 + n_cap - 1;
if na > 0
    last = min(last, na);
end
if nb > 0
    last = min(last, nb);
end
if last - i0 + 1 < 256
    return
end
if na >= last
    a = a(i0:last);
end
if nb >= last
    b = b(i0:last);
end
end

function [i0, i1] = signal_span(y, xinc)
% 相对记录开头的空档，包络超过峰值 25% 的那一段。
% 正弦和猝发台阶都算有信号；整段都是同一个直流时峰值不够，返回空。
i0 = [];
i1 = [];
n = numel(y);
if n < 1000 || ~(isfinite(xinc) && xinc > 0)
    return
end
win = max(8, round(0.02e-3 / xinc));
if n < win * 4
    return
end
% 空档是最靠近 0 的那一截。猝发占了大半段时，整段中位数会落到高电平上。
nq = max(win, floor(0.15 * n));
[~, ord] = sort(abs(y(:)));
base = median(y(ord(1:nq)));
ac = abs(y(:) - base);
c = cumsum([0; ac]);
ma = (c((1 + win):end) - c(1:(end - win))) / win;
pk = max(ma);
% 门限必须是**相对**的：ma 是 20 µs 滑动平均，正弦包络只有幅度的 ~2/π。
% 实测 98 mVpp（峰 49 mV）的信号，ma 峰值只有 30.9 mV —— 原来那道
% `max(0.05, …)` 的绝对 50 mV 门槛是它的 1.6 倍，于是永远判「找不到猝发」，
% 65 mVpp 以下的信号更是连 pk>=0.02 都过不去。
% 现在用空档里的典型起伏 nz = median(ac) 当噪声底：真猝发的 pk/nz 实测约 130 倍，
% 纯噪声只有 1 倍出头，所以 6× 既能挡住噪声，又不对幅度设死板下限。
%
% 注意这条启发式现在只在**没有独立触发通道**时才用（crop_mode='span'）。
% 配了硬件触发时锚点由 XORigin/XINCrement 直接算出，不必扫波形 —— 那条路
% 实测零漂移、误差 64 ns，比这里的 20 µs 平滑窗精确约 190 倍。
nz = median(ac);
if ~(isfinite(pk) && isfinite(nz) && pk >= max(0.002, 6 * nz))
    return
end
ks = find(ma > max(6 * nz, 0.4 * pk));
if isempty(ks)
    return
end
i0 = ks(1);
i1 = min(n, ks(end) + win - 1);
if i1 - i0 + 1 < 256
    i0 = [];
    i1 = [];
end
end

function [y, xinc, xorigin] = read_raw(dev, ch, npts)
y = [];
xinc = NaN;
xorigin = NaN;
for attempt = 1:2
    try
        [y, xinc, xorigin] = rigol_dho814_read_channel(dev, ch, npts, 'RAW');
        return
    catch
        try
            writeline(dev, '*CLS');
            writeline(dev, ':STOP');
        catch
        end
    end
end
end

function restore_timeout(dev, oldT)
if ~isempty(oldT)
        try
            dev.Timeout = oldT;
        catch
        end
end
end

function tf = scope_abort()
global pcd_abort %#ok<GVMIS>
tf = ~isempty(pcd_abort) && logical(pcd_abort);
end

function ok = pause_or_abort(dt)
% 短暂停也要让 STOP / 关窗进来；中止就立刻返回，别把 visadev 空等到 Timeout。
ok = false;
t0 = tic;
while toc(t0) < dt
    if scope_abort()
        return;
    end
    pause(min(0.02, dt));
end
ok = true;
end
