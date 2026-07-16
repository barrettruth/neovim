if vim.nonnil(vim.b.diffhl, vim.g.diffhl, false) then
  pcall(vim.treesitter.start, 0, 'diff')
  vim.b.undo_ftplugin = (vim.b.undo_ftplugin or '') .. '\n lua pcall(vim.treesitter.stop, 0)'
end
