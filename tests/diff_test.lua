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

local function check(name, got, want)
    if not vim.deep_equal(got, want) then
        failed = failed + 1
        print(('FAIL %s: got %s want %s'):format(name, vim.inspect(got), vim.inspect(want)))
    end
end

-- Inline changes rebuild the new line from the old one
local function apply_inline(old, changes)
    local out, pos = {}, 0
    for _, c in ipairs(changes) do
        table.insert(out, old:sub(pos + 1, c.col))
        table.insert(out, c.text)
        pos = c.end_col
    end
    table.insert(out, old:sub(pos + 1))
    return table.concat(out)
end

local inline_cases = {
    { '        "baz": "2.0.0"', '        "baz": "2.0.0",', true },
    { 'foo(a, b)', 'foo(a, c, b)', true },
    { 'local a = foo(x)', 'local b = foo(y)', true },
    { 'låt x = "å"', 'låt y = "ä"', true },
    { '', '    foo()', true },
    { '    return x', '    if y then', false },
}
for i, c in ipairs(inline_cases) do
    local r = Diff.inline_changes(c[1], c[2])
    check('inline rebuild ' .. i, apply_inline(c[1], r.changes), c[2])
    check('inline score ' .. i, r.score >= 0.5, c[3])
end
check('inline comma', Diff.inline_changes(inline_cases[1][1], inline_cases[1][2]).changes,
    { { col = 22, end_col = 22, text = ',' } })

local function kinds(items)
    local out = {}
    for _, it in ipairs(items) do
        table.insert(out, ('%s:%s:%s'):format(it.kind, it.old or '-', it.new or '-'))
    end
    return out
end
local baz, baz2, qux = '"baz": "2.0.0"', '"baz": "2.0.0",', '"qux": "3.0.0"'
check('pair append', kinds(Diff.pair_lines({ baz }, { baz2, qux })), { 'pair:1:1', 'add:-:2' })
check('pair prepend', kinds(Diff.pair_lines({ baz }, { qux, baz2 })), { 'add:-:1', 'pair:1:2' })
check('pair none', kinds(Diff.pair_lines({ 'return x' }, { 'if y then' })), { 'delete:1:-', 'add:-:1' })

-- Preview of the reported case: only the comma inline, the new line below,
-- and nothing marked as deleted
local UI = require('sweep.ui')
local ui = UI(Config():setup({}))
local json = {
    '{',
    '    "package": "foo",',
    '    "version": "1.0.0",',
    '    "dependencies": {',
    '        "bar": "1.0.0",',
    '        "baz": "2.0.0"',
    '    }',
    '}',
}
local updated = vim.deepcopy(json)
updated[6] = '        "baz": "2.0.0",'
table.insert(updated, 7, '        "qux": "3.0.0"')
api.nvim_buf_set_lines(buf, 0, -1, false, json)
ui:show_edit(updated, { bufnr = buf, window_start = 1, current_lines = json, line_num = 6, cursor_col = 21 })
local marks = {}
for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns_id, 0, -1, { details = true })) do
    local d = m[4]
    table.insert(marks, {
        row = m[2], col = m[3], hl = d.hl_group,
        inline = d.virt_text and d.virt_text[1][1],
        lines = d.virt_lines and #d.virt_lines,
        line1 = d.virt_lines and d.virt_lines[1][1][1],
    })
end
table.sort(marks, function(x, y) return x.col > y.col end)
check('render json', marks, {
    { row = 5, col = 22, inline = ',' },
    { row = 5, col = 0, lines = 1, line1 = '        "qux": "3.0.0"' },
})
ui:hide()

print(failed == 0 and 'diff tests: OK' or ('diff tests: %d failed'):format(failed))
vim.cmd(failed == 0 and 'qa!' or 'cq!')
