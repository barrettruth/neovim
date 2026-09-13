vim.pack.add({
    'https://github.com/nvimdev/guard.nvim',
    'https://github.com/nvimdev/guard-collection',
}, { confirm = false, load = true })

local ft = require('guard.filetype')

ft('lua'):fmt('stylua')
ft('sh,bash'):lint('shellcheck')
ft('cmake'):fmt('cmake-format')
ft('make'):lint('checkmake')
