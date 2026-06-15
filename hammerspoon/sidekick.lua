local sidekick = {}

local config = {}
local canvas = nil
local bubble = nil
local bubbleTimer = nil
local watcher = nil
local paneTimer = nil
local menuCanvas = nil
local dragTimer = nil
local menuDismissCanvas = nil
local tasks = {}
local latestTaskId = nil
local dragging = false
local dragOffset = nil
local dragMoved = false
local dragStart = nil

local positionKey = "sidekick.position"
local bubblesEnabledKey = "sidekick.bubblesEnabled"

local function readEvents()
  local file = io.open(config.eventsFile, "r")
  if not file then return {} end

  local events = {}
  for line in file:lines() do
    local ok, value = pcall(hs.json.decode, line)
    if ok and type(value) == "table" then
      table.insert(events, value)
    end
  end
  file:close()
  return events
end

local function activePaneIds()
  local command = config.tmux .. " list-panes -a -F '#{pane_id}'"
  local output, success = hs.execute(command, true)
  if not success then return nil end

  local paneIds = {}
  for paneId in tostring(output):gmatch("[^\r\n]+") do
    paneIds[paneId] = true
  end
  return paneIds
end

local function reduceTasks(events)
  local readIds = {}
  for _, event in ipairs(events) do
    if event.eventType == "task.read" then
      readIds[event.targetEventId] = true
    end
  end

  local currentPanes = activePaneIds()
  local latestBySession = {}
  for _, event in ipairs(events) do
    local isSessionEvent = event.eventType == "session.started"
      or event.eventType == "turn.started"
      or event.eventType == "turn.completed"
      or event.eventType == "turn.failed"
      or event.eventType == "confirm.requested"
      or event.eventType == "session.ended"
    if isSessionEvent then
      local key
      if event.sessionId then
        key = (event.agent or "unknown") .. "|" .. event.sessionId
      elseif event.turnId then
        key = (event.agent or "unknown") .. "|" .. event.turnId
      else
        key = event.eventId
      end
      local previous = latestBySession[key]
      if not previous or tostring(event.occurredAt) >= tostring(previous.occurredAt) then
        if event.eventType == "session.ended" then
          latestBySession[key] = nil
        else
          event.unread = (event.eventType == "turn.completed"
            or event.eventType == "turn.failed"
            or event.eventType == "confirm.requested")
            and not readIds[event.eventId]
          latestBySession[key] = event
        end
      end
    end
  end

  -- 같은 pane에 새 세션이 시작된 경우 가장 최근 세션만 유지
  local latestByPane = {}
  for _, event in pairs(latestBySession) do
    local paneId = event.tmux and event.tmux.paneId
    if paneId and (currentPanes == nil or currentPanes[paneId]) then
      local existing = latestByPane[paneId]
      if not existing or tostring(event.occurredAt) > tostring(existing.occurredAt) then
        latestByPane[paneId] = event
      end
    end
  end

  local completed = {}
  for _, event in pairs(latestByPane) do
    table.insert(completed, event)
  end
  table.sort(completed, function(a, b)
    return tostring(a.occurredAt) > tostring(b.occurredAt)
  end)
  return completed
end

local function latestBubbleEvent(events)
  for index = #events, 1, -1 do
    local event = events[index]
    if event.eventType == "turn.started"
      or event.eventType == "turn.completed"
      or event.eventType == "turn.failed"
      or event.eventType == "confirm.requested" then
      return event
    end
  end
  return nil
end

local function unreadCount()
  local count = 0
  for _, task in ipairs(tasks) do
    if task.unread then count = count + 1 end
  end
  return count
end

local function refreshCanvas()
  if not canvas then return end
  local count = unreadCount()
  if count == 0 then
    canvas["badge-bg"].hidden = true
    canvas["badge-text"].hidden = true
  else
    canvas["badge-text"].text = count > 9 and "9+" or tostring(count)
    canvas["badge-bg"].hidden = false
    canvas["badge-text"].hidden = false
  end
end

local function bubblesEnabled()
  local value = hs.settings.get(bubblesEnabledKey)
  return value == nil or value == true
