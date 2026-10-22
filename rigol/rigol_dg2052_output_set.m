function rigol_dg2052_output_set(dev, on)
%RIGOL_DG2052_OUTPUT_SET 打开/关闭主通道与回读镜像通道的输出。
%
% 为什么要把镜像通道一起开关：
%   回读通道接在发生器的另一个通道上（rigol_instr_config.awg_monitor_channel）。
%   只开主通道的话，示波器回读那一路上什么都没有，削顶检测、回读 FFT、
%   「回读峰在 f0」这些判断全部退化成噪声 —— 而且不会报错，看起来一切正常。
%   关闭时也要一起关，否则「射频已关」之后镜像通道还在输出。
%
% 负载声明按通道给不同的值：主通道驱动 50 Ω 功放，声明 50；镜像通道驱动示波器
% 1 MΩ，声明 10000（本机上限），否则回读会显示设定值的 2 倍。
% 这里写 LOAD 不会改变已经算好的幅度，但下次写 :VOLTage 时会用到它，
% 所以必须在这里就摆对 —— rigol_dg2052_set_vpp_mV 也依赖它。
cfg = rigol_instr_config();
chans = cfg.awg_channel;
loads = 50;
[mon, mon_load] = rigol_dg2052_monitor(cfg);
if mon > 0 && mon ~= cfg.awg_channel
    chans = [chans mon];
    loads = [50 mon_load];
end
for i = 1:numel(chans)
    out = sprintf('OUTPut%d', chans(i));
    if on
        % 打开前再钉一次负载，避免前面板被人拨回高阻。
        writeline(dev, sprintf(':%s:LOAD %.10g', out, loads(i)));
        writeline(dev, [':' out ':STATe ON']);
    else
        writeline(dev, [':' out ':STATe OFF']);
    end
end
end
