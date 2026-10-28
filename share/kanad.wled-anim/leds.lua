-- Демон светомузыки WLED Animation (yam-пакет kanad/wled-anim): лента WLED.
-- Уровни приходят от tap.lua UDP-датаграммами на 127.0.0.1:21399 (раз в 10 мс) —
-- демон спит в poll() и просыпается сразу по данным. Со старым tap.lua (без UDP)
-- работает по-прежнему через опрос /tmp/wled_anim/level.
-- mode=rainbow|mono|vu|pulse|spectrum — станция рисует кадр и шлёт его по UDP (DRGB);
--        mode=wled_fx — станция не рисует, а модулирует штатный эффект WLED
--        (яркость/цвет/интенсивность) JSON-пакетами по UDP; после музыки
--        состояние WLED восстанавливается.
local ffi = require("ffi")
ffi.cdef[[
  typedef struct { long tv_sec; long tv_nsec; } timespec_t;
  int clock_gettime(int clk, timespec_t *ts);
  typedef struct { uint16_t family; uint16_t port; uint32_t addr; uint8_t zero[8]; } sockaddr_in_t;
  struct pollfd { int fd; short events; short revents; };
  int socket(int domain, int type, int protocol);
  int bind(int fd, const void *addr, uint32_t alen);
  int poll(struct pollfd *fds, unsigned long n, int timeout);
  long recv(int fd, void *buf, size_t len, int flags);
  long sendto(int fd, const void *buf, size_t len, int flags, const void *addr, uint32_t alen);
  uint32_t inet_addr(const char *cp);
  uint16_t htons(uint16_t x);
]]
local C = ffi.C
local ts = ffi.new("timespec_t")
local function now() C.clock_gettime(1, ts); return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9 end
local exp, min, max, floor, abs = math.exp, math.min, math.max, math.floor, math.abs
local function clamp(x, a, b) return x < a and a or (x > b and b or x) end
local function ease(tau, dt) return 1 - exp(-dt / tau) end      -- доля пути к цели за dt

local D = os.getenv("WLED_ANIM_VAR") or "/data/yam/var/wled_anim"   -- настройки (settings)
local LEVEL = "/tmp/wled_anim/level"
local SAVED = "/tmp/wled_anim/wled_saved"     -- состояние WLED до wled_fx (на случай падения)
local LPORT = 21399
local HOLD_SEC = 1.5            -- после тишины ещё столько гасим плавно, потом отпускаем WLED
local DEBUG = os.getenv("WLED_ANIM_DEBUG")
local function log(s) io.stderr:write(os.date("%F %T "), s, "\n"); io.stderr:flush() end

-- настройки (файл settings: key=value), перечитываются раз в секунду
local cfg = { brightness = 0.8, speed = 1.0, mode = "rainbow",
              output = "wled", wled_ip = "", wled_leds = 188,
              fps = 50, gamma = 2.2, smooth = 1.0, gate = 0.08, alice_mute = 1,
              fx_id = -1, fx_pal = -1, fx_color = 1, fx_floor = 0.2, fx_ix = 1, fx_fps = 30 }

-- WLED: UDP-сокет и адрес, пересобирается при смене wled_ip
local WLED_PORT, WLED_TIMEOUT = 21324, 2   -- через 2 с без пакетов WLED вернёт свой эффект
local sock = C.socket(2, 2, 0)              -- AF_INET, SOCK_DGRAM
local wled_addr = ffi.new("sockaddr_in_t")
local wled_ip_cur = nil

-- приём уровней от tap.lua
local lsock = C.socket(2, 2, 0)
local laddr = ffi.new("sockaddr_in_t")
laddr.family, laddr.port, laddr.addr = 2, C.htons(LPORT), C.inet_addr("127.0.0.1")
local have_sock = C.bind(lsock, laddr, ffi.sizeof(laddr)) == 0
if not have_sock then log("leds.lua: bind 127.0.0.1:" .. LPORT .. " не удался — только опрос файла") end
local pfd = ffi.new("struct pollfd[1]")
pfd[0].fd, pfd[0].events = lsock, 1        -- POLLIN
local rbuf = ffi.new("char[256]")

