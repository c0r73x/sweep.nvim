-- Post-processing tests (FIM trimming, edit hunks near the cursor, truncation)
-- Run: nvim --headless --clean --cmd 'set rtp^=.' -l tests/postprocess_test.lua
local p = require('sweep.postprocess')
local fails = 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then print('ok   ' .. name)
  else fails = fails + 1; print('FAIL ' .. name .. '\n  got  ' .. vim.inspect(got) .. '\n  want ' .. vim.inspect(want)) end
end
-- FIM
eq('fim basic', p.post_process_fim(' x = 1\n', false, {'end'}, 4), ' x = 1')
eq('fim max lines', p.post_process_fim('a\nb\nc\nd\ne\nf', false, {}, 4), 'a\nb\nc\nd')
eq('fim truncated drops partial', p.post_process_fim('a\nb\npar', true, {}, 4), 'a\nb')
eq('fim suffix overlap next line', p.post_process_fim('foo()\n  bar()\nend\nx', false, {'', 'end', 'other'}, 4), 'foo()\n  bar()')
eq('fim no false cut on later suffix line', p.post_process_fim('if x then\n  y()\nend', false, {'z()', 'end'}, 4), 'if x then\n  y()\nend')
eq('fim keeps backticks', p.post_process_fim('```lua', false, {}, 4), '```lua')
eq('fim strips special', p.post_process_fim('abc<|endoftext|>', false, {}, 4), 'abc')
eq('should_stop lines', p.fim_should_stop('a\nb\nc\nd\ne', 4, nil), true)
eq('should_stop not yet', p.fim_should_stop('a\nb\nc\nd', 4, nil), false)
eq('should_stop overlap', p.fim_should_stop('a\nend\nx', 4, 'end'), true)
eq('should_stop partial overlap waits', p.fim_should_stop('a\nend', 4, 'end'), false)
-- edit
local cur = {'l1','l2','l3','l4','l5','l6','l7','l8','l9','l10','l11','l12','l13','l14','l15','l16','l17','l18','l19','l20','l21'}
local function upd(f) local t = vim.deepcopy(cur); f(t); return '\n' .. table.concat(t, '\n') .. '\n' end
eq('edit change near cursor', p.post_process_edit(upd(function(t) t[11] = 'L11' end), false, cur, 10, 8)[11], 'L11')
eq('edit no change -> nil', p.post_process_edit(upd(function() end), false, cur, 10, 8), nil)
eq('edit far change dropped', p.post_process_edit(upd(function(t) t[1] = 'L1' end), false, cur, 20, 8), nil)
local r = p.post_process_edit(upd(function(t) t[1] = 'L1'; t[20] = 'L20' end), false, cur, 19, 8)
eq('edit keeps only near hunk', {r[1], r[20]}, {'l1', 'L20'})
-- truncated: output stops at line 12 (partial), change at 11
local tr = '\n' .. table.concat({'l1','l2','l3','l4','l5','l6','l7','l8','l9','l10','L11','l1'}, '\n')
local rt = p.post_process_edit(tr, true, cur, 10, 8)
eq('edit truncated keeps tail', rt and #rt, 21)
eq('edit truncated change applied', rt and rt[11], 'L11')
eq('edit truncated tail only -> nil', p.post_process_edit('\nl1\nl2\nl', true, cur, 1, 8), nil)
-- big hunk spanning cursor but starting far above
local big = upd(function(t) for i = 1, 15 do t[i] = 'X' .. i end end)
eq('edit spanning hunk kept', p.post_process_edit(big, false, cur, 12, 2) ~= nil, true)
eq('edit empty output -> nil', p.post_process_edit('\n', false, cur, 10, 8), nil)
eq('edit fence kept', p.post_process_edit('\n```\nnew\n', false, {'```', 'old'}, 1, 8), {'```', 'new'})
-- insertion / deletion
local ins = p.post_process_edit(upd(function(t) table.insert(t, 11, 'NEW') end), false, cur, 10, 8)
eq('edit insertion', ins and {#ins, ins[11], ins[12]}, {22, 'NEW', 'l11'})
local del = p.post_process_edit(upd(function(t) table.remove(t, 11) end), false, cur, 10, 8)
eq('edit deletion', del and {#del, del[11]}, {20, 'l12'})
-- truncated after a model-inserted line: tail shift must not delete
local ti = '\n' .. table.concat({'l1','l2','l3','l4','l5','l6','l7','l8','l9','l10','NEW','l11','l12','l1'}, '\n')
local rti = p.post_process_edit(ti, true, cur, 10, 8)
eq('edit truncated insert', rti and {#rti, rti[11], rti[12], rti[22]}, {22, 'NEW', 'l11', 'l21'})
local td = '\n' .. table.concat({'l1','l2','l3','l4','l5','l6','l7','l8','l9','l10','l12','l13','l1'}, '\n')
local rtd = p.post_process_edit(td, true, cur, 10, 8)
eq('edit truncated delete', rtd and {#rtd, rtd[11], rtd[20]}, {20, 'l12', 'l21'})
print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
