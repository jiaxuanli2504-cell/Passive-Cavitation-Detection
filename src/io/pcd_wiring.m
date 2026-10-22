function [lines, note] = pcd_wiring(cfg)
%PCD_WIRING 本实验室这套仪器（DG2052 + DHO814）的接线方式，按当前配置生成。
%
% 为什么要把接线写进界面：这套接法有四处不显然的地方，接错任何一处都**不会报错**，
% 只会「数据看着正常但其实不对」——
%   1) 回读不走功放前的分路，而用发生器的第二个通道做副本：功放前接三通会把
%      驱动分压，幅度口径就不准了；
%   2) 副本通道必须由主通道后面板 TrigOut 做外部触发，否则两路猝发各起各的
%      （面板 Align 没有 SCPI 命令，参数相同也不保证对齐）；
%   3) DHO814 后面板没有 EXT TRIG 插座，那条 TTL 只能进 CH1–CH4 里的某一路；
%   4) TrigOut 要一分二（BNC 三通）：一路喂示波器触发，一路喂副本通道的外触发。
%
% 全部从 rigol_instr_config 的通道号生成，用户改了通道号，提示会跟着改。
if nargin < 1 || isempty(cfg)
    cfg = rigol_instr_config();
end
awg  = num_of(cfg, 'awg_channel', 1);
mon  = num_of(cfg, 'awg_monitor_channel', 0);
tx   = num_of(cfg, 'scope_tx_channel', 1);
pcd  = num_of(cfg, 'scope_pcd_channel', 2);
trig = num_of(cfg, 'scope_trig_channel', 0);
manual = isfield(cfg, 'awg_mode') && strcmpi(strtrim(char(string(cfg.awg_mode))), 'manual');

if manual
    lines = {'手动信号源模式：电脑不控制发生器。下面这套接线只在「电脑控制 DG2052」时才成立。'};
    note = lines{1};
    return
end

% 「触发通道 = 回读通道」与填 0 等价（rigol_dho814_setup 里 ttlTrig 判的就是
% trigCh ~= tx），所以不能把它当成冲突报警，否则正常配置也会被标成错的。
indep_trig = trig >= 1 && trig ~= tx;
clash = indep_trig && trig == pcd;   % 真正接错的只有「触发通道 = PCD 通道」

L = {};
L{end + 1} = sprintf('① 发生器前面板 CH%d → 功放 → 换能器（主输出，不经三通）', awg);
if mon > 0
    L{end + 1} = sprintf('② 发生器前面板 CH%d → 示波器 CH%d　（回读副本，独立通道，与功放互不分压）', mon, tx);
else
    L{end + 1} = sprintf('② 示波器 CH%d ← 回读（未启用镜像通道，只能从功放前分路取得）', tx);
end
L{end + 1} = sprintf('③ 示波器 CH%d ← PCD 换能器', pcd);
if indep_trig
    L{end + 1} = sprintf('④ 发生器后面板 CH%d TrigOut ── 三通 ──→ 示波器 CH%d　（硬件触发源）', awg, trig);
    if mon > 0
        L{end + 1} = sprintf('⑤ 　　　　　　　　　　└─ 三通另一支 → 发生器后面板 CH%d　（外部触发输入）', mon);
    end
else
    L{end + 1} = sprintf(['④ 未设独立触发通道：改为示波器 CH%d 的模拟边沿触发，' ...
        '窗起点只能靠扫回读包络（约 12 µs 偏置，且回读弱于 ~20 mVpp 会失锁）'], tx);
end

% 配置自检：这几条接错都不会报错，只能在这里提醒
W = {};
if mon > 0 && mon == awg
    W{end + 1} = sprintf('⚠ 回读镜像通道不能和主输出通道相同（都是 CH%d）', awg);
end
if clash
    W{end + 1} = sprintf('⚠ 触发通道 CH%d 和 PCD 通道撞了同一路，请另选一路空闲通道', trig);
end
if mon > 0 && ~indep_trig
    W{end + 1} = ['⚠ 启用了回读镜像但没有独立触发通道：副本通道靠 TrigOut 外触发才出波形，' ...
        '缺这根线它一直是空的（回读与削顶检测会静默退化成噪声）'];
end
if trig >= 1 && trig == tx && mon > 0
    W{end + 1} = sprintf(['提示：触发 CH = 回读 CH%d 等价于填 0，窗起点会退回扫包络。' ...
        '把 TrigOut 接到一路空闲通道再填那个通道号，才能按触发几何精确定点。'], tx);
end
if mon == 0 && ~indep_trig
    W{end + 1} = '⚠ 既没有镜像通道也没有独立触发通道：回读与触发都压在回读那一路的模拟边沿上';
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