local gamma_lut, gamma_cur = ffi.new("float[1025]"), nil
local function load_cfg()
  local f = io.open(D .. "/settings")
  if not f then return end
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
    if k then cfg[k] = (k == "wled_ip") and v or (tonumber(v) or v) end
  end
  f:close()
  -- IP ленты задаётся в интерфейсе; пока его нет (или он не IPv4) — ничего не шлём
  if not cfg.wled_ip:match("^%d+%.%d+%.%d+%.%d+$") then cfg.wled_ip = "" end
  if cfg.wled_ip ~= wled_ip_cur and cfg.wled_ip ~= "" then
    wled_addr.family = 2
    wled_addr.port = C.htons(WLED_PORT)
    wled_addr.addr = C.inet_addr(cfg.wled_ip)
    wled_ip_cur = cfg.wled_ip
  end
  cfg.fps = clamp(tonumber(cfg.fps) or 50, 10, 100)
  cfg.fx_fps = clamp(tonumber(cfg.fx_fps) or 30, 5, 50)
  cfg.smooth = clamp(tonumber(cfg.smooth) or 1, 0, 3)
  local g = clamp(tonumber(cfg.gamma) or 2.2, 1, 3)
  if g ~= gamma_cur then
    for i = 0, 1024 do gamma_lut[i] = (i / 1024) ^ g end
    gamma_cur = g
  end
end

local function use_wled() return cfg.output ~= "off" and cfg.wled_ip ~= "" end   -- output: wled | off

local function udp_wled(buf, len) C.sendto(sock, buf, len, 0, wled_addr, ffi.sizeof(wled_addr)) end

local function hsv(h, s, v)
  h = (h % 360) / 60
  local i, f = floor(h), h - floor(h)
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return v, t, p elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v else return v, p, q end
end

---------------------------------------------------------------- анализ уровней
local env_b, env_m, env_t = 0, 0, 0
local peak_b, peak_m, peak_t = 0.02, 0.02, 0.02
local flo_b, flo_m, flo_t = 0, 0, 0          -- «пол» полосы: уровень ровного фона
local dbg_gate_t = 0
local avg_b, beat_cond, last_beat = 0, false, 0
local flash, hue, hue_kick, spin = 0, 0, 0, 0
local last_data_t, last_loud_t = -10, -10
local lat_sum, lat_n, lat_max = 0, 0, 0     -- задержка tap → отправка (для отладки)
local pending_tsend = nil

local function env(e, x, dt, rel)
  if x > e then return e + (x - e) * ease(0.012 * clamp(cfg.smooth, 0.25, 1), dt) end   -- атака 3..12 мс (по smooth)
  return e + (x - e) * ease(rel * max(0.3, cfg.smooth), dt)
end

-- Алиса слушает/думает/говорит: её голос и «утопленная» музыка — не светомузыка.
-- Состояние берём из лога maind (onAliceStateChanged: IDLE|LISTENING|BUSY|SPEAKING),
-- читаем только дописанное, раз в 20 мс.
local ALOG = "/data/quasar/daemons_logs/maind.log"
local alog, alog_pos, alog_check, alog_t = nil, 0, -10, -10
local alice_state, alice_until = "IDLE", 0
local function alice_poll(t)
  if t - alog_t < 0.02 then return end
  alog_t = t
  if t - alog_check > 1 then                   -- раз в секунду: открыт ли лог, не сменился ли (ротация)
    alog_check = t
    local f = io.open(ALOG)
    if f then
      local size = f:seek("end")
      if not alog then alog, alog_pos = f, size                      -- старт: только новые строки
      elseif size < alog_pos then alog:close(); alog, alog_pos = f, 0
      else f:close() end
    end
  end
  if not alog then return end
  alog:seek("set", alog_pos)
  local s = alog:read("*a")
  if not s or s == "" then return end
  local last_nl = s:match(".*()\n")              -- неполную последнюю строку дочитаем в следующий раз
  if not last_nl then return end
  alog_pos = alog_pos + last_nl
  for st in s:sub(1, last_nl):gmatch("onAliceStateChanged: (%u+)") do
    if st == "IDLE" and alice_state ~= "IDLE" then
      -- уровни идут с задержкой delay_ms — даём хвосту её голоса пройти
      alice_until = t + (tonumber(cfg.delay_ms) or 0) / 1000 + 0.4
    end
    if DEBUG and st ~= alice_state then log("alice: " .. st) end
    alice_state = st
  end
end
local function alice_mute(t)
  if cfg.alice_mute == 0 then return false end
  return alice_state ~= "IDLE" or t < alice_until