end

local function clampPosition(point, screen)
  local frame = screen:frame()
  return {
    x = math.max(frame.x, math.min(point.x, frame.x + frame.w - config.size)),
    y = math.max(frame.y, math.min(point.y, frame.y + frame.h - config.size))
  }
end

local function defaultPosition()
  local frame = hs.screen.mainScreen():frame()
  return {
    x = frame.x + frame.w - config.size - config.margin,
    y = frame.y + frame.h - config.size - config.margin
  }
end

local function savedPosition()
  local saved = hs.settings.get(positionKey)
  if type(saved) ~= "table" or type(saved.x) ~= "number" or type(saved.y) ~= "number" then
    return defaultPosition()
  end
  local screen = hs.screen.find({ x = saved.x, y = saved.y }) or hs.screen.mainScreen()
  return clampPosition(saved, screen)
end

local function savePosition()
  if not canvas then return end
  local point = canvas:topLeft()
  hs.settings.set(positionKey, { x = point.x, y = point.y })
end

local function hideBubble()
  if bubbleTimer then bubbleTimer:stop(); bubbleTimer = nil end
  if bubble then bubble:delete(); bubble = nil end
end

local function hideMenu()
  if menuCanvas then menuCanvas:delete(); menuCanvas = nil end
  if menuDismissCanvas then menuDismissCanvas:delete(); menuDismissCanvas = nil end
end

local function focusTask(task)
  if not task.tmux or not task.tmux.paneId then
    hs.alert.show("이 작업은 tmux pane 정보가 없어요")
    return
  end

  local arguments = { "focus", task.tmux.paneId }
  if task.tmux.clientTty and task.tmux.clientTty ~= "" then
    table.insert(arguments, task.tmux.clientTty)
  end

  hs.application.launchOrFocusByBundleID("com.mitchellh.ghostty")
  hs.task.new(config.cli, function(exitCode, _, stderr)
    if exitCode == 0 then
      hs.task.new(config.cli, nil, { "read", task.eventId }):start()
      task.unread = false
      refreshCanvas()
    else
      hs.alert.show("pane 이동 실패: " .. (stderr ~= "" and stderr or "pane closed"))
    end
  end, arguments):start()
end

local function bubbleFrame()
  local characterFrame = canvas:frame()
  local screen = hs.screen.find(characterFrame) or hs.screen.mainScreen()
  local screenFrame = screen:frame()
  local width = 360
  local height = 124
  local gap = 8
  local x = characterFrame.x - width - gap
  if x < screenFrame.x then
    x = characterFrame.x + characterFrame.w + gap
  end
  local y = math.max(
    screenFrame.y,
    math.min(characterFrame.y + (characterFrame.h - height) / 2, screenFrame.y + screenFrame.h - height)
  )
  return { x = x, y = y, w = width, h = height }
end

local function truncateText(value, maxCharacters)
  local text = tostring(value or "")
  local length = utf8.len(text)
  if not length or length <= maxCharacters then return text end
  local byteIndex = utf8.offset(text, maxCharacters + 1)
  return text:sub(1, byteIndex - 1) .. "..."
end

