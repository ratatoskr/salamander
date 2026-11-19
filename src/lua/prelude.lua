-- Promises and tasks, for async methods. Runs once as the binder starts, given what it needs from
-- Zig, and gives back what Zig and scripts use. Adapted from wraith's.
local report, traceback = ...

local create, resume, running, status, yield = coroutine.create, coroutine.resume, coroutine.running, coroutine.status, coroutine.yield

-- Each task's promise, by its coroutine
local tasks = setmetatable({}, { __mode = "k" })
-- Tasks to resume, since what they waited for settled
local queue = {}
-- Rejected with nothing waiting, reported if it stays that way
local unhandled = {}

-- What async calls and spawn give. Await it in a task.
local Promise = { __name = "Promise" }
Promise.__index = Promise

local function new_promise()
  return setmetatable({ state = "pending" }, Promise)
end

local function settle(p, ok, value)
  if p.state ~= "pending" then return end
  p.state = ok and "fulfilled" or "rejected"
  p.value = value
  local waiters = p.waiters
  p.waiters = nil
  if waiters then
    for i = 1, #waiters do queue[#queue + 1] = waiters[i] end
  elseif not ok then
    unhandled[p] = true
  end
end

local function describe(e)
  if type(e) == "string" then return e end
  local ok, s = pcall(tostring, e)
  return ok and s or "(an error that can't be shown)"
end

-- False and the error if it failed. Done tasks resolve their promise.
local function step(co, ...)
  local ok, result = resume(co, ...)
  if not ok then return false, result end
  if status(co) == "dead" then settle(tasks[co], true, result) end
  return true
end

-- Rejects its promise if another task awaits it, else it's reported with where it was.
local function failed(co, err)
  local p = tasks[co]
  if p.waiters then return settle(p, false, err) end
  p.state = "rejected"
  p.value = err
  report(describe(err) .. "\n" .. traceback(co))
end

local function task(f)
  local co = create(f)
  local p = new_promise()
  tasks[co] = p
  return co, p
end

-- Runs `f(...)` as a task, so it can await. Gives its promise.
local function spawn(f, ...)
  local co, p = task(f)
  local ok, err = step(co, ...)
  if not ok then failed(co, err) end
  return p
end

-- For Zig. Like spawn, but failing right away gives the error and where it was instead.
local function start(f, ...)
  local co, p = task(f)
  local ok, err = step(co, ...)
  if ok then return true, p end
  p.state = "rejected"
  p.value = err
  return false, err, traceback(co)
end

local function in_task(what)
  local co = running()
  if not tasks[co] then error(what .. " only works in a task: a script's main chunk, an async method, or one from task.spawn", 3) end
  return co
end

-- Waits for it in a task, giving its value or raising why it was rejected.
function Promise:await()
  if self.state == "pending" then
    local co = in_task("await")
    local w = self.waiters
    if not w then
      w = {}
      self.waiters = w
    end
    w[#w + 1] = co
    repeat yield() until self.state ~= "pending"
  end
  unhandled[self] = nil
  if self.state == "rejected" then error(self.value, 0) end
  return self.value
end

-- Calls `on_ok(value)` or `on_err(reason)` in a task once it settles. Gives a promise for what that returns.
function Promise:next(on_ok, on_err)
  return spawn(function()
    local ok, v = pcall(Promise.await, self)
    local f = ok and on_ok or (not ok and on_err)
    if f then
      v = f(v)
    elseif not ok then
      error(v, 0)
    end
    if getmetatable(v) == Promise then return v:await() end
    return v
  end)
end

function Promise:catch(on_err)
  return self:next(nil, on_err)
end

-- Lets everything else ready run, then carries on.
local function pass()
  queue[#queue + 1] = in_task("task.yield")
  yield()
end

-- For Zig: calls `f(ok, value)` once `p` settles.
local function watch(p, f)
  spawn(function()
    local ok, v = pcall(Promise.await, p)
    f(ok, v)
  end)
end

-- Resumes what's ready. Reports what was rejected with nothing waiting, if asked.
local function drain(report_unhandled)
  for _ = 1, 1000 do
    if #queue == 0 then break end
    local jobs = queue
    queue = {}
    for i = 1, #jobs do
      local co = jobs[i]
      if status(co) == "suspended" then
        local ok, err = step(co)
        if not ok then failed(co, err) end
      end
    end
  end
  if report_unhandled and next(unhandled) then
    local list = unhandled
    unhandled = {}
    for p in pairs(list) do
      report("Unhandled promise rejection: " .. describe(p.value))
    end
  end
end

-- What a result's error is raised as
local Error = { __name = "Error" }
Error.__index = Error
Error.__tostring = function(e) return e.message or e.name end

return {
  start = start,
  new_promise = new_promise,
  settle = settle,
  drain = drain,
  watch = watch,
  Promise = Promise,
  Error = Error,
  -- For scripts
  task = { spawn = spawn, yield = pass },
}
