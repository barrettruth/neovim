--- Provides 'autoread' via OS filewatchers: watches 'autoread' buffers for external changes using
--- vim._watch. Complements the existing FocusGained/:checktime approach.

local uv = vim.uv
local watch = vim._watch
local nvim_on = require('vim._core.util').nvim_on

local M = {}

local enabled = false
local debounce_ms = 100

---@class (private) nvim.autoread.Provider
---@field refresh fun(bufnr: integer, path: string)
---@field watch? fun(path: string, callback: vim._watch.Callback): fun()

---@class (private) nvim.autoread.State
---@field path string
---@field provider nvim.autoread.Provider

--- @type table<integer, fun()> bufnr -> cancel function
local watchers = {}
--- @type table<integer, uv.uv_timer_t> bufnr -> debounce timer
local timers = {}
--- @type table<integer, true> bufnr -> true. Tracks pending autoreads (debounce window, or provider refresh in flight),
--- so we can surface activity via the 'busy' flag.
local pending = {}
--- @type table<integer, true> bufnr -> true. Tracks which `pending` buffers have set 'busy'.
local pending_busy = {}

--- @private
--- Test-only: override the debounce window so tests can run faster.
--- @param ms integer
function M._set_debounce(ms)
  debounce_ms = ms
end

--- @private
--- @param bufnr integer
--- @return boolean
function M._is_watching(bufnr)
  return watchers[bufnr] ~= nil
end

