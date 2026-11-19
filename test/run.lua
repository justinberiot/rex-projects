-- Tests for projects.lua against a stand-in for the rex table and real git.
-- Run: luajit test/run.lua   (any Lua 5.1 works; needs git on PATH)

local function sh(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function capture(cmd)
  local p = io.popen(cmd .. " 2>/tmp/rex-projects-stderr; echo \"::$?\"")
  local out = p:read("*a"); p:close()
  local body, code = out:match("^(.*)::(%d+)\n$")
  local ef = io.open("/tmp/rex-projects-stderr"); local err = ef:read("*a"); ef:close()
  return body, tonumber(code), err
end

-- A JSON codec just big enough for { projects = {...}, last = {k = v} }.
local json = {}
function json.encode(v)
  local t = type(v)
  if t == "string" then return '"' .. v:gsub('[\\"]', "\\%0") .. '"' end
  if v == nil then return "null" end
  if t ~= "table" then return tostring(v) end
  if #v > 0 or next(v) == nil then
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = json.encode(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = json.encode(k) .. ":" .. json.encode(x) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function json.decode(s)
  local pos = 1
  local function ws() pos = s:find("%S", pos) or #s + 1 end
  local value
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == '"' then
      local out = {}
      pos = pos + 1
      while s:sub(pos, pos) ~= '"' do
        if s:sub(pos, pos) == "\\" then pos = pos + 1 end
        out[#out + 1] = s:sub(pos, pos); pos = pos + 1
      end
      pos = pos + 1
      return table.concat(out)
    elseif c == "[" then
      local list = {}; pos = pos + 1; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return list end
      while true do
        list[#list + 1] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return list end
      end
    elseif c == "{" then
      local obj = {}; pos = pos + 1; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        local k = value(); ws(); pos = pos + 1
        obj[k] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return obj end
      end
    end
    for word, v in pairs({ ["true"] = true, ["false"] = false }) do
      if s:sub(pos, pos + #word - 1) == word then pos = pos + #word; return v end
    end
    if s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
    local num = s:match("^-?%d+%.?%d*", pos)
    if num then pos = pos + #num; return tonumber(num) end
    error("bad json at " .. pos)
  end
  return value()
end

-- The scripted answers rex.ui gives, in order, and what it was asked.
local answers, asked, actions, binds, calls, queued = {}, {}, {}, {}, {}, {}
local function answer(x) answers[#answers + 1] = x end

rex = {
  json = json,
  log = function(level, msg) io.stderr:write("[" .. level .. "] " .. msg .. "\n") end,
  exec = function(argv)
    local parts = {}
    for _, a in ipairs(argv) do parts[#parts + 1] = sh(a) end
    local out, code, err = capture(table.concat(parts, " "))
    return { ok = code == 0, code = code, stdout = out, stderr = err }
  end,
  action = function(spec) actions[spec.name] = spec end,
  bind = function(key, name) binds[key] = name end,
  unbind = function(key) binds[key] = nil end,
  ui = {
    pick = function(spec)
      asked[#asked + 1] = spec
      local a = table.remove(answers, 1)
      if a == nil then return nil, "cancelled" end
      if type(a) == "table" then return a end -- typed text, as allow_other gives
      -- A string answer is matched against a row's title or id; a function
      -- answer picks the first row it accepts.
      if type(a) == "function" then
        for _, row in ipairs(spec.items) do if a(row) then return row.id end end
        error("no matching row in " .. spec.title)
      end
      for _, row in ipairs(spec.items) do
        if row.title == a or row.id == a then return row.id end
      end
      error("no row " .. tostring(a) .. " in " .. spec.title)
    end,
    input = function(spec)
      asked[#asked + 1] = spec
      local a = table.remove(answers, 1)
      if a == nil then return nil, "cancelled" end
      return a
    end,
  },
  layout = { block = function(t) return t end },
  call = function(method, args) calls[#calls + 1] = { method, args }; return { session_id = "s1" } end,
  client = { queue = function(m, a) queued[#queued + 1] = { m, a } end },
}

local tmp = os.tmpname(); os.remove(tmp); os.execute("mkdir -p " .. sh(tmp))
local function git(dir, ...)
  local a = { "git", "-C", dir, ... }
  for i, v in ipairs(a) do a[i] = sh(v) end
  local _, code = capture(table.concat(a, " "))
  assert(code == 0, "git failed: " .. table.concat(a, " "))
end
local repo = tmp .. "/code/my-app"
os.execute("mkdir -p " .. sh(repo))
git(repo, "init", "-q", "-b", "main")
git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
git(repo, "branch", "feature-x")
os.execute("mkdir -p " .. sh(tmp .. "/plain"))

package.loaded.projects = nil
local P = dofile("projects.lua").setup{
  worktrees = tmp .. "/wt",
  state_file = tmp .. "/state/projects.json",
  roots = {},
}
local I = P._internal
assert(binds["alt+cmd+n"] == "new_project_session", "default key bound")
P.setup{ key = "ctrl+alt+p" }
assert(binds["alt+cmd+n"] == nil and binds["ctrl+alt+p"] == "new_project_session", "key moves")

local n = 0
local function test(name, fn)
  n = n + 1
  asked, calls, queued = {}, {}, {}
  local ok, err = pcall(fn)
  print((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ("\n     " .. tostring(err))))
  if not ok then os.exit(1) end
end

test("path helpers", function()
  assert(I.expand("  ~/x  ") == I.slashes(os.getenv("HOME") or os.getenv("USERPROFILE")) .. "/x")
  assert(I.expand('"/a/b"') == "/a/b")
  assert(I.expand("C:\\Users\\me") == "C:/Users/me")
  assert(I.basename("/a/b/") == "b")
end)

test("add a project, then it is listed and persisted", function()
  answers = { "Add project…", { text = repo }, "Current checkout" }
  I.run({})
  assert(#calls == 1, "session created")
  assert(calls[1][2].initial_windows[1].layout.options.cwd == repo, "cwd is the repo")
  assert(calls[1][2].label == "my-app")
  local f = io.open(tmp .. "/state/projects.json"); local text = f:read("*a"); f:close()
  assert(text:find("my-app", 1, true), "state file written: " .. text)
  I.reset()
  local rows = I.project_rows()
  assert(rows[1].title == "my-app" and #rows == 1)
end)

test("a folder that is not a repository still starts a session", function()
  answers = { "Add project…", { text = tmp .. "/plain" }, "Add plain", "Current folder" }
  I.run({})
  assert(calls[1][2].initial_windows[1].layout.options.cwd == tmp .. "/plain")
end)

test("a path that is not a folder is refused without a session", function()
  answers = { "Add project…", { text = tmp .. "/missing" } }
  I.run({})
  assert(#calls == 0)
end)

test("the browser lists folders alike, and Return on one adds it", function()
  answers = { "Add project…", { text = tmp .. "/code" } }
  I.run({})
  local page = asked[3]
  assert(page.allow_other, "typing a path is allowed")
  assert(page.items[1].title == "Add code", "first row adds the folder: " .. page.items[1].title)
  assert(page.items[2].title == "..", "second row goes up")
  local row
  for _, r in ipairs(page.items) do if r.title == "my-app" then row = r end end
  assert(row and row.icon == "folder" and row.detail == nil, "every folder looks alike")
  -- Choose the repository: it is added and the flow moves on to the checkout.
  answers = { "Add project…", { text = tmp .. "/code" }, "my-app", "Current checkout" }
  asked, calls = {}, {}
  I.run({})
  assert(calls[1][2].initial_windows[1].layout.options.cwd == repo)
end)

test("Return on a plain folder opens it and .. goes back up", function()
  answers = { "Add project…", { text = tmp }, "code", ".." , { text = tmp .. "/missing" } }
  I.run({})
  assert(#calls == 0)
  -- Page 3 lists tmp, page 4 lists code, page 5 is tmp again after "..".
  assert(asked[4].placeholder:find("code", 1, true))
  assert(asked[5].items[1].title == "Add " .. I.basename(tmp))
end)

test("new worktree from a base creates branch, folder and session", function()
  answers = { "my-app", "New worktree…", "feat/login", "main" }
  I.run({})
  local want = tmp .. "/wt/my-app/feat-login"
  assert(calls[1][2].initial_windows[1].layout.options.cwd == want, tostring(calls[1][2].initial_windows[1].layout.options.cwd))
  assert(calls[1][2].label == "my-app · feat/login")
  assert(queued[1][1] == "session.select")
  local trees = I.worktrees(repo)
  assert(#trees == 2 and trees[2].branch == "feat/login")
end)

test("an existing branch needs no base prompt", function()
  answers = { "my-app", "New worktree…", "feature-x" }
  I.run({})
  assert(#asked == 3, "project, checkout, name only; got " .. #asked)
  assert(#calls == 1)
end)

test("existing worktrees are listed and the last choice comes first", function()
  local rows = I.checkout_rows(repo)
  assert(rows[1].title == "feature-x", "last used first: " .. rows[1].title)
  answers = { "my-app", "feat/login" }
  I.run({})
  assert(calls[1][2].label == "my-app · feat/login")
end)

test("base rows lead with the current branch and skip duplicates", function()
  local rows = I.base_rows(repo)
  assert(rows[1].id == "main")
  local seen = {}
  for _, r in ipairs(rows) do assert(not seen[r.id]); seen[r.id] = true end
end)

test("an invalid branch name is refused before anything is made", function()
  answers = { "my-app", "New worktree…", "bad..name" }
  I.run({})
  assert(#calls == 0)
end)

test("cancelling at any step creates nothing", function()
  answers = { "my-app" }
  I.run({})
  assert(#calls == 0)
end)

test("a session on another host still opens this machine's projects", function()
  answers = { "my-app", "Current checkout" }
  I.run({ server = "studio" })
  assert(#calls == 1 and calls[1][2].initial_windows[1].layout.options.cwd == repo)
end)

-- Another host is a second copy of the script reached through rex.server.
-- Here it loops back to this one's projects_remote action, through JSON as
-- the real call goes, and records its own calls.
local function with_studio(fn)
  local remote_calls = {}
  rex.servers = function() return { "studio" } end
  rex.server = function(label)
    assert(label == "studio")
    return { call = function(method, args)
      remote_calls[#remote_calls + 1] = { method, args }
      if method == "client.action" then
        assert(args.action == "projects_remote")
        local wire = json.decode(json.encode(args.args))
        local result = actions.projects_remote.run({ client_id = "app-on-studio" }, wire)
        return { result = json.decode(json.encode(result)) }
      end
      return { session_id = "remote-s1" }
    end }
  end
  local ok, err = pcall(fn, remote_calls)
  rex.servers, rex.server = nil, nil
  if not ok then error(err, 0) end
end

test("another host's projects are listed by host and open there", function()
  with_studio(function(remote_calls)
    local on_studio = function(row) return row.title == "my-app" and row.subtitle:find("^studio · ") ~= nil end
    answers = { on_studio, "New worktree…", "feat/remote", "main" }
    I.run({})
    local items = asked[1].items
    -- Each project twice, once for each host, then one add row each.
    assert(items[#items].title == "Add project on studio…", items[#items].title)
    assert(items[1].subtitle:find(" · ", 1, true), "host named: " .. items[1].subtitle)
    for _, c in ipairs(calls) do assert(c[1] ~= "session.create", "nothing made on this machine") end
    local create = remote_calls[#remote_calls]
    local create
    for _, c in ipairs(remote_calls) do if c[1] == "session.create" then create = c end end
    assert(create, "session made on studio")
    assert(create[2].initial_windows[1].layout.options.cwd == tmp .. "/wt/my-app/feat-remote")
    -- The switch goes through studio to the app's connection there: an ID from
    -- studio means nothing to this machine's server.
    assert(#queued == 0, "no session.select queued here")
    local perform = calls[#calls]
    assert(perform[1] == "client.perform" and perform[2].client_id == "app-on-studio", tostring(perform[1]))
    assert(perform[2].args.session_id == "remote-s1")
  end)
end)

test("a host that does not answer is left out", function()
  rex.servers = function() return { "away" } end
  rex.server = function() return { call = function() return nil, "unreachable" end } end
  answers = { "my-app", "Current checkout" }
  local ok, err = pcall(I.run, {})
  rex.servers, rex.server = nil, nil
  assert(ok, tostring(err))
  assert(asked[1].items[#asked[1].items].title == "Add project…")
  for _, row in ipairs(asked[1].items) do assert(not row.subtitle:find("away", 1, true)) end
end)

test("remove a project from another host", function()
  with_studio(function()
    local before = #I.load_state().projects
    answers = { function(row) return row.title == "plain" and row.subtitle:find("^studio · ") ~= nil end }
    I.remove_run()
    assert(#asked[1].items == 2 * before, "each host's list: " .. #asked[1].items)
  end)
  I.reset()
  for _, p in ipairs(I.load_state().projects) do assert(I.basename(p) ~= "plain", "forgotten through the other host") end
  I.reset()
end)

test("a corrupt state file is an empty list", function()
  local f = io.open(tmp .. "/state/projects.json", "w"); f:write("{not json"); f:close()
  I.reset()
  assert(#I.load_state().projects == 0)
end)

os.execute("rm -rf " .. sh(tmp))
print(n .. " passed")
