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


-- Older drafts of the lines being changed now are left out
local t2 = EditTracker(config)
local function entry(b, line, old, new) return { bufnr = b, filepath = 'f', start_line = line, end_line = line, old_lines = { old }, new_lines = { new } } end
t2.edit_history = { entry(buf, 10, 'bab', 'baz'), entry(buf, 10, '3', '2'), entry(buf, 20, 'a', 'b'), entry(buf + 1, 10, 'x', 'y') }
eq('drafts of edited lines skipped', #t2:get_diff_sections(buf, nil, { { 10, 10 } }), 2)
eq('no spans keeps all', #t2:get_diff_sections(buf, nil, nil), 4)


-- A freshly opened file gets its history from its undofile, then from
-- uncommitted git changes the undo steps don't cover
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. '/undo', 'p')
vim.o.undodir = dir .. '/undo'
vim.o.undofile = true
local function sh(cmd) vim.fn.system(cmd); assert(vim.v.shell_error == 0, cmd) end
local path = dir .. '/f.lua'
vim.fn.writefile({ 'local a = 1', 'local b = 2', 'local c = 3', 'local d = 4' }, path)
sh({ 'git', '-C', dir, 'init', '-q' })
sh({ 'git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'x' })
sh({ 'git', '-C', dir, 'add', 'f.lua' })
sh({ 'git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'f' })
-- Changed outside Neovim: only git knows
vim.fn.writefile({ 'local a = 10', 'local b = 2', 'local c = 3', 'local d = 4' }, path)
vim.cmd('silent edit ' .. path)
local function step(row, text)
    api.nvim_buf_set_lines(0, row - 1, row, false, { text })
    vim.cmd('let &undolevels = &undolevels')
end
step(2, 'local b = 20')
step(4, 'local d = 5')
step(4, 'local d = 40')
vim.cmd('silent write')
vim.cmd('bwipeout')

local t3 = EditTracker(config)
vim.cmd('silent edit ' .. path)
local fbuf = api.nvim_get_current_buf()
eq('undo state of the buffer itself', vim.fn.undotree().seq_cur, 3)
t3:attach(fbuf)
vim.wait(5000, function() return #t3.edit_history >= 3 end, 20)
local got = {}
for _, e in ipairs(t3.edit_history) do table.insert(got, e.old_lines[1] .. ' -> ' .. e.new_lines[1]) end
eq('restored: git change, then undo steps oldest first, drafts merged', got,
    { 'local a = 1 -> local a = 10', 'local b = 2 -> local b = 20', 'local d = 4 -> local d = 40' })
eq('restored entries older than any snapshot', t3.edit_history[3].tick, 0)
eq('buffer untouched', { vim.fn.undotree().seq_cur, vim.bo[fbuf].modified }, { 3, false })
-- Not restored again, and not for a file with session edits
t3:restore_history(fbuf)
eq('restore once', #t3.edit_history, 3)
t3:shutdown()

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
