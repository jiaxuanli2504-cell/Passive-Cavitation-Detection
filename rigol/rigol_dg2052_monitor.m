function [mon, load_ohms] = rigol_dg2052_monitor(cfg)
%RIGOL_DG2052_MONITOR 回读镜像通道号（0 = 不镜像）与它应该声明的输出负载（Ω）。
%
% 镜像通道接的是示波器的 1 MΩ 输入。发生器按 50 Ω 声明去推输出时，落到 1 MΩ 上
% 就是设定值的 2 倍（实测 20 mVpp 设定 → 39.7 mVpp 实收），回读会把驱动电压高报一倍。
% 声明成 10000 Ω（本机接受的上限，OMEG 直接 -220）后补偿按 10 kΩ 算，
% 落到 1 MΩ 上约 1.02 倍，与设定值基本一致。
%
% 注意：这个补偿只在写 :VOLTage 那一刻算一次。所以每次给镜像通道写幅度之前都要
% 确保负载声明已经是 10000 —— 只改 LOAD 不重写幅度是没有效果的（实测）。
%
% 主通道维持 50 Ω：它驱动的是 50 Ω 功放，按 50 Ω 声明才是对的。
if nargin < 1 || isempty(cfg)
    cfg = rigol_instr_config();
end
mon = 0;
load_ohms = 50;
if isfield(cfg, 'awg_monitor_channel') && isnumeric(cfg.awg_monitor_channel) ...
        && isscalar(cfg.awg_monitor_channel) && isfinite(cfg.awg_monitor_channel)
    v = round(double(cfg.awg_monitor_channel));
    if v >= 1 && v <= 2
        mon = v;
    end
end
if mon > 0
    load_ohms = 10000;
end
end
