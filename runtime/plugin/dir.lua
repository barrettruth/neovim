local api = vim.api
local nvim_on = require('vim._core.util').nvim_on

vim.keymap.set('n', '<Plug>(nvim-dir-open)', function()
  require('nvim.dir')._open_entry()
end, { silent = true, desc = 'Open directory entry' })

vim.keymap.set('n', '<Plug>(nvim-dir-up)', function()
  require('nvim.dir')._open_parent()
end, { silent = true, desc = 'Open parent directory' })

vim.keymap.set('n', '<Plug>(nvim-dir-reload)', function()
  require('nvim.dir')._reload()
end, { silent = true, desc = 'Reload directory' })

if vim.fn.mapcheck('-', 'n') == '' and vim.fn.hasmapto('<Plug>(nvim-dir-up)', 'n') == 0 then
  vim.keymap.set('n', '-', '<Plug>(nvim-dir-up)', { silent = true, desc = 'Open parent directory' })
end

---@param buf integer
---@return boolean
local function should_open(buf)
  if not api.nvim_buf_is_valid(buf) then
    return false
  end
  local path = api.nvim_buf_get_name(buf)
  if path == '' then
    return false
  end
  if vim.bo[buf].buftype ~= '' and vim.b[buf].nvim_dir == nil then
    return false
  end
  if vim.bo[buf].filetype ~= 'directory' or vim.b[buf].netrw_curdir ~= nil then
    return false
  end
  return vim.fn.isdirectory(path) == 1
end

api.nvim_create_augroup('FileExplorer', { clear = true })
local group = api.nvim_create_augroup('nvim.dir', { clear = true })

nvim_on('FileType', group, {
  pattern = 'directory',
  desc = 'Open local directories',
  nested = true,
}, function(ev)
  if should_open(ev.buf) then
    require('nvim.dir').try_open(ev.buf, api.nvim_buf_get_name(ev.buf))
  end
end)