end

-- шумовой гейт: громкость сравнивается с обычной громкостью трека (медленный пик);
-- тише gate от неё — тишина, вдвое громче порога — полная светомузыка
local ref, pres = 0.05, 0

-- уровень полосы 0..1: насколько выше «пола» (fl) относительно пика (pk)
local function norm(x, fl, pk) return 0.85 * clamp((x - fl) / max(pk - fl, pk * 0.2), 0, 1) + 0.15 * x / pk end

local function feed(b, m, tr, dt, t)
  last_data_t = t
  local sum = b + m + tr
  ref = max(ref * exp(-dt / 20), sum, 0.02)
  local gate = clamp(tonumber(cfg.gate) or 0.08, 0, 0.5)
  local target = (sum > 0.003) and clamp((sum / ref - gate) / max(gate, 0.01), 0, 1) or 0
  if alice_mute(t) then target = 0 end
  pres = pres + (target - pres) * ease(target > pres and 0.005 or 0.25, dt)   -- открывается сразу, закрывается плавно
  if pres > 0.05 then last_loud_t = t end
  if DEBUG and t - dbg_gate_t > 0.5 then
    dbg_gate_t = t
    log(string.format("gate: sum %.4f ref %.4f q %.3f target %.2f pres %.2f", sum, ref, sum / ref, target, pres))
  end
  b, m, tr = b * pres, m * pres, tr * pres
  local pd = exp(-dt / 6.7)                    -- автоусиление: пик спадает за ~7 с
  local pmin = 0.15 * ref                      -- но тихое место не раздувается до максимума
  peak_b = max(peak_b * pd, b, 0.01, pmin * 0.5)
  peak_m = max(peak_m * pd, m, 0.005, pmin * 0.3)
  peak_t = max(peak_t * pd, tr, 0.003, pmin * 0.2)
  -- «пол» полосы: к провалам опускается быстро (~0,3 с), к ровному гулу поднимается
  -- медленно (~3 с). Свет показывает, насколько звук выше пола, — постоянный бас
  -- не держит ленту зажжённой; 15% «как раньше» оставляют немного тела.
  local fu, fd = ease(3.0, dt), ease(0.3, dt)
  flo_b = flo_b + (b - flo_b) * (b > flo_b and fu or fd)
  flo_m = flo_m + (m - flo_m) * (m > flo_m and fu or fd)
  flo_t = flo_t + (tr - flo_t) * (tr > flo_t and fu or fd)
  local nb, nm, nt = norm(b, flo_b, peak_b), norm(m, flo_m, peak_m), norm(tr, flo_t, peak_t)
  env_b = env(env_b, nb, dt, 0.16)
  env_m = env(env_m, nm, dt, 0.20)
  env_t = env(env_t, nt, dt, 0.10)
  -- бит: бас резко выше среднего (по фронту, не чаще чем раз в 150 мс)
  avg_b = avg_b + (nb - avg_b) * ease(0.4, dt)
  local cond = nb > 0.6 and nb > avg_b * 1.5
  if cond and not beat_cond and t - last_beat > 0.15 then
    last_beat = t
    flash = 1
    hue_kick = hue_kick + 35
  end
  beat_cond = cond
end

local last_seq, last_file_seq = nil, nil
local sock_t, file_t = -10, -10      -- когда последний раз приходили данные по UDP / из файла
local function read_socket(t)
  local got = false
  while true do
    local n = C.recv(lsock, rbuf, 255, 0x40)   -- MSG_DONTWAIT
    if n <= 0 then break end
    local s = ffi.string(rbuf, n)
    local seq, b, m, tr, tsend = s:match("^(%d+) (%S+) (%S+) (%S+) ?(%S*)")
    seq = tonumber(seq)
    if seq then
      local dt = 0.01
      if last_seq and seq > last_seq and seq - last_seq < 20 then dt = 0.01 * (seq - last_seq) end
      last_seq = seq
      feed(tonumber(b) or 0, tonumber(m) or 0, tonumber(tr) or 0, dt, t)
      pending_tsend = tonumber(tsend) or pending_tsend
      got = true
      sock_t = t
    end
  end
  return got
end

