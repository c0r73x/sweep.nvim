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

-- c, s and o change the text before Insert mode starts: the original is
-- the text before that change when the typed text continues it (one undo
-- step), not the text Insert mode started with
local group = api.nvim_create_augroup('tracker_test', { clear = true })
api.nvim_create_autocmd('InsertEnter', { group = group, callback = function()
    local b = api.nvim_get_current_buf()
    bs:snapshot_original(b, tracker:step_before(b))
end })
api.nvim_create_autocmd('InsertLeave', { group = group, callback = function()
    bs:settle_original(api.nvim_get_current_buf())
end })
local function keys(k)
    api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), 'xt', false)
end
local function original(b)
    bs:update_state(b)
    local c = bs:get_context(b, 'edit')
    return c.original_lines, c
end

buf = new_buf({ "console.log('a');", "console.log('b');" })
tracker:attach(buf)
api.nvim_win_set_cursor(0, { 1, 9 })
keys('ciwwarn<Esc>')
local orig
orig, ctx = original(buf)
eq('ciw: word before the change', orig[1], "console.log('a');")
eq('ciw: edit not repeated as history', #tracker:get_diff_sections(buf, ctx.original_tick), 4)

-- Entering Insert mode again without a change keeps the typed text
keys('A<Esc>')
eq('A after ciw: typed text stays', original(buf)[1], "console.warn('a');")

buf = new_buf({ 'a', 'b' })
tracker:attach(buf)
keys('1Goc<Esc>')
eq('o: without the opened line', original(buf), { 'a', 'b' })

buf = new_buf({ 'a', 'b', 'c' })
tracker:attach(buf)
keys('2Gdd')
keys('ix<Esc>')
eq('dd then i: dd is not part of the insert', original(buf), { 'a', 'c' })

buf = new_buf({ 'one two' })
tracker:attach(buf)
keys('1G0cw<Esc>')
eq('cw without typing: the deleted word', original(buf), { 'one two' })

buf = new_buf({ 'x = 1', 'y = 2' })
tracker:attach(buf)
keys('2GSy = 3<Esc>')
eq('S: line before the change', original(buf), { 'x = 1', 'y = 2' })

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
