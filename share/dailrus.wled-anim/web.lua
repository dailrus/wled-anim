-- Веб-интерфейс WLED Animation: http://<станция>:8098 (порт — WLED_ANIM_PORT).
-- Однопоточный HTTP-сервер на сокетах LuaJIT: отдаёт index.html, читает и пишет
-- settings (только известные ключи, значения проверяются) и проксирует к WLED
-- несколько GET-запросов (/json/info|eff|pal|nodes) — браузеру не нужен CORS.
local ffi = require("ffi")
ffi.cdef[[
  typedef struct { uint16_t family; uint16_t port; uint32_t addr; uint8_t zero[8]; } sockaddr_in_t;
  struct pollfd { int fd; short events; short revents; };
  int socket(int domain, int type, int protocol);
  int setsockopt(int fd, int level, int name, const void *val, uint32_t len);
  int bind(int fd, const void *addr, uint32_t alen);
  int listen(int fd, int backlog);
  int accept(int fd, void *addr, void *alen);
  long recv(int fd, void *buf, size_t len, int flags);
  long send(int fd, const void *buf, size_t len, int flags);
  int close(int fd);
  int poll(struct pollfd *fds, unsigned long n, int timeout);
  uint16_t htons(uint16_t x);
]]
local C = ffi.C

local SHARE = os.getenv("WLED_ANIM_SHARE") or "/data/yam/share/dailrus.wled-anim"
local VAR = os.getenv("WLED_ANIM_VAR") or "/data/yam/var/wled_anim"
local SETTINGS = VAR .. "/settings"
local PORT = tonumber(os.getenv("WLED_ANIM_PORT") or "8098")
local CURL = "/opt/bin/curl"
local CALIB_PID = "/tmp/wled_anim/calib.pid"
local CALIB_SEC = 15

-- калибровка задержки: тестовый бит через штатный звук (идёт через отвод, как музыка)
local function calib_running()
  local f = io.open(CALIB_PID)
  local pid = f and tonumber(f:read("*l")); if f then f:close() end
  return pid and os.execute("kill -0 " .. pid .. " 2>/dev/null") == 0
end
local function calib_start()
  if calib_running() then return false end
  os.execute("(/opt/bin/luajit " .. SHARE .. "/testbeat.lua " .. CALIB_SEC ..
    " | aplay -q -f S16_LE -r 48000 -c 2) >/dev/null 2>&1 & echo $! >" .. CALIB_PID)
  return true
end

-- допустимые ключи settings: тип и границы
local SCHEMA = {
  output = { "enum", { wled = 1, off = 1 } },
  mode = { "enum", { rainbow = 1, mono = 1, vu = 1, pulse = 1, spectrum = 1, wled_fx = 1 } },
  wled_ip = { "ip" },
  wled_leds = { "int", 1, 490 },
  brightness = { "num", 0, 1 }, speed = { "num", 0, 5 }, delay_ms = { "int", 0, 300 },
  fps = { "int", 10, 100 }, gamma = { "num", 1, 3 }, smooth = { "num", 0, 3 },
  gate = { "num", 0, 0.5 }, alice_mute = { "int", 0, 1 },
  fx_id = { "int", -1, 255 }, fx_pal = { "int", -1, 255 },
  fx_color = { "int", 0, 1 }, fx_ix = { "int", 0, 1 },
  fx_floor = { "num", 0, 1 }, fx_fps = { "int", 5, 50 },
  mono_color = { "color" },             -- auto (по музыке) или rrggbb
  sensitivity = { "num", 0, 1 },
}

local function valid_ip(s)
  local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, x in ipairs({ a, b, c, d }) do if #x > 3 or tonumber(x) > 255 then return false end end
  return true
end

-- нормализованное значение или nil, ошибка
local function check(k, v)
  local s = SCHEMA[k]
  if not s then return nil, "неизвестный ключ " .. k end
  if s[1] == "enum" then
    if s[2][v] then return v end
  elseif s[1] == "ip" then
    if valid_ip(v) then return v end
  elseif s[1] == "color" then
    v = v:lower()
    if v == "auto" or v:match("^%x%x%x%x%x%x$") then return v end
  else
    local n = tonumber(v)
    if n and n == n and n >= s[2] and n <= s[3] then
      if s[1] == "int" then return tostring(math.floor(n + 0.5)) end
      return string.format("%g", n)
    end
  end
  return nil, "недопустимое значение " .. k .. "=" .. v
end

local function read_settings()
  local t = {}
  local f = io.open(SETTINGS)
  if not f then return t end
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
    if k and SCHEMA[k] then t[k] = v end
  end
  f:close()
  return t
end

