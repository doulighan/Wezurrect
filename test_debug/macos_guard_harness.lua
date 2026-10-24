local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local wezterm_stub = {
	target_triple = "x86_64-apple-darwin",
	GLOBAL = {},
	log_info = function() end, log_warn = function(m) print("WARN", m) end, log_error = function(m) print("ERR", m) end,
	nerdfonts = setmetatable({}, { __index = function() return "" end }),
	run_child_process = function(args)
		local parts = {}
		for _, a in ipairs(args) do table.insert(parts, q(a)) end
		local p = assert(io.popen(table.concat(parts, " ")))
		local out = p:read("a")
		return p:close() and true or false, out, ""
	end,
	time = { call_after = function() end },
	json_encode = function(t)
		local keys, parts = {}, {}
		for k in pairs(t) do table.insert(keys, k) end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local v = t[k]
			table.insert(parts, string.format("%q:%s", k, type(v) == "string" and string.format("%q", v) or tostring(v)))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end,
	json_parse = function(text)
		local t = {}
		for k, v in text:gmatch('"([^"]+)":("?[^,}"]*"?)') do
			t[k] = v:sub(1, 1) == '"' and v:sub(2, -2) or tonumber(v)
		end
		if not next(t) then error("bad json") end
		return t
	end,
	home_dir = os.getenv("HOME"),
}
package.loaded["wezterm"] = wezterm_stub
_G.wezterm = wezterm_stub
package.path = "./plugin/?.lua;./plugin/?/init.lua;" .. package.path
local guard = require("resurrect.restore_guard")

local fails = 0
local function check(name, cond) print((cond and "ok   " or "FAIL ") .. name); if not cond then fails = fails + 1 end end

-- 1. real control files
local snap = guard.get_snapshot(true)
check("real sessions: no error (" .. tostring(snap.error) .. ")", snap.error == nil)
for id, s in pairs(snap.sessions) do print("     ", id, s.state, s.pid) end
for _, r in ipairs(snap.records) do print("     proc_start", r.proc_start, "start_time", r.start_time) end
local live = 0
for _, s in pairs(snap.sessions) do if s.state == "live" then live = live + 1 end end
check("at least one live session found", live > 0)

-- 2. temp folders
local ROOT = os.tmpname(); os.remove(ROOT); os.execute("mkdir -p " .. q(ROOT .. "/ctl") .. " " .. q(ROOT .. "/no-restore"))
local function write(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end
local DEAD = "aaaaaaaa-1111-4111-8111-111111111111"
local MANGLED = "ffffffff-6666-4666-8666-666666666666"
write(ROOT .. "/ctl/4000000.json", '{"sessionId":"' .. DEAD .. '","pid":4000000,"procStart":"Sat Oct 24 00:31:04 2026","cwd":"/x"}')
-- our own shell is running; give it a procStart that does not parse -> unknown
local mypid = io.popen("echo $PPID"):read("l")
write(ROOT .. "/ctl/" .. mypid .. ".json", '{"sessionId":"' .. MANGLED .. '","pid":' .. mypid .. ',"procStart":"garbage","cwd":"/y"}')
write(ROOT .. "/no-restore/bbbbbbbb-2222-4222-8222-222222222222.json", '{"v":1,"sessionId":"x","by":"fleet park","reason":"parked"}')
write(ROOT .. "/no-restore/CCCCCCCC-3333-4333-8333-333333333333.JSON", "not json {")
os.execute("mkdir " .. q(ROOT .. "/no-restore/dddddddd-4444-4444-8444-444444444444.json"))
write(ROOT .. "/no-restore/eeeeeeee-5555-4555-8555-555555555555.json.tmp", "{}")
guard.control_dirs = function() return { ROOT .. "/ctl", ROOT .. "/nope" } end
guard.marker_dir = function() return ROOT .. "/no-restore" end
guard.claim_dir = function() return ROOT .. "/claims" end
guard._test.reset()
snap = guard.get_snapshot(true)
check("temp: no error (" .. tostring(snap.error) .. ")", snap.error == nil)
check("dead pid -> dead", snap.sessions[DEAD] and snap.sessions[DEAD].state == "dead")
check("running pid, bad procStart -> unknown", snap.sessions[MANGLED] and snap.sessions[MANGLED].state == "unknown")
check("parked marker read", snap.parked["bbbbbbbb-2222-4222-8222-222222222222"] and snap.parked["bbbbbbbb-2222-4222-8222-222222222222"].reason == "parked")
check("upper-case marker read", snap.parked["cccccccc-3333-4333-8333-333333333333"] ~= nil)
check("folder marker counted", snap.parked["dddddddd-4444-4444-8444-444444444444"] ~= nil)
check(".json.tmp ignored", snap.parked["eeeeeeee-5555-4555-8555-555555555555"] == nil)

guard.marker_dir = function() return ROOT .. "/absent" end
guard._test.reset()
check("absent marker folder -> no error", guard.get_snapshot(true).error == nil)
write(ROOT .. "/markerfile", "x")
guard.marker_dir = function() return ROOT .. "/markerfile" end
guard._test.reset()
check("marker path is a file -> error", (guard.get_snapshot(true).error or ""):find("not a folder") ~= nil)
guard.marker_dir = function() return ROOT .. "/absent" end
guard.control_dirs = function() return { ROOT .. "/nope" } end
guard._test.reset()
check("missing first control folder -> error", (guard.get_snapshot(true).error or ""):find("control directory not found") ~= nil)

-- 3. claims: os.rename would overwrite here; link must refuse
guard.control_dirs = function() return { ROOT .. "/ctl" } end
guard._test.reset()
os.execute("mkdir -p " .. q(ROOT .. "/claims"))
local ok1 = guard.check_command("claude --resume " .. DEAD, "/x", 7)
ok1 = ok1.allow; print("     check_command 1:", ok1)
local claim = io.open(ROOT .. "/claims/" .. DEAD)
check("first resume allowed", ok1 == true)
check("claim file created", claim ~= nil); if claim then claim:close() end
-- a second WezTerm process: its own GLOBAL, so its own owner and no local claims
wezterm_stub.GLOBAL = {}
guard._test.reset()
local r2 = guard.check_command("claude --resume " .. DEAD, "/x", 9)
local ok2, why2 = r2.allow, r2.reason
print("     check_command 2:", ok2, why2)
check("second process refused while the claim is fresh", ok2 ~= true)
os.execute("rm -rf " .. q(ROOT))
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
