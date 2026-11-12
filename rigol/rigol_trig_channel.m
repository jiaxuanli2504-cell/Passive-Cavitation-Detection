function [trigCh, independent] = rigol_trig_channel(cfg)
%RIGOL_TRIG_CHANNEL 这一轮示波器实际用哪一路触发。
%
% 手动信号源：回读通道自己的上升沿，不接独立触发。
% 电脑控制：仍用配置里的触发通道（本实验室是通道 3，发生器后面板 TrigOut）。
% independent 为 true 时电平是 TTL 1.5 V，窗起点按触发几何算。
if nargin < 1 || isempty(cfg)
    cfg = rigol_instr_config();
end
tx = 1;
if isfield(cfg, 'scope_tx_channel') && isnumeric(cfg.scope_tx_channel) ...
        && isfinite(cfg.scope_tx_channel)
    tx = round(double(cfg.scope_tx_channel));
end
manual = isfield(cfg, 'awg_mode') ...
    && strcmpi(strtrim(char(string(cfg.awg_mode))), 'manual');
trigCh = tx;
independent = false;
if manual
    return
end
if isfield(cfg, 'scope_trig_channel') && isnumeric(cfg.scope_trig_channel) ...
        && isfinite(cfg.scope_trig_channel)
    tc = round(double(cfg.scope_trig_channel));
    if tc >= 1 && tc <= 4 && tc ~= tx
        trigCh = tc;
        independent = true;
    end
end
end
