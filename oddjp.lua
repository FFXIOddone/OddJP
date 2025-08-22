-- oddjp.lua
-- Ashita v4 Addon: OddJP — Party chat translator to Japanese
-- v1.4.1
-- Fix: harden is_kana_only against FFXI autotranslate tokens / bad bytes; skip auto-translate braces.
-- Also: safer UTF-8 normalization; contains_japanese never true on decode errors.

addon.name = 'oddjp';
addon.author = 'Oddone';
addon.version = '1.4.1';
addon.desc = 'Chat translator to Japanese (Ashita v4).';
addon.link = '';

require('common')

local chat     = require('chat')
local settings = require('settings')
local ffi      = require('ffi')
local bit      = require('bit')

-- ========== Defaults ==========
local defaults = {
    enabled = false,
    dual_send = false,
    provider = 'google',   -- 'google' | 'deepl' | 'none'
    api_key = '',
    rate_ms = 400,
    debug = false,
    send_encoding = 'sjis',     -- 'sjis' (recommended) or 'utf8'
    default_channel = 'p',      -- default output channel (p/s/l/l2/a)
    translate_incoming = true,  -- translate incoming JP messages
    hiragana_mode = false,      -- (outbound EN->JA) katakana→hiragana normalize
    translate_modes = {         -- chat modes to translate (incoming filter)
        [4]  = true,  -- say
        [5]  = true,  -- shout
        [3]  = true,  -- tell
        [1]  = true,  -- linkshell
        [14] = true,  -- linkshell2
        [0x17] = true,-- party
        [8]  = true   -- emote
    },
    -- Optional: Furigana (hiragana-only) logger for incoming JP
    furigana = { enabled = false, provider = 'goo', app_id = '' }
}

local cfg = settings.load(defaults)
settings.register('settings', 'settings_update', function(s) if s then for k,v in pairs(s) do cfg[k]=v end end end)

-- ========== FFI: UTF-8 <-> CP932 ==========
ffi.cdef[[
int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags,
                        const char* lpMultiByteStr, int cbMultiByte,
                        wchar_t* lpWideCharStr, int cchWideChar);
int WideCharToMultiByte(unsigned int CodePage, unsigned long dwFlags,
                        const wchar_t* lpWideCharStr, int cchWideChar,
                        char* lpMultiByteStr, int cbMultiByte,
                        const char* lpDefaultChar, int* lpUsedDefaultChar);
]]
local CP_UTF8, CP_932 = 65001, 932

