# svn-blame.nvim

This is a fork of [git-blame.nvim](https://github.com/f-person/git-blame.nvim) with the intention to support multiple version control systems (VCS).
To change the VCS, set `g:vcs` to one of the supported VCS.

```vim
:GitBlameDisable
:let g:vcs="..."
:GitBlameEnable
```
## Supported VCS

- `git` (default)
- `jj`, thanks to [entropitor](https://github.com/entropitor/jj-blame.nvim)

## Installation with `lazy.nvim`

```lua
{ "phazus/svn-blame.nvim", config = function() require("gitblame").setup({enabled = false}) end }
```
