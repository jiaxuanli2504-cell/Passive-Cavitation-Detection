function varargout = pcd_debug_live(cmd, ui, fdef, vdef)
%PCD_DEBUG_LIVE 调试采集运行中：界面上改了频率/电压就立刻下发到 DG2052。
%
%   pcd_debug_live('start', ui, f0, v0)   开始跟踪，返回当前 (freq, volt)
%   pcd_debug_live('apply', ui)           界面上的值变了就重下发一次
%   pcd_debug_live('stop')                结束跟踪
%   tf = pcd_debug_live('active')         是否正在跟踪
%   [f, v] = pcd_debug_live('get')        取当前值
%
% ui 为 UI 适配层（约定见 pcd_ui_check）；界面上的「采集频率 / 电压」以 ui.debugfv() 为准。
persistent active freq volt drive

if isempty(active), active = false; end
if isempty(drive), drive = 'cw'; end
if nargin < 2, ui = []; end
if nargin < 3 || isempty(fdef), fdef = 1.5; end
if nargin < 4 || isempty(vdef), vdef = 20; end

switch lower(cmd)
    case 'start'
        [freq, volt] = read_fv(ui, fdef, vdef);
        drive = drive_of(ui);
        active = true;
        push_out(ui, freq, volt, drive);
        varargout = {freq, volt};
    case 'stop'
        active = false;
    case 'active'
        varargout{1} = logical(active);
    case 'apply'
        if ~active
            return;
        end
        [f, v] = read_fv(ui, freq, volt);
        d = drive_of(ui);
        if abs(f - freq) < 1e-9 && abs(v - volt) < 1e-9 && strcmp(d, drive)
            return;
        end
        freq = f;
        volt = v;
        drive = d;
        push_out(ui, freq, volt, drive);
    case 'get'
        if nargout >= 1, varargout{1} = freq; end
        if nargout >= 2, varargout{2} = volt; end
    otherwise
        error('PCD:debugLive:cmd', '未知命令 %s', cmd);
end
end

function [f, v] = read_fv(ui, f0, v0)
% 从界面适配层读频率/电压；拿不到就沿用上一组值
f = f0;
v = v0;
if isempty(ui) || ~isstruct(ui) || ~isfield(ui, 'debugfv') || ~isa(ui.debugfv, 'function_handle')
    return;
end
try
    [f2, v2] = ui.debugfv();
    if isfinite(f2) && f2 > 0, f = f2; end
    if isfinite(v2) && v2 > 0, v = v2; end
catch
end
end

function d = drive_of(ui)
d = 'cw';
if isempty(ui) || ~isstruct(ui) || ~isfield(ui, 'raw') || ~isa(ui.raw, 'function_handle')
    return;
end
try
    S = ui.raw();
catch
    return;
end
if isstruct(S) && isfield(S, 'dbg_drive') && strcmpi(strtrim(char(string(S.dbg_drive))), 'burst')
    d = 'burst';
end
end

function push_out(ui, freq, volt, mode)
if pcd_scope_labels().manual
    return;
end
cfg = rigol_instr_config();
dev = pcd_visa('fgen');
if strcmp(mode, 'burst')
    nc = 400;
    prf = 2;
    if ~isempty(ui) && isstruct(ui) && isfield(ui, 'raw') && isa(ui.raw, 'function_handle')
        try
            S = ui.raw();
            if isfield(S, 'n_cycle') && isnumeric(S.n_cycle) && isfinite(S.n_cycle) && S.n_cycle > 0
                nc = S.n_cycle;
            end
            if isfield(S, 'prf_hz') && isnumeric(S.prf_hz) && isfinite(S.prf_hz) && S.prf_hz > 0
                prf = S.prf_hz;
            end
        catch
        end
    end
    rigol_dg2052_apply_burst(dev, cfg.awg_channel, freq, volt, 0, nc, 1 / prf);
else
    rigol_dg2052_cw(dev, cfg.awg_channel, freq, volt);
end
rigol_dg2052_output_set(dev, true);
end
