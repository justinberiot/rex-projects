# rex-projects

A [Rex](https://www.superlogical.com/rex) Lua script that adds **New Session in Project…** (`⌥⌘N`).

1. **Pick a project** from a list you keep, or choose **Add project…**. That opens a folder browser: Return on a repository adds it, Return on any other folder opens it, the first row adds the folder you're in, and typing a path jumps straight there.
2. **Pick where to work:** the current checkout, a worktree the project already has, or **New worktree…**. The choice you made last for a project is listed first next time.
3. For a new worktree, **name the branch**, then **pick what it starts from** (the current branch, the remote's default branch, or any local branch). An existing branch skips that last prompt.

Rex then opens a session in that folder, on the machine the project is on.

## Projects on several machines

Put the same `projects.lua` in the config of every machine you work on: say a Mac and a Linux server. The picker then lists the projects of every machine the app is connected to, each marked with its machine:

```
my-app     macbook · ~/Code/my-app
lagotta    vps · ~/src/lagotta/lagotta
Add project on macbook…
Add project on vps…
```

The action runs on the server whose shortcuts the app follows (`rex home`). It reaches the others with `rex.server(label)`, calling their `projects_remote` action, so their git, folders and project list stay on their side. A worktree is made there and the session starts there. A machine that is away, or has no copy of the script, is left out of the list. Every machine keeps its own project list and its own settings.

`projects_remote` shows up in the command palette as **Projects: Answer Another Machine**; it is only for the other copies to call. **Remove Project from List…** forgets a project without touching its folder.

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
- Projects are found on the machine that runs the Rex server and on every other host the app is connected to that runs this script too.
- Everything runs through `rex.exec` with argument lists, never a shell, so paths with spaces or quotes are safe.

Tested on macOS with Git 2.54. Windows and Linux code paths (`cmd`, `dir`, `%APPDATA%`) follow the same logic but have not been run.
