-- rex-projects: start a Rex session for a project.
--
-- The flow:
--   1. Pick a project from a list you keep (or add one by its folder).
--   2. Pick where to work: the current checkout, a worktree the project
--      already has, or a new worktree.
--   3. For a new worktree, name its branch and pick what to start from.
-- Then Rex opens a session in that folder. The last choice for each project
-- is listed first next time.
--
-- Projects on other hosts the app is connected to are listed too, when those
-- hosts run this script; their work is done there through projects_remote.
--
-- Install: put this file next to init.lua and add to init.lua
--
--     require("projects")
--
-- Optional settings, before or after the require:
--
--     require("projects").setup{
--       key       = "alt+cmd+n",        -- false to bind nothing
--       worktrees = "~/.rex/worktrees", -- where new worktrees are made,
--                                       -- except in a bare-repository
--                                       -- layout (project/.bare), where
--                                       -- they go beside the others
--       roots     = { "~/Code" },       -- folders whose repositories are
--                                       -- listed without being added
--     }
--
-- Written for Lua 5.1 (what Rex embeds) and for init.lua, which runs
-- unsandboxed on the server. Without io, the project list is kept only
-- until the server restarts, and the script says so in the log.

local M = {}

-- Servers before control API revision 17 have no rex.ui. Do nothing there
-- instead of failing the whole init.lua.
local has_ui, ui = pcall(function() return rex.ui end)
if not has_ui or ui == nil then
  return M
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- The settings. A call to M.setup replaces the ones it names.
local config = {
  key = "alt+cmd+n",
  worktrees = nil, -- nil means <home>/.rex/worktrees
  roots = {},
  state_file = nil, -- nil means <config dir>/rex/projects.json
}

-- The key that is bound now, so that setup can move it.
local bound_key = nil

---------------------------------------------------------------------------
-- Platform
---------------------------------------------------------------------------

-- The first character of package.config is the directory separator, and it
-- is a backslash only on Windows.
local is_windows = (package and package.config or "/"):sub(1, 1) == "\\"

-- env returns an environment variable, or nil when it is unset or empty, or
-- when this script has no os library.
local function env(name)
  if os == nil or os.getenv == nil then return nil end
  local value = os.getenv(name)
  if value == nil or value == "" then return nil end
  return value
end

local home = env("HOME") or env("USERPROFILE") or ""

-- slashes writes every separator as "/", which git and Windows both take.
local function slashes(path)
  return (path:gsub("\\", "/"))
end

-- expand writes a leading ~ as the home folder and trims blanks and quotes
-- that a pasted path carries.
local function expand(path)
  path = path:gsub("^%s+", ""):gsub("%s+$", "")
  path = path:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
  path = slashes(path)
  if path == "~" then return slashes(home) end
  if path:sub(1, 2) == "~/" then return slashes(home) .. path:sub(2) end
  return path
end