local function to_wide(codepage, s)
    if s == nil then return nil, 0 end
    local n = ffi.C.MultiByteToWideChar(codepage, 0, s, #s, nil, 0); if n == 0 then return nil, 0 end
    local buf = ffi.new('wchar_t[?]', n)
    if ffi.C.MultiByteToWideChar(codepage, 0, s, #s, buf, n) == 0 then return nil, 0 end
    return buf, n
end
local function from_wide(codepage, wbuf, wlen)
    if not wbuf or wlen == 0 then return nil end
    local m = ffi.C.WideCharToMultiByte(codepage, 0, wbuf, wlen, nil, 0, nil, nil); if m == 0 then return nil end
    local mb = ffi.new('char[?]', m)
    if ffi.C.WideCharToMultiByte(codepage, 0, wbuf, wlen, mb, m, nil, nil) == 0 then return nil end
    return ffi.string(mb, m)
end

local function utf8_to_cp932(s)
    if type(s) ~= 'string' then s = tostring(s or '') end
    if s == '' then return s end
    local wbuf, wlen = to_wide(CP_UTF8, s); if not wbuf then return s end
    local out = from_wide(CP_932, wbuf, wlen); return out or s
end

local function cp932_to_utf8(s)
    if type(s) ~= 'string' then s = tostring(s or '') end
    if s == '' then return s end
    local wbuf, wlen = to_wide(CP_932, s); if not wbuf then return s end
    local out = from_wide(CP_UTF8, wbuf, wlen); return out or s
end

-- If s is valid UTF-8, return as-is; otherwise assume CP932 and convert to UTF-8.
local function ensure_utf8(s)
    if s == nil then return '' end
    if type(s) ~= 'string' then s = tostring(s) end
    if s == '' then return s end
    local wbuf = select(1, to_wide(CP_UTF8, s))
    if wbuf then return s end
    return cp932_to_utf8(s)
end

-- ========== Channels ==========
local valid_channels = { s=true, t=true, l=true, l2=true, p=true, a=true }

-- ========== Utils / Logging ==========
local function trim(s) if type(s) ~= 'string' then return '' end return (s:gsub('^%s+',''):gsub('%s+$','')) end
local function starts_with_ci(s,p) return type(s)=='string' and s:sub(1,#p):lower()==p:lower() end

-- Chat log out as CP932 (so JP appears in parsed logs too)
local function to_chatlog(m)
    local s = tostring(m or '')
    local as_utf8 = ensure_utf8(s)
    return utf8_to_cp932(as_utf8)
end
local function info(m) print(chat.header(addon.name):append(chat.message(to_chatlog(m)))) end
local function dbg(m) if cfg.debug then print(chat.header(addon.name):append(chat.message(to_chatlog('[debug] '..tostring(m))))) end end
local function dbg_raw(m) if cfg.debug then print(chat.header(addon.name):append(chat.message(to_chatlog('[debug] '..tostring(m))))) end end

local function urlencode(str)
    if type(str) ~= 'string' then return '' end
    str=str:gsub('\n','\r\n')
    str=str:gsub('([^%w%-_%.~ ])', function(c) return string.format('%%%02X', string.byte(c)) end)
    return str:gsub(' ','%%20')
end

-- ========== Exec helpers ==========
local function exec(cmd)
    local f = io.popen(cmd..' 2>nul','r'); if not f then return nil end
    local s = f:read('*a'); f:close(); if s and #s>0 then return s end
    return nil
end

local function http_exec(cmd)
    local full = cmd .. ' -w "\\nCURL_HTTP_CODE=%{http_code}\\n"'
    local f = io.popen(full .. ' 2>nul', 'r'); if not f then return nil, 0 end
    local out = f:read('*a') or ''; f:close()
    local code = tonumber((out:match('\nCURL_HTTP_CODE=(%d+)\n') or '0')) or 0
    out = out:gsub('\nCURL_HTTP_CODE=%d+\n$', '')
    return out, code
end

local function hex_preview(s, n)
    if type(s) ~= 'string' then return '' end
    n = math.min(#s, n or 128)
    local t = {}
    for i = 1, n do t[#t+1] = string.format('%02X', s:byte(i)) end
    return table.concat(t, ' ')
end

-- ========== Minimal JSON decoder ==========
local json = {}
do
    local function skip(ws, i) local _, j = ws:find('^%s*', i); return j + 1 end
    local function parse_string(s, i)
        i = i + 1; local res = {}; local len = #s
        while i <= len do
            local c = s:sub(i,i)
            if c == '"' then return table.concat(res), i + 1 end
            if c == '\\' then
                local nx = s:sub(i+1,i+1)
                if nx == '"' or nx == '\\' or nx == '/' then res[#res+1]=nx; i=i+2
                elseif nx=='b' then res[#res+1]='\b'; i=i+2
                elseif nx=='f' then res[#res+1]='\f'; i=i+2
                elseif nx=='n' then res[#res+1]='\n'; i=i+2
                elseif nx=='r' then res[#res+1]='\r'; i=i+2
                elseif nx=='t' then res[#res+1]='\t'; i=i+2
                elseif nx=='u' then
                    local hex = s:sub(i+2,i+5); local code = tonumber(hex,16) or 0
                    if code<=0x7F then res[#res+1]=string.char(code)
                    elseif code<=0x7FF then res[#res+1]=string.char(0xC0+math.floor(code/0x40),0x80+(code%0x40))
                    else res[#res+1]=string.char(0xE0+math.floor(code/0x1000),0x80+(math.floor(code/0x40)%0x40),0x80+(code%0x40)) end
                    i = i + 6
                else res[#res+1]=nx; i=i+2 end
            else res[#res+1]=c; i=i+1 end
        end
        error('Unterminated string')
    end
    local function parse_number(s, i)
        local num_str = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
        local n = tonumber(num_str)
        return n, i + #num_str
    end
    local function parse_value(s, i)
        i = skip(s, i)
        local c = s:sub(i,i)
        if c == '"' then return parse_string(s, i)
        elseif c == '{' then
            local obj = {}; i = i + 1; i = skip(s, i)
            if s:sub(i,i) == '}' then return obj, i+1 end
            while true do
                local key; key, i = parse_string(s, i)
                i = skip(s, i); if s:sub(i,i) ~= ':' then error('Expected :') end
                i = i + 1
                local val; val, i = parse_value(s, i)
                obj[key] = val
                i = skip(s, i)
                local ch = s:sub(i,i)
                if ch == '}' then return obj, i+1 end
                if ch ~= ',' then error('Expected ,') end
                i = i + 1
            end
        elseif c == '[' then
            local arr = {}; i = i + 1; i = skip(s, i)
            if s:sub(i,i) == ']' then return arr, i+1 end
            while true do
                local val; val, i = parse_value(s, i)
                arr[#arr+1] = val
                i = skip(s, i)
                local ch = s:sub(i,i)
                if ch == ']' then return arr, i+1 end
                if ch ~= ',' then error('Expected ,') end
                i = i + 1
            end
        elseif c == 'n' and s:sub(i,i+3) == 'null' then return nil, i + 4
        elseif c == 't' and s:sub(i,i+3) == 'true' then return true, i + 4
        elseif c == 'f' and s:sub(i,i+4) == 'false' then return false, i + 5
        else return parse_number(s, i) end
    end
    function json.decode(s)
        if type(s) ~= 'string' then error('expected string') end
        local ok, res = pcall(function() local v,_=parse_value(s,1); return v end)
        if not ok then error(res) end
        return res
    end
end

local function unescape_json(s)
    if type(s) ~= 'string' then return s end
    s=s:gsub('\\/','/'):gsub('\\"','"'):gsub("\\'","'"):gsub('\\\\','\\')
       :gsub('\\n','\n'):gsub('\\r','\r'):gsub('\\t','\t')
    s=s:gsub('\\u(%x%x%x%x)', function(hex)
        local code=tonumber(hex,16) or 0
        if code<=0x7F then return string.char(code)
        elseif code<=0x7FF then return string.char(0xC0+math.floor(code/0x40),0x80+(code%0x40))
        else return string.char(0xE0+math.floor(code/0x1000),0x80+(math.floor(code/0x40)%0x40),0x80+(code%0x40)) end
    end)
    return s
end

-- ========== Helpers ==========
local function strip_ashita_codes(s)
    if type(s) ~= 'string' then return '' end
    s = s:gsub('\30%d',''):gsub('\31%d','')
    s = s:gsub('[\0\1\2\3\4\5\6\7\8\11\12\14-\31]', '')
    return s
end

-- FFXI autotranslate tokens are commonly shown as { ... } in logs; skip special handling on those lines.
local function looks_like_ffxi_autotranslate(s)
    if type(s) ~= 'string' then return false end
    if s:find('%b{}') then return true end
    return false
end

-- ========== UTF-8 presence / detection ==========
local has_utf8_lib = (type(utf8) == 'table' and type(utf8.codes) == 'function')
local function contains_japanese(text)
    local s = ensure_utf8(text or '')
    if s == '' then return false end
    if has_utf8_lib then
        local ok, res = pcall(function()
            for _, cp in utf8.codes(s) do
                if (cp >= 0x3040 and cp <= 0x309F) -- hiragana
                or (cp >= 0x30A0 and cp <= 0x30FF) -- katakana
                or (cp >= 0x4E00 and cp <= 0x9FFF) -- CJK
                or (cp >= 0xFF66 and cp <= 0xFF9D) -- halfwidth katakana
                or (cp == 0x30FC) then            -- ー
                    return true
                end
            end
            return false
        end)
        return ok and res or false
    else
        local ok, res = pcall(function()
            if s:match('[\227-\238][\128-\191][\128-\191]') then return true end
            if s:match('[\192-\255]') then return true end
            return false
        end)
        return ok and res or false
    end
end

-- ========== Kana → Romaji (small mapper) ==========
local kana_map = {
    ['ア']='a',['イ']='i',['ウ']='u',['エ']='e',['オ']='o',
    ['カ']='ka',['キ']='ki',['ク']='ku',['ケ']='ke',['コ']='ko',
    ['サ']='sa',['シ']='shi',['ス']='su',['セ']='se',['ソ']='so',
    ['タ']='ta',['チ']='chi',['ツ']='tsu',['テ']='te',['ト']='to',
    ['ナ']='na',['ニ']='ni',['ヌ']='nu',['ネ']='ne',['ノ']='no',
    ['ハ']='ha',['ヒ']='hi',['フ']='fu',['ヘ']='he',['ホ']='ho',
    ['マ']='ma',['ミ']='mi',['ム']='mu',['メ']='me',['モ']='mo',
    ['ヤ']='ya',['ユ']='yu',['ヨ']='yo',
    ['ラ']='ra',['リ']='ri',['ル']='ru',['レ']='re',['ロ']='ro',
    ['ワ']='wa',['ヲ']='o',['ン']='n',
    ['ガ']='ga',['ギ']='gi',['グ']='gu',['ゲ']='ge',['ゴ']='go',
    ['ザ']='za',['ジ']='ji',['ズ']='zu',['ゼ']='ze',['ゾ']='zo',
    ['ダ']='da',['ヂ']='ji',['ヅ']='zu',['デ']='de',['ド']='do',
    ['バ']='ba',['ビ']='bi',['ブ']='bu',['ベ']='be',['ボ']='bo',
    ['パ']='pa',['ピ']='pi',['プ']='pu',['ペ']='pe',['ポ']='po'
}
local small_map = {['ャ']='ya',['ュ']='yu',['ョ']='yo',['ァ']='a',['ィ']='i',['ゥ']='u',['ェ']='e',['ォ']='o',['ッ']='tsu'}

local function kana_to_romaji(s)
    if type(s) ~= 'string' then return '' end
    local out = {}
    local i, len = 1, #s
    while i <= len do
        local ch = s:sub(i,i)
        local rom = kana_map[ch]
        if not rom then out[#out+1]=ch; i=i+1
        else
            local nextch = s:sub(i+1,i+1)
            if nextch and small_map[nextch] then
                local base = rom
                if base:sub(-1):match('[aeiou]') then base = base:sub(1,-2) end
                out[#out+1] = base .. small_map[nextch]
                i = i + 2
            else
                out[#out+1] = rom
                i = i + 1
            end
        end
    end
    return table.concat(out)
end

-- Hardened: never return nil; guard autotranslate braces.
local function is_kana_only(s)
    if type(s) ~= 'string' then return false end
    if s == '' then return false end
    if looks_like_ffxi_autotranslate(s) then return false end
    local u = ensure_utf8(s)
    if u == '' then return false end
    if has_utf8_lib then
        local ok, res = pcall(function()
            for _, cp in utf8.codes(u) do
                if not ((cp >= 0x3040 and cp <= 0x309F) or (cp >= 0x30A0 and cp <= 0x30FF) or (cp >= 0xFF66 and cp <= 0xFF9D) or cp == 0x30FC) then
                    return false
                end
            end
            return true
        end)
        if not ok then return false end
        return res and true or false
    else
        local ok, res = pcall(function()
            if u:match('%w') then return false end
            return u:match('[\192-\255]') ~= nil
        end)
        if not ok then return false end
        return res and true or false
    end
end

-- ========== Katakana→Hiragana (offline) ==========
local function u8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + bit.rshift(cp,6),
                           0x80 + bit.band(cp,0x3F))
    elseif cp < 0x10000 then
        return string.char(0xE0 + bit.rshift(cp,12),
                           0x80 + bit.band(bit.rshift(cp,6),0x3F),
                           0x80 + bit.band(cp,0x3F))
    else
        return "\239\191\189" -- U+FFFD
    end
end

local function katakana_to_hiragana(s)
    local str = ensure_utf8(s or '')
    if str == '' then return str end
    local out = {}
    local i, n = 1, #str
    while i <= n do
        local b1 = str:byte(i)
        if not b1 then break end
        if b1 < 0x80 then
            out[#out+1] = string.char(b1); i = i + 1
        elseif b1 < 0xE0 and i+1 <= n then
            local b2 = str:byte(i+1)
            local cp = bit.lshift(bit.band(b1,0x1F),6) + bit.band(b2,0x3F)
            out[#out+1] = u8_encode(cp); i = i + 2
        elseif b1 < 0xF0 and i+2 <= n then
            local b2, b3 = str:byte(i+1), str:byte(i+2)
            local cp = bit.lshift(bit.band(b1,0x0F),12)
                    + bit.lshift(bit.band(b2,0x3F),6)
                    + bit.band(b3,0x3F)
            if cp >= 0x30A1 and cp <= 0x30F6 then
                cp = cp - 0x60
            end
            out[#out+1] = u8_encode(cp); i = i + 3
        else
            out[#out+1] = string.char(b1); i = i + 1
        end
    end
    return table.concat(out)
end

-- ========== Phrasebook (outbound helper) ==========
local phrasebook = {
    ["hello"]="こんにちは",["hi"]="やあ",["good morning"]="おはよう",["good night"]="おやすみ",
    ["thank you"]="ありがとう",["thanks"]="ありがとう",["ty"]="ありがとう",["tyty"]="ありがとう！",
    ["please"]="お願いします",["sorry"]="ごめんね",["i'm sorry"]="ごめんなさい",
    ["let's go"]="行こう",["one moment"]="ちょっと待って",["brb"]="すぐ戻るね",["back"]="戻ったよ",
    ["good job"]="ナイス！",["nice"]="ナイス！",["ready?"]="準備できた？",["ready"]="準備できた",
    ["pull"]="引きます",["wait"]="待って",["help"]="助けて",["need help"]="助けが必要",
    ["sorry i'm late"]="遅れてごめん",["let's party up"]="パーティー組もう",
    ["congrats"]="おめでとう！",["grats"]="おめ！",["gz"]="おめ！",
    ["hooray"]="やったー！",["yay"]="やったー！",["woohoo"]="やったー！",
}
local function phrasebook_match(s)
    local ls = (type(s)=='string' and s or ''):lower()
    if phrasebook[ls] then return phrasebook[ls] end
    local stripped = ls:gsub('[%p%s]+$', '')
    if phrasebook[stripped] then return phrasebook[stripped] end
    local best, bestlen = nil, 0
    for k,v in pairs(phrasebook) do
        local pattern = "%f[%w]" .. k:gsub("%s+", "%s+") .. "%f[%W]"
        if ls:match(pattern) and #k > bestlen then best, bestlen = v, #k end
    end
    return best
end
local function naive_fallback(text) return string.format("「%s」", text) end

-- ========== Cleaning / To-send ==========
local function remove_hex_artifacts(s)
    if type(s) ~= 'string' then return '' end
    s = s:gsub('%s*[%x][%x%s]+$', '')
    s = s:gsub('%s+', ' ')
    return s
end

local function sanitize_lines(s)
    if type(s) ~= 'string' then return '' end
    s = s:gsub('[\r\n]', ' ')
         :gsub('[\0\1\2\3\4\5\6\7\8\11\12\14-\31]', '')
         :gsub('%s+', ' ')
    return remove_hex_artifacts(s)
end

local function to_send(s)
    s = sanitize_lines(s)
    if cfg.send_encoding == 'sjis' then return utf8_to_cp932(s) else return s end
end

-- ========== Temp writers ==========
local function write_temp_utf8(text)
    local base = os.getenv('TEMP') or os.getenv('TMP') or '.'
    local path = (base .. '\\oddjp_q.txt'):gsub('/', '\\')
    local f = io.open(path, 'wb'); if not f then return nil end
    f:write(text or '')
    f:close()
    return path
end
local function write_temp_json(text)
    local base = os.getenv('TEMP') or os.getenv('TMP') or '.'
    local path = (base .. '\\oddjp_q.json'):gsub('/', '\\')
    local f = io.open(path, 'wb'); if not f then return nil end
    f:write(text or '')
    f:close()
    return path
end

-- ========== Google EN->JA ==========
local function translate_google_en_to_ja(text)
    local qfile = write_temp_utf8(text)
    if not qfile then return nil, 'tmpfile' end
    local base = 'https://translate.googleapis.com/translate_a/single'
    local cmd = table.concat({
        'curl -s -G --retry 2 --max-time 8',
        '"'..base..'"',
        '--data-urlencode "client=gtx"',
        '--data-urlencode "sl=en"',
        '--data-urlencode "tl=ja"',
        '--data-urlencode "dt=t"',
        '--data-urlencode "q@'..qfile..'"'
    }, ' ')
    local out, code = http_exec(cmd)
    os.remove(qfile)
    if cfg.debug then
        dbg(string.format('google EN->JA http=%d', code))
        dbg_raw('google EN->JA head: '..tostring(out or ''):sub(1,200))
        if out and #out>0 then dbg_raw('google EN->JA hex:  '..hex_preview(out, 64)) end
    end
    if not out then return nil, 'curl' end
    if code ~= 200 or out == '' then return nil, 'http_'..tostring(code) end
    out = unescape_json(out)
    local ok, parsed = pcall(function() return json.decode(out) end)
    if ok and parsed and type(parsed) == 'table' then
        local primary = parsed[1] and parsed[1][1] and parsed[1][1][1]
        if type(primary) == 'string' then return remove_hex_artifacts(primary), nil end
        local function walk(v)
            if type(v)=='string' then return v end
            if type(v)~='table' then return nil end
            if v[1] and type(v[1])=='table' and v[1][1] and type(v[1][1])=='table' and type(v[1][1][1])=='string' then
                return v[1][1][1]
            end
            for i=1,#v do local r=walk(v[i]); if r then return r end end
            for _,nv in pairs(v) do local r=walk(nv); if r then return r end end
            return nil
        end
        local candidate = walk(parsed)
        if candidate then return remove_hex_artifacts(candidate), nil end
    end
    local parts = {}; for translated,_ in out:gmatch('%["(.-)","(.-)"') do parts[#parts+1]=translated end
    if #parts == 0 then return nil, 'parse' end
    return remove_hex_artifacts(table.concat(parts, '')), nil
end

-- ========== DeepL EN->JA ==========
local function translate_deepl_en_to_ja(text)
    if cfg.api_key=='' then return nil,'no_key' end
    local data='auth_key='..urlencode(cfg.api_key)..'&text='..urlencode(text)..'&source_lang=EN&target_lang=JA'
    local cmd = 'curl -s -X POST --retry 2 --max-time 10 -H "Content-Type: application/x-www-form-urlencoded" -d "'..data..'" "https://api-free.deepl.com/v2/translate"'
    local out, code = http_exec(cmd)
    if cfg.debug then
        dbg(string.format('deepl EN->JA http=%d', code))
        dbg_raw('deepl EN->JA head: '..tostring(out or ''):sub(1,200))
        if out and #out>0 then dbg_raw('deepl EN->JA hex:  '..hex_preview(out, 64)) end
    end
    if not out then return nil,'curl' end
    if code ~= 200 or out == '' then return nil, 'http_'..tostring(code) end
    out=unescape_json(out)
    local t=out:match('%"text%":%s*%"(.-)%"'); if not t or #t==0 then return nil,'parse' end
    local cleaned = remove_hex_artifacts(t)
    if not cleaned then return nil,'clean' end
    return cleaned,nil
end

-- ========== JA->EN ==========
local function translate_google_ja_to_en(text)
    local qfile = write_temp_utf8(text)
    if not qfile then return nil, 'tmpfile' end
    local base = 'https://translate.googleapis.com/translate_a/single'
    local cmd = table.concat({
        'curl -s -G --retry 2 --max-time 8',
        '"'..base..'"',
        '--data-urlencode "client=gtx"',
        '--data-urlencode "sl=ja"',
        '--data-urlencode "tl=en"',
        '--data-urlencode "dt=t"',
        '--data-urlencode "q@'..qfile..'"'
    }, ' ')
    if cfg.debug then dbg('JA->EN executing curl (google)') end
    local out, code = http_exec(cmd)
    os.remove(qfile)
    if cfg.debug then
        dbg(string.format('google JA->EN http=%d', code))
        dbg_raw('google JA->EN head: '..tostring(out or ''):sub(1,200))
        if out and #out>0 then dbg_raw('google JA->EN hex:  '..hex_preview(out, 64)) end
    end
    if not out then return nil,'curl' end
    if code ~= 200 or out == '' then return nil, 'http_'..tostring(code) end
    out = unescape_json(out)
    local ok, parsed = pcall(function() return json.decode(out) end)
    if ok and parsed and type(parsed) == 'table' then
        local primary = parsed[1] and parsed[1][1] and parsed[1][1][1]
        if type(primary) == 'string' then return remove_hex_artifacts(primary), nil end
        local function find(v)
            if type(v)=='string' then return v end
            if type(v)~='table' then return nil end
            if v[1] and type(v[1])=='table' and v[1][1] and type(v[1][1])=='table' and type(v[1][1][1])=='string' then
                return v[1][1][1]
            end
            for i=1,#v do local r=find(v[i]); if r then return r end end
            for _,nv in pairs(v) do local r=find(nv); if r then return r end end
            return nil
        end
        local candidate = find(parsed)
        if candidate then return remove_hex_artifacts(candidate), nil end
        return nil, 'parse'
    end
    local parts = {}; for translated,_ in out:gmatch('%["(.-)","(.-)"') do parts[#parts+1]=translated end
    if #parts == 0 then return nil, 'parse' end
    return remove_hex_artifacts(table.concat(parts, '')), nil
end

local function translate_deepl_ja_to_en(text)
    if cfg.api_key == '' then return nil, 'no_key' end
    local data = 'auth_key='..urlencode(cfg.api_key)..'&text='..urlencode(text)..'&source_lang=JA&target_lang=EN'
    local cmd = 'curl -s -X POST --retry 2 --max-time 10 -H "Content-Type: application/x-www-form-urlencoded" -d "'..data..'" "https://api-free.deepl.com/v2/translate"'
    local out, code = http_exec(cmd)
    if cfg.debug then
        dbg(string.format('deepl JA->EN http=%d', code))
        dbg_raw('deepl JA->EN head: '..tostring(out or ''):sub(1,200))
        if out and #out>0 then dbg_raw('deepl JA->EN hex:  '..hex_preview(out, 64)) end
    end
    if not out then return nil, 'curl' end
    if code ~= 200 or out == '' then return nil, 'http_'..tostring(code) end
    out = unescape_json(out)
    local t = out:match('%"text%":%s*%"(.-)%"')
    if not t or #t == 0 then return nil, 'parse' end
    return remove_hex_artifacts(t), nil
end

local function translate_ja_to_en(text_utf8)
    if not text_utf8 then return nil, 'empty' end
    local text = trim(text_utf8); if text == '' then return nil, 'empty' end

    -- Skip kana-heuristic on FFXI autotranslate tokens
    if #text < 12 and not looks_like_ffxi_autotranslate(text) and is_kana_only(text) then
        local rom = kana_to_romaji(text)
        if rom and #rom > 0 then
            if cfg.debug then dbg('kana-only short, romaji='..tostring(rom)) end
            return rom, nil
        end
    end

    if cfg.provider == 'google' then
        return translate_google_ja_to_en(text)
    elseif cfg.provider == 'deepl' then
        return translate_deepl_ja_to_en(text)
    end
    return nil, 'provider'
end

-- ========== EN->JA wrapper ==========
local function translate_en_to_ja(text)
    if not text then return '' end
    text = trim(text); if text == '' then return '' end
    if #text < 30 then
        local ph = phrasebook_match(text)
        if ph then return ph end
    end
    local t
    if cfg.provider == 'google' then
        t = select(1, translate_google_en_to_ja(text))
    elseif cfg.provider == 'deepl' then
        t = select(1, translate_deepl_en_to_ja(text))
    elseif cfg.provider == 'none' then
        t = nil
    else
        t = select(1, translate_google_en_to_ja(text))
    end
    if t and #t > 0 then
        t = trim(t)
        if cfg.hiragana_mode then
            t = katakana_to_hiragana(t)
        end
        return t
    end
    return naive_fallback(text)
end

-- ========== Furigana APIs (optional logger) ==========
local function furigana_via_goo(text_utf8)
    local key = (cfg.furigana and cfg.furigana.app_id) or ''
    if key == '' then return nil, 'no_key' end
    local payload = string.format('{"app_id":"%s","sentence":"%s","output_type":"hiragana"}',
        key:gsub('\\','\\\\'):gsub('"','\\"'),
        (text_utf8 or ''):gsub('\\','\\\\'):gsub('"','\\"'))
    local tmp = write_temp_json(payload); if not tmp then return nil, 'tmpfile' end
    local cmd = ('curl -s -X POST --retry 1 --max-time 6 -H "Content-Type: application/json; charset=utf-8" --data-binary "@%s" "https://labs.goo.ne.jp/api/hiragana"'):format(tmp)
    local out, code = http_exec(cmd); os.remove(tmp)
    if not out or code ~= 200 then return nil, 'http_'..tostring(code) end
    out = unescape_json(out)
    local ok, obj = pcall(json.decode, out)
    if not ok or type(obj) ~= 'table' then
        local t = out:match('%"converted%":%s*%"(.-)%"')
        if t and #t>0 then return sanitize_lines(t), nil end
        return nil, 'parse'
    end
    local t = obj['converted']
    if type(t) ~= 'string' then return nil, 'parse' end
    return sanitize_lines(t), nil
end

local function furigana_via_yahoo(text_utf8)
    local key = (cfg.furigana and cfg.furigana.app_id) or ''
    if key == '' then return nil, 'no_key' end
    local payload = string.format('{"id":"oddjp-1","jsonrpc":"2.0","method":"jlp.furiganaservice.furigana","params":{"q":"%s","grade":1}}',
        (text_utf8 or ''):gsub('\\','\\\\'):gsub('"','\\"'))
    local tmp = write_temp_json(payload); if not tmp then return nil, 'tmpfile' end
    local cmd = ('curl -s -X POST --retry 1 --max-time 6 ' ..
                 '-H "Content-Type: application/json; charset=utf-8" ' ..
                 '-H "User-Agent: Yahoo AppID: %s" ' ..
                 '--data-binary "@%s" "https://jlp.yahooapis.jp/FuriganaService/V2/furigana"')
                 :format(key, tmp)
    local out, code = http_exec(cmd); os.remove(tmp)
    if not out or code ~= 200 then return nil, 'http_'..tostring(code) end
    out = unescape_json(out)
    local ok, obj = pcall(json.decode, out); if not ok or type(obj) ~= 'table' then return nil, 'parse' end
    local result = obj['result'] or obj['Result'] or obj['resultset'] or obj['resultSet'] or obj
    local out_words = {}
    local function push(s) if type(s)=='string' and #s>0 then out_words[#out_words+1] = s end end
    local function use_item(w)
        if type(w) ~= 'table' then return end
        if w['subword'] and type(w['subword'])=='table' then
            for _,sw in ipairs(w['subword']) do
                local f = sw['furigana'] or sw['Furigana'] or sw['surface'] or sw['Surface']
                push(f)
            end
        else
            local f = w['furigana'] or w['Furigana'] or w['surface'] or w['Surface']
            push(f)
        end
    end
    local wordlist = (result and result['word']) or obj['word']
    if type(wordlist) == 'table' then
        for _,w in ipairs(wordlist) do use_item(w) end
    else
        local function deep(v)
            if type(v) ~= 'table' then return end
            if v['surface'] or v['Surface'] then use_item(v); return end
            for _,nv in pairs(v) do deep(nv) end
        end
        deep(obj)
    end
    if #out_words == 0 then return nil, 'empty' end
    return sanitize_lines(table.concat(out_words, ' ')), nil
end

local function get_hiragana(text_utf8)
    local prov = (cfg.furigana and cfg.furigana.provider) or 'goo'
    if prov == 'yahoo' then
        return furigana_via_yahoo(text_utf8)
    else
        return furigana_via_goo(text_utf8)
    end
end

-- ========== Sending helpers ==========
local suppress_until = 0
local function queue_message(raw, channel, target)
    local msg = to_send(raw)
    local cmd = channel
    if channel == 'l2' then cmd = 'linkshell2'
    elseif channel == 'l' then cmd = 'linkshell'
    elseif channel == 's' then cmd = 'say'
    elseif channel == 'p' then cmd = 'party'
    elseif channel == 'a' then cmd = 'alliance'
    elseif channel == 't' and target then cmd = 'tell ' .. target
    else return end
    suppress_until = os.clock() + 0.6
    AshitaCore:GetChatManager():QueueCommand(1, '/' .. cmd .. ' ' .. msg)
end
local function queue_p(raw) queue_message(raw, 'p') end
local function queue_say(raw) queue_message(raw, 's') end
local function queue_tell(name, raw) queue_message(raw, 't', name) end

-- ========== Incoming processor ==========
local function process_incoming(mode_num, raw_message)
    if not raw_message or raw_message == '' then return nil end

    local msg_game = strip_ashita_codes(raw_message)
    local just_text = msg_game
    local prefix = ''
    while true do
        local br = just_text:match('^%s*(%b[])')
        if br then prefix = prefix .. br .. ' '; just_text = just_text:sub(#br + 1)
        else
            local ang = just_text:match('^%s*(%b<>)')
            if ang then prefix = prefix .. ang .. ' '; just_text = just_text:sub(#ang + 1)
            else break end
        end
    end
    just_text = just_text:gsub('^%s+', '')

    local text_utf8 = ensure_utf8(just_text)
    if not cfg.translate_incoming then return nil end

    local channel_map = { s=4, p=0x17, l=1, l2=14, t=3 }
    local mode_base = bit.band(tonumber(mode_num) or 0, 0xFF)
    local expected_mode = channel_map[(cfg.default_channel or 'p'):lower()]
    local should_process = (expected_mode and mode_base == expected_mode) or cfg.translate_modes[mode_base] or cfg.translate_modes[mode_num]
    if not should_process then return nil end

    -- SKIP: FFXI autotranslate tokens entirely
    if looks_like_ffxi_autotranslate(text_utf8) then return nil end

    if not contains_japanese(text_utf8) then return nil end

    local en = select(1, translate_ja_to_en(text_utf8))
    if not en then return nil end

    info(text_utf8 .. ' > ' .. en)

    if cfg.furigana and cfg.furigana.enabled then
        local hira = select(1, get_hiragana(text_utf8))
        if hira and #hira > 0 then info(hira) end
    end

    local reinject = prefix .. just_text .. ' [' .. en .. ']'
    return reinject, en, text_utf8
end

-- ========== Commands / Auto ==========
local function split_words(s) local t={}; if type(s)~='string' then return t end for w in s:gmatch('%S+') do t[#t+1]=w end; return t end
local last_auto_send = 0

ashita.events.register('command','oddjp_command', function(e)
    local cmd=e.command or ''; if #cmd==0 then return end

    if starts_with_ci(cmd, '/oddjp') then
        e.blocked = true
        local args=split_words(cmd); local sub=(args[2] or ''):lower()

        if sub=='on' then cfg.enabled=true; settings.save(); info('Auto translate: ON'); return
        elseif sub=='off' then cfg.enabled=false; settings.save(); info('Auto translate: OFF'); return
        elseif sub=='dual' then
            local v=(args[3] or ''):lower()
            if v=='on' or v=='true' then cfg.dual_send=true; settings.save(); info('Dual send: ON (EN+JA)')
            elseif v=='off' or v=='false' then cfg.dual_send=false; settings.save(); info('Dual send: OFF (JA only)') end
            return
        elseif sub=='provider' then
            local p=(args[3] or ''):lower()
            if p=='google' or p=='deepl' or p=='none' then cfg.provider=p; settings.save(); info('Provider: '..p)
            else info('Usage: /oddjp provider google|deepl|none') end
            return
        elseif sub=='key' then
            local k=cmd:match('^/oddjp%s+key%s+(.+)$'); if not k then info('Usage: /oddjp key <YOUR_API_KEY>'); return end
            cfg.api_key=trim(k); settings.save(); info('API key set.'); return
        elseif sub=='sendenc' then
            local enc=(args[3] or ''):lower()
            if enc=='sjis' or enc=='utf8' then cfg.send_encoding=enc; settings.save(); info('Send encoding: '..enc)
            else info('Usage: /oddjp sendenc sjis|utf8') end
            return
        elseif sub=='test' then
            local t=cmd:match('^/oddjp%s+test%s+(.+)$'); if not t then info('Usage: /oddjp test <text>'); return end
            local ja=translate_en_to_ja(t); info('EN: '..t); info('JA: '..ja); return
        elseif sub=='status' then
            info(('enabled=%s, dual=%s, provider=%s, sendenc=%s, rate_ms=%d, debug=%s, furi=%s/%s'):format(
                tostring(cfg.enabled), tostring(cfg.dual_send), cfg.provider, cfg.send_encoding, cfg.rate_ms, tostring(cfg.debug),
                tostring(cfg.furigana and cfg.furigana.enabled), cfg.furigana and cfg.furigana.provider or ''))
            return
        elseif sub=='debug' then
            local v=(args[3] or ''):lower()
            if v=='on' or v=='true' then cfg.debug=true; settings.save(); info('debug: ON')
            elseif v=='off' or v=='false' then cfg.debug=false; settings.save(); info('debug: OFF') end
            return
        elseif sub=='incoming' then
            local v=(args[3] or ''):lower()
            if v=='on' or v=='true' then cfg.translate_incoming=true; settings.save(); info('Incoming translation: ON')
            elseif v=='off' or v=='false' then cfg.translate_incoming=false; settings.save(); info('Incoming translation: OFF') end
            return
        elseif sub=='hiragana' then
            local v=(args[3] or ''):lower()
            if v=='on' or v=='true' then cfg.hiragana_mode=true; settings.save(); info('Hiragana mode (outbound EN->JA): ON')
            elseif v=='off' or v=='false' then cfg.hiragana_mode=false; settings.save(); info('Hiragana mode: OFF') end
            return
        elseif sub=='channel' then
            local ch=(args[3] or ''):lower()
            if valid_channels[ch] then cfg.default_channel=ch; settings.save(); info('Default channel set to: /' .. ch)
            else info('Valid channels: /s /t /l /l2 /p /a') end
            return

        elseif sub=='furigana' then
            local v=(args[3] or ''):lower()
            if v=='on' or v=='true' then
                cfg.furigana.enabled = true; settings.save(); info('Furigana logger: ON'); return
            elseif v=='off' or v=='false' then
                cfg.furigana.enabled = false; settings.save(); info('Furigana logger: OFF'); return
            elseif v=='provider' then
                local p=(args[4] or ''):lower()
                if p=='yahoo' or p=='goo' then cfg.furigana.provider = p; settings.save(); info('Furigana provider: '..p)
                else info('Usage: /oddjp furigana provider yahoo|goo') end
                return
            elseif v=='key' then
                local k=cmd:match('^/oddjp%s+furigana%s+key%s+(.+)$'); if not k then info('Usage: /oddjp furigana key <APP_ID>'); return end
                cfg.furigana.app_id = trim(k); settings.save(); info('Furigana key set.'); return
            else
                info('Furigana: on|off | provider yahoo|goo | key <APP_ID>'); return
            end

        elseif sub=='inc' then
            local simulated_mode = 0x17 -- party
            local simulated_raw  = '[17] <OddFriend> おはよう'
            if cfg.debug then dbg('Manual incoming injection: mode=0x17 text="おはよう"') end
            local newmsg, en, orig = process_incoming(simulated_mode, simulated_raw)
            if en then
                info((orig or '??') .. ' > ' .. en)
                info('Injected preview: ' .. (newmsg or simulated_raw))
            else
                info('Injection produced no translation (check incoming settings / mode filters).')
            end
            return

        else
            info('Commands: on|off | dual on|off | provider google|deepl|none | key <KEY> | sendenc sjis|utf8 | channel <s|t|l|l2|p|a> | test <text> | status | debug on|off | incoming on|off | hiragana on|off | furigana on|off | furigana provider yahoo|goo | furigana key <APP_ID> | inc')
            return
        end
    end

    -- Quick senders (outbound EN->JA)
    if starts_with_ci(cmd, '/jp ') then
        e.blocked=true
        local text=trim(cmd:match('^/jp%s+(.+)$') or ''); if #text==0 then return end
        queue_p(translate_en_to_ja(text)); return
    end
    if starts_with_ci(cmd, '/jpsay ') then
        e.blocked=true
        local text=trim(cmd:match('^/jpsay%s+(.+)$') or ''); if #text==0 then return end
        queue_say(translate_en_to_ja(text)); return
    end
    if starts_with_ci(cmd, '/jptell ') then
        e.blocked=true
        local who,text=cmd:match('^/jptell%s+(%S+)%s+(.+)$')
        if not who or not text then info('Usage: /jptell <name> <text>'); return end
        queue_tell(who, translate_en_to_ja(trim(text))); return
    end

    -- Auto mode on default channel
    if starts_with_ci(cmd, '/' .. cfg.default_channel .. ' ') then
        if os.clock() < suppress_until then return end
        if not cfg.enabled then return end
        local now=os.clock()*1000; if (now-last_auto_send)<cfg.rate_ms then return end
        last_auto_send=now
        local text=trim(cmd:match('^/' .. cfg.default_channel .. '%s+(.+)$') or ''); if #text==0 then return end
        local ja=translate_en_to_ja(text)
        e.blocked=true
        if cfg.dual_send then info(string.format('[EN] %s', text)); queue_message(ja, cfg.default_channel)
        else queue_message(ja, cfg.default_channel) end
        return
    end
end)

-- ========== Incoming JP -> EN ==========
ashita.events.register('text_in','oddjp_text_in', function(e)
    if not e or not e.message then return end
    if e.injected or os.clock() < suppress_until then return end
    local newmsg, en = process_incoming(e.mode, e.message)
    if not newmsg or not en then return end
    local ok_assign, err_assign = pcall(function() e.message = newmsg end)
    if not ok_assign and cfg.debug then dbg('Failed to assign e.message: '..tostring(err_assign)) end
end)

-- ========== Load / Unload ==========
ashita.events.register('load','oddjp_load', function()
    info(string.format('Loaded. Auto=%s, Dual=%s, Channel=%s, Provider=%s, SendEnc=%s, Furi=%s/%s',
        tostring(cfg.enabled), tostring(cfg.dual_send), cfg.default_channel, cfg.provider, cfg.send_encoding,
        tostring(cfg.furigana and cfg.furigana.enabled), cfg.furigana and cfg.furigana.provider or ''))
    if cfg.debug then dbg('Incoming JP→EN; hardened against FFXI autotranslate tokens.') end
end)
ashita.events.register('unload','oddjp_unload', function() end)
