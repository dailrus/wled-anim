-- Анализатор: stdin — копия звука из ALSA (raw S16_LE, 48 кГц, стерео).
-- Каждые 10 мс шлёт UDP-датаграмму на 127.0.0.1:21399 (её ждёт leds.lua, просыпается сразу):
--   "<счётчик> <бас> <середина> <верх> <время отправки, CLOCK_MONOTONIC>"
-- и раз в 20 мс дублирует первые четыре поля в /tmp/wled_anim/level (совместимость/отладка).
-- Уровни — RMS полос со сглаживанием энергии ~10–25 мс (без «фазового» дрожания баса).
local ffi = require("ffi")
ffi.cdef[[
  typedef struct { long tv_sec; long tv_nsec; } timespec_t;
  int clock_gettime(int clk, timespec_t *ts);
  typedef struct { uint16_t family; uint16_t port; uint32_t addr; uint8_t zero[8]; } sockaddr_in_t;
  int socket(int domain, int type, int protocol);
  long sendto(int fd, const void *buf, size_t len, int flags, const void *addr, uint32_t alen);
  uint32_t inet_addr(const char *cp);
  uint16_t htons(uint16_t x);
]]
local ts = ffi.new("timespec_t")
local function now() ffi.C.clock_gettime(1, ts); return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9 end

local RATE, CHUNK = 48000, 480                     -- 480 кадров = 10 мс
local CHUNK_MS = 1000 * CHUNK / RATE
-- ALSA-буфер опережает динамик: придерживаем уровни на DELAY чанков (по 10 мс).
-- Задаётся delay_ms в settings (перечитывается раз в секунду); WLED_ANIM_DELAY (в старых
-- 20-мс чанках) — приоритетнее.
local DELAY = 0
local SETTINGS = (os.getenv("WLED_ANIM_VAR") or "/data/yam/var/wled_anim") .. "/settings"
local DIR = "/tmp/wled_anim"
local OUT = DIR .. "/level"
local PORT = 21399

local function load_delay()
  local env = tonumber(os.getenv("WLED_ANIM_DELAY") or "")
  if env then DELAY = math.max(0, math.floor(env * 20 / CHUNK_MS + 0.5)); return end
  local f = io.open(SETTINGS)
  if not f then return end
  for line in f:lines() do
    local v = tonumber(line:match("^%s*delay_ms%s*=%s*(%S+)") or "")
    if v then DELAY = math.max(0, math.min(100, math.floor(v / CHUNK_MS + 0.5))) end
  end
  f:close()
end

local sock = ffi.C.socket(2, 2, 0)
local addr = ffi.new("sockaddr_in_t")
addr.family, addr.port, addr.addr = 2, ffi.C.htons(PORT), ffi.C.inet_addr("127.0.0.1")

local function coef(fc) return 1 - math.exp(-2 * math.pi * fc / RATE) end
local function tcoef(tau) return 1 - math.exp(-1 / (tau * RATE)) end
local a_lo, a_hi = coef(150), coef(2500)
local k_b, k_m, k_t = tcoef(0.020), tcoef(0.010), tcoef(0.006)   -- сглаживание энергии
local lo, mid_lp = 0, 0
local eb, em, et = 0, 0, 0
local queue, seq = {}, 0

local function publish(line)
  local s = line .. string.format(" %.4f", now())
  ffi.C.sendto(sock, s, #s, 0, addr, ffi.sizeof(addr))
  if seq % 2 == 0 then
    local f = io.open(OUT .. ".tmp", "w")
    if f then f:write(line); f:close(); os.rename(OUT .. ".tmp", OUT) end
  end
end

os.execute("mkdir -p " .. DIR)
while true do
  local s = io.stdin:read(CHUNK * 4)
  if not s or #s < 4 then break end
  local n = math.floor(#s / 4)
  local p = ffi.cast("const int16_t*", s)
  for i = 0, n - 1 do
    local x = (p[2 * i] + p[2 * i + 1]) * (1 / 65536)  -- моно, -1..1
    lo = lo + a_lo * (x - lo)
    mid_lp = mid_lp + a_hi * (x - mid_lp)
    local b, m, t = lo, mid_lp - lo, x - mid_lp
    eb = eb + k_b * (b * b - eb)
    em = em + k_m * (m * m - em)
    et = et + k_t * (t * t - et)
  end
  seq = seq + 1
  if seq % 30 == 1 then load_delay() end      -- раз в 0,3 с: ползунок задержки откликается сразу
  queue[#queue + 1] = string.format("%.5f %.5f %.5f", math.sqrt(eb), math.sqrt(em), math.sqrt(et))
  -- задержку уменьшили — выбрасываем лишнее из очереди
  while #queue > DELAY + 1 do table.remove(queue, 1) end
  if #queue > DELAY then
    publish(seq .. " " .. table.remove(queue, 1))
  end
end
