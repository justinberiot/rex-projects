# rex-projects

A [Rex](https://www.superlogical.com/rex) Lua script that adds **New Session in Project…** (`⌥⌘N`).

1. **Pick a project** from a list you keep, or choose **Add project…**. That opens a folder browser: Return on a repository adds it, Return on any other folder opens it, the first row adds the folder you're in, and typing a path jumps straight there.
2. **Pick where to work:** the current checkout, a worktree the project already has, or **New worktree…**. The choice you made last for a project is listed first next time.
3. For a new worktree, **name the branch**, then **pick what it starts from** (the current branch, the remote's default branch, or any local branch). An existing branch skips that last prompt.

Rex then opens a session in that folder. **Remove Project from List…** forgets a project without touching its folder.

## Install

Save `projects.lua` next to your `init.lua` (`~/.config/rex/` on macOS and Linux) and add this line to `init.lua`:

```lua
require("projects")
```

Servers older than control API revision 17 have no `rex.ui`; the script then does nothing.

## Configure

All settings are optional.

```lua
require("projects").setup{
  key       = "alt+cmd+n",        -- false binds no key
  worktrees = "~/.rex/worktrees", -- new worktrees go in <dir>/<project>/<branch>
  roots     = { "~/Code" },       -- folders whose repositories are listed without adding them
}
```

### Bare-repository layouts

A project kept as a bare repository with its checkouts beside it is detected and kept that way:

```
project/.bare        the repository
project/.git         "gitdir: .bare"
project/main         a worktree
project/feature-x    a worktree
```

New worktrees go in `project/<branch>` instead of the `worktrees` folder, whether you added `project` or one of its worktrees. The project folder itself has no files to work in, so it offers only its worktrees and **New worktree…**. Git's `worktree.useRelativePaths` setting is respected.

`REX_WORKTREES` and `REX_PROJECTS` set the worktree folder and one scan root when `setup` doesn't.

The project list and each project's last choice are kept in `projects.json` under your config folder (`$XDG_CONFIG_HOME/rex`, `~/.config/rex`, or `%APPDATA%\rex` on Windows).

## What it needs

- Git 2.x on the server's `PATH`. A folder that is not a repository still works, as a plain folder.
- The projects live on the machine that runs the Rex server. A session on another host is refused.
- Everything runs through `rex.exec` with argument lists, never a shell, so paths with spaces or quotes are safe.

Tested on macOS with Git 2.54. Windows and Linux code paths (`cmd`, `dir`, `%APPDATA%`) follow the same logic but have not been run.
