-- Edit context alignment: the original window must cover the same lines as
-- the current window even after lines were inserted/deleted above it.
-- Run: nvim --headless --clean --cmd 'set rtp^=.' -l tests/buffer_test.lua
local api = vim.api
local BufferState = require('sweep.buffer')
local Config = require('sweep.config')

local config = Config():setup({})
local fails = 0
local function eq(name, got, want)
    if vim.deep_equal(got, want) then
        print('ok   ' .. name)
    else
        fails = fails + 1
        print('FAIL ' .. name .. '\n  got  ' .. vim.inspect(got) .. '\n  want ' .. vim.inspect(want))
    end
end

local function setup(n)
    local buf = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(buf)
    local lines = {}
    for i = 1, n do lines[i] = 'line ' .. i end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local bs = BufferState(config)
    bs:snapshot_original(buf)
    return buf, bs
end

local function changed(ctx)
    local out = {}
    for i = 1, math.max(#ctx.original_lines, #ctx.current_lines) do
        if ctx.original_lines[i] ~= ctx.current_lines[i] then
            table.insert(out, { i, ctx.original_lines[i], ctx.current_lines[i] })
        end
    end
    return out
end

-- 3 lines inserted at the top, then line 30 edited
local buf, bs = setup(60)
api.nvim_buf_set_lines(buf, 0, 0, false, { 'a', 'b', 'c' })
api.nvim_buf_set_lines(buf, 32, 33, false, { 'line 30 edited' })
api.nvim_win_set_cursor(0, { 33, 0 })
bs:update_state(buf)
local ctx = bs:get_context(buf, 'edit')
eq('insert above: only the edited line differs', changed(ctx), { { 11, 'line 30', 'line 30 edited' } })

-- 5 lines deleted above, then line 40 edited
buf, bs = setup(60)
api.nvim_buf_set_lines(buf, 2, 7, false, {})
api.nvim_buf_set_lines(buf, 34, 35, false, { 'line 40 edited' })
api.nvim_win_set_cursor(0, { 35, 0 })
bs:update_state(buf)
ctx = bs:get_context(buf, 'edit')
eq('delete above: only the edited line differs', changed(ctx), { { 11, 'line 40', 'line 40 edited' } })

-- a line inserted inside the window
buf, bs = setup(60)
api.nvim_buf_set_lines(buf, 30, 30, false, { 'new' })
api.nvim_win_set_cursor(0, { 31, 0 })
bs:update_state(buf)
ctx = bs:get_context(buf, 'edit')
eq('insert inside: original is one line shorter', #ctx.original_lines, #ctx.current_lines - 1)
eq('insert inside: diff is the insertion', vim.diff(table.concat(ctx.original_lines, '\n') .. '\n',
    table.concat(ctx.current_lines, '\n') .. '\n', { result_type = 'indices' }), { { 10, 0, 11, 1 } })

-- unchanged buffer: original is the current window
buf, bs = setup(30)
api.nvim_win_set_cursor(0, { 15, 0 })
bs:update_state(buf)
ctx = bs:get_context(buf, 'edit')
eq('unchanged', ctx.original_lines, ctx.current_lines)

-- forget
bs:forget(buf)
eq('forget', bs:get_context(buf, 'edit'), nil)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
