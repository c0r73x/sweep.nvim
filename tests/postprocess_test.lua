-- Post-processing tests (FIM trimming, edit hunks near the cursor, truncation)
-- Run: nvim --headless --clean --cmd 'set rtp^=.' -l tests/postprocess_test.lua
local p = require('sweep.postprocess')
local fails = 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then print('ok   ' .. name)
  else fails = fails + 1; print('FAIL ' .. name .. '\n  got  ' .. vim.inspect(got) .. '\n  want ' .. vim.inspect(want)) end
end
-- FIM
local function sc(before, after, below, max) return p.fim_scope(before, after, below, max or 8) end
local blk = sc('local x = ', '', {'print(x)'})
eq('scope mid-line', sc('foo(', ')', {}).kind, 'line')
eq('scope eol with body below', sc('if x then', '', {'  y()'}).kind, 'line')
eq('scope empty line at block end', sc('  ', '', {'', 'end'}).kind, 'body')
eq('scope empty line at eof', sc('  ', '', {}).kind, 'body')
eq('scope empty line mid-block', sc('  ', '', {'  y()'}).kind, 'block')
eq('scope typed line at eof', sc('x', '', {}).kind, 'block')
eq('fim basic', p.post_process_fim(' x = 1\n', false, blk), ' x = 1')
eq('fim default scope', p.post_process_fim(' x = 1\n', false), ' x = 1')
eq('fim mid-line one line', p.post_process_fim('a, b)\nfoo()', false, sc('f(', ')', {})), 'a, b)')
eq('fim stops at next statement', p.post_process_fim('1\nprint(x)\nmore', false, blk), '1')
eq('fim block with closer', p.post_process_fim(' foo()\n  bar()\nend\nx = 1', false, sc('function', '', {'y()'})), ' foo()\n  bar()\nend')
eq('fim block else', p.post_process_fim(' x then\n  a()\nelse\n  b()\nend\nz()', false, sc('if', '', {})), ' x then\n  a()\nelse\n  b()\nend')
eq('fim rust closer', p.post_process_fim(' {\n    a();\n}\nfn g() {}', false, sc('fn f()', '', {})), ' {\n    a();\n}')
eq('fim end_line is not a closer', p.post_process_fim('1\nend_line = 2', false, blk), '1')
eq('fim endif closer', p.post_process_fim(' x then\n  a()\nend\n', false, sc('if', '', {})), ' x then\n  a()\nend')
eq('fim python dedent', p.post_process_fim('\n    return 1\nx = f()', false, sc('def f():', '', {})), '\n    return 1')
local eol = sc('  a()', '', {'  z()'})
eq('fim eol json next entry', p.post_process_fim('\n        "qux": "3.0.0"\n', false, sc('        "baz": "4.0.0",', '', {'    }', '}'})), '\n        "qux": "3.0.0"')
eq('fim eol mid-block one statement', p.post_process_fim('\n  b()\n  z()', false, eol), '\n  b()')
eq('fim eol mid-block statement with block', p.post_process_fim('\n  if x then\n    y()\n  end\n  z()', false, eol), '\n  if x then\n    y()\n  end')
eq('fim eol at block end continues', p.post_process_fim('\n  b()\n  c()\nend', false, sc('  a()', '', {'end'})), '\n  b()\n  c()')
eq('fim eol last line of block', p.post_process_fim('\n  end', false, sc('    s = s + 1', '', {'  end'})), '')
eq('fim eol cap skips blank start', p.post_process_fim('\n  b()\n  c()\n  d()', false, sc('  a()', '', {}, 2)), '\n  b()\n  c()')
eq('should_stop eol after statement', p.fim_should_stop('\n  b()\n  z()\n', eol), true)
eq('should_stop eol first statement', p.fim_should_stop('\n  b()\n', eol), false)
eq('fim body stops at dedent', p.post_process_fim('a()\n  b()\nend\nfoo()', false, sc('  ', '', {'end'})), 'a()\n  b()')
eq('fim body keeps blank lines', p.post_process_fim('a()\n\n  b()\n\n', false, sc('  ', '', {})), 'a()\n\n  b()')
eq('fim max lines', p.post_process_fim('a\n  b\n  c\n  d', false, sc('  ', '', {}, 3)), 'a\n  b\n  c')
eq('fim truncated drops partial', p.post_process_fim('a\n  b\n  pa', true, sc('  ', '', {})), 'a\n  b')
eq('fim keeps backticks', p.post_process_fim('```lua', false, blk), '```lua')
eq('fim strips special', p.post_process_fim('abc<|endoftext|>', false, blk), 'abc')
eq('should_stop mid-line at newline', p.fim_should_stop('a, b)\n', sc('f(', ')', {})), true)
eq('should_stop mid-line not yet', p.fim_should_stop('a, b)', sc('f(', ')', {})), false)
eq('should_stop next statement', p.fim_should_stop('1\nprint(x)\n', blk), true)
eq('should_stop waits for the line', p.fim_should_stop('1\nprint(x', blk), false)
eq('should_stop dedent on partial line', p.fim_should_stop('a()\nen', sc('  ', '', {'end'})), true)
eq('should_stop blank partial waits', p.fim_should_stop('a()\n ', sc('  ', '', {'end'})), false)
eq('should_stop cap', p.fim_should_stop('a\n  b\n  c\n  ', sc('  ', '', {}, 3)), true)
eq('should_stop body continues', p.fim_should_stop('a\n  b\n  c', sc('  ', '', {})), false)
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

-- Hunks that undo the user's change are dropped
local function json(v10, v13)
  local t = {}
  for i = 1, 18 do t[i] = 'l' .. i end
  t[10] = '        "baz": "' .. v10 .. '"'
  t[13] = '        "baz": "' .. v13 .. '",'
  return t
end
local orig, cur = json('2.0.0', '3.0.0'), json('12.0.0', '3.0.0')
local r = p.post_process_edit(table.concat(json('2.0.0', '1.0.0'), '\n'), false, cur, 9, 8, orig)
eq('revert of edited line dropped, other hunk kept', r and { r[10], r[13] }, { cur[10], '        "baz": "1.0.0",' })
r = p.post_process_edit(table.concat(json('2.0.0', '3.0.0'), '\n'), false, cur, 9, 8, orig)
eq('only a revert: nothing', r, nil)
r = p.post_process_edit('a\nx = 2,\ny = 3\nb', false, { 'a', 'x = 2', 'b' }, 1, 8, { 'a', 'x = 1', 'b' })
eq('text added after the typed text is kept', r, { 'a', 'x = 2,', 'y = 3', 'b' })
r = p.post_process_edit('a\nx = 2\ny = 2\nb', false, { 'a', 'x = 2', 'b' }, 1, 8, { 'a', 'x = 1', 'b' })
eq('new line after the edited line is kept', r, { 'a', 'x = 2', 'y = 2', 'b' })
r = p.post_process_edit('a\nb\nc', false, { 'a', 'c' }, 1, 8, { 'a', 'b', 'c' })
eq('putting back a deleted line dropped', r, nil)
r = p.post_process_edit('a\nx = 3\nb', false, { 'a', 'x = 2', 'b' }, 1, 8, nil)
eq('no original: unchanged behaviour', r, { 'a', 'x = 3', 'b' })
eq('edit spans', p.edit_spans({ 'a', 'b', 'c', 'd' }, { 'a', 'B', 'c' }), { { 2, 2 }, { 3, 4 } })

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
os.exit(fails == 0 and 0 or 1)
