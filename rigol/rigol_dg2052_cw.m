function rigol_dg2052_cw(dev, ch, freq_mhz, ampl_mVpp)
%RIGOL_DG2052_CW 关闭猝发，连续正弦（调试回读/FFT 用）。
% 负载 50 Ω 必须先于幅度：否则面板数字按高阻解释，一改低阻实际电压就翻倍/减半。
%
% 回读镜像通道必须一起配。示波器的回读那一路接的是发生器的**第二个通道**
% （rigol_instr_config.awg_monitor_channel）。那个通道在猝发模式下是外触发的，
% 而 CW 模式主通道不产生 TrigOut 脉冲 —— 不管它，它就一个波形都不出，
% 回读 FFT 里看不到 f0 峰（而 PCD 通道仍在采，看起来「只是回读坏了」）。
% 所以这里要把它也切到连续输出：BURSt OFF + 同频率同幅度。
src = sprintf('SOURce%d', ch);
freq_hz = freq_mhz * 1e6;
vpp = ampl_mVpp / 1000;
writeline(dev, sprintf(':%s:BURSt:STATe OFF', src));
rigol_dg2052_load(dev, ch);
writeline(dev, sprintf(':%s:FUNCtion SINusoid', src));
writeline(dev, sprintf(':%s:FREQuency %.12g', src, freq_hz));
writeline(dev, sprintf(':%s:VOLTage:UNIT VPP', src));
writeline(dev, sprintf(':%s:VOLTage %.12g', src, vpp));

[mon, mon_load] = rigol_dg2052_monitor();
if mon > 0 && mon ~= ch
    msrc = sprintf('SOURce%d', mon);
    % 先关猝发：留着 EXT 触发它就会一直等那个永远不来的 TrigOut。
    writeline(dev, sprintf(':%s:BURSt:STATe OFF', msrc));
    rigol_dg2052_load(dev, mon, mon_load);   % 负载声明必须在写幅度之前
    writeline(dev, sprintf(':%s:FUNCtion SINusoid', msrc));
    writeline(dev, sprintf(':%s:FREQuency %.12g', msrc, freq_hz));
    writeline(dev, sprintf(':%s:VOLTage:UNIT VPP', msrc));
    writeline(dev, sprintf(':%s:VOLTage %.12g', msrc, vpp));
end
end