local function read_file(t)
  local f = io.open(LEVEL)
  if not f then return false end
  local seq, lb, lm, lt = f:read("*n", "*n", "*n", "*n"); f:close()
  if not seq or seq == last_file_seq then return false end
  local primed = last_file_seq ~= nil      -- первое чтение — только запоминаем (файл мог устареть)
  last_file_seq = seq
  if not primed then return false end
  file_t = t
  feed(lb or 0, lm or 0, lt or 0, 0.02, t)
  return true
end

---------------------------------------------------------------- лента: DRGB-кадр
local pkt, pkt_n = nil, 0
local cur, spark = nil, nil      -- сглаженный кадр (0..1, до гаммы) и искры
local vu_peak = 0                -- пиковая точка VU-метра (0..1, спадает 0.5/с)
local function draw_wled(dt, fade)
  local n = max(1, min(490, floor(cfg.wled_leds)))   -- DRGB вмещает до 490
  if n ~= pkt_n then
    pkt, pkt_n = ffi.new("uint8_t[?]", 2 + 3 * n), n
    cur, spark = ffi.new("float[?]", 3 * n), ffi.new("float[?]", n)
  end
  pkt[0], pkt[1] = 2, WLED_TIMEOUT
  local k = clamp(cfg.brightness, 0, 1) * 255
  local reach = 0.12 + 0.88 * env_b
  local sm = max(0.3, cfg.smooth)
  local a_up, a_dn = ease(0.010 * sm, dt), ease(0.060 * sm, dt)
  local sd = exp(-dt / (0.09 * sm))
  local sp = env_t * env_t * 0.04 * dt / 0.02
  local sat = 1 - 0.4 * flash
  local fw = 0.4 * flash
  local mode = cfg.mode                                   -- строку сравниваем один раз
  local mv = mode == "vu" and 1 or (mode == "pulse" and 2 or (mode == "spectrum" and 3 or 0))
  local mono = mode == "mono"
  local half = max(1, n - 1)
  local edge = 0.14                                       -- ширина мягкого края столба
  local vlen = clamp(0.65 * env_b + 0.35 * env_m, 0, 1)   -- длина столбика VU
  if mv == 1 then vu_peak = max(vu_peak - dt * 0.5, vlen) end
  local peak_w = 1.5 / n                                  -- полуширина пиковой точки
  local pulse_v = clamp(0.08 + 0.92 * env_b, 0, 1)        -- яркость pulse по басу
  for j = 0, n - 1 do
    local d = abs(j / half - 0.5) * 2                     -- 0 в центре, 1 на краях
    local r, g, bl, mask
    if mv == 1 then                                       -- vu: столбик от начала ленты
      local x = j / half                                  -- 0 в начале, 1 в конце
      local xm = clamp((vlen - x) / 0.04 + 0.5, 0, 1)     -- мягкий край столбика
      mask = xm * xm * (3 - 2 * xm)
      r, g, bl = hsv(120 - 120 * x, 1, mask)              -- зелёный → красный
      if vu_peak > 0.03 and abs(x - vu_peak) < peak_w then r, g, bl = 1, 1, 1 end   -- пиковая точка белая
    elseif mv == 2 then                                   -- pulse: вся лента одним цветом
      local v = pulse_v * (0.8 + 0.2 * math.cos((d * 2 - spin) * 2 * math.pi))
      r, g, bl = hsv(hue, sat, v)
      mask = 1
    elseif mv == 3 then                                   -- spectrum: три зоны от центра
      local wb = clamp((0.4 - d) / 0.15, 0, 1)            -- вес баса в центре
      local wt = clamp((d - 0.6) / 0.15, 0, 1)            -- вес верха на краях
      local wm = max(0, 1 - wb - wt)                      -- вес середины
      local e = wb * env_b + wm * env_m + wt * env_t
      r, g, bl = hsv(hue + wm * 120 + wt * 240, sat, e)
      mask = e
    else                                                  -- rainbow / mono (по умолчанию)
      local x = clamp((reach - d) / edge + 0.5, 0, 1)
      mask = x * x * (3 - 2 * x)                          -- smoothstep, без ступенек
      local wave = 0.55 + 0.45 * math.cos((d * 3 - spin) * 2 * math.pi)
      local h = mono and hue or (hue + d * 240)
      r, g, bl = hsv(h, sat, mask * wave)
    end
    local s = spark[j] * sd
    if math.random() < sp then s = 0.6 + 0.4 * math.random() end
    spark[j] = s
    local w = fw * mask + 0.7 * s
    r, g, bl = min(1, r + w) * fade, min(1, g + w) * fade, min(1, bl + w) * fade
    local o = 3 * j
    local c = cur[o];     cur[o]     = c + (r - c) * (r > c and a_up or a_dn)
    c = cur[o + 1];       cur[o + 1] = c + (g - c) * (g > c and a_up or a_dn)
    c = cur[o + 2];       cur[o + 2] = c + (bl - c) * (bl > c and a_up or a_dn)
    pkt[2 + o]     = floor(k * gamma_lut[floor(cur[o] * 1024)] + 0.5)
    pkt[2 + o + 1] = floor(k * gamma_lut[floor(cur[o + 1] * 1024)] + 0.5)
    pkt[2 + o + 2] = floor(k * gamma_lut[floor(cur[o + 2] * 1024)] + 0.5)
  end
  udp_wled(pkt, 2 + 3 * n)