local function showBubble(task)
  if not task or not bubblesEnabled() or not canvas then return end
  hideBubble()

  local agent = task.agent == "claude" and "Claude" or "Codex"
  local result
  if task.status == "running" then
    result = "작업 중"
  elseif task.status == "waiting" then
    result = "확인 대기"
  elseif task.status == "failed" then
    result = "작업 실패"
  else
    result = "작업 완료"
  end
  local preview = task.promptPreview or task.summaryPreview or "클릭하면 작업 화면으로 이동해요"
  preview = truncateText(preview, 86)
  local title = string.format("%s · %s · %s", agent, task.repo or "unknown", result)

  bubble = hs.canvas.new(bubbleFrame())
  bubble:level(hs.canvas.windowLevels.overlay)
  bubble:clickActivating(false)
  bubble:behavior({ "canJoinAllSpaces", "stationary" })
  bubble:appendElements({
    {
      type = "rectangle",
      action = "strokeAndFill",
      fillColor = { red = 0.08, green = 0.09, blue = 0.11, alpha = 0.97 },
      strokeColor = { white = 1, alpha = 0.18 },
      strokeWidth = 1,
      roundedRectRadii = { xRadius = 16, yRadius = 16 },
      withShadow = true,
      shadow = {
        blurRadius = 12,
        color = { white = 0, alpha = 0.4 },
        offset = { h = 3, w = 0 }
      },
      frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
      trackMouseUp = true
    },
    {
      type = "text",
      text = title,
      textColor = { white = 1 },
      textFont = ".AppleSystemUIFont",
      textSize = 15,
      textLineBreak = "truncateTail",
      frame = { x = 18, y = 14, w = 324, h = 22 },
      trackMouseUp = true
    },
    {
      type = "text",
      text = preview,
      textColor = { white = 0.92 },
      textFont = ".AppleSystemUIFont",
      textSize = 14,
      textLineBreak = "wordWrap",
      frame = { x = 18, y = 43, w = 324, h = 48 },
      trackMouseUp = true
    },
    {
      type = "text",
      text = "클릭하면 해당 tmux pane으로 이동해요",
      textColor = { red = 0.55, green = 0.76, blue = 1, alpha = 1 },
      textFont = ".AppleSystemUIFont",
      textSize = 12,
      textLineBreak = "truncateTail",
      frame = { x = 18, y = 96, w = 324, h = 18 },
      trackMouseUp = true
    }
  })
  bubble:mouseCallback(function(_, message)
    if message == "mouseUp" then
      hideBubble()
      focusTask(task)
    end
  end)
  bubble:show()
  bubbleTimer = hs.timer.doAfter(config.bubbleDuration, hideBubble)
end

local function popupFrame(width, height)
  local characterFrame = canvas:frame()
  local screen = hs.screen.find(characterFrame) or hs.screen.mainScreen()
  local screenFrame = screen:frame()
  local gap = 8
  local screenRight = screenFrame.x + screenFrame.w
  local screenBottom = screenFrame.y + screenFrame.h
  local x
  if characterFrame.x - screenFrame.x >= width + gap then
    x = characterFrame.x - width - gap
  elseif screenRight - characterFrame.x - characterFrame.w >= width + gap then
    x = characterFrame.x + characterFrame.w + gap
  elseif characterFrame.y - screenFrame.y >= height + gap then
    x = math.max(screenFrame.x + 8, math.min(characterFrame.x, screenRight - width - 8))
    return { x = x, y = characterFrame.y - height - gap, w = width, h = height }
  else
    x = math.max(screenFrame.x + 8, math.min(characterFrame.x, screenRight - width - 8))
    return { x = x, y = characterFrame.y + characterFrame.h + gap, w = width, h = height }
  end
  local y = math.max(
    screenFrame.y + 8,
    math.min(characterFrame.y + (characterFrame.h - height) / 2, screenBottom - height - 8)
  )
  return { x = x, y = y, w = width, h = height }
end

local function newMenuCanvas(frame)
  hideMenu()
  hideBubble()
  local screen = hs.screen.find(frame) or hs.screen.mainScreen()
  menuDismissCanvas = hs.canvas.new(screen:frame())
  menuDismissCanvas:level(hs.canvas.windowLevels.popUpMenu)
  menuDismissCanvas:clickActivating(false)
  menuDismissCanvas:behavior({ "canJoinAllSpaces", "stationary" })
  menuDismissCanvas:appendElements({
    {
      id = "dismiss",
      type = "rectangle",
      action = "fill",
      fillColor = { white = 0, alpha = 0.001 },
      frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
      trackMouseDown = true
    }
  })
  menuDismissCanvas:mouseCallback(function(_, message)
    if message == "mouseDown" then hideMenu() end
  end)
  menuDismissCanvas:show()

  menuCanvas = hs.canvas.new(frame)
  menuCanvas:level(hs.canvas.windowLevels.overlay)
  menuCanvas:clickActivating(false)
  menuCanvas:behavior({ "canJoinAllSpaces", "stationary" })
  menuCanvas:appendElements({
    {
      id = "background",
      type = "rectangle",
      action = "strokeAndFill",
      fillColor = { red = 0.10, green = 0.11, blue = 0.13, alpha = 0.97 },
      strokeColor = { white = 1, alpha = 0.2 },
      strokeWidth = 1,
      roundedRectRadii = { xRadius = 14, yRadius = 14 },
      withShadow = true,
      frame = { x = 0, y = 0, w = frame.w, h = frame.h }
    }
  })
  menuCanvas:orderAbove(menuDismissCanvas)
  return menuCanvas
