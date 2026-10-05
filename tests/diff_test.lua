-- Diff / apply_update regression test (pure insertions used to be anchored
-- on the new-side index and land in the wrong place).
-- Run: nvim --headless --clean --cmd 'set rtp^=.' -l tests/diff_test.lua
local api = vim.api
local Diff = require('sweep.diff')
local BufferState = require('sweep.buffer')
local Config = require('sweep.config')

local cases = {
    { { 'a', 'b', 'c', 'd' }, { 'a', 'c', 'd', 'Z' } }, -- delete + append
    { { 'a', 'b', 'c' }, { 'X', 'a', 'b', 'c' } },      -- insert at top
    { { 'a', 'b', 'c' }, { 'a', 'X', 'b', 'c' } },      -- insert in middle
    { { 'a', 'b', 'c' }, { 'a', 'b', 'c', 'X', 'Y' } }, -- append
    { { 'a', 'b', 'c' }, { 'a', 'c' } },                -- delete
    { { 'a', 'b', 'c' }, { 'a', 'X', 'c' } },           -- replace
    { { 'a', 'b', 'c', 'd', 'e' }, { 'Q', 'b', 'R', 'S', 'd' } },
    { { 'a', 'a', 'b' }, { 'a', 'b', 'a', 'b' } },
}

local bs = BufferState(Config():setup({}))
local buf = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(buf)
local failed = 0

for i, c in ipairs(cases) do
    local old, new = c[1], c[2]
    local applied = Diff.apply(old, Diff.diff(old, new).hunks)
    if not vim.deep_equal(applied, new) then
        failed = failed + 1
        print(('FAIL Diff.apply %d: got %s'):format(i, vim.inspect(applied)))
    end

    -- Window starting at buffer line 3, with lines around it
    local lines = { 'p1', 'p2' }
    vim.list_extend(lines, old)
    vim.list_extend(lines, { 's1', 's2' })
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    bs:apply_update(buf, {
        bufnr = buf, window_start = 3, current_lines = old,
        changedtick = api.nvim_buf_get_changedtick(buf),
    }, new)
    local want = { 'p1', 'p2' }
    vim.list_extend(want, new)
    vim.list_extend(want, { 's1', 's2' })
    local got = api.nvim_buf_get_lines(buf, 0, -1, false)
    if not vim.deep_equal(got, want) then
        failed = failed + 1
        print(('FAIL apply_update %d: got %s'):format(i, vim.inspect(got)))
    end
end

print(failed == 0 and 'diff tests: OK' or ('diff tests: %d failed'):format(failed))
vim.cmd(failed == 0 and 'qa!' or 'cq!')
