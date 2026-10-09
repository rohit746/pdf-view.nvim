--- A tiny test harness: describe/it plus a few assertions, run with `make test`.
local M = {}

local stack = {}
local stats = { passed = 0, failed = 0 }

function M.describe(name, body)
  stack[#stack + 1] = name
  body()
  stack[#stack] = nil
end

---@param name string
---@param body fun()
function M.it(name, body)
  local label = table.concat(stack, " > ") .. " > " .. name
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    stats.passed = stats.passed + 1
    io.stdout:write("  ok    ", label, "\n")
  else
    stats.failed = stats.failed + 1
    io.stdout:write("  FAIL  ", label, "\n", tostring(err), "\n")
  end
end

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%sexpected %s\n   but got %s"):format(
        message and (message .. ": ") or "",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function M.truthy(value, message)
  if not value then
    error(message or ("expected a truthy value, got " .. vim.inspect(value)), 2)
  end
end

function M.near(expected, actual, tolerance, message)
  if math.abs(expected - actual) > tolerance then
    error(("%sexpected %s ± %s, got %s"):format(message and (message .. ": ") or "", expected, tolerance, actual), 2)
  end
end

--- Run the event loop until `condition()` holds. Fails the test on timeout.
---@param condition fun(): boolean
---@param message? string
---@param timeout? integer ms
function M.wait_for(condition, message, timeout)
  local ok = vim.wait(timeout or 5000, condition, 10)
  if not ok then
    error("timed out waiting for " .. (message or "condition"), 2)
  end
end

function M.summary()
  io.stdout:write(("\n%d passed, %d failed\n"):format(stats.passed, stats.failed))
  return stats.failed == 0
end

return M
