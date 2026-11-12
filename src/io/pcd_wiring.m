function [lines, note] = pcd_wiring(cfg)
%PCD_WIRING 本实验室这套仪器（DG2052 + DHO814）的接线方式，按当前配置生成。
%
% 回读从功放前的三通取得。发生器主通道声明 50 Ω，示波器这一路保持 1 MΩ，
% 三通上读到的就是功放输入端的电压。示波器若拨成 50 Ω，会和功放并联，幅度变低。
% DHO814 后面板没有 EXT TRIG，TrigOut 只能进 CH1–CH4 里空着的一路。
%
% 全部从 rigol_instr_config 的通道号生成，用户改了通道号，提示会跟着改。
if nargin < 1 || isempty(cfg)
    cfg = rigol_instr_config();
end
awg  = num_of(cfg, 'awg_channel', 1);
tx   = num_of(cfg, 'scope_tx_channel', 1);
pcd  = num_of(cfg, 'scope_pcd_channel', 2);
trig = num_of(cfg, 'scope_trig_channel', 0);
manual = isfield(cfg, 'awg_mode') && strcmpi(strtrim(char(string(cfg.awg_mode))), 'manual');

if manual
    lines = { ...
        '手动信号源：电脑不控制发生器。频率、电压、PRF、周期数在发生器面板上设。', ...
        sprintf('示波器 CH%d 同时是回读和触发（上升沿）。这一路保持 1 MΩ。', tx), ...
        sprintf('通道 %d 的 TrigOut 只在切回「电脑控制」时使用，手动不要接。', max(trig, 1))};
    note = strjoin(lines, newline);
    return
end

% 「触发通道 = 回读通道」与填 0 等价（rigol_dho814_setup 里 ttlTrig 判的就是
% trigCh ~= tx），所以不能把它当成冲突报警，否则正常配置也会被标成错的。
indep_trig = trig >= 1 && trig ~= tx;
clash = indep_trig && trig == pcd;   % 真正接错的只有「触发通道 = PCD 通道」

L = {};
L{end + 1} = sprintf('① 发生器前面板 CH%d → 功放 → 换能器', awg);
L{end + 1} = sprintf('② 功放前三通 → 示波器 CH%d（回读，这一路保持 1 MΩ）', tx);
L{end + 1} = sprintf('③ 示波器 CH%d ← PCD', pcd);
if indep_trig
    L{end + 1} = sprintf('④ 发生器后面板 CH%d TrigOut → 示波器 CH%d（触发）', awg, trig);
else
    L{end + 1} = sprintf(['④ 未设独立触发通道：改为示波器 CH%d 的模拟边沿触发，' ...
        '窗起点只能靠扫回读包络（约 12 µs 偏置，且回读弱于 ~20 mVpp 会失锁）'], tx);
end

W = {};
if clash
    W{end + 1} = sprintf('⚠ 触发通道 CH%d 和 PCD 通道撞了同一路，请另选一路空闲通道', trig);
end
if trig >= 1 && trig == tx
    W{end + 1} = sprintf(['提示：触发 CH = 回读 CH%d 等价于填 0，窗起点会退回扫包络。' ...
        '把 TrigOut 接到一路空闲通道再填那个通道号，才能按触发几何精确定点。'], tx);
end
if ~indep_trig
    W{end + 1} = '⚠ 没有独立触发通道：回读与触发都压在回读那一路的模拟边沿上';
end

lines = [L, W];
note = strjoin(lines, newline);
end

function v = num_of(cfg, key, fallback)
v = fallback;
if isfield(cfg, key) && isnumeric(cfg.(key)) && isscalar(cfg.(key)) && isfinite(cfg.(key))
    v = round(double(cfg.(key)));
end
end
