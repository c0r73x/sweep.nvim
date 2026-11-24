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
    -- One word renamed in a short line: little text left in common, but
    -- still read in place
    { 'if (barfoo) {', 'if (isTrue) {', true },
    { 'barfoo', 'isTrue', true },
    { 'x = "日本"', 'x = "日"', true },
    -- Two words changed: not a rename
    { 'x = 1', 'y = 2', false },
    -- A word replaced by more than a word
    { 'if (barfoo) {', 'if (this.isTrue) {', false },
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

-- Replacements are drawn over the old text: what the screen shows is the
-- new line (old text left over is marked as deleted, extra new text is
-- inline)
local function render_line(old, new)
    api.nvim_buf_set_lines(buf, 0, -1, false, { '{', old, '}' })
    ui:show_edit({ '{', new, '}' }, { bufnr = buf, window_start = 1, current_lines = { '{', old, '}' }, line_num = 2, cursor_col = 0 })
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns_id, 0, -1, { details = true })) do
        local d = m[4]
        local kind = d.virt_text_pos or (d.virt_lines and 'lines') or (d.hl_group and 'del') or 'line_hl'
        local what = d.virt_text and d.virt_text[1][1] or d.virt_lines and d.virt_lines[1][1][1] or d.end_col
        table.insert(out, ('%s@%d:%s'):format(kind, m[3], what))
    end
    table.sort(out)
    vim.cmd('redraw')
    local screen = {}
    for c = 1, 40 do screen[c] = vim.fn.screenstring(2, c) end
    ui:hide()
    return out, table.concat(screen):gsub('%s+$', '')
end
local base = '        "baz": '
local cases = {
    { 'replace same width', base .. '"1.0.0"', base .. '"3.0.0"', { 'overlay@16:3' } },
    { 'replace shorter', base .. '"10.0.0"', base .. '"3.0.0"', { 'overlay@16:3' } },
    { 'replace longer', base .. '"1.0.0"', base .. '"12.0.0"', { 'inline@17:2', 'overlay@16:1' } },
    { 'shorter then insert', 'f(10, a)', 'f(3, a, b)', { 'inline@8:b', 'overlay@2:3' } },
    { 'insert then shorter', 'g(a, 10)', 'g(a, b, 3)', { 'inline@7: 3', 'overlay@5:b,' } },
    { 'wide characters', 'local title = "日本" -- heading', 'local title = "日" -- heading', { 'overlay@15:日' } },
    { 'tab before the change', '\tx = 10', '\tx = 2', { 'overlay@5:2' } },
    { 'rename', 'if (barfoo) {', 'if (isTrue) {', { 'overlay@4:isTrue' } },
    { 'rename longer', 'if (ok) {', 'if (enabled) {', { 'inline@6:abled', 'overlay@4:en' } },
}
-- Text that only moves in a shorter line is redrawn as preview text too;
-- the padding over the old line's end stays plain
api.nvim_buf_set_lines(buf, 0, -1, false, { '{', base .. '"12.0.0"', '}' })
ui:show_edit({ '{', base .. '"2.0.0"', '}' }, { bufnr = buf, window_start = 1,
    current_lines = { '{', base .. '"12.0.0"', '}' }, line_num = 2, cursor_col = 0 })
local over
for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns_id, 0, -1, { details = true })) do
    if m[4].virt_text_pos == 'overlay' then over = m[4].virt_text end
end
ui:hide()
check('moved text highlight', over, { { '2', 'SweepAddition' }, { '.0.0"', 'SweepAddition' }, { ' ' } })

for _, c in ipairs(cases) do
    local m, scr = render_line(c[2], c[3])
    if c[4] then check(c[1] .. ' marks', m, c[4]) end
    check(c[1] .. ' screen', scr, (c[3]:gsub('\t', string.rep(' ', vim.o.tabstop))))
end
-- A tab in the changed text has no fixed width: the old text is marked
-- and the new one inline
check('tab in change marks', render_line('a\t= 1', 'a = 1'), { 'del@1:2', 'inline@2: ' })

print(failed == 0 and 'diff tests: OK' or ('diff tests: %d failed'):format(failed))
vim.cmd(failed == 0 and 'qa!' or 'cq!')
