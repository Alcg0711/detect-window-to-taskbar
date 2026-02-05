-- detect-window-to-taskbar.lua

local ffi = require("ffi")
local bit = require("bit")
local obs = obslua

local is_64bit = ffi.abi("64bit")

ffi.cdef[[
typedef int BOOL;
typedef unsigned int UINT;
typedef void* HWND;
typedef unsigned short wchar_t;
typedef intptr_t LONG_PTR;
typedef long LONG;
typedef unsigned long DWORD;
typedef void* HANDLE;
typedef DWORD* LPDWORD;

BOOL EnumWindows(BOOL (*lpEnumFunc)(HWND, LONG_PTR), LONG_PTR);
BOOL IsWindowVisible(HWND hwnd);
int GetClassNameW(HWND hwnd, wchar_t* lpClassName, int nMaxCount);
int GetWindowTextW(HWND hWnd, wchar_t* lpString, int nMaxCount);
LONG_PTR GetWindowLongPtrW(HWND hWnd, int nIndex);
LONG_PTR SetWindowLongPtrW(HWND hWnd, int nIndex, LONG_PTR);
LONG GetWindowLongW(HWND hWnd, int nIndex);
LONG SetWindowLongW(HWND hWnd, int nIndex, LONG dwNewLong);
BOOL SetWindowPos(HWND, HWND, int, int, int, int, UINT);
DWORD GetWindowThreadProcessId(HWND hWnd, LPDWORD lpdwProcessId);
HANDLE OpenProcess(DWORD, BOOL, DWORD);
BOOL CloseHandle(HANDLE);
BOOL QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, wchar_t* lpExeName, LPDWORD lpdwSize);
int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const wchar_t* lpWideCharStr, int cchWideChar,
                       char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, BOOL* lpUsedDefaultChar);
void SHChangeNotify(DWORD wEventId, UINT uFlags, void* dwItem1, void* dwItem2);
]]

local WIN_CONST = {
    GWL_STYLE=-16, GWL_EXSTYLE=-20,
    WS_EX_APPWINDOW=0x00040000,
    WS_EX_TOOLWINDOW=0x00000080,
    SWP_NOMOVE=0x0002,
    SWP_NOSIZE=0x0001,
    SWP_NOZORDER=0x0004,
    SWP_FRAMECHANGED=0x0020,
    CP_UTF8=65001,
    PROCESS_QUERY_FLAGS=0x0410,
    SHCNE_ASSOCCHANGED=0x08000000,
    SHCNF_IDLIST=0x00001000,
    MAX_WINDOW_TITLE=256,
    MAX_PATH=260,
}

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")
local shell32 = ffi.load("shell32")

local WideCharToMultiByte = kernel32.WideCharToMultiByte
if not WideCharToMultiByte then
    local kernelbase = ffi.load("kernelbase")
    WideCharToMultiByte = kernelbase.WideCharToMultiByte
end

-- 默认配置
local DEFAULT_CONFIG = {
    PROCESS_PROCESSES_TEXT=[[cloudmusic
qqmusic
kugou
kwmusic
wesing
foobar2000]],
    CLASS_PATTERNS_TEXT=[[DesktopLyrics
KwDeskLyricWnd
ATL:79330D08
ATL:7BF61FD0
uie_eslyric_desktop_wnd_class]],
    TITLE_PATTERNS_TEXT=[[歌词
lyric
字幕
subtitle]],
}

-- 全局状态
local state = {
    enable_timer=false,
    interval_sec=5,
    debug_mode=false,
    debug_print_all_windows=false,
    require_class_or_title_match=true,
    process_processes={}, class_patterns={}, title_patterns={},
    utf16_cache={}, utf16_cache_order={},
    utf16_cache_size=0, utf16_cache_max=1000,
    class_cache=setmetatable({}, {__mode="k"}),
    process_cache=setmetatable({}, {__mode="k"}), 
    last_log_time={}, stats={total_scans=0,total_windows_found=0,total_windows_modified=0},
    enum_cb=nil,
}

-- 日志函数
local function log_info(msg) obs.script_log(obs.LOG_INFO,msg) end
local function log_debug(msg) if state.debug_mode then log_info("[MATCH] "..msg) end end
local function log_warn(msg) if state.debug_mode then log_info("[WARN] "..msg) end end
local function log_all(msg) if state.debug_print_all_windows then log_info("[ALL] "..msg) end end

