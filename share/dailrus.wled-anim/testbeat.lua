-- Тестовый сигнал для калибровки задержки: ровный бит 120 BPM без тонов и свипов.
-- Удар — затухающий синус 100 Гц (басовая полоса анализатора, слышен из динамика Mini)
-- плюс щелчок 4 мс в самом начале, чтобы на слух было точно понятно, где удар.
-- Аргумент — длительность в секундах. Выход: raw S16_LE 48 кГц стерео в stdout.
local RATE, SEC = 48000, tonumber(arg and arg[1]) or 6
local PERIOD = 0.5                                     -- 120 BPM
local out = {}
for n = 0, RATE * SEC - 1 do
  local tb = (n / RATE) % PERIOD                       -- время от начала удара
  local body = math.sin(2 * math.pi * 100 * tb) * math.exp(-tb * 30)
  local click = tb < 0.004 and (math.random() * 2 - 1) * math.exp(-tb * 900) or 0
  local v = math.floor((0.7 * body + 0.35 * click) * 26000)
  local lo, hi = v % 256, math.floor(v / 256) % 256
  local s = string.char(lo, hi)
  out[#out + 1] = s .. s
  if #out >= 4800 then io.write(table.concat(out)); out = {} end
end
io.write(table.concat(out))
