-- oddjp.lua
-- Ashita v4 Addon: OddJP — Party chat translator to Japanese
-- v1.3.5 (instrumented)
-- Adds HTTP status/body head/hex logging around curl calls to pinpoint failures.

addon.name = 'oddjp';
addon.author = 'Oddone';
addon.version = '1.3.5';
addon.desc = 'Chat translator to Japanese (Ashita v4).';
addon.link = '';

require('common')

local chat     = require('chat')
local settings = require('settings')
local ffi      = require('ffi')

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
    hiragana_mode = false,      -- convert kanji to hiragana before translation
    translate_modes = {         -- chat modes to translate
        [4]  = true,  -- say
        [5]  = true,  -- shout
        [3]  = true,  -- tell
        [1]  = true,  -- linkshell
        [14] = true,  -- linkshell2
        [0x17] = true,-- party
        [8]  = true   -- emote
    }
}

local cfg = settings.load(defaults)
settings.register('settings', 'settings_update', function(s) if s then for k,v in pairs(s) do cfg[k]=v end end end)

-- ========== UTF-8 presence / detection ==========
local has_utf8_lib = (type(utf8) == 'table' and type(utf8.codes) == 'function')

local function contains_japanese(text)
    if not text or text == '' then return false end
    if has_utf8_lib then
        local ok, res = pcall(function()
            for _, cp in utf8.codes(text) do
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
        if ok then return res else return true end
    else
        if text:match('[\227-\238][\128-\191][\128-\191]') then return true end
        if text:match('[\192-\255]') then return true end
        return false
    end
end

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
local function utf8_to_cp932(s)
    if not s or s == '' then return s end
    local wlen = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0); if wlen == 0 then return s end
    local wbuf = ffi.new('wchar_t[?]', wlen)
    if ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, #s, wbuf, wlen) == 0 then return s end
    local mblen = ffi.C.WideCharToMultiByte(CP_932, 0, wbuf, wlen, nil, 0, nil, nil); if mblen == 0 then return s end
    local mbuf  = ffi.new('char[?]', mblen)
    if ffi.C.WideCharToMultiByte(CP_932, 0, wbuf, wlen, mbuf, mblen, nil, nil) == 0 then return s end
    return ffi.string(mbuf, mblen)
end

-- ========== Channels ==========
local valid_channels = { s=true, t=true, l=true, l2=true, p=true, a=true }

