function rigol_dg2052_load(dev, ch, ohms)
%RIGOL_DG2052_LOAD 声明输出负载（Ω），默认 50。
%
% 必须在写 VOLTage **之前**调用。实测（DG2052 / 00.02.07）：
%   同一个 20 mVpp 的设定，LOAD=50 驱动 1 MΩ 负载 → 实收 39.7 mV（2 倍）；
%   先声明 LOAD=10000 再写幅度 → 实收 20.3 mV（1.02 倍）；
%   先写幅度、后改 LOAD → 没有任何效果，仍是 2 倍。
% 也就是说负载补偿只在写 :VOLTage 那一刻算一次，改 LOAD 不会追溯重算。
% 主通道驱动 50 Ω 功放，调用时不传欧姆数就是 50。开机面板默认高阻。
if nargin < 2 || isempty(ch)
    cfg = rigol_instr_config();
    ch = cfg.awg_channel;
end
if nargin < 3 || isempty(ohms) || ~isfinite(ohms) || ohms <= 0
    ohms = 50;
end
out = sprintf('OUTPut%d', ch);
writeline(dev, sprintf(':%s:LOAD %.10g', out, ohms));
rd = strtrim(char(writeread(dev, sprintf(':%s:LOAD?', out))));
n = str2double(rd);
% 固件会把过大的值钳到上限（10000），所以只校验「别比要的小太多」。
if ~(isfinite(n) && n >= 0.8 * ohms)
    error('rigol:dg2052:load', ...
        'CH%d 输出负载未能设为 %.10g Ω（回读 %s）。', ch, ohms, rd);
end
end