local function log_info_throttled(msg,key,interval)
    interval=interval or 30
    local now=os.time()
    if not state.last_log_time[key] or (now-state.last_log_time[key])>=interval then
        state.last_log_time[key]=now
        log_info(msg)
        return true
    end
    return false
end

-- 工具函数
local function safe_string(str, default) default=default or "null"; return (str and str~="") and str or default end
local function parse_lines_to_array(text)
    local arr = {}
    if not text or text == "" then return arr end
    for line in tostring(text):gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line~="" and not line:match("^#") then table.insert(arr,line) end
    end
    return arr
end
local function parse_lines_to_set_lower(text)
    local set = {}
    for _,v in ipairs(parse_lines_to_array(text)) do set[v:lower()]=true end
    return set
end
local function parse_lines_to_array_lower(text)
    local arr = {}
    for _,v in ipairs(parse_lines_to_array(text)) do table.insert(arr,v:lower()) end
    return arr
end

local function rebuild_rules_from_settings(settings)
    state.process_processes = parse_lines_to_set_lower(obs.obs_data_get_string(settings,"process_processes_text"))
    state.class_patterns = parse_lines_to_array_lower(obs.obs_data_get_string(settings,"class_patterns_text"))
    state.title_patterns = parse_lines_to_array_lower(obs.obs_data_get_string(settings,"title_patterns_text"))
    state.require_class_or_title_match = obs.obs_data_get_bool(settings,"require_class_or_title_match")
    log_debug(string.format("规则更新: processes=%d class=%d title=%d",
        (function() local c=0; for _ in pairs(state.process_processes) do c=c+1 end return c end)(),
        #state.class_patterns,#state.title_patterns))
end

-- UTF16 -> UTF8 LRU缓存
local function utf16_to_utf8(wstr,len)
    if not wstr or len<=0 then return "" end
    if len>WIN_CONST.MAX_WINDOW_TITLE then len=WIN_CONST.MAX_WINDOW_TITLE end
    local key = ffi.string(wstr,len*2,true)..":"..len
    if state.utf16_cache[key] then
        
        for i=#state.utf16_cache_order,1,-1 do
            if state.utf16_cache_order[i]==key then table.remove(state.utf16_cache_order,i) break end
        end
        table.insert(state.utf16_cache_order,key)
        return state.utf16_cache[key]
    end

    local n = WideCharToMultiByte(WIN_CONST.CP_UTF8,0,wstr,len,nil,0,nil,nil)
    if n==0 then return "" end
    local buf=ffi.new("char[?]",n+1)
    WideCharToMultiByte(WIN_CONST.CP_UTF8,0,wstr,len,buf,n,nil,nil)
    buf[n]=0
    local str = ffi.string(buf)

    state.utf16_cache[key]=str
    table.insert(state.utf16_cache_order,key)
    state.utf16_cache_size = state.utf16_cache_size +1
    if state.utf16_cache_size>state.utf16_cache_max then
        local old_key = table.remove(state.utf16_cache_order,1)
        state.utf16_cache[old_key]=nil
        state.utf16_cache_size = state.utf16_cache_size -1
    end
    return str
end

-- HWND操作函数
local function is_valid_hwnd(hwnd) return hwnd~=nil and hwnd~=ffi.NULL and hwnd~=ffi.cast("HWND",0) end
local function hwnd_key(hwnd) return tostring(ffi.cast("uintptr_t", hwnd)) end
local function GetWindowLongPtrW_Compat(hwnd,nIndex)
    if is_64bit then return tonumber(user32.GetWindowLongPtrW(hwnd,nIndex))
    else return tonumber(user32.GetWindowLongW(hwnd,nIndex)) end
end
local function SetWindowLongPtrW_Compat(hwnd,nIndex,dwNewLong)
    local v = tonumber(dwNewLong) or 0
    if is_64bit then return tonumber(user32.SetWindowLongPtrW(hwnd,nIndex,ffi.cast("LONG_PTR",v)))
    else return tonumber(user32.SetWindowLongW(hwnd,nIndex,ffi.cast("LONG",v))) end
end

local function get_window_class(hwnd)
    if not is_valid_hwnd(hwnd) then return "" end
    local key = hwnd_key(hwnd)
    if state.class_cache[key] then return state.class_cache[key] end
    local wbuf=ffi.new("wchar_t[?]",WIN_CONST.MAX_WINDOW_TITLE)
    local len=user32.GetClassNameW(hwnd,wbuf,WIN_CONST.MAX_WINDOW_TITLE)
    local class_name = (len>0) and utf16_to_utf8(wbuf,len) or ""
    state.class_cache[key]=class_name
    return class_name
end

local function get_window_title(hwnd)
    if not is_valid_hwnd(hwnd) then return "" end
    local wbuf=ffi.new("wchar_t[?]",WIN_CONST.MAX_WINDOW_TITLE)
    local len=user32.GetWindowTextW(hwnd,wbuf,WIN_CONST.MAX_WINDOW_TITLE)
    return (len>0) and utf16_to_utf8(wbuf,len) or ""
end

local function get_process_name(hwnd)
    if not is_valid_hwnd(hwnd) then return nil end
    local key=hwnd_key(hwnd)
    if state.process_cache[key] then return state.process_cache[key] end

    local pid=ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(hwnd,pid)
    if pid[0]==0 then return nil end

    local hProcess=kernel32.OpenProcess(WIN_CONST.PROCESS_QUERY_FLAGS,false,pid[0])
    if not hProcess or hProcess==ffi.NULL then
        log_warn("无法打开进程 hwnd="..key)
        return nil
    end

    local wbuf=ffi.new("wchar_t[?]",WIN_CONST.MAX_PATH)
    local size=ffi.new("DWORD[1]",WIN_CONST.MAX_PATH)
    local ok=kernel32.QueryFullProcessImageNameW(hProcess,0,wbuf,size)
    kernel32.CloseHandle(hProcess)
    if ok==0 then return nil end

    local fullpath=utf16_to_utf8(wbuf,size[0])
    if fullpath=="" then return nil end
    local filename = fullpath:match("([^\\/]+)$")
    if not filename then return nil end
    local process_name=filename:gsub("%.[eE][xX][eE]$",""):lower()
    state.process_cache[key]=process_name
    return process_name
end

local function is_process_window(class_name,title)
    class_name=(class_name or ""):lower()
    title=(title or ""):lower()
    if state.require_class_or_title_match then
        for _,p in ipairs(state.class_patterns) do if class_name==p or class_name:find(p,1,true) then return true end end
        for _,p in ipairs(state.title_patterns) do if title:find(p,1,true) then return true end end
        return false
    else
        return true
    end
end

local function set_taskbar_visible(hwnd)
    if not is_valid_hwnd(hwnd) then return false end
    local ex_style = GetWindowLongPtrW_Compat(hwnd,WIN_CONST.GWL_EXSTYLE) or 0
    local has_appwindow = bit.band(ex_style,WIN_CONST.WS_EX_APPWINDOW) ~= 0
    local has_toolwindow = bit.band(ex_style,WIN_CONST.WS_EX_TOOLWINDOW) ~= 0
    if has_appwindow and not has_toolwindow then return false end
    local new_style = bit.bor(ex_style,WIN_CONST.WS_EX_APPWINDOW)
    new_style = bit.band(new_style, bit.bnot(WIN_CONST.WS_EX_TOOLWINDOW))
    SetWindowLongPtrW_Compat(hwnd,WIN_CONST.GWL_EXSTYLE,new_style)
    local flags = bit.bor(WIN_CONST.SWP_NOMOVE,WIN_CONST.SWP_NOSIZE,WIN_CONST.SWP_NOZORDER,WIN_CONST.SWP_FRAMECHANGED)
    user32.SetWindowPos(hwnd,ffi.NULL,0,0,0,0,flags)
    shell32.SHChangeNotify(WIN_CONST.SHCNE_ASSOCCHANGED,WIN_CONST.SHCNF_IDLIST,nil,nil)
    return true
end

-- 枚举窗口
local function find_process_windows()
    local results = {}
    local function enum_callback(hwnd,lParam)
        local ok,err = pcall(function()
            if user32.IsWindowVisible(hwnd)==0 then return end
            local class_name = get_window_class(hwnd)
            local title = get_window_title(hwnd)
            local process_name = get_process_name(hwnd) or ""
            process_name = process_name:lower()
            log_all(string.format("process=%s class=%s title=%s",safe_string(process_name),safe_string(class_name),safe_string(title)))
            if process_name~="" and state.process_processes[process_name] then
                if is_process_window(class_name,title) then
                    table.insert(results,{hwnd=hwnd,process=process_name,class_name=class_name,title=title})
                    log_debug("Matched window: "..process_name.." / "..class_name.." / "..title)
                end
            end
        end)
        if not ok then log_warn("EnumWindows 回调错误: "..tostring(err)) end
        return 1
    end
    state.enum_cb = ffi.cast("BOOL(*)(HWND,LONG_PTR)",enum_callback)
    local ok,err = pcall(function() user32.EnumWindows(state.enum_cb,0) end)
    state.enum_cb:free()
    state.enum_cb=nil
    if not ok then log_warn("枚举窗口出错: "..tostring(err)) return {} end
    return results
end

local function run_detection()
    state.stats.total_scans = state.stats.total_scans +1
    local windows = find_process_windows()
    if #windows==0 then
        log_info_throttled("未检测到桌面窗口","no_windows",30)
        return
    end
    state.stats.total_windows_found = state.stats.total_windows_found + #windows
    log_info(string.format("检测到 %d 个桌面窗口",#windows))
    local modified = 0
    for i,w in ipairs(windows) do
        log_info(string.format("[%d] process=%s class=%s title=%s",i,safe_string(w.process),safe_string(w.class_name),safe_string(w.title)))
        if set_taskbar_visible(w.hwnd) then modified=modified+1 end
    end
    state.stats.total_windows_modified = state.stats.total_windows_modified + modified
    if modified>0 then
        log_info(string.format("已修改 %d 个窗口为任务栏显示",modified))
    else
        log_info("所有窗口已是任务栏显示状态，无需修改")
    end
end

-- 定时器
local function timer_tick() local ok,err=pcall(run_detection) if not ok then log_warn("定时检测出错: "..tostring(err)) end end
local function update_timer()
    obs.timer_remove(timer_tick)
    if state.enable_timer then
        obs.timer_add(timer_tick,state.interval_sec*1000)
        log_info(string.format("定时检测已启用：每 %d 秒执行一次",state.interval_sec))
    else log_info("定时检测已禁用") end
end

-- OBS UI
function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_button(props,"btn_run","手动检测",function() run_detection() return true end)
    obs.obs_properties_add_bool(props,"enable_timer","自动检测")
    obs.obs_properties_add_int(props,"interval_sec","检测间隔(秒)",1,3600,1)
    obs.obs_properties_add_bool(props,"debug_mode","调试模式")
    obs.obs_properties_add_bool(props,"debug_print_all_windows","打印所有窗口")
    obs.obs_properties_add_bool(props,"require_class_or_title_match","Class/Title 特征")
    obs.obs_properties_add_text(props,"process_processes_text","process 名称（每行一个）",obs.OBS_TEXT_MULTILINE)
    obs.obs_properties_add_text(props,"class_patterns_text","Class 特征（每行一个）",obs.OBS_TEXT_MULTILINE)
    obs.obs_properties_add_text(props,"title_patterns_text","Title 特征（每行一个）",obs.OBS_TEXT_MULTILINE)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings,"enable_timer",false)
    obs.obs_data_set_default_int(settings,"interval_sec",5)
    obs.obs_data_set_default_bool(settings,"debug_mode",false)
    obs.obs_data_set_default_bool(settings,"debug_print_all_windows",false)
    obs.obs_data_set_default_bool(settings,"require_class_or_title_match",true)
    obs.obs_data_set_default_string(settings,"process_processes_text",DEFAULT_CONFIG.PROCESS_PROCESSES_TEXT)
    obs.obs_data_set_default_string(settings,"class_patterns_text",DEFAULT_CONFIG.CLASS_PATTERNS_TEXT)
    obs.obs_data_set_default_string(settings,"title_patterns_text",DEFAULT_CONFIG.TITLE_PATTERNS_TEXT)
end

function script_update(settings)
    state.enable_timer = obs.obs_data_get_bool(settings,"enable_timer")
    state.interval_sec = math.max(1, obs.obs_data_get_int(settings,"interval_sec"))
    state.debug_mode = obs.obs_data_get_bool(settings,"debug_mode")
    state.debug_print_all_windows = obs.obs_data_get_bool(settings,"debug_print_all_windows")
    rebuild_rules_from_settings(settings)
    update_timer()
end

function script_description()
    return [[
<h2>Detect Window to Taskbar</h2>
<p>检测窗口到任务栏</p>
<b>v</b> <a href="https://github.com/Alcg0711/detect-window-to-taskbar">0.1.0</a></p>
<b>by</b> <a href="https://space.bilibili.com/11662625">Alcg</a>
]]
end

function script_load(settings)
    log_info("=== detect-window-to-taskbar 脚本已加载 ===")
end

function script_unload()
    obs.timer_remove(timer_tick)
    log_info("=== detect-window-to-taskbar 脚本已卸载 ===")
end
