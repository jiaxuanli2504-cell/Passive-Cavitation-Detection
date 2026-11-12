function rigol_dg2052_output_set(dev, on)
%RIGOL_DG2052_OUTPUT_SET 打开或关闭主通道输出。
%
% 主通道驱动 50 Ω 功放。打开前再写一次 LOAD 50，避免前面板停在开机默认的高阻。
% 只写 LOAD 不会重算已经写下的幅度，幅度以写 :VOLTage 时的负载声明为准。
cfg = rigol_instr_config();
out = sprintf('OUTPut%d', cfg.awg_channel);
if on
    writeline(dev, sprintf(':%s:LOAD 50', out));
    writeline(dev, [':' out ':STATe ON']);
else
    writeline(dev, [':' out ':STATe OFF']);
end
end
