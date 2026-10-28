function [y, xinc, xorigin, i0] = rigol_dho814_read_channel(dev, ch, npts, wavemode, i0in)
%RIGOL_DHO814_READ_CHANNEL STOP 后读取通道。
%
% 用 WORD（16 位）而不是 BYTE（8 位）：DHO814 是 12 位 ADC，BYTE 读回来只剩 8 位，
% 白扔 24 dB 动态范围。实测某轮数据里 IC 频带（3.3 MHz 一带）的信号只有 20–95 µV，
% 而 BYTE 的量化噪声 RMS 就有约 72 µV —— 那时测到的全是量化本底，不是空化宽带。
%
% 第 5 个输入 i0in：已定好的起点（两路必须同一个）。空则用本通道 XORigin 算。
% 第 4 个输出 i0：这一包已经是从触发点起的 npts 点时，给出内存里的起点下标；
% 读回来的仍是整段内存时为 []，由 acquire_block 再裁。
%
% 手册 3.28.12：RAW 下 :WAVeform:STARt/:STOP 是「读哪一段」，不是搬触发点。
% 先把 STAR 收到 1，再把 STOP 放到脉冲末尾，最后把 STAR 放到触发点，避免
% 起点大于当前终点而 -200。这台机器若仍拒绝，试一次就关掉，之后每帧仍读整段。
%
% 注意 DHO800 的 :WAVeform:* 一共 14 条命令，**没有** :WAVeform:BYTeorder
% （手册 3.28 各节），所以字节序不能靠发命令声明，只能按约定解析 —— 见下面的
% YREFerence 判断。
if nargin < 3 || isempty(npts) || ~isfinite(npts) || npts < 256
    npts = 256;
end
if nargin < 4 || isempty(wavemode)
    wavemode = 'RAW';
end
if nargin < 5 || isempty(i0in) || ~isfinite(i0in)
    i0in = [];
end
xorigin = NaN;
i0 = [];
FMT = 'WORD';                          % 想退回 8 位就改这里（decode 两条分支都在）

chan = sprintf('CHANnel%d', ch);
% 通道关着时 :WAVeform:SOURce 会回 -200，屏幕每一帧闪「远程指令执行错误」。
writeline(dev, sprintf(':CHANnel%d:DISPlay ON', ch));
writeline(dev, sprintf(':WAVeform:SOURce %s', chan));
writeline(dev, sprintf(':WAVeform:MODE %s', wavemode));
writeline(dev, sprintf(':WAVeform:FORMat %s', FMT));

% 几何走缓存：POINts/XINCrement/XORigin 一轮内定死，Y 三项只在这个通道换过量程后才重查。
% 实测 :WAVeform:* 查询约 31–93 ms/条，每帧两路各 6 条就是几百毫秒 —— 缓存掉这些查询
% 是整帧从 ~0.73 s 降到 ~0.17 s 的主要来源。换量程处必须调用 wf_geom('stale')。
G = rigol_dho814_wf_geom('get', dev, ch);
nact   = G.poins;
yinc   = G.yinc;
yor    = G.yor;
yref   = G.yref;
xinc   = G.xinc;
xorigin = G.xorigin;
if ~(isfinite(nact) && nact >= 256)
    error('rigol:dho814:npts', 'CH%d 缓冲只有 %g 点，跳过本帧', ch, nact);
end

if ~(isfinite(yinc) && yinc ~= 0)
    error('rigol:dho814:yinc', 'CH%d YINCrement 无效（%.4g）。通道可能未打开或未采到波形。', ch, yinc);
end
if ~(isfinite(xinc) && xinc > 0)
    error('rigol:dho814:xinc', 'CH%d XINCrement 无效', ch);
end
if ~isfinite(yor), yor = 0; end
if ~isfinite(yref), yref = 0; end

% 只传触发后这一发。两路字节从约 4 MB 降到脉冲本身（6.66 ms 约 0.8 MB），
% 5 Hz 的下一发到来之前才有机会读完。失败则这一帧仍是整段内存。
[i0, armed] = arm_slice(dev, npts, nact, xorigin, xinc, i0in);
writeline(dev, ':WAVeform:DATA?');
payload = rigol_read_ieee_block_binary(dev);
if isempty(payload)
    error('rigol:dho814:waveform', '未读到 CH%d 波形', ch);
end
want_b = round(npts) * 2;
if armed && abs(numel(payload) - want_b) > 8
    % 命令没报错，但块长度仍是整段：这台固件没按窗口裁。退回，别把窗口留在半截。
    disarm_slice(dev, nact);
    i0 = [];
end

% 按 YREFerence 判定二进制约定（详见 rigol_decode_waveform 的说明）
raw = rigol_decode_waveform(payload, FMT, yref);

y = (raw - yor - yref) .* yinc;
if isfinite(nact) && nact > 0 && numel(y) > nact
    y = y(1:nact);
end
if ~isempty(i0) && numel(y) > npts + 4
    i0 = [];
end
end

function [i0, armed] = arm_slice(dev, npts, nact, xorigin, xinc, i0in)
%ARM_SLICE 把下一次 DATA? 限制在触发点起的 npts 点。armed 为 false 时不要假设读回来是短的。
% arm_slice('off') 关掉之后的尝试。persistent 只放在这里，避免和 disarm 各记各的。
persistent gate
if isempty(gate)
    gate = 'try';
end
if nargin >= 1 && (ischar(dev) || isstring(dev)) && strcmp(char(dev), 'off')
    gate = 'off';
    i0 = [];
    armed = false;
    return
end
i0 = [];
armed = false;
if strcmp(gate, 'off')
    return
end
npts = round(npts);
if ~(isfinite(nact) && nact > npts + 8 && isfinite(xinc) && xinc > 0)
    return
end
if ~isempty(i0in) && isfinite(i0in) && i0in >= 1
    i0 = round(i0in);
elseif isfinite(xorigin)
    i0 = round(-xorigin / xinc) + 1;
else
    return
end
i1 = i0 + npts - 1;
if i0 < 1 || i1 > nact
    i0 = [];
    return
end
if strcmp(gate, 'try')
    writeline(dev, '*CLS');
end
write_window(dev, i0, i1);
if strcmp(gate, 'try')
    if slice_err(dev)
        fprintf('示波器不接受波形读窗口，仍读整段内存。\n');
        disarm_slice(dev, nact);
        i0 = [];
        return
    end
    gate = 'on';
    fprintf('波形只读触发后 %d 点（约 %.3f ms），不再传整段内存。\n', ...
        npts, npts * xinc * 1e3);
end
armed = true;
end

function write_window(dev, i0, i1)
% 先把起点收回 1，终点才抬得过旧的 STOP；再把起点放到触发点。
writeline(dev, ':WAVeform:STARt 1');
writeline(dev, sprintf(':WAVeform:STOP %.0f', i1));
writeline(dev, sprintf(':WAVeform:STARt %.0f', i0));
end

function disarm_slice(dev, nact)
arm_slice('off');
try
    writeline(dev, '*CLS');
    writeline(dev, ':WAVeform:STARt 1');
    if isfinite(nact) && nact >= 256
        writeline(dev, sprintf(':WAVeform:STOP %.0f', round(nact)));
    end
    writeline(dev, '*CLS');
catch
end
end

function bad = slice_err(dev)
bad = false;
try
    for k = 1:6 %#ok<NASGU>
        txt = strtrim(char(rigol_visa_query(dev, ':SYSTem:ERRor?')));
        if startsWith(txt, '0')
            return
        end
        bad = true;
    end
catch
    bad = true;
end
end
