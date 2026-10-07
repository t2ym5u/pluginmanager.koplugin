-- Minimal KOReader + network stubs so main.lua can be driven headlessly
-- against a real on-disk sandbox. Not a spec (the .busted pattern is
-- "_spec%.lua$"), just the fixture test_bulk_install_spec.lua loads.
local H = {}
H.messages, H.queue, H.fetched = {}, {}, {}
H.server = {}            -- url -> body ; nil => 404

local function sh(cmd)
  local p = io.popen(cmd); local o = p:read("*a"); p:close(); return o
end
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- lfs ---------------------------------------------------------------------
local lfs = {}
function lfs.attributes(path, what)
  local t = sh(("if [ -d %s ]; then echo d; elif [ -e %s ]; then echo f; else echo n; fi")
               :format(q(path), q(path))):gsub("%s", "")
  if t == "n" then return nil end
  local mode = (t == "d") and "directory" or "file"
  if what == "mode" then return mode end
  return { mode = mode }
end
function lfs.dir(path)
  if lfs.attributes(path, "mode") ~= "directory" then error("not a dir: " .. path) end
  local out = sh(("ls -A %s 2>/dev/null"):format(q(path)))
  local entries = { ".", ".." }
  for line in out:gmatch("[^\n]+") do entries[#entries + 1] = line end
  local i = 0
  return function() i = i + 1; return entries[i] end
end
function lfs.mkdir(path) os.execute(("mkdir -p %s"):format(q(path))); return true end
package.preload["lfs"] = function() return lfs end

-- KOReader widgets --------------------------------------------------------
local function widget(name)
  return { new = function(self, o)
    o = o or {}
    if o.text then H.messages[#H.messages + 1] = { w = name, text = o.text } end
    o._widget = name
    return o
  end }
end
package.preload["ui/widget/infomessage"]  = function() return widget("InfoMessage") end
package.preload["ui/widget/confirmbox"]   = function() return widget("ConfirmBox") end
package.preload["ui/widget/buttondialog"] = function() return widget("ButtonDialog") end
package.preload["ui/widget/inputdialog"]  = function() return widget("InputDialog") end

package.preload["ui/uimanager"] = function()
  return {
    show = function() end, close = function() end,
    scheduleIn = function(_, _, fn) H.queue[#H.queue + 1] = fn end,
    nextTick   = function(_, fn)    H.queue[#H.queue + 1] = fn end,
    setDirty = function() end,
  }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
  local WC = {}
  WC.__index = WC
  function WC:extend(o)
    o = o or {}; o.__index = o
    return setmetatable(o, { __index = self, __call = function(c, ...) return c:new(...) end })
  end
  function WC:new(o) o = o or {}; setmetatable(o, self); return o end
  return WC
end
package.preload["datastorage"] = function()
  return { getPatchesDir   = function() return H.root .. "/patches" end,
           getSettingsDir  = function() return H.root .. "/settings" end,
           getDataDir      = function() return H.root end }
end
package.preload["luasettings"] = function()
  return { open = function(_, _)
    local store = {}
    return { readSetting = function(_, k) return store[k] end,
             saveSetting = function(_, k, v) store[k] = v end,
             delSetting  = function(_, k) store[k] = nil end,
             flush       = function() end }
  end }
end
package.preload["logger"] = function()
  local n = function() end
  return { warn = n, info = n, dbg = n, err = n }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
  return { template = function(s, ...) return string.format((s:gsub("%%%d", "%%s")), ...) end }
end

-- Network -----------------------------------------------------------------
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["ltn12"]  = function()
  return { sink = { table = function(t)
             return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
           end } }
end
package.preload["ssl.https"] = function()
  return { request = function(req)
    H.fetched[#H.fetched + 1] = req.url
    local body = H.server[req.url]
    if not body then return nil, 404 end
    req.sink(body); req.sink(nil)
    return 1, 200, {}
  end }
end

-- JSON --------------------------------------------------------------------
local function decode(s)
  local pos = 1
  local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local value
  local function str()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
        if e == "u" then
          out[#out + 1] = "?"; pos = pos + 6
        else
          out[#out + 1] = map[e] or e; pos = pos + 2
        end
      else
        out[#out + 1] = c; pos = pos + 1
      end
    end
    return table.concat(out)
  end
  value = function()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local o = {}
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return o end
      while true do
        skip(); local k = str(); skip(); pos = pos + 1  -- ':'
        o[k] = value(); skip()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return o end
      end
    elseif c == "[" then
      pos = pos + 1; local a = {}
      skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return a end
      while true do
        a[#a + 1] = value(); skip()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return a end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null"  then pos = pos + 4; return nil
    else
      local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      pos = pos + #n; return tonumber(n)
    end
  end
  return value()
end
package.preload["rapidjson"] = function() return { decode = decode, encode = function() return "{}" end } end

_G.G_reader_settings = { readSetting = function() return "fr" end, saveSetting = function() end }

function H.drain(limit)
  local n = 0
  while #H.queue > 0 and n < (limit or 10000) do
    local fn = table.remove(H.queue, 1)
    fn(); n = n + 1
  end
  return n
end
function H.texts()
  local t = {}
  for _, m in ipairs(H.messages) do t[#t + 1] = m.text end
  return t
end
return H
