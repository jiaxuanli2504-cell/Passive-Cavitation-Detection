function rigol_dg2052_apply_burst(dev, ch, freq_mhz, ampl_mVpp, phase_deg, n_cycle, period_s)
%RIGOL_DG2052_APPLY_BURST 正弦 N 周期猝发，并同步配置"回读镜像通道"。
%
% 本机固件要求：先 BURSt ON，再写 NCYCles / PERiod 与触发源（burst 关闭时写这些
% 会被静默忽略或返回 -220）。这一点是实测出来的，顺序不能改。
%
% 回读镜像（rigol_instr_config.awg_monitor_channel > 0）：
%   示波器的回读通道接在发生器的另一个通道上时，那个通道必须发出与主通道**同一个**
%   猝发，否则回读看到的是出厂默认信号（1 kHz / 5 Vpp / 输出关闭）。
%   镜像通道的猝发触发源设为 EXTernal，由主通道后面板 TrigOut 启动 —— 两路因此
%   同起点，不需要相位对齐（面板 Align 按键没有 SCPI 命令，参数相同也不保证对齐，
%   见 DG2000 用户手册 2-13「同相位」）。
%
% 软件 NCYCles 上限与 pcd_param_limits.n_cycle_max 一致（10000）；不要在这里
% 悄悄截成更小的数，否则界面显示 10000、仪器却按旧上限跑。
if ~(isscalar(period_s) && isnumeric(period_s) && isfinite(period_s) && period_s > 0)
    error('rigol:dg2052:period', 'period_s 须为有限正标量（猝发周期 = 1/PRF）。');
end
src = sprintf('SOURce%d', ch);
freq_hz = freq_mhz * 1e6;
vpp = ampl_mVpp / 1000;
nc = max(1, round(n_cycle));

rigol_dg2052_load(dev, ch);
writeline(dev, sprintf(':%s:FUNCtion SINusoid', src));
writeline(dev, sprintf(':%s:FREQuency %.12g', src, freq_hz));
writeline(dev, sprintf(':%s:VOLTage:UNIT VPP', src));
writeline(dev, sprintf(':%s:VOLTage %.12g', src, vpp));
writeline(dev, sprintf(':%s:PHASe %.12g', src, phase_deg));

writeline(dev, sprintf(':%s:BURSt:MODE TRIG', src));
writeline(dev, sprintf(':%s:BURSt:STATe ON', src));
pause(0.08);
L = pcd_param_limits();
nc = min(nc, L.n_cycle_max);
pl = nc / freq_hz;
period_s = max(period_s, pl + 50e-6);

% 主通道必须是内部触发：外触发时后面板那个 BNC 变成输入，不会给出每发一个脉冲，
% 示波器就没有触发源了。以前这里直接 error 让人去面板改，其实 burst 开着的时候
% 写 INTernal 是能生效的（burst 关闭时才 -220），所以这里自己钉一次并回读校验。
writeline(dev, sprintf(':%s:BURSt:TRIGger:SOURce INTernal', src));
pause(0.05);
src_rd = upper(strtrim(char(writeread(dev, sprintf(':%s:BURSt:TRIGger:SOURce?', src)))));
if startsWith(src_rd, 'EXT')
    error('rigol:dg2052:trigsrc', ...
        ['CH%d 的猝发触发源仍是外触发（回读 %s）。' ...
         '外触发时后面板是输入，不会输出 TrigOut，示波器也就没有触发源。' ...
         '请在发生器面板上把该通道的猝发触发源改回 Internal。'], ch, src_rd);
end
% 后面板 [CHn/Sync/Ext Mod/Trig/FSK] 的 Trig Out 出厂是 OFF。
% 远程时面板改不了。POSitive = 每个猝发一个上升沿。
writeline(dev, sprintf(':%s:BURSt:TRIGger:TRIGOut POSitive', src));
writeline(dev, sprintf(':%s:BURSt:NCYCles %d', src, nc));
pause(0.05);
writeline(dev, sprintf(':%s:BURSt:INTernal:PERiod %.12g', src, period_s));
writeline(dev, sprintf(':%s:BURSt:TDELay 0', src));
pause(0.05);