--- Sets the 'busy' option on a `pending` buffer. Idempotent: if `pending` and `pending_busy`
--- already agree, it's a no-op. Must run on main thread.
---
--- @param bufnr integer
local function sync_busy(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    pending_busy[bufnr] = nil
    return
  end
  local want = pending[bufnr] ~= nil
  local have = pending_busy[bufnr] ~= nil
  if want == have then
    return
  end
  vim.bo[bufnr].busy = math.max(0, vim.bo[bufnr].busy + (want and 1 or -1))
  pending_busy[bufnr] = want or nil
end

--- Sends `pending` state for `bufnr`.
---
--- @param bufnr integer
--- @param is_pending boolean
local function set_pending(bufnr, is_pending)
  pending[bufnr] = is_pending or nil
  vim.schedule(function()
    sync_busy(bufnr)
  end)
end

--- Returns the effective 'autoread' value for a buffer.
--- 'autoread' is global-local: vim.bo[bufnr].autoread is nil when not set locally,
--- so we must fall back to the global value.
--- @param bufnr integer
--- @return boolean
local function buf_autoread(bufnr)
  local local_val = vim.bo[bufnr].autoread
  if local_val ~= nil then
    return local_val
  end
  return vim.go.autoread
end

--- @param bufnr integer
local function refresh_file(bufnr)
  -- :checktime may throw if the file was deleted (E211), or if reload triggers a buggy autocmd.
  local ok, err = pcall(vim.cmd.checktime, bufnr) ---@type any, any
  local file_missing = tostring(err):find('E211:', 1, true)
  if ok or file_missing then
    return
  end
  vim.api.nvim_echo({
    { ('autoread: :checktime failed for buffer %d: %s'):format(bufnr, err) },
  }, true, { err = true })
end

---@type nvim.autoread.Provider
local file_provider = { refresh = refresh_file }

---@param path string
---@param callback vim._watch.Callback
---@return fun()
local function watch_path(path, callback)
  return watch.watch(path, {}, callback)
end

--- Returns the effective autoread provider and path for a buffer.
--- @param bufnr integer
--- @return nvim.autoread.Provider? provider
--- @return string? path
local function get_provider(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) or not buf_autoread(bufnr) then
    return nil, nil
  end

  local state = vim.b[bufnr].nvim_autoread
  if type(state) == 'table' then
    ---@cast state nvim.autoread.State
    if state.path ~= '' and uv.fs_stat(state.path) then
      return state.provider, state.path
    end
    return nil, nil
  end

  -- Skip special buffers (terminal, help, quickfix, etc.)
  if vim.bo[bufnr].buftype ~= '' then
    return nil, nil
  end
  -- Must have a file name that exists on disk
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' or not uv.fs_stat(name) then
    return nil, nil
  end
  return file_provider, name
end

--- Stops and cleans up the watcher for a buffer.
--- @param bufnr integer
local function stop_watcher(bufnr)
  set_pending(bufnr, false)
  local cancel = watchers[bufnr]
  if cancel then
    cancel()
    watchers[bufnr] = nil
  end
  local timer = timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    timers[bufnr] = nil
  end
end

--- Ensures the buffer has an active file watcher if appropriate, or stops
--- an existing one if the buffer should no longer be watched.
--- @param bufnr integer
local function ensure_watcher(bufnr)
  stop_watcher(bufnr)

  local provider, path = get_provider(bufnr)
  if not provider or not path then
    return
  end

  local timer = assert(uv.new_timer())
  timers[bufnr] = timer
  local restart = false

  local cancel = (provider.watch or watch_path)(path, function(changed_path, change_type)
    -- Set the 'busy' buffer option for the duration of the pending cycle. This is a small, "best
    -- effort" UX hint, not intended to be noticeable except when filewatcher activity is "noisy".
    set_pending(bufnr, true)
    restart = restart or (changed_path == path and change_type ~= watch.FileChangeType.Changed)
    -- Debounce: restart the same timer on each event, so only the last
    -- event in a rapid series (e.g. truncate + write) triggers a refresh.
    timer:start(debounce_ms, 0, function()
      vim.schedule(function()
        if timers[bufnr] ~= timer then
          return
        end
        sync_busy(bufnr)

        local current_provider, current_path = get_provider(bufnr)
        if
          not current_provider
          or current_provider.refresh ~= provider.refresh
          or current_path ~= path
        then
          set_pending(bufnr, false)
          ensure_watcher(bufnr)
          return
        end

        local should_restart = restart
        restart = false
        local ok, err = pcall(provider.refresh, bufnr, path) ---@type boolean, any
        set_pending(bufnr, false)
        if should_restart or not uv.fs_stat(path) then
          ensure_watcher(bufnr)
        end
        if not ok then
          vim.api.nvim_echo({
            { ('autoread: provider failed to refresh buffer %d: %s'):format(bufnr, err) },
          }, true, { err = true })
        end
      end)
    end)
  end)

  watchers[bufnr] = cancel
end

--- Registers {provider} for {path} in {bufnr}.
--- @private
--- @param bufnr integer
--- @param path string
--- @param provider nvim.autoread.Provider
function M.register(bufnr, path, provider)
  bufnr = vim._resolve_bufnr(bufnr)
  vim.validate('path', path, 'string')
  vim.validate('provider', provider, 'table')
  vim.validate('provider.refresh', provider.refresh, 'function')
  vim.validate('provider.watch', provider.watch, 'function', true)
  vim.b[bufnr].nvim_autoread = {
    path = path,
    provider = provider,
  }
  if enabled then
    ensure_watcher(bufnr)
  end
end

--- Unregisters the provider for {bufnr}.
--- @private
--- @param bufnr integer
function M.unregister(bufnr)
  bufnr = vim._resolve_bufnr(bufnr)
  vim.b[bufnr].nvim_autoread = nil
  if enabled then
    ensure_watcher(bufnr)
  end
end

function M.enable()
  enabled = true
  local group = vim.api.nvim_create_augroup('nvim.autoread', { clear = true })

  -- (Re)start watcher when a file is loaded or written.
  nvim_on({ 'BufReadPost', 'BufWritePost' }, group, function(args)
    ensure_watcher(args.buf)
  end)

  nvim_on('BufEnter', group, function(args)
    if not watchers[args.buf] and type(vim.b[args.buf].nvim_autoread) == 'table' then
      ensure_watcher(args.buf)
    end
  end)

  -- Stop watcher when buffer is unloaded or wiped out.
  nvim_on({ 'BufUnload', 'BufWipeout' }, group, function(args)
    stop_watcher(args.buf)
  end)

  nvim_on('BufDelete', group, function(args)
    vim.b[args.buf].nvim_autoread = nil
  end)

  -- Clean up all watchers on exit to avoid dangling handles in the event loop.
  nvim_on('VimLeavePre', group, function()
    for bufnr in pairs(watchers) do
      stop_watcher(bufnr)
    end
  end)

  -- React to 'autoread' option changes.
  nvim_on('OptionSet', group, { pattern = 'autoread' }, function()
    if vim.v.option_type == 'global' then
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        ensure_watcher(bufnr)
      end
    else
      ensure_watcher(vim.api.nvim_get_current_buf())
    end
  end)

  -- Attach to buffers that were already loaded before enable() ran.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    ensure_watcher(bufnr)
  end
end

return M