-- правит строки key=value на месте (комментарии сохраняются), новые ключи — в конец
local function write_settings(upd)
  local lines, seen = {}, {}
  local f = io.open(SETTINGS)
  if f then
    for line in f:lines() do
      local k = line:match("^%s*([%w_]+)%s*=")
      if k and upd[k] then line = k .. "=" .. upd[k]; seen[k] = true end
      lines[#lines + 1] = line
    end
    f:close()
  end
  for k, v in pairs(upd) do if not seen[k] then lines[#lines + 1] = k .. "=" .. v end end
  local tmp = SETTINGS .. ".tmp"
  f = assert(io.open(tmp, "w"))
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  os.rename(tmp, SETTINGS)
end

local function json_str(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function settings_json()
  local parts = {}
  for k, v in pairs(read_settings()) do
    local ty = SCHEMA[k][1]
    local n = (ty == "num" or ty == "int") and tonumber(v)
    parts[#parts + 1] = json_str(k) .. ":" .. (n and tostring(n) or json_str(v))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function urldecode(s)
  return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse_form(s)
  local t = {}
  for pair in s:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=(.*)$")
    if k then t[urldecode(k)] = urldecode(v) end
  end
  return t
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

---------------------------------------------------------------- HTTP
local STATUS = { [200] = "OK", [400] = "Bad Request", [404] = "Not Found",
                 [405] = "Method Not Allowed", [502] = "Bad Gateway" }

local function send_all(fd, s)
  local off = 0
  while off < #s do
    local n = C.send(fd, ffi.cast("const char *", s) + off, #s - off, 0x4000)  -- MSG_NOSIGNAL
    if n <= 0 then return end
    off = off + n
  end
end

local function respond(fd, code, ctype, body)
  send_all(fd, string.format(
    "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
    code, STATUS[code] or "", ctype, #body) .. body)
end

local pfd = ffi.new("struct pollfd[1]")
local rbuf = ffi.new("char[4096]")

-- читает запрос целиком (заголовки + тело по Content-Length), не дольше ~3 с
local function read_request(fd)
  local data, deadline = "", os.time() + 3
  pfd[0].fd, pfd[0].events = fd, 1
  while #data < 65536 do
    local head_end = data:find("\r\n\r\n", 1, true)
    if head_end then
      local len = tonumber(data:sub(1, head_end):lower():match("content%-length:%s*(%d+)")) or 0
      if len > 16384 then return nil end
      if #data >= head_end + 3 + len then
        return data:sub(1, head_end - 1), data:sub(head_end + 4, head_end + 3 + len)
      end
    end
    if C.poll(pfd, 1, 2000) <= 0 or os.time() > deadline then return nil end
    local n = C.recv(fd, rbuf, 4096, 0)
    if n <= 0 then return nil end
    data = data .. ffi.string(rbuf, n)
  end
end

local WLED_PATHS = { info = "info", eff = "eff", pal = "pal", nodes = "nodes" }

local function handle(fd)
  local head, body = read_request(fd)
  if not head then return end
  local method, path = head:match("^(%u+) (%S+) HTTP")
  if not method then return respond(fd, 400, "text/plain", "bad request") end
  local route, query = path:match("^/([^?]*)%??(.*)$")

  if route == "" or route == "index.html" then
    local html = read_file(SHARE .. "/index.html") or "index.html not found"
    return respond(fd, 200, "text/html; charset=utf-8", html)

  elseif route == "api/settings" and method == "GET" then
    return respond(fd, 200, "application/json", '{"settings":' .. settings_json() .. "}")

  elseif route == "api/settings" and method == "POST" then
    local upd, n = {}, 0
    for k, v in pairs(parse_form(body or "")) do
      local val, err = check(k, v)
      if not val then return respond(fd, 400, "application/json", '{"ok":false,"error":' .. json_str(err) .. "}") end
      upd[k], n = val, n + 1
    end
    if n > 0 then write_settings(upd) end
    return respond(fd, 200, "application/json", '{"ok":true,"settings":' .. settings_json() .. "}")

  elseif route == "api/calibrate" and method == "POST" then
    local started = calib_start()
    return respond(fd, 200, "application/json",
      string.format('{"ok":true,"started":%s,"seconds":%d}', tostring(started), CALIB_SEC))

  elseif route == "api/wled" and method == "GET" then
    local q = parse_form(query or "")
    local ip, p = q.ip or "", WLED_PATHS[q.p or ""]
    if not valid_ip(ip) or not p then return respond(fd, 400, "application/json", '{"error":"bad ip or p"}') end
    -- ip и путь проверены выше: только цифры/точки и фиксированное слово
    local h = io.popen(CURL .. " -s -f -m 3 http://" .. ip .. "/json/" .. p .. " 2>/dev/null")
    local out = h and h:read("*a") or ""
    if h then h:close() end
    if out == "" then return respond(fd, 502, "application/json", '{"error":"WLED не отвечает"}') end
    return respond(fd, 200, "application/json", out)
  end
  return respond(fd, 404, "text/plain", "not found")
end

---------------------------------------------------------------- main
local srv = C.socket(2, 1, 0)                                   -- AF_INET, SOCK_STREAM
C.setsockopt(srv, 1, 2, ffi.new("int[1]", 1), 4)               -- SOL_SOCKET, SO_REUSEADDR
local addr = ffi.new("sockaddr_in_t")
addr.family, addr.port, addr.addr = 2, C.htons(PORT), 0         -- 0.0.0.0
assert(C.bind(srv, addr, ffi.sizeof(addr)) == 0, "bind :" .. PORT .. " не удался")
assert(C.listen(srv, 8) == 0, "listen не удался")

while true do
  local fd = C.accept(srv, nil, nil)
  if fd >= 0 then
    local ok, err = pcall(handle, fd)
    if not ok then io.stderr:write(os.date("%F %T "), "web.lua: ", tostring(err), "\n") end
    C.close(fd)
  end
end