-- ========== Utils / Logging ==========
local function trim(s) return (s and s:gsub('^%s+',''):gsub('%s+$','')) or '' end
local function starts_with_ci(s,p) return s:sub(1,#p):lower()==p:lower() end
local function info(m) print(chat.header(addon.name):append(chat.message(m and tostring(m) or ''))) end

local function format_output(m)
    local s = tostring(m or '')
    if cfg.send_encoding == 'sjis' then return utf8_to_cp932(s) else return s end
end

local function dbg(m)
    if not cfg.debug then return end
    print(chat.header(addon.name):append(chat.message('[debug] '..format_output(m))))
end

local function dbg_raw(m)
    if not cfg.debug then return end
    print(chat.header(addon.name):append(chat.message('[debug] '..tostring(m))))
end

local function urlencode(str)
    if not str then return '' end
    str=str:gsub('\n','\r\n')
    str=str:gsub('([^%w%-_%.~ ])', function(c) return string.format('%%%02X', string.byte(c)) end)
    return str:gsub(' ','%%20')
end

-- original exec (kept for non-HTTP uses)
local function exec(cmd)
    local f = io.popen(cmd..' 2>nul','r'); if not f then return nil end
    local s = f:read('*a'); f:close(); if s and #s>0 then return s end
    return nil
end

-- ========== Instrumented HTTP exec ==========
local function http_exec(cmd)
    -- write CURL_HTTP_CODE trailer we can parse
    local full = cmd .. ' -w "\\nCURL_HTTP_CODE=%{http_code}\\n"'
    local f = io.popen(full .. ' 2>nul', 'r'); if not f then return nil, 0 end
    local out = f:read('*a') or ''; f:close()
    local code = tonumber((out:match('\nCURL_HTTP_CODE=(%d+)\n') or '0')) or 0
    out = out:gsub('\nCURL_HTTP_CODE=%d+\n$', '')
    return out, code
end

local function hex_preview(s, n)
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
    if not s then return s end
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

-- ========== Helpers to pick a string out of unknown JSON ==========
local function is_mostly_ascii(str)
    if not str or #str == 0 then return false end
    local ascii, other = 0, 0
    for i=1,#str do local b=str:byte(i); if b>=32 and b<=126 then ascii=ascii+1 else other=other+1 end end
    if ascii == 0 then return false end
    return (ascii / (ascii + other)) >= 0.6
end

local function find_best_string(obj)
    if type(obj) ~= 'table' and type(obj) ~= 'string' then return nil end

    local first_found = nil
    local best, best_score = nil, -1
    local seen = setmetatable({}, { __mode = 'k' })
    local priority_keys = {
        translatedText = true, text = true, translation = true, translated = true,
        output = true, target = true, result = true, message = true
    }

    local function has_letters(s) return s:match('[A-Za-z]') ~= nil end

    local function score(s, key)
        if type(s) ~= 'string' or #s == 0 then return -1 end
        local sc = 0
        if is_mostly_ascii and is_mostly_ascii(s) then sc = sc + 50 else sc = sc + 5 end
        if has_letters(s) then sc = sc + 20 end
        local len = #s
        if len >= 2 and len <= 240 then sc = sc + 20 end
        if key and priority_keys[key] then sc = sc + 40 end
        if s:match('^%s*[%[%{<]') and not s:match('[A-Za-z]') then sc = sc - 10 end
        return sc
    end

    local function consider(s, key)
        if not first_found then first_found = s end
        local sc = score(s, key)
        if sc > best_score then best, best_score = s, sc end
    end

    local function walk(v, key, depth)
        if depth > 8 then return end
        local tv = type(v)
        if tv == 'string' then
            consider(v, key)
        elseif tv == 'table' then
            if seen[v] then return end
            seen[v] = true

            -- Fast-path for Google translate_a/single: [[{"translated","orig",..},...],...]
            if v[1] and type(v[1]) == 'table' and v[1][1] and type(v[1][1]) == 'table' and type(v[1][1][1]) == 'string' then
                consider(v[1][1][1], 'translatedText')
            end

            -- Array-like entries first (preserve typical ordering)
            local n = #v
            for i = 1, n do walk(v[i], nil, depth + 1) end
            -- Then map-like entries (string keys)
            for k, nv in pairs(v) do
                if type(k) ~= 'number' then walk(nv, tostring(k), depth + 1) end
            end
        end
    end

    if type(obj) == 'string' then consider(obj, nil) else walk(obj, nil, 1) end
    return best or first_found
end


-- ========== Temp file helper ==========
local function write_temp_utf8(text)
    local base = os.getenv('TEMP') or os.getenv('TMP') or '.'
    local path = (base .. '\\oddjp_q.txt'):gsub('/', '\\')
    local f = io.open(path, 'wb')
    if not f then return nil end
    f:write(text or '')
    f:close()
    return path
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
    if not s then return s end
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

local function is_kana_only(s)
    if not s or s == '' then return false end
    if has_utf8_lib then
        local ok, res = pcall(function()
            for _, cp in utf8.codes(s) do
                if not ((cp >= 0x3040 and cp <= 0x309F) or (cp >= 0x30A0 and cp <= 0x30FF) or (cp >= 0xFF66 and cp <= 0xFF9D) or cp == 0x30FC) then
                    return false
                end
            end
            return true
        end)
        return ok and res
    else
        if s:match('%w') then return false end
        return s:match('[\192-\255]') ~= nil
    end
end

-- ========== Phrasebook ==========
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
    local ls = (s or ''):lower()
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

-- ========== Cleaning ==========
local function remove_hex_artifacts(s)
    if not s then return '' end
    s = s:gsub('%s*[%x][%x%s]+$', '') -- trailing hex-ish junk
    s = s:gsub('%s+', ' ')
    return s
end

local function sanitize_lines(s)
    if not s then return '' end
    s = s:gsub('[\r\n]', ' ')
         :gsub('[\0\1\2\3\4\5\6\7\8\11\12\14-\31]', '')
         :gsub('%s+', ' ')
    return remove_hex_artifacts(s)
end
local function to_send(s)
    s = sanitize_lines(s)
    if cfg.send_encoding == 'sjis' then return utf8_to_cp932(s) else return s end
end

-- ========== Google EN->JA ==========
local function translate_google(text)
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
        local candidate = find_best_string(parsed); if candidate then return remove_hex_artifacts(candidate), nil end
    end
    local parts = {}; for translated,_ in out:gmatch('%["(.-)","(.-)"') do parts[#parts+1]=translated end
    if #parts == 0 then return nil, 'parse' end
    return remove_hex_artifacts(table.concat(parts, '')), nil
end

-- ========== DeepL EN->JA ==========
local function translate_deepl(text)
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
local function translate_ja_to_en(text)
    if not text then return nil, 'empty' end
    text = trim(text)
    if text == '' then return nil, 'empty' end

    if #text < 12 and is_kana_only(text) then
        local rom = kana_to_romaji(text)
        if rom and #rom > 0 then
            if cfg.debug then dbg('kana-only short, romaji='..tostring(rom)) end
            return rom, nil
        end
    end

    if cfg.provider == 'google' then
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
            if type(primary) == 'string' and is_mostly_ascii(primary) then
                return remove_hex_artifacts(primary), nil
            end
            local candidate = find_best_string(parsed)
            if candidate then
                if not is_mostly_ascii(candidate) and contains_japanese(text) then
                    local rom = kana_to_romaji(text)
                    if rom and #rom>0 then return rom, nil end
                end
                return remove_hex_artifacts(candidate), nil
            end
            return nil, 'parse'
        end
        local parts = {}; for translated,_ in out:gmatch('%["(.-)","(.-)"') do parts[#parts+1]=translated end
        if #parts == 0 then return nil, 'parse' end
        return remove_hex_artifacts(table.concat(parts, '')), nil

    elseif cfg.provider == 'deepl' then
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

    local t, err
    if cfg.provider == 'google' then
        t, err = translate_google(text)
    elseif cfg.provider == 'deepl' then
        t, err = translate_deepl(text)
    elseif cfg.provider == 'none' then
        t, err = nil, 'none'
    else
        t, err = translate_google(text)
    end

    if t and #t > 0 then
        t = trim(t)
        if #t > 0 then
            if cfg.debug then dbg(string.format('EN->JA ok: %s -> %s', text, t)) end
            return t
        end
    end
    if cfg.debug then dbg(string.format('EN->JA failed: %s (err:%s)', text, err or 'unknown')) end
    return naive_fallback(text)
end

-- ========== Optional: Kanji→Hiragana (instrumented; experimental) ==========
local function to_hiragana(text)
    if not text or text == '' then return text end
    if cfg.api_key == '' then return text end
    local payload = '{"q": '..('"%s"'):format(text:gsub('\\','\\\\'):gsub('"','\\"'))..',"source":"ja","target":"ja","format":"text"}'
    local tmp = write_temp_utf8(payload)
    if not tmp then return text end
    local url = 'https://translation.googleapis.com/language/translate/v2?key='..urlencode(cfg.api_key)
    local cmd = ('curl -s -X POST --retry 1 --max-time 6 -H "Content-Type: application/json; charset=utf-8" --data-binary "@%s" "%s"'):format(tmp, url)
    local out, code = http_exec(cmd)
    os.remove(tmp)
    if cfg.debug then
        dbg(string.format('hiragana http=%d', code))
        dbg_raw('hiragana head: '..tostring(out or ''):sub(1,200))
        if out and #out>0 then dbg_raw('hiragana hex:  '..hex_preview(out, 64)) end
    end
    if not out or code ~= 200 then return text end
    local t = out:match('%"translatedText%":%s*%"(.-)%"')
    return t or text
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
    suppress_until = os.clock() + 0.2
    AshitaCore:GetChatManager():QueueCommand(1, '/' .. cmd .. ' ' .. msg)
end
local function queue_p(raw) queue_message(raw, 'p') end
local function queue_say(raw) queue_message(raw, 's') end
local function queue_tell(name, raw) queue_message(raw, 't', name) end

-- ========== Commands / Auto ==========
local function split_words(s) local t={}; for w in s:gmatch('%S+') do t[#t+1]=w end; return t end
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
            info(('enabled=%s, dual=%s, provider=%s, sendenc=%s, rate_ms=%d, debug=%s'):format(
                tostring(cfg.enabled), tostring(cfg.dual_send), cfg.provider, cfg.send_encoding, cfg.rate_ms, tostring(cfg.debug)))
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
            if v=='on' or v=='true' then cfg.hiragana_mode=true; settings.save(); info('Hiragana mode: ON')
            elseif v=='off' or v=='false' then cfg.hiragana_mode=false; settings.save(); info('Hiragana mode: OFF') end
            return
        elseif sub=='channel' then
            local ch=(args[3] or ''):lower()
            if valid_channels[ch] then cfg.default_channel=ch; settings.save(); info('Default channel set to: /' .. ch)
            else info('Valid channels: /s /t /l /l2 /p /a') end
            return
        else
            info('Commands: on|off | dual on|off | provider google|deepl|none | key <KEY> | sendenc sjis|utf8 | channel <s|t|l|l2|p|a> | test <text> | status | debug on|off | incoming on|off | hiragana on|off')
            return
        end
    end

    -- Quick senders
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

    local raw = e.message
    local msg = raw:gsub('\30%d',''):gsub('\31%d','')
    msg = msg:gsub('[%z\1-\8\11\12\14-\31]', '')

    local prefix, speaker = '', nil
    while true do
        local br = msg:match('^%s*(%b[])')
        if br then prefix = prefix .. br .. ' '; msg = msg:sub(#br + 1)
        else
            local ang = msg:match('^%s*(%b<>)')
            if ang then local name = ang:sub(2, -2); if name ~= '' then speaker = name end; prefix = prefix .. ang .. ' '; msg = msg:sub(#ang + 1)
            else break end
        end
    end
    msg = msg:gsub('^%s+', '')
    local cleaned = msg

    if not cfg.translate_incoming then return end

    local channel_map = { s=4, p=0x17, l=1, l2=14, t=3 }
    local mode = e.mode or 0
    local default_ch = (cfg.default_channel or 'p'):lower()
    local expected_mode = channel_map[default_ch]
    local mode_num = tonumber(mode) or 0
    local mode_base = (mode_num >= 200) and (mode_num - 200) or mode_num
    mode_base = mode_base % 256

    local should_process = expected_mode and (mode_base == expected_mode) or (cfg.translate_modes[mode_base] or cfg.translate_modes[mode])

    local numeric_tag = prefix:match('%[(%d+)%]')
    if not should_process and numeric_tag then
        local n = tonumber(numeric_tag)
        if default_ch == 'l' and n == 1 then should_process = true end
        if default_ch == 'l2' and n == 2 then should_process = true end
    end

    if cfg.debug then
        dbg(string.format('Incoming: mode=%s (base=%s) default_ch=%s expected=%s incoming_on=%s',
            tostring(mode), tostring(mode_base), tostring(default_ch), tostring(expected_mode), tostring(cfg.translate_incoming)))
        dbg_raw('Cleaned preview: '..(cleaned:sub(1,80)))
    end

    if not should_process then return end

    local has_jp = contains_japanese(cleaned)
    if cfg.debug then
        dbg('contains_japanese=' .. tostring(has_jp))
        dbg('provider=' .. tostring(cfg.provider) .. ', api_key_set=' .. tostring(cfg.api_key ~= ''))
    end
    if not has_jp then return end

    if cfg.debug then dbg_raw('JA->EN call for: '..tostring(cleaned:sub(1,200))) end
    local en, err = translate_ja_to_en(cleaned)
    if cfg.debug then dbg('JA->EN returned err='..tostring(err)) end
    if cfg.debug and en then dbg_raw('JA->EN result: '..tostring(en)) end
    if not en then
        if cfg.debug then dbg(string.format('Incoming translation failed: (err: %s)', err or 'unknown')) end
        return
    end
    if en and en ~= cleaned then
        if cfg.debug then dbg('Final translation: ' .. tostring(en)) end
        info('Translation: ' .. en)
        local ok_assign, err_assign = pcall(function() e.message = prefix .. msg .. ' [' .. en .. ']' end)
        if not ok_assign and cfg.debug then dbg('Failed to assign e.message: '..tostring(err_assign)) end
    end
end)

-- ========== Load / Unload ==========
ashita.events.register('load','oddjp_load', function()
    info(string.format('Loaded. Auto=%s, Dual=%s, Channel=%s, Provider=%s, SendEnc=%s',
        tostring(cfg.enabled), tostring(cfg.dual_send), cfg.default_channel, cfg.provider, cfg.send_encoding))
    if cfg.debug then
        dbg('Instrumentation active: http status/head/hex logging enabled')
    end
end)
ashita.events.register('unload','oddjp_unload', function() end)
