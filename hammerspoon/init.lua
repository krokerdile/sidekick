require("hs.ipc")

local logFile = os.getenv("HOME") .. "/.sidekick/logs/ui-errors.log"
local ok, errorMessage = pcall(function()
  sidekick = require("sidekick").start({
    home = os.getenv("HOME") .. "/.sidekick",
    size = 96,
    margin = 24
  })
end)

if not ok then
  local file = io.open(logFile, "a")
  if file then
    file:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " init ", tostring(errorMessage), "\n")
    file:close()
  end
  hs.alert.show("Sidekick load failed")
end
