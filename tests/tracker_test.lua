-- Edit history in the prompt: edits to the current buffer made after the
-- original snapshot must not be repeated as diff sections (the model then
-- reads the change as done and predicts nothing).
-- Run: nvim --headless --clean --cmd 'set rtp^=.' -l tests/tracker_test.lua
local api = vim.api
local EditTracker = require('sweep.tracker')
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

local function new_buf(lines)
    local buf = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
end

local tracker = EditTracker(config)
local bs = BufferState(config)

local other = new_buf({ 'a = 1', 'b = 2' })
tracker:attach(other)
api.nvim_buf_set_lines(other, 0, 1, false, { 'a = 10' })

local buf = new_buf({ 'x = 1', 'y = 2', 'z = 3' })
tracker:attach(buf)
api.nvim_buf_set_lines(buf, 0, 1, false, { 'x = 10' })
-- Two seconds apart in the tracker's eyes, so they don't coalesce
tracker.edit_history[#tracker.edit_history].timestamp = 0

-- Snapshot (InsertEnter), then the edits of this insert session
bs:snapshot_original(buf)
api.nvim_buf_set_lines(buf, 1, 2, false, { 'y = 20' })
api.nvim_buf_set_lines(buf, 3, 3, false, { 'w = 4' })
eq('history has every edit', #tracker.edit_history, 4)

bs:update_state(buf)
local ctx = bs:get_context(buf, 'edit')
local sections = tracker:get_diff_sections(ctx.bufnr, ctx.original_tick)
eq('edits since snapshot left out', #sections, 2)
eq('other buffer edit kept', sections[1]:find('a = 10', 1, true) ~= nil, true)
eq('earlier edit kept', sections[2]:find('x = 10', 1, true) ~= nil, true)
eq('no snapshot keeps all', #tracker:get_diff_sections(buf, nil), 4)

-- After a snapshot with no change since, everything is history
bs:snapshot_original(buf)
bs:update_state(buf)
ctx = bs:get_context(buf, 'edit')
eq('fresh snapshot keeps all', #tracker:get_diff_sections(ctx.bufnr, ctx.original_tick), 4)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
