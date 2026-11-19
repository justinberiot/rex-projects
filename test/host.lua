-- Runs the script's git and folder code inside Rex's own Lua (gopher-lua), which
-- differs from LuaJIT in ways that matter: a gsub call inside a ".." expression
-- followed by :gmatch once panicked it. Run with:  rex do test/host.lua
-- It needs git. It makes and removes a repository in a temporary folder.
local dir = (os.getenv("TMPDIR") or "/tmp") .. "/rex-projects-host-" .. os.time()
local function run(...)
  local r = rex.exec({ ... })
  assert(r and r.ok, "failed: " .. table.concat({ ... }, " "))
  return r
end
run("mkdir", "-p", dir .. "/repo")
run("git", "-C", dir .. "/repo", "init", "-q", "-b", "main")
run("git", "-C", dir .. "/repo", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i")
local here = debug and debug.getinfo and debug.getinfo(1, "S").source:match("^@(.*)/test/[^/]+$") or "."
local P = dofile(here .. "/projects.lua").setup{ state_file = dir .. "/state.json", worktrees = dir .. "/wt" }
local I = P._internal

local trees = I.worktrees(dir .. "/repo")
assert(#trees == 1 and trees[1].branch == "main", "one checkout on main")
local wt = I.add_worktree(dir .. "/repo", "feat/x", "main")
assert(wt == dir .. "/wt/repo/feat-x", "worktree folder: " .. tostring(wt))
assert(#I.worktrees(dir .. "/repo") == 2)
local rows = I.checkout_rows(dir .. "/repo")
assert(rows[1].title == "Current checkout" and #rows == 3, "rows: " .. #rows)
assert(#I.subfolders(dir) >= 2)
assert(I.base_rows(dir .. "/repo")[1].id == "main")

-- A bare repository in project/.bare, with project/.git pointing at it and
-- every checkout beside it.
local bare = dir .. "/layout"
run("git", "clone", "-q", "--bare", dir .. "/repo", bare .. "/.bare")
local gitfile = io.open(bare .. "/.git", "w"); gitfile:write("gitdir: .bare\n"); gitfile:close()
run("git", "-C", bare, "worktree", "add", "-q", bare .. "/main", "main")
local bt = I.add_worktree(bare, "feat/y", "main")
assert(bt == bare .. "/feat-y", "bare-layout worktree folder: " .. tostring(bt))
-- From a worktree of the layout, new worktrees still go beside the others.
local bt2 = I.add_worktree(bare .. "/main", "feat/z", "main")
assert(bt2 == bare .. "/feat-z", "bare-layout worktree from a worktree: " .. tostring(bt2))
local brows = I.checkout_rows(bare)
assert(brows[1].id ~= "\0current", "no current row for a bare project")
assert(#brows == 4, "new + main + feat/y + feat/z, got " .. #brows)
for _, row in ipairs(brows) do
  assert(row.id ~= bare .. "/.bare", "the bare repository is not a checkout")
end
assert(I.base_rows(bare)[1].subtitle == "default branch")
-- From the main worktree: CURRENT, new, and the two others, not main twice.
local mrows = I.checkout_rows(bare .. "/main")
assert(mrows[1].title == "Current checkout" and #mrows == 4, "worktree rows: " .. #mrows)

I.load_state().projects[1] = dir .. "/repo"; I.save_state(); I.reset()
assert(I.load_state().projects[1] == dir .. "/repo", "state round trip")
run("rm", "-rf", dir)
return "host ok"
