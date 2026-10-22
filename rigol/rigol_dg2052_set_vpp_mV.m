function rigol_dg2052_set_vpp_mV(dev, ampl_mVpp)
%RIGOL_DG2052_SET_VPP_MV 运行时更新幅度（峰峰值，mV），镜像通道一起跟随。
%
% 闭环每一发都在改电压。如果只改主通道，镜像通道会停在 apply_burst 时那个初始幅度，
% 而示波器读的正是镜像通道 —— 回读就永远是第一发的电压：
% 削顶检测、set_ranges、以及「回读峰峰 ≥ 0.2×volt」这些判断全部基于错的数值，
% 且不会报错。所以这里必须同步。
cfg = rigol_instr_config();
ch = cfg.awg_channel;
vpp = ampl_mVpp / 1000;
src = sprintf('SOURce%d', ch);
writeline(dev, sprintf(':%s:VOLTage:UNIT VPP', src));
writeline(dev, sprintf(':%s:VOLTage %.12g', src, vpp));

[mon, load_ohms] = rigol_dg2052_monitor(cfg);
if mon > 0 && mon ~= ch
    msrc = sprintf('SOURce%d', mon);
    % 顺序：先把负载声明摆对，再写幅度。补偿只在写 :VOLTage 时计算一次，
    % 反过来（先幅度后 LOAD）实测无效，回读会重新变成 2 倍。
    writeline(dev, sprintf(':OUTPut%d:LOAD %.10g', mon, load_ohms));
    writeline(dev, sprintf(':%s:VOLTage:UNIT VPP', msrc));
    writeline(dev, sprintf(':%s:VOLTage %.12g', msrc, vpp));
end
end
