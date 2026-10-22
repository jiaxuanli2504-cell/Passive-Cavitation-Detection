function rigol_dg2052_output_set(dev, on)
%RIGOL_DG2052_OUTPUT_SET 打开/关闭主通道与回读镜像通道的输出。
%
% 为什么要把镜像通道一起开关：
%   回读通道接在发生器的另一个通道上（rigol_instr_config.awg_monitor_channel）。
%   只开主通道的话，示波器回读那一路上什么都没有，削顶检测、回读 FFT、
%   「回读峰在 f0」这些判断全部退化成噪声 —— 而且不会报错，看起来一切正常。
%   关闭时也要一起关，否则「射频已关」之后镜像通道还在输出。
cfg = rigol_instr_config();
chans = cfg.awg_channel;
mon = 0;
if isfield(cfg, 'awg_monitor_channel') && isnumeric(cfg.awg_monitor_channel) ...
        && isscalar(cfg.awg_monitor_channel) && isfinite(cfg.awg_monitor_channel)
    v = round(double(cfg.awg_monitor_channel));
    if v >= 1 && v <= 2
        mon = v;
    end
end
if mon > 0 && mon ~= chans
    chans = [chans mon];
end
for ch = chans
    out = sprintf('OUTPut%d', ch);
    if on
        % 打开前再钉一次 50 Ω，避免前面板被人拨回高阻。
        writeline(dev, [':' out ':LOAD 50']);
        writeline(dev, [':' out ':STATe ON']);
    else
        writeline(dev, [':' out ':STATe OFF']);
    end
end
end