nc_rd = str2double(writeread(dev, sprintf(':%s:BURSt:NCYCles?', src)));
per_rd = str2double(writeread(dev, sprintf(':%s:BURSt:INTernal:PERiod?', src)));
if ~(isfinite(nc_rd) && abs(nc_rd - nc) < 1)
    error('rigol:dg2052:ncyc', '猝发周期数未写入（欲 %d，回读 %.4g）。', nc, nc_rd);
end
if ~(isfinite(per_rd) && abs(per_rd - period_s) / period_s < 0.05)
    warning('rigol:dg2052:period', '猝发周期回读 %.4g s（设定 %.4g s）', per_rd, period_s);
end
sl = strtrim(char(writeread(dev, sprintf(':%s:BURSt:TRIGger:TRIGOut?', src))));
if ~startsWith(upper(sl), 'POS')
    error('rigol:dg2052:trigout', ...
        '猝发触发输出未能设为上升沿（回读 %s）。后面板不会给出每发一次的脉冲。', sl);
end

% ---- 回读镜像通道：同一波形，外触发，由主通道 TrigOut 启动 ----
[mon, mon_load] = rigol_dg2052_monitor();
if mon > 0 && mon ~= ch
    apply_mirror(dev, mon, freq_hz, vpp, nc, mon_load);
end
end

function apply_mirror(dev, ch, freq_hz, vpp, nc, load_ohms)
%APPLY_MIRROR 把镜像通道配成主通道的副本，触发源设为外触发。
% 两处顺序都不能动：
%   1) 负载声明要在写 VOLTage 之前 —— 补偿只在写幅度时算一次（实测，反了就是 2 倍）；
%   2) BURSt ON 要在写触发源之前 —— 否则被静默忽略（实测无报错、回读仍是 INT）。
msrc = sprintf('SOURce%d', ch);
rigol_dg2052_load(dev, ch, load_ohms);
writeline(dev, sprintf(':%s:FUNCtion SINusoid', msrc));
writeline(dev, sprintf(':%s:FREQuency %.12g', msrc, freq_hz));
writeline(dev, sprintf(':%s:VOLTage:UNIT VPP', msrc));
writeline(dev, sprintf(':%s:VOLTage %.12g', msrc, vpp));
writeline(dev, sprintf(':%s:BURSt:MODE TRIG', msrc));
writeline(dev, sprintf(':%s:BURSt:STATe ON', msrc));
pause(0.08);
writeline(dev, sprintf(':%s:BURSt:NCYCles %d', msrc, nc));
writeline(dev, sprintf(':%s:BURSt:TDELay 0', msrc));
pause(0.05);
writeline(dev, sprintf(':%s:BURSt:TRIGger:SOURce EXTernal', msrc));
pause(0.05);

% 静默失效比报错难查：必须回读确认真的切到 EXT，否则回读通道永远没有输出。
ms_rd = upper(strtrim(char(writeread(dev, sprintf(':%s:BURSt:TRIGger:SOURce?', msrc)))));
if ~startsWith(ms_rd, 'EXT')
    error('rigol:dg2052:mirror', ...
        ['镜像通道 CH%d 的猝发触发源没能切到外触发（回读 %s）。' ...
         '回读通道会一直没有波形。请确认后面板 TrigOut 已接到该通道的 ' ...
         '[Sync/Ext Mod/Trig/FSK]，或在面板上手动设为 External。'], ch, ms_rd);
end
mnc = str2double(writeread(dev, sprintf(':%s:BURSt:NCYCles?', msrc)));
if ~(isfinite(mnc) && abs(mnc - nc) < 1)
    error('rigol:dg2052:mirror:ncyc', ...
        '镜像通道 CH%d 的猝发周期数未写入（欲 %d，回读 %.4g）。', ch, nc, mnc);
end
end