end

local live = false               -- WLED сейчас в нашем realtime-режиме
local function release_live()    -- DRGB с таймаутом 0: WLED сразу выходит из live
  if not live then return end
  local p = ffi.new("uint8_t[5]", 2, 0, 0, 0, 0)
  udp_wled(p, 5)
  live = false
  if cur then ffi.fill(cur, 3 * pkt_n * ffi.sizeof("float")); ffi.fill(spark, pkt_n * ffi.sizeof("float")) end
end

---------------------------------------------------------------- лента: wled_fx
local fx = nil                   -- сохранённое состояние WLED: {on, bri, fx, sx, ix, pal, col}
local fx_t, fx_fail_t = 0, -100

local function udp_json(s) udp_wled(s, #s) end

local function parse_state(s)
  if not s or s == "" then return nil end
  local seg = s:match('"seg":%[(.*)')
  if not seg then return nil end
  local top = s:sub(1, #s - #seg)
  local st = {
    on = top:match('"on":(%a+)'), bri = tonumber(top:match('"bri":(%d+)')),
    fx = tonumber(seg:match('"fx":(%d+)')), sx = tonumber(seg:match('"sx":(%d+)')),
    ix = tonumber(seg:match('"ix":(%d+)')), pal = tonumber(seg:match('"pal":(%d+)')),
    col = seg:match('"col":(%b[])'),
  }
  if not (st.on and st.bri and st.fx and st.sx and st.ix and st.pal and st.col) then return nil end
  return st
end

local function restore_json(st)
  return string.format('{"on":%s,"bri":%d,"seg":[{"id":0,"fx":%d,"sx":%d,"ix":%d,"pal":%d,"col":%s}]}',
    st.on, st.bri, st.fx, st.sx, st.ix, st.pal, st.col)
end

local function fx_begin()
  local p = io.popen("/opt/bin/curl -s -m 2 http://" .. cfg.wled_ip .. "/json/state 2>/dev/null")
  local s = p and p:read("*a"); if p then p:close() end
  local st = parse_state(s)
  if not st then log("wled_fx: не удалось прочитать /json/state"); fx_fail_t = now(); return false end
  fx = st
  local f = io.open(SAVED, "w"); if f then f:write(restore_json(st)); f:close() end
  local extra = ""
  if tonumber(cfg.fx_id) and cfg.fx_id >= 0 then extra = extra .. ',"fx":' .. floor(cfg.fx_id) end
  if tonumber(cfg.fx_pal) and cfg.fx_pal >= 0 then extra = extra .. ',"pal":' .. floor(cfg.fx_pal) end
  udp_json('{"on":true,"tt":0,"seg":[{"id":0' .. extra .. '}]}')
  if DEBUG then log("wled_fx: начало, сохранено " .. restore_json(st)) end
  return true
end

local function fx_end()
  if not fx then return end
  udp_json(restore_json(fx))
  fx = nil
  os.remove(SAVED)
  if DEBUG then log("wled_fx: восстановлено") end
end

local function fx_send(fade)
  local base = fx.bri > 0 and fx.bri or 255
  local lvl = clamp(env_b * 0.9 + flash * 0.3, 0, 1)
  local fl = clamp(tonumber(cfg.fx_floor) or 0.2, 0, 1)
  lvl = (fl + (1 - fl) * lvl) * fade + (1 - fade)       -- после музыки плавно к исходной яркости
  local bri = max(1, floor(base * clamp(cfg.brightness, 0, 1) * gamma_lut[floor(lvl * 1024)] + 0.5))
  local s = '{"tt":0,"bri":' .. min(255, bri) .. ',"seg":[{"id":0'
  if cfg.fx_ix == 1 then
    s = s .. ',"ix":' .. floor(clamp(40 + 215 * (0.6 * env_t + 0.4 * env_m), 0, 255))
  end
  if cfg.fx_color == 1 then
    local r, g, b = hsv(hue, 1 - 0.4 * flash, 1)
    s = s .. string.format(',"col":[[%d,%d,%d]]', floor(r * 255), floor(g * 255), floor(b * 255))
  end
  udp_json(s .. "}]}")
end

---------------------------------------------------------------- главный цикл
local cfg_t, last_render = 0, now()
local stat_t = now()

load_cfg()
do  -- остался сохранённый стейт от прошлого запуска (упали посреди wled_fx) — вернуть
  local f = io.open(SAVED)
  if f then local s = f:read("*a"); f:close(); udp_json(s); os.remove(SAVED); log("wled_fx: восстановлено после перезапуска") end
end

while true do
  local t0 = now()
  if t0 - cfg_t > 1 then load_cfg(); cfg_t = t0 end
  alice_poll(t0)

  -- новые уровни: UDP от tap.lua, иначе (старый tap.lua) — файл
  local fresh = have_sock and read_socket(t0)
  if t0 - sock_t < 1 then last_file_seq = nil
  elseif not fresh then fresh = read_file(t0) end
  local file_mode = t0 - file_t < 1

  local playing = (t0 - last_loud_t < 0.3) and (t0 - last_data_t < 0.3)
  local tail = t0 - last_loud_t < HOLD_SEC            -- плавное затухание после музыки

  local interval = 1 / cfg.fps
  local due = t0 - last_render >= interval * (fresh and 0.85 or 1)
  if (playing or tail) and due then
    local dt = min(0.1, t0 - last_render)
    last_render = t0
    if t0 - last_data_t > 0.1 then                    -- данных нет: огибающие спадают сами
      env_b, env_m, env_t = env(env_b, 0, dt, 0.16), env(env_m, 0, dt, 0.2), env(env_t, 0, dt, 0.1)
    end
    flash = flash * exp(-dt / (0.12 * max(0.3, cfg.smooth)))
    local hk = hue_kick * ease(0.15, dt); hue_kick = hue_kick - hk
    hue = (hue + hk + (6 + 40 * env_m) * cfg.speed * dt) % 360
    spin = (spin + (0.3 + 2.5 * env_t) * cfg.speed * dt) % 1
    local fade = playing and 1 or clamp(1 - (t0 - last_loud_t - 0.3) / (HOLD_SEC - 0.3), 0, 1)

    -- лента
    if use_wled() and cfg.mode == "wled_fx" then
      release_live()
      if not fx and playing and t0 - fx_fail_t > 10 then fx_begin(); fx_t = 0 end
      if fx and t0 - fx_t >= 1 / cfg.fx_fps - 0.002 then fx_send(fade); fx_t = t0 end
    elseif use_wled() then
      fx_end()
      draw_wled(dt, fade); live = true
    else
      fx_end(); release_live()
    end
    if DEBUG and pending_tsend then
      local l = now() - pending_tsend
      lat_sum, lat_n, lat_max = lat_sum + l, lat_n + 1, max(lat_max, l)
      pending_tsend = nil
    end
  elseif not playing and not tail then
    -- тишина: отпускаем WLED сразу, без 2-секундного таймаута
    release_live()
    fx_end()
  end
  if fx and not (use_wled() and cfg.mode == "wled_fx") then fx_end() end

  if DEBUG and t0 - stat_t > 5 then
    if lat_n > 0 then log(string.format("tap->send: avg %.1f ms, max %.1f ms, n=%d", lat_sum / lat_n * 1000, lat_max * 1000, lat_n)) end
    lat_sum, lat_n, lat_max, stat_t = 0, 0, 0, t0
  end

  -- ждём данных или следующего кадра
  local wait
  if playing or tail then
    wait = interval - (now() - last_render)
    if file_mode or not have_sock then wait = min(wait, 0.004) end   -- старый tap.lua: опрос файла
  else
    wait = 0.05
  end
  if have_sock then
    C.poll(pfd, 1, max(1, floor(wait * 1000)))
  else
    C.poll(nil, 0, max(1, floor(wait * 1000)))
  end
end