-- short writes the home folder at the start of path as ~.
local function short(path)
  local h = slashes(home)
  if h ~= "" and path:sub(1, #h + 1) == h .. "/" then
    return "~" .. path:sub(#h + 1)
  end
  return path
end

-- basename returns the last component of a slash-separated path.
local function basename(path)
  return (path:gsub("/+$", ""):match("([^/]+)$")) or path
end

-- trim removes blanks from both ends of s.
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- worktrees_dir is the folder that new worktrees are made in, as
-- <dir>/<project>/<branch>.
local function worktrees_dir()
  if config.worktrees then return expand(config.worktrees) end
  local from_env = env("REX_WORKTREES")
  if from_env then return expand(from_env) end
  return slashes(home) .. "/.rex/worktrees"
end

---------------------------------------------------------------------------
-- State: the project list and each project's last choice
---------------------------------------------------------------------------

-- state is { projects = { path, ... }, last = { [path] = choice } }, where a
-- choice is "current", a worktree's folder, or "new".
local state = nil

-- state_path returns where the state is kept, or nil when there is nowhere.
local function state_path()
  if config.state_file then return expand(config.state_file) end
  local base
  if is_windows then
    base = env("APPDATA")
  else
    base = env("XDG_CONFIG_HOME") or (home ~= "" and (home .. "/.config") or nil)
  end
  if base == nil then return nil end
  return slashes(base) .. "/rex/projects.json"
end

-- warned_memory_only keeps the log to one warning about a missing io library.
local warned_memory_only = false

-- load_state reads the state once and returns it. A missing or unreadable
-- file is an empty state: a corrupt list must never stop a session starting.
local function load_state()
  if state ~= nil then return state end
  state = { projects = {}, last = {} }
  local path = state_path()
  if io == nil or io.open == nil or path == nil then return state end
  local file = io.open(path, "r")
  if file == nil then return state end
  local text = file:read("*a")
  file:close()
  local ok, decoded = pcall(rex.json.decode, text)
  if ok and type(decoded) == "table" then
    -- Read each member by hand: a newer version of this file may hold more.
    if type(decoded.projects) == "table" then
      for _, p in ipairs(decoded.projects) do
        if type(p) == "string" then state.projects[#state.projects + 1] = p end
      end
    end
    if type(decoded.last) == "table" then
      for k, v in pairs(decoded.last) do
        if type(k) == "string" and type(v) == "string" then state.last[k] = v end
      end
    end
  end
  return state
end

-- save_state writes the state. It returns nothing and never raises: failing
-- to remember is not worth stopping a session for.
local function save_state()
  local path = state_path()
  if io == nil or io.open == nil or path == nil then
    if not warned_memory_only then
      warned_memory_only = true
      rex.log("warn", "projects: no place to save the project list; it lasts until the server restarts")
    end
    return
  end
  -- Make the folder first. mkdir -p exists on every Unix; Windows mkdir
  -- makes parents by itself and fails when the folder exists, which is fine.
  local dir = path:match("^(.*)/[^/]+$")
  if dir then
    if is_windows then
      rex.exec({ "cmd", "/c", "mkdir", (dir:gsub("/", "\\")) })
    else
      rex.exec({ "mkdir", "-p", dir })
    end
  end
  local file, err = io.open(path, "w")
  if file == nil then
    rex.log("warn", "projects: cannot save " .. path .. ": " .. tostring(err))
    return
  end
  file:write(rex.json.encode({ projects = state.projects, last = state.last }))
  file:close()
end

---------------------------------------------------------------------------
-- Git
---------------------------------------------------------------------------

-- git runs git in dir and returns what it printed, or nil and a message.
-- Arguments go as a list, never through a shell, so no quoting is needed.
local function git(dir, ...)
  local r, err = rex.exec({ "git", "-C", dir, ... })
  if r == nil then return nil, err end
  if not r.ok then
    local message = trim(r.stderr)
    return nil, message ~= "" and message or ("git exited with status " .. tostring(r.code))
  end
  return r.stdout
end

-- is_repo_root says whether dir is the top folder of a repository. It asks for
-- the way up to the top, which is empty at the top, instead of comparing paths:
-- git spells a symlinked folder (/tmp, a linked ~/Code) its own way.
local function is_repo_root(dir)
  local out = git(dir, "rev-parse", "--show-cdup")
  return out ~= nil and trim(out) == ""
end

-- current_branch returns the branch checked out in dir, or nil when HEAD is
-- detached or the repository has no commit yet.
local function current_branch(dir)
  local out = git(dir, "symbolic-ref", "--short", "-q", "HEAD")
  if out == nil then return nil end
  out = trim(out)
  return out ~= "" and out or nil
end

-- worktrees lists a project's checkouts, main one first, as
-- { path = ..., branch = ... or nil }. It returns nil for a folder that is
-- not a repository.
local function worktrees(project)
  local out = git(project, "worktree", "list", "--porcelain")
  if out == nil then return nil end
  local list = {}
  -- Each checkout is a paragraph of lines. Appending a blank line makes the
  -- last one end like the others.
  -- Take gsub's first result into a local before using it. A gsub call inside
  -- a ".." expression, with :gmatch called on the result, makes gopher-lua
  -- (the Lua in Rex) panic with a nil dereference.
  local text = out:gsub("\r", "")
  text = text .. "\n"
  for entry in text:gmatch("(.-)\n\n") do
    local path = entry:match("^worktree ([^\n]+)")
    if path then
      list[#list + 1] = {
        path = slashes(path),
        branch = entry:match("\nbranch refs/heads/([^\n]+)"),
        bare = entry:find("\nbare", 1, true) ~= nil,
        prunable = entry:find("\nprunable", 1, true) ~= nil,
      }
    end
  end
  return list
end

-- local_branches returns the names of the branches, newest commit first.
local function local_branches(project)
  local out = git(project, "for-each-ref", "--sort=-committerdate",
    "--format=%(refname:short)", "refs/heads")
  local names = {}
  if out == nil then return names end
  for line in out:gmatch("[^\r\n]+") do names[#names + 1] = line end
  return names
end

-- remote_default returns "origin/main" and the like, the branch that the
-- remote's HEAD names, or nil when there is none.
local function remote_default(project)
  local out = git(project, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")
  if out == nil then return nil end
  out = trim(out)
  return out ~= "" and out or nil
end

-- valid_branch_name says whether git accepts name as a branch name.
local function valid_branch_name(project, name)
  return git(project, "check-ref-format", "--branch", name) ~= nil
end

---------------------------------------------------------------------------
-- Projects
---------------------------------------------------------------------------

-- scan lists the repositories directly under each folder in config.roots,
-- as paths. Only folders are searched, one level down, so it stays quick.
local function scan()
  local found = {}
  local roots = config.roots
  local from_env = env("REX_PROJECTS")
  if from_env then
    roots = { from_env }
    for _, r in ipairs(config.roots) do roots[#roots + 1] = r end
  end
  for _, root in ipairs(roots) do
    root = expand(root)
    if is_windows then
      -- dir /b /ad lists folder names only.
      local r = rex.exec({ "cmd", "/c", "dir", "/b", "/ad", (root:gsub("/", "\\")) })
      if r ~= nil and r.ok then
        for name in r.stdout:gmatch("[^\r\n]+") do
          local path = root .. "/" .. name
          if is_repo_root(path) then found[#found + 1] = path end
        end
      end
    else
      -- A repository has a .git entry: a folder, or a file in a worktree.
      -- -print0 ends each path with NUL, the one byte a path cannot hold.
      local r = rex.exec({
        "find", root, "-mindepth", "2", "-maxdepth", "2", "-name", ".git", "-print0",
      })
      if r ~= nil and r.ok then
        for hit in r.stdout:gmatch("[^%z]+") do
          local path = hit:match("^(.*)/%.git$")
          if path then found[#found + 1] = path end
        end
      end
    end
  end
  return found
end

-- project_rows returns this machine's rows of the project picker: the added
-- projects and the scanned ones, sorted by name.
local function project_rows()
  local s = load_state()
  local seen, paths = {}, {}
  for _, p in ipairs(s.projects) do
    if not seen[p] then seen[p] = true; paths[#paths + 1] = p end
  end
  for _, p in ipairs(scan()) do
    if not seen[p] then seen[p] = true; paths[#paths + 1] = p end
  end
  table.sort(paths, function(a, b)
    return basename(a):lower() < basename(b):lower()
  end)
  local rows = {}
  for _, p in ipairs(paths) do
    rows[#rows + 1] = { id = p, title = basename(p), subtitle = short(p), icon = "folder" }
  end
  return rows
end

-- is_folder says whether path is a folder on this machine.
local function is_folder(path)
  if is_windows then
    -- A folder holds the NUL device on Windows; a file does not.
    local native = path:gsub("/", "\\")
    local r = rex.exec({ "cmd", "/c", "if", "exist", native .. "\\NUL", "echo", "yes" })
    return r ~= nil and r.ok and r.stdout:find("yes", 1, true) ~= nil
  end
  local r = rex.exec({ "test", "-d", path })
  return r ~= nil and r.ok
end

-- subfolders lists the folders directly inside dir as { path = ..., repo =
-- boolean }, sorted by name, hidden folders left out. It returns an empty list
-- for a folder it cannot read.
local function subfolders(dir)
  local list = {}
  if is_windows then
    -- dir /b /ad lists folder names only. Repositories are not marked: one
    -- git call for each folder would be slow, and Return then opens the
    -- folder, from where "Add" is one row away.
    local r = rex.exec({ "cmd", "/c", "dir", "/b", "/ad", (dir:gsub("/", "\\")) })
    if r ~= nil and r.ok then
      for name in r.stdout:gmatch("[^\r\n]+") do
        if name:sub(1, 1) ~= "." then
          local base = dir:gsub("/+$", "")
          list[#list + 1] = { path = base .. "/" .. name, repo = false }
        end
      end
    end
  else
    -- -print0 ends each path with NUL, the one byte a path cannot hold.
    local r = rex.exec({ "find", dir, "-mindepth", "1", "-maxdepth", "1", "-type", "d",
      "-not", "-name", ".*", "-print0" })
    local repos = {}
    local g = rex.exec({ "find", dir, "-mindepth", "2", "-maxdepth", "2", "-name", ".git", "-print0" })
    if g ~= nil and g.ok then
      for hit in g.stdout:gmatch("[^%z]+") do
        local path = hit:match("^(.*)/%.git$")
        if path then repos[path] = true end
      end
    end
    if r ~= nil and r.ok then
      for path in r.stdout:gmatch("[^%z]+") do
        list[#list + 1] = { path = path, repo = repos[path] == true }
      end
    end
  end
  table.sort(list, function(a, b) return basename(a.path):lower() < basename(b.path):lower() end)
  return list
end

-- parent_of returns the folder above dir, or nil at the top.
local function parent_of(dir)
  local parent = dir:match("^(.*)/[^/]+/?$")
  if parent == nil or parent == "" then
    -- "/x" has the parent "/"; "C:/x" has "C:/".
    if dir:match("^/[^/]+/?$") then return "/" end
    return nil
  end
  if parent:match("^%a:$") then return parent .. "/" end
  return parent
end

-- save_project adds path to the list, once, and returns it.
local function save_project(path)
  local s = load_state()
  for _, p in ipairs(s.projects) do
    if p == path then return path end
  end
  s.projects[#s.projects + 1] = path
  save_state()
  return path
end

---------------------------------------------------------------------------
-- Checkouts
---------------------------------------------------------------------------

-- NEW_WORKTREE and CURRENT are the ids of the rows that are not a folder.
-- The NUL byte keeps them apart from any real path.
local NEW_WORKTREE = "\0new"
local CURRENT = "\0current"

-- is_bare says whether dir is itself a bare repository: no files checked out,
-- only worktrees. The folder holding a .git file that points at a .bare
-- repository counts, because git opens the bare repository from there.
local function is_bare(dir)
  local out = git(dir, "rev-parse", "--is-bare-repository")
  return out ~= nil and trim(out) == "true"
end

-- bare_layout_root returns the folder that holds a repository's worktrees
-- side by side, or nil when the repository is not laid out that way. The
-- layout is a bare repository in a hidden folder (.bare, .git) with every
-- checkout beside it:
--
--     project/.bare  project/.git -> .bare  project/main  project/feature
--
-- It is found from the project folder or from any of its worktrees.
local function bare_layout_root(project)
  local bare = git(project, "config", "--bool", "core.bare")
  if bare == nil or trim(bare) ~= "true" then return nil end
  local common = git(project, "rev-parse", "--path-format=absolute", "--git-common-dir")
  if common == nil then return nil end
  common = slashes(trim(common)):gsub("/+$", "")
  -- A bare repository that is not hidden (project.git) sits among other
  -- folders; making worktrees beside it would scatter them.
  if basename(common):sub(1, 1) ~= "." then return nil end
  return parent_of(common)
end

-- checkout_rows returns the rows of the checkout picker, with the one that
-- was used last for project first. Its second result is the project's list of
-- worktrees, nil for a folder with no repository.
local function checkout_rows(project)
  local trees = worktrees(project)
  local rows = {}
  if trees == nil then
    rows[1] = { id = CURRENT, title = "Current folder", subtitle = short(project), icon = "folder" }
    return rows, nil
  end
  -- A bare repository has no files of its own to work in, so it gets no
  -- CURRENT row; its worktrees are the only checkouts.
  local top = nil
  if not is_bare(project) then
    local branch = current_branch(project)
    rows[#rows + 1] = {
      id = CURRENT,
      title = "Current checkout",
      subtitle = (branch or "detached HEAD") .. " · " .. short(project),
      icon = "folder",
    }
    -- Git's spelling of the project's folder, to leave it out of the list
    -- below: CURRENT already names it.
    local out = git(project, "rev-parse", "--show-toplevel")
    if out ~= nil then top = slashes(trim(out)) end
  end
  rows[#rows + 1] = { id = NEW_WORKTREE, title = "New worktree…", icon = "plus" }
  for i, tree in ipairs(trees) do
    -- Without a top folder, fall back to the first entry being the
    -- checkout that CURRENT names.
    local is_current = (top ~= nil and tree.path == top) or (top == nil and i == 1 and rows[1].id == CURRENT)
    if not is_current and not tree.bare and not tree.prunable then
      rows[#rows + 1] = {
        id = tree.path,
        title = tree.branch or basename(tree.path),
        subtitle = short(tree.path),
        icon = "branch",
      }
    end
  end
  local last = load_state().last[project]
  if last ~= nil then
    for i, row in ipairs(rows) do
      if row.id == last and i > 1 then
        table.remove(rows, i)
        table.insert(rows, 1, row)
        break
      end
    end
  end
  return rows, trees
end

-- base_rows returns the rows that say what a new branch starts from.
local function base_rows(project)
  local rows, seen = {}, {}
  local function add(ref, title, subtitle)
    if ref ~= nil and not seen[ref] then
      seen[ref] = true
      rows[#rows + 1] = { id = ref, title = title or ref, subtitle = subtitle, icon = "branch" }
    end
  end
  local branch = current_branch(project)
  -- A bare repository's HEAD is its default branch, not one being worked on.
  local label = is_bare(project) and "default branch" or "current branch"
  if branch then add(branch, branch, label) else add("HEAD", "HEAD", "detached") end
  -- origin's default branch, so a worktree can start from the remote's
  -- latest instead of a stale local branch.
  add(remote_default(project), nil, "remote default")
  for _, name in ipairs(local_branches(project)) do add(name) end
  return rows
end

-- add_worktree makes a worktree of project for branch, starting from base
-- when the branch is new. It returns the folder, or nil and a message.
local function add_worktree(project, branch, base)
  -- A branch name may hold slashes; a folder name may not.
  local folder = branch:gsub("[/\\:]", "-")
  local root = bare_layout_root(project)
  local dir = root and (root .. "/" .. folder)
    or (worktrees_dir() .. "/" .. basename(project) .. "/" .. folder)
  local exists = git(project, "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch)
  local _, err
  if exists then
    _, err = git(project, "worktree", "add", dir, branch)
  else
    _, err = git(project, "worktree", "add", "-b", branch, dir, base or "HEAD")
  end
  if err ~= nil then return nil, err end
  return dir
end

---------------------------------------------------------------------------
-- Operations: the work done on the machine that holds the projects
---------------------------------------------------------------------------

-- ops is everything the action does to a machine's files: git, folders and
-- the saved list. The action calls them directly for this machine, and
-- through the projects_remote action for another host. So each one takes and
-- returns plain data that survives JSON, and returns one value.
local ops = {}

-- REMOTE_ACTION is the action another machine's copy of this script calls
-- to run an op here.
local REMOTE_ACTION = "projects_remote"

-- remote_ctx is the ctx of the projects_remote call being answered, so that
-- an op can reach the client that asked: the app, relaying for another host.
local remote_ctx = nil

function ops.project_rows() return project_rows() end

-- ops.browse_start returns the folder the folder browser opens in.
function ops.browse_start()
  local dir = config.roots[1] and expand(config.roots[1])
    or env("REX_PROJECTS") and expand(env("REX_PROJECTS"))
    or slashes(home)
  if dir == "" or not is_folder(dir) then dir = "/" end
  return dir
end

-- ops.browse_page describes one page of the folder browser: the folder, its
-- parent, and the folders inside it.
function ops.browse_page(dir)
  dir = dir:gsub("/+$", "")
  if dir == "" then dir = "/" end
  local parent = parent_of(dir)
  return {
    dir = dir,
    name = dir == "/" and "/" or basename(dir),
    short = short(dir),
    parent = parent,
    parent_short = parent and short(parent),
    children = subfolders(dir),
  }
end

-- ops.resolve reads a path typed into the browser: where it points, and
-- whether that is a folder and a repository.
function ops.resolve(text)
  local path = expand(text or "")
  if path == "" then return { path = "" } end
  local folder = is_folder(path)
  return { path = path, folder = folder, repo = folder and is_repo_root(path) }
end

function ops.save_project(path) return save_project(path) end

function ops.checkout_rows(project)
  local rows, trees = checkout_rows(project)
  return { rows = rows, trees = trees }
end

function ops.valid_branch_name(project, name) return valid_branch_name(project, name) end

function ops.branch_exists(project, branch)
  return git(project, "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch) ~= nil
end

function ops.base_rows(project) return base_rows(project) end

function ops.add_worktree(project, branch, base)
  local dir, err = add_worktree(project, branch, base)
  return { dir = dir, err = err }
end

-- ops.remember saves where a project was last opened. A new worktree is
-- remembered as that worktree. Git may spell the folder differently from the
-- path made here (a symlink such as /tmp), and the picker's rows use git's
-- spelling, so the new worktree is looked up by its branch.
function ops.remember(project, choice, dir, branch)
  local remembered = choice
  if choice == NEW_WORKTREE then
    remembered = dir
    for _, tree in ipairs(worktrees(project) or {}) do
      if branch ~= nil and tree.branch == branch then remembered = tree.path end
    end
  end
  load_state().last[project] = remembered
  save_state()
  return true
end

-- ops.show_session asks the app to switch to a session on this machine.
-- When the action runs on another host, the app can't find this machine's
-- session by its ID there, but the app's own connection here, which relays
-- the call, can. It returns whether the app switched.
function ops.show_session(session_id)
  local client = remote_ctx and remote_ctx.client_id
  if client == nil then return false end
  local done = rex.call("client.perform", {
    client_id = client,
    action = "session.select",
    args = { session_id = session_id },
    timeout_ms = 5000,
  })
  return done ~= nil
end

function ops.saved_projects() return load_state().projects end

function ops.forget(project)
  local s = load_state()
  for i, p in ipairs(s.projects) do
    if p == project then table.remove(s.projects, i); break end
  end
  s.last[project] = nil
  save_state()
  return true
end

---------------------------------------------------------------------------
-- Hosts: this machine and the other Rex servers the app is connected to
---------------------------------------------------------------------------

-- this_name is what this machine is called next to other hosts' projects:
-- its host name without the domain.
local this_name_cache = nil
local function this_name()
  if this_name_cache ~= nil then return this_name_cache end
  local name = env("COMPUTERNAME")
  if name == nil then
    local r = rex.exec({ "uname", "-n" })
    name = r ~= nil and r.ok and trim(r.stdout) or ""
  end
  name = name:match("^[^.]*") or ""
  this_name_cache = name ~= "" and name or "this machine"
  return this_name_cache
end

-- A host is where projects live. host.call(op, ...) runs an op there and
-- returns its result; host.create_session makes a session there. label is
-- nil for this machine and the server's label for another host.
local function this_host()
  return {
    label = nil,
    name = this_name(),
    call = function(op, ...) return ops[op](...) end,
    create_session = function(spec) return rex.call("session.create", spec) end,
  }
end

local function other_host(label)
  local server = rex.server(label)
  return {
    label = label,
    name = label,
    call = function(op, ...)
      local res, err = server.call("client.action", {
        action = REMOTE_ACTION,
        args = { op = op, args = { ... }, n = select("#", ...) },
      })
      if res == nil then error(label .. ": " .. tostring(err), 0) end
      return res.result ~= nil and res.result.value or nil
    end,
    create_session = function(spec) return server.call("session.create", spec) end,
  }
end

-- reachable_hosts returns this machine and every other host the app is
-- connected to that runs this script, each with what first(host) returned.
-- A host that is away, or has no copy of the script, is left out.
local function reachable_hosts(first)
  local found = {}
  local candidates = { this_host() }
  local ok, labels = pcall(function() return rex.servers and rex.servers() or {} end)
  for _, label in ipairs(ok and labels or {}) do
    local made, host = pcall(other_host, label)
    if made then candidates[#candidates + 1] = host end
  end
  for _, host in ipairs(candidates) do
    local answered, value = pcall(first, host)
    if answered then
      found[#found + 1] = { host = host, value = value }
    else
      rex.log("info", "projects: leaving out " .. host.name .. ": " .. tostring(value))
    end
  end
  return found
end

---------------------------------------------------------------------------
-- The action
---------------------------------------------------------------------------

-- fail raises a one-line error that names the action.
local function fail(message)
  error("new_project_session: " .. tostring(message), 0)
end

-- add_project is a folder browser in the palette, over the folders of host.
-- Each page lists the folders inside one folder. Return on a repository adds
-- it, and on any other folder opens it. The first row adds the folder being
-- browsed, so a folder that is no repository can be a project too. Typing a
-- path and pressing Return on the last row jumps there, and a path that is a
-- repository is added. It returns the folder, or nil and why ("cancelled"
-- when the person gave up).
local ADD_HERE = "\0here"
local UP = "\0up"
local function add_project(host)
  local dir = host.call("browse_start")
  -- A folder tree is finite, but a typed path can loop; the cap keeps a
  -- script from asking forever.
  for _ = 1, 200 do
    local page = host.call("browse_page", dir)
    dir = page.dir
    local rows = {
      { id = ADD_HERE, title = "Add " .. page.name, subtitle = page.short, icon = "plus" },
    }
    if page.parent ~= nil then
      rows[#rows + 1] = { id = UP, title = "..", subtitle = page.parent_short, icon = "folder" }
    end
    local children = {}
    for _, child in ipairs(page.children or {}) do
      children[child.path] = child
      rows[#rows + 1] = { id = child.path, title = basename(child.path), icon = "folder" }
    end
    local picked, why = rex.ui.pick{
      title = host.label and ("Add project on " .. host.name) or "Add project",
      placeholder = page.short .. "/  (type a path to jump)",
      allow_other = true,
      items = rows,
    }
    if picked == nil then return nil, why end
    if type(picked) == "table" then
      -- The person typed a path instead of choosing a row.
      local typed = host.call("resolve", picked.text or "")
      if typed.path == "" then return nil, "cancelled" end
      if not typed.folder then return nil, "not a folder: " .. typed.path end
      if typed.repo then return host.call("save_project", typed.path) end
      dir = typed.path
    elseif picked == ADD_HERE then
      return host.call("save_project", dir)
    elseif picked == UP then
      dir = page.parent
    elseif children[picked] and children[picked].repo then
      return host.call("save_project", picked)
    else
      dir = picked
    end
  end
  return nil, "too many steps"
end

-- pick_project asks for a project among every host's, or for a new one. It
-- returns the host and the project's folder, or nil and why.
local ADD_PROJECT = "\0add"
local function pick_project()
  local listed = reachable_hosts(function(host) return host.call("project_rows") end)
  local several = #listed > 1
  local items, chosen = {}, {}
  for _, entry in ipairs(listed) do
    for _, row in ipairs(entry.value or {}) do
      local id = entry.host.label and (entry.host.label .. "\0" .. row.id) or row.id
      chosen[id] = { host = entry.host, project = row.id }
      items[#items + 1] = {
        id = id,
        title = row.title,
        subtitle = several and (entry.host.name .. " · " .. row.subtitle) or row.subtitle,
        icon = row.icon,
      }
    end
  end
  for i, entry in ipairs(listed) do
    local id = ADD_PROJECT .. tostring(i)
    chosen[id] = { host = entry.host, add = true }
    items[#items + 1] = {
      id = id,
      title = several and ("Add project on " .. entry.host.name .. "…") or "Add project…",
      subtitle = "Choose a folder",
      icon = "plus",
    }
  end
  local picked, why = rex.ui.pick{
    title = "New session",
    placeholder = "Choose a project",
    items = items,
  }
  if picked == nil then return nil, why end
  local choice = chosen[picked]
  if choice.add then
    local project
    project, why = add_project(choice.host)
    if project == nil then return nil, why end
    return choice.host, project
  end
  return choice.host, choice.project
end

-- run is the body of New Session in Project… The projects can be on this
-- machine or on any other host the app is connected to that runs this
-- script; the session starts on the host the project is on.
local function run(ctx)
  -- stop ends the action. A person who cancels is not worth a log line.
  local function stop(why)
    if why ~= "cancelled" then rex.log("warn", "new_project_session: " .. tostring(why)) end
  end

  -- 1. The project.
  local host, project = pick_project()
  if host == nil then return stop(project) end
  local name = basename(project)

  -- 2. The checkout.
  local listing = host.call("checkout_rows", project)
  local trees = listing.trees
  local choice, why = rex.ui.pick{
    title = name,
    placeholder = "Choose where to work",
    items = listing.rows,
  }
  if choice == nil then return stop(why) end

  local dir, label, branch = project, name, nil
  if choice == NEW_WORKTREE then
    -- 3. The branch, then what it starts from.
    branch, why = rex.ui.input{
      title = "New worktree in " .. name,
      placeholder = "Branch name",
      confirm = "Create worktree",
    }
    if branch == nil then return stop(why) end
    branch = trim(branch)
    if branch == "" then return end
    if not host.call("valid_branch_name", project, branch) then
      return stop("not a valid branch name: " .. branch)
    end
    -- An existing branch needs no base.
    local base
    if not host.call("branch_exists", project, branch) then
      base, why = rex.ui.pick{
        title = "Start " .. branch .. " from",
        placeholder = "Choose a base",
        items = host.call("base_rows", project),
      }
      if base == nil then return stop(why) end
    end
    local made = host.call("add_worktree", project, branch, base)
    if made.dir == nil then fail(made.err) end
    dir = made.dir
    label = name .. " · " .. branch
  elseif choice ~= CURRENT then
    dir = choice
    for _, tree in ipairs(trees or {}) do
      if tree.path == choice then
        label = name .. " · " .. (tree.branch or basename(choice))
      end
    end
  end

  host.call("remember", project, choice, dir, branch)

  local session, failed = host.create_session({
    label = label,
    initial_windows = { {
      window_label = "shell",
      layout = rex.layout.block{
        flavor = "com.superlogical.terminal.shell",
        options = { cwd = dir },
      },
    } },
  })
  if session == nil then error(failed, 0) end

  -- Creating a session does not show it. Ask the app to switch to it. A
  -- session on another host has to be shown from there.
  if host.label == nil then
    rex.client.queue("session.select", { session_id = session.session_id })
  else
    local asked, shown = pcall(host.call, "show_session", session.session_id)
    if not (asked and shown) then
      rex.log("warn", "new_project_session: could not switch to the new session on " .. host.name)
    end
  end
end

-- remove_run is the body of Remove Project from List….
local function remove_run()
  local listed = reachable_hosts(function(host) return host.call("saved_projects") end)
  local several = #listed > 1
  local items, chosen = {}, {}
  for _, entry in ipairs(listed) do
    for _, p in ipairs(entry.value or {}) do
      local id = entry.host.label and (entry.host.label .. "\0" .. p) or p
      chosen[id] = { host = entry.host, project = p }
      items[#items + 1] = {
        id = id,
        title = basename(p),
        -- short knows only this machine's home folder.
        subtitle = several and (entry.host.name .. " · " .. (entry.host.label and p or short(p))) or short(p),
        icon = "folder",
      }
    end
  end
  if #items == 0 then return end
  local picked = rex.ui.pick{
    title = "Remove project",
    placeholder = "Choose a project to forget (its folder stays)",
    items = items,
  }
  if picked == nil then return end
  chosen[picked].host.call("forget", chosen[picked].project)
end

rex.action{
  name = "new_project_session",
  title = "New Session in Project…",
  description = "Choose a project, then a checkout or a new worktree, and start a session there",
  category = "Projects",
  keywords = "worktree branch repository folder thread add project",
  run = run,
}

rex.action{
  name = "remove_project",
  title = "Remove Project from List…",
  description = "Forget a project that was added to the New Session picker",
  category = "Projects",
  keywords = "forget delete project list",
  run = remove_run,
}

-- projects_remote runs one op for New Session in Project… on another
-- machine, which reaches this one with rex.server(label).call.
rex.action{
  name = REMOTE_ACTION,
  title = "Projects: Answer Another Machine",
  description = "Used by New Session in Project… on another machine to reach this one's projects; not for running by hand",
  category = "Projects",
  run = function(ctx, args)
    local fn = ops[args.op]
    if fn == nil then error(REMOTE_ACTION .. ": unknown operation " .. tostring(args.op), 0) end
    local list = args.args or {}
    remote_ctx = ctx
    local ok, value = pcall(fn, unpack(list, 1, args.n or #list))
    remote_ctx = nil
    if not ok then error(value, 0) end
    return { value = value }
  end,
}

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

-- bind_key moves the key for New Session in Project… to key, or removes it
-- for false.
local function bind_key(key)
  -- Removing a binding works only while the file loads, which is when setup
  -- runs. pcall keeps a refusal from stopping the rest of init.lua.
  if bound_key ~= nil then pcall(rex.unbind, bound_key) end
  bound_key = nil
  if key then
    rex.bind(key, "new_project_session")
    bound_key = key
  end
end

-- M.setup changes the settings it is given and leaves the rest as they were.
function M.setup(opts)
  opts = opts or {}
  if opts.worktrees ~= nil then config.worktrees = opts.worktrees end
  if opts.roots ~= nil then config.roots = opts.roots end
  if opts.state_file ~= nil then config.state_file = opts.state_file; state = nil end
  if opts.key ~= nil then bind_key(opts.key) end
  return M
end

bind_key(config.key)

-- Pure helpers, for the tests in test/.
M._internal = {
  expand = expand, short = short, basename = basename, slashes = slashes,
  load_state = load_state, save_state = save_state, worktrees = worktrees,
  checkout_rows = checkout_rows, base_rows = base_rows, add_worktree = add_worktree,
  project_rows = project_rows, valid_branch_name = valid_branch_name,
  run = run, config = config, subfolders = subfolders, parent_of = parent_of, is_folder = is_folder,
  ops = ops, remove_run = remove_run,
  reset = function() state = nil end,
}

return M
