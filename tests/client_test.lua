-- The request path from prompt to filtered result, with the HTTP layer
-- replaced by a canned model answer. Filters that only work when called
-- directly (a value never reaching them) show up here.
-- Run: nvim --headless --clean --cmd 'set rtp^=.' -l tests/client_test.lua
local api = vim.api

local answer
package.loaded['sweep.http'] = {
    request = function(opts, callback)
        opts.on_event({ content = answer, stop = true, stop_type = 'eos' })
        callback(nil, 200, '')
        return function() end
    end,
}

local Client = require('sweep.client')
local EditTracker = require('sweep.tracker')
local Config = require('sweep.config')

local config = Config():setup({ context = { restore_history = false } })
local fails = 0
local function eq(name, got, want)
    if vim.deep_equal(got, want) then
        print('ok   ' .. name)
    else
        fails = fails + 1
        print('FAIL ' .. name .. '\n  got  ' .. vim.inspect(got) .. '\n  want ' .. vim.inspect(want))
    end
end

local buf = api.nvim_create_buf(true, false)
local cur = { 'const baba = true;', '', 'if (foozbar) {', '}' }
api.nvim_buf_set_lines(buf, 0, -1, false, cur)

local tracker = EditTracker(config)
local function entry(line, old, new)
    return { bufnr = buf, filepath = 'test.js', tick = 0, start_line = line, end_line = line,
        old_lines = { old }, new_lines = { new }, timestamp = 0 }
end
-- if (booo) -> if (foozbar) was the last change to line 3
tracker.edit_history = {
    entry(3, 'if (foozbar) {', 'if (baba) {'),
    entry(3, 'if (baba) {', 'if (booo) {'),
    entry(3, 'if (booo) {', 'if (foozbar) {'),
}

local client = Client(config)
local function request(model_answer)
    answer = model_answer
    local got, done = nil, false
    client:request_completion('edit', {
        bufnr = buf, filepath = 'test.js', current_lines = cur, original_lines = cur,
        cursor_offset = 0, original_tick = api.nvim_buf_get_changedtick(buf),
    }, tracker, function(lines) got, done = lines, true end)
    vim.wait(1000, function() return done end)
    return got
end

eq('turning a line back into an earlier version is dropped',
    request('const baba = true;\n\nif (booo) {\n}'), nil)
eq('so is a version from further back',
    request('const baba = true;\n\nif (baba) {\n}'), nil)
eq('a new version is kept',
    request('const baba = true;\n\nif (isTrue) {\n}'), { 'const baba = true;', '', 'if (isTrue) {', '}' })

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
vim.cmd(fails == 0 and 'qa!' or 'cq!')
