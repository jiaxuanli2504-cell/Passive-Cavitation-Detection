function rigol_dg2052_set_vpp_mV(dev, ampl_mVpp)
%RIGOL_DG2052_SET_VPP_MV 运行时更新主通道幅度（峰峰值，mV）。
% 负载声明要在这之前已经是 50 Ω（apply_burst 与 output_set 会写）。
% 补偿只在写 :VOLTage 时计算一次。
cfg = rigol_instr_config();
vpp = ampl_mVpp / 1000;
src = sprintf('SOURce%d', cfg.awg_channel);
writeline(dev, sprintf(':%s:VOLTage:UNIT VPP', src));
writeline(dev, sprintf(':%s:VOLTage %.12g', src, vpp));
end