end

local function resetPosition()
  hs.settings.clear(positionKey)
  canvas:topLeft(defaultPosition())
  hideBubble()
  hideMenu()
end

local showSettingsMenu

local function showMenu()
  local visibleTasks = math.min(#tasks, 8)
  local rowHeight = 48
  local taskRows = math.max(1, visibleTasks)
  local height = (taskRows + 1) * rowHeight
  local currentMenu = newMenuCanvas(popupFrame(520, height))
  local selectedTasks = {}

  if visibleTasks == 0 then
    currentMenu:appendElements({
      {
        id = "empty",
        type = "text",
        text = "열려 있는 작업이 없어요",
        textColor = { white = 0.9 },
        textFont = ".AppleSystemUIFont",
        textSize = 15,
        textAlignment = "center",
        frame = { x = 16, y = 14, w = 488, h = 24 }
      }
    })
  else
    for index = 1, visibleTasks do
      local task = tasks[index]
      selectedTasks[index] = task
      local status = task.status == "running" and "작업 중"
        or task.status == "waiting" and "확인 대기"
        or task.status == "failed" and "실패"
        or task.status == "idle" and "대기"
        or "완료"
      local marker = task.unread and "● " or ""
      local title = string.format(
        "%s[%s] %s · #%s · %s — %s",
        marker,
        task.agent or "agent",
        task.repo or "unknown",
        task.turnNumber or "?",
        status,
        truncateText(task.promptPreview or task.summaryPreview or "작업 내용 없음", 30)
      )
      currentMenu:appendElements({
        {
          id = "row-" .. index,
          type = "rectangle",
          action = "fill",
          fillColor = { white = index % 2 == 0 and 0.055 or 0.025 },
          frame = { x = 0, y = (index - 1) * rowHeight, w = 520, h = rowHeight },
          trackMouseUp = true
        },
        {
          id = "row-text-" .. index,
          type = "text",
          text = title,
          textColor = { white = 0.94 },
          textFont = ".AppleSystemUIFont",
          textSize = 14,
          textLineBreak = "truncateTail",
          frame = { x = 16, y = (index - 1) * rowHeight + 13, w = 488, h = 24 },
          trackMouseUp = true
        }
      })
    end
  end
  currentMenu:appendElements({
    {
      id = "options",
      type = "rectangle",
      action = "fill",
      fillColor = { white = 0.075 },
      frame = { x = 0, y = taskRows * rowHeight, w = 520, h = rowHeight },
      trackMouseUp = true
    },
    {
      id = "options-text",
      type = "text",
      text = "옵션",
      textColor = { red = 0.55, green = 0.76, blue = 1, alpha = 1 },
      textFont = ".AppleSystemUIFont",
      textSize = 14,
      frame = { x = 16, y = taskRows * rowHeight + 13, w = 488, h = 24 },
      trackMouseUp = true
    }
  })
  currentMenu:mouseCallback(function(_, message, elementId)
    if message ~= "mouseUp" then return end
    if elementId == "options" or elementId == "options-text" then
      showSettingsMenu()
      return
    end
    local index = tonumber(tostring(elementId):match("(%d+)$"))
    if index and selectedTasks[index] then
      local task = selectedTasks[index]
      hideMenu()
      focusTask(task)
    end
  end)
  currentMenu:show()
end

showSettingsMenu = function()
  local width = 300
  local rowHeight = 46
  local currentMenu = newMenuCanvas(popupFrame(width, rowHeight * 3))
  local settingsItems = {
    {
      title = (bubblesEnabled() and "✓ " or "") .. "완료 말풍선 표시",
      fn = function()
        hs.settings.set(bubblesEnabledKey, not bubblesEnabled())
        if not bubblesEnabled() then hideBubble() end
        hideMenu()
      end
    },
    { title = "위치를 우하단으로 초기화", fn = resetPosition },
    { title = "최근 작업 보기", fn = showMenu }
  }
  for index, item in ipairs(settingsItems) do
    currentMenu:appendElements({
      {
        id = "setting-" .. index,
        type = "rectangle",
        action = "fill",
        fillColor = { white = index % 2 == 0 and 0.055 or 0.025 },
        frame = { x = 0, y = (index - 1) * rowHeight, w = width, h = rowHeight },
        trackMouseUp = true
      },
      {
        id = "setting-text-" .. index,
        type = "text",
        text = item.title,
        textColor = { white = 0.94 },
        textFont = ".AppleSystemUIFont",
        textSize = 15,
        frame = { x = 16, y = (index - 1) * rowHeight + 12, w = width - 32, h = 24 },
        trackMouseUp = true
      }
    })
  end
  currentMenu:mouseCallback(function(_, message, elementId)
    if message ~= "mouseUp" then return end
    local index = tonumber(tostring(elementId):match("(%d+)$"))
    if index and settingsItems[index] then settingsItems[index].fn() end
  end)
  currentMenu:show()
end

local function handleCharacterClick()
  showMenu()
end

local function stopDragTracking()
  if dragTimer then dragTimer:stop(); dragTimer = nil end
end

local function updateDragPosition()
  if not dragging then return end
  local current = hs.mouse.absolutePosition()
  if math.abs(current.x - dragStart.x) > 1 or math.abs(current.y - dragStart.y) > 1 then
    dragMoved = true
  end
  local nextPoint = { x = current.x - dragOffset.x, y = current.y - dragOffset.y }
  local screen = hs.screen.find(nextPoint) or hs.screen.mainScreen()
  canvas:topLeft(clampPosition(nextPoint, screen))
end

local function finishDrag()
  if not dragging then return end
  dragging = false
  stopDragTracking()
  if dragMoved then
    savePosition()
  else
    handleCharacterClick()
  end
  dragOffset = nil
  dragStart = nil
end

local function beginDrag()
  local mouse = hs.mouse.absolutePosition()
  local topLeft = canvas:topLeft()
  dragging = true
  dragMoved = false
  dragStart = mouse
  dragOffset = { x = mouse.x - topLeft.x, y = mouse.y - topLeft.y }
  hideBubble()
  hideMenu()
  stopDragTracking()

  dragTimer = hs.timer.doEvery(0.01, function()
    if not dragging then return end
    local buttons = hs.eventtap.checkMouseButtons()
    if buttons.left then
      updateDragPosition()
    else
      finishDrag()
    end
  end)
end

local function reloadEvents()
  local previousLatestId = latestTaskId
  local events = readEvents()
  local latestEvent = latestBubbleEvent(events)
  tasks = reduceTasks(events)
  latestTaskId = latestEvent and latestEvent.eventId or nil
  refreshCanvas()
  if previousLatestId and latestTaskId and previousLatestId ~= latestTaskId then
    showBubble(latestEvent)
  end
end

local function createCanvas()
  local size = config.size
  local image = hs.image.imageFromPath(config.character)
  if not image then
    error("Sidekick character image not found: " .. config.character)
  end
  local position = savedPosition()
  local frame = { x = position.x, y = position.y, w = size, h = size }

  canvas = hs.canvas.new(frame)
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:alpha(1)
  canvas:clickActivating(false)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:appendElements({
    {
      type = "image",
      image = image,
      imageScaling = "scaleToFit",
      frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
      trackMouseDown = true,
      trackMouseUp = true,
      trackMouseMove = true,
      trackMouseByBounds = true
    },
    {
      id = "badge-bg",
      type = "circle",
      action = "fill",
      fillColor = { red = 0.88, green = 0.22, blue = 0.22, alpha = 1 },
      frame = { x = "66%", y = "0%", w = "28%", h = "28%" },
      hidden = true,
      withShadow = true,
      shadow = { blurRadius = 4, color = { white = 0, alpha = 0.45 }, offset = { h = 1, w = 0 } }
    },
    {
      id = "badge-text",
      type = "text",
      text = "",
      textColor = { white = 1 },
      textFont = ".AppleSystemUIFont",
      textSize = 11,
      textAlignment = "center",
      frame = { x = "66%", y = "2%", w = "28%", h = "26%" },
      hidden = true
    }
  })
  canvas:mouseCallback(function(_, message)
    if message == "mouseDown" then
      local buttons = hs.eventtap.checkMouseButtons()
      if buttons.right then
        dragging = false
        stopDragTracking()
        showSettingsMenu()
        return
      end
      beginDrag()
    elseif message == "mouseMove" and dragging then
      updateDragPosition()
    elseif message == "mouseUp" and dragging then
      finishDrag()
    end
  end)
  canvas:show()
end

function sidekick.start(options)
  config.home = options and options.home or os.getenv("HOME") .. "/.sidekick"
  config.size = options and options.size or 72
  config.margin = options and options.margin or 24
  config.eventsFile = config.home .. "/state/events.jsonl"
  config.character = config.home .. "/assets/character-widget-v2.png"
  config.cli = config.home .. "/bin/sidekick"
  config.tmux = (function()
    if options and options.tmux then return options.tmux end
    for _, candidate in ipairs({ "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux" }) do
      if hs.fs.attributes(candidate) then return candidate end
    end
    return "tmux"
  end)()
  config.bubbleDuration = options and options.bubbleDuration or 8

  createCanvas()
  reloadEvents()
  watcher = hs.pathwatcher.new(config.home .. "/state", function()
    hs.timer.doAfter(0.1, reloadEvents)
  end)
  watcher:start()
  paneTimer = hs.timer.doEvery(2, reloadEvents)
  return sidekick
end

function sidekick.stop()
  if watcher then watcher:stop(); watcher = nil end
  if paneTimer then paneTimer:stop(); paneTimer = nil end
  stopDragTracking()
  hideBubble()
  hideMenu()
  if canvas then canvas:delete(); canvas = nil end
end

function sidekick.status()
  return {
    canvasCreated = canvas ~= nil,
    canvasShowing = canvas ~= nil and canvas:isShowing() or false,
    frame = canvas ~= nil and canvas:frame() or nil,
    taskCount = #tasks,
    unreadCount = unreadCount(),
    character = config.character,
    position = canvas ~= nil and canvas:topLeft() or nil,
    dragging = dragging,
    menuShowing = menuCanvas ~= nil and menuCanvas:isShowing() or false,
    menuFrame = menuCanvas ~= nil and menuCanvas:frame() or nil,
    bubbleShowing = bubble ~= nil and bubble:isShowing() or false,
    bubblesEnabled = bubblesEnabled(),
    bubbleFrame = canvas ~= nil and bubbleFrame() or nil
  }
end

function sidekick.focus(eventId)
  for _, task in ipairs(tasks) do
    if task.eventId == eventId then
      focusTask(task)
      return true
    end
  end
  return false
end

function sidekick.moveTo(x, y)
  if not canvas then return false end
  local point = { x = x, y = y }
  local screen = hs.screen.find(point) or hs.screen.mainScreen()
  canvas:topLeft(clampPosition(point, screen))
  savePosition()
  return true
end

function sidekick.resetPosition()
  resetPosition()
end

function sidekick.showMenu()
  showMenu()
end

function sidekick.showSettings()
  showSettingsMenu()
end

function sidekick.hideMenu()
  hideMenu()
end

function sidekick.showBubble(eventId)
  for _, task in ipairs(tasks) do
    if task.eventId == eventId then
      showBubble(task)
      return true
    end
  end
  return false
end

return sidekick
