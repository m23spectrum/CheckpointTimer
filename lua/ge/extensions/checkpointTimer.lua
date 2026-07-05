-- ===========================================================================
-- CheckpointTimer v3.0 — BeamNG.drive чекпоинт-таймер
-- ===========================================================================
-- Переписано по официальной документации BeamNG:
--   https://documentation.beamng.com/modding/programming/extensions/
--   https://documentation.beamng.com/modding/programming/virtualmachines/
--   https://documentation.beamng.com/modding/programming/console/   (VFS API)
--   https://documentation.beamng.com/modding/ui/app_creation/
--
-- Возможности:
--   • Запись координат старта / чекпоинтов / финиша для любой карты
--   • Авто-детект прохождения через триггер-зоны (настраиваемый радиус)
--   • Подсчёт дельты времени между чекпоинтами + общее время
--   • Per-map конфиги в JSON (через jsonWriteFile / jsonReadFile)
--   • История заездов с посекундными сплитами
--   • Push-обновление UI через guihooks.trigger('CTStatus', payload)
--   • Консольные команды: вызов из консоли как checkpointTimer.ct_command("...")
--   • v3.0: Метки чекпоинтов на миникарте мира
--       - core_map.setMarker() / core_map.removeMarker() API
--       - Цветные метки: зелёный=старт, жёлтый=чекпоинт, красный=финиш
--       - Подписи: СТАРТ / ЧК1 / ФИНИШ
--   • Наземные круги через debugDrawer (GTA SA стиль):
--       - Плоский круг на земле из линий
--       - Пульсация (круг дышит)
--       - Внутренний крест (+) в центре
--       - Подпись над кругом
--       - Соединительные линии между чекпоинтами
--   • Лучшие сплиты с цветовой индикацией
-- ===========================================================================

local M = {}

-- ===========================================================================
-- Состояние (сериализуемое, переживает Ctrl-L)
-- ===========================================================================
M.state = {
  triggerRadius      = 3.0,    -- радиус сферической триггер-зоны в метрах
  triggerCheckHz     = 20,     -- частота проверки (раз в секунду)
  maxHistory         = 50,     -- макс. записей в истории
  showTriggerZones   = true,   -- показывать круги на земле через debug-рендер
  showMapMarkers     = true,   -- показывать метки на миникарте мира
  debugMode          = false,  -- режим отладки (лог в onGuiUpdate)
  circleRadius       = 2.5,    -- радиус круга-чекпоинта на земле (метры)
  circleSegments     = 48,     -- количество сегментов для отрисовки круга
  circlePulse        = true,   -- пульсация круга (дыхание)
  circlePulseSpeed   = 2.0,    -- скорость пульсации (Гц)
  circlePulseAmp     = 0.4,    -- амплитуда пульсации (метры)
  terrainSnap        = true,   -- привязывать Z к рельефу при записи
  routes             = {},     -- { [routeName] = routeDef } — для сериализации
  history            = {},     -- массив записей истории
  useSystemClock     = true,   -- использовать часы системы (os.clock) в качестве таймера
}

-- ===========================================================================
-- Рантайм-состояние (не сериализуется)
-- ===========================================================================
local runtime = {
  currentLevel         = "",
  activeRoute          = nil,
  runActive            = false,
  runStartTime         = 0,
  lastCheckpointTime   = 0,
  currentCheckpointIdx = 0,
  splits               = {},
  bestSplits           = {},   -- { [idx] = {name=, delta=} }

  -- Запись нового маршрута
  recordingNewRoute    = false,
  newRouteName         = "",
  recordingStage       = 0,    -- 0=неактивно, 1=ждём старт, 2=ждём CP/финиш, 99=ждём финиш

  -- Троттлинг
  triggerTimer         = 0,
  statusPushTimer      = 0,

  -- Метки на миникарте
  mapMarkerIds         = {},   -- ID-шки созданных маркеров (для удаления)
  mapMarkerRoute       = nil,  -- имя маршрута для которого маркеры выставлены
  _mapApiLogged        = false,-- логировали ли доступность API
}

-- Forward-объявления (определяются ниже, но вызываются из ct_command)
local runDiagnostics

-- ===========================================================================
-- Утилиты
-- ===========================================================================

-- Расстояние между двумя 3D-точками (поддерживает vec3 и plain-таблицы)
local function dist3D(a, b)
  if not a or not b then return math.huge end
  local ax, ay, az = a.x or 0, a.y or 0, a.z or 0
  local bx, by, bz = b.x or 0, b.y or 0, b.z or 0
  local dx, dy, dz = ax - bx, ay - by, az - bz
  return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Форматирование времени: "MM:SS.ms" — на вход СЕКУНДЫ
local function formatTime(seconds)
  if not seconds or seconds < 0 then return "00:00.000" end
  local m  = math.floor(seconds / 60)
  local s  = math.floor(seconds % 60)
  local ms = math.floor((seconds % 1) * 1000)
  return string.format("%02d:%02d.%03d", m, s, ms)
end

-- Симуляционное время в СЕКУНДАХ.
-- be:getSimTime() возвращает миллисекунды — делим на 1000.
local function getSimTime()
  if M.state.useSystemClock then
    return os.clock()
  end
  if be and be.getSimTime then
    local ok, ms = pcall(function() return be:getSimTime() end)
    if ok and type(ms) == "number" then return ms / 1000.0 end
  end
  if type(_G.getTime) == "function" then
    local ok, t = pcall(_G.getTime)
    if ok and type(t) == "number" then return t end
  end
  return os.clock()
end

-- Получение пути к директории конфигов (внутри userfolder/settings/)
local function getConfigDir()
  if FS and FS.getGamePath then
    local gp = FS:getGamePath()
    if gp and gp ~= "" then
      return gp .. "/settings/checkpointTimer"
    end
  end
  return "settings/checkpointTimer"
end

-- Получение имени текущей карты.
local function getCurrentLevel()
  if type(_G.getMissionFilename) == "function" then
    local ok, missionFile = pcall(_G.getMissionFilename)
    if ok and missionFile and missionFile ~= "" then
      local m = missionFile:match("/levels/([^/]+)")
      if m and m ~= "" then return m end
      if type(_G.path) == "table" and _G.path.split then
        local dir, fn, ext = _G.path.split(missionFile)
        if dir then
          local m2 = dir:match("/levels/([^/]+)/")
          if m2 and m2 ~= "" then return m2 end
        end
      end
    end
  end
  if type(_G.core_levels) == "table" and _G.core_levels.getLevelName then
    local ok, name = pcall(function()
      local mf = (_G.getMissionFilename and _G.getMissionFilename()) or ""
      return _G.core_levels.getLevelName(mf)
    end)
    if ok and name and name ~= "" then return name end
  end
  if type(_G.core_environment) == "table" then
    local ce = _G.core_environment
    if ce.getLevelName then
      local ok, name = pcall(ce.getLevelName)
      if ok and name and name ~= "" then return name end
    end
  end
  return "unknown"
end

-- Получение активного транспорта игрока.
local function getPlayerVehicle()
  if type(_G.getPlayerVehicle) == "function" then
    local ok, veh = pcall(_G.getPlayerVehicle, 0)
    if ok and veh then return veh end
  end
  if be and be.getPlayerVehicle then
    local ok, veh = pcall(function() return be:getPlayerVehicle(0) end)
    if ok and veh then return veh end
  end
  if type(_G.activeVehiclesIterator) == "function" then
    for vid, veh in _G.activeVehiclesIterator() do
      return veh
    end
  end
  return nil
end

-- Получение позиции транспорта как plain-таблицы {x,y,z}
local function getVehiclePos()
  local veh = getPlayerVehicle()
  if not veh then return nil end
  local ok, pos = pcall(function() return veh:getPosition() end)
  if not ok or not pos then return nil end
  return { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 }
end

-- Получение высоты террейна в точке.
local function getTerrainHeight(x, y)
  if type(_G.core_terrain) == "table" and type(_G.core_terrain.getTerrainHeight) == "function" then
    local ok, h = pcall(function()
      if type(_G.Point3F) == "function" or type(_G.Point3F) == "table" then
        return _G.core_terrain.getTerrainHeight(_G.Point3F(x, y, 0))
      elseif type(_G.vec3) == "function" then
        return _G.core_terrain.getTerrainHeight(_G.vec3(x, y, 0))
      end
    end)
    if ok and type(h) == "number" and h > -1000 then return h end
  end
  if type(_G.scenetree) == "table" and type(_G.scenetree.getTerrainHeight) == "function" then
    local ok, h = pcall(function() return _G.scenetree.getTerrainHeight(x, y) end)
    if ok and type(h) == "number" and h > -1000 then return h end
  end
  if type(_G.getTerrainHeight) == "function" then
    local ok, h = pcall(_G.getTerrainHeight, x, y)
    if ok and type(h) == "number" and h > -1000 then return h end
  end
  if type(_G.be) == "table" and type(_G.be.getTerrainHeight) == "function" then
    local ok, h = pcall(function() return _G.be:getTerrainHeight(x, y) end)
    if ok and type(h) == "number" and h > -1000 then return h end
  end
  return nil
end

-- ===========================================================================
-- Работа с конфигами карт (через глобальные jsonWriteFile / jsonReadFile)
-- ===========================================================================

local function getMapConfigPath(levelName)
  local safe = (levelName or "unknown"):gsub("[^%w_%-]", "_")
  return getConfigDir() .. "/" .. safe .. ".json"
end

local function loadMapConfig(levelName)
  local path = getMapConfigPath(levelName)
  if type(_G.jsonReadFile) == "function" then
    local ok, data = pcall(_G.jsonReadFile, path)
    if ok and type(data) == "table" then
      return data.routes or data or {}
    end
  end
  if type(_G.readFile) == "function" and type(_G.jsonDecode) == "function" then
    local content = _G.readFile(path)
    if content and content ~= "" then
      local ok, data = pcall(_G.jsonDecode, content)
      if ok and type(data) == "table" then
        return data.routes or data or {}
      end
    end
  end
  local f = io.open(path, "r")
  if f then
    local content = f:read("*all")
    f:close()
    if content and content ~= "" and type(_G.jsonDecode) == "function" then
      local ok, data = pcall(_G.jsonDecode, content)
      if ok and type(data) == "table" then
        return data.routes or data or {}
      end
    end
  end
  return {}
end

local function saveMapConfig(levelName, routes)
  local path = getMapConfigPath(levelName)
  local data = {
    level     = levelName,
    updatedAt = os.date("%Y-%m-%d %H:%M:%S"),
    routes    = routes,
  }
  if FS and FS.directoryCreate then
    pcall(function() FS:directoryCreate(getConfigDir(), true) end)
  end
  if type(_G.jsonWriteFile) == "function" then
    local ok = pcall(_G.jsonWriteFile, path, data, true)
    if ok then return true end
  end
  if type(_G.jsonEncode) == "function" and type(_G.writeFile) == "function" then
    local ok, encoded = pcall(_G.jsonEncode, data, true)
    if not ok then
      ok, encoded = pcall(_G.jsonEncode, data)
    end
    if ok and encoded then
      return pcall(_G.writeFile, path, encoded)
    end
  end
  if type(_G.jsonEncode) == "function" then
    local _, encoded = pcall(_G.jsonEncode, data, true)
    if encoded then
      local f = io.open(path, "w")
      if f then
        f:write(encoded)
        f:close()
        return true
      end
    end
  end
  log("E", "checkpointTimer", "Failed to save map config: " .. path)
  return false
end

-- ===========================================================================
-- История заездов
-- ===========================================================================

local function getHistoryPath()
  return getConfigDir() .. "/history.json"
end

local function loadHistory()
  if type(_G.jsonReadFile) == "function" then
    local ok, data = pcall(_G.jsonReadFile, getHistoryPath())
    if ok and type(data) == "table" then
      return data.entries or data or {}
    end
  end
  if type(_G.readFile) == "function" and type(_G.jsonDecode) == "function" then
    local content = _G.readFile(getHistoryPath())
    if content and content ~= "" then
      local ok, data = pcall(_G.jsonDecode, content)
      if ok and type(data) == "table" then
        return data.entries or data or {}
      end
    end
  end
  return {}
end

local function saveHistory(history)
  if FS and FS.directoryCreate then
    pcall(function() FS:directoryCreate(getConfigDir(), true) end)
  end
  local data = {
    updatedAt = os.date("%Y-%m-%d %H:%M:%S"),
    entries   = history,
  }
  if type(_G.jsonWriteFile) == "function" then
    local ok = pcall(_G.jsonWriteFile, getHistoryPath(), data, true)
    if ok then return true end
  end
  if type(_G.jsonEncode) == "function" and type(_G.writeFile) == "function" then
    local _, encoded = pcall(_G.jsonEncode, data, true)
    if encoded then return pcall(_G.writeFile, getHistoryPath(), encoded) end
  end
  return false
end

local function addHistoryEntry(entry)
  local history = M.state.history or {}
  table.insert(history, 1, entry)
  while #history > (M.state.maxHistory or 50) do
    table.remove(history)
  end
  M.state.history = history
  saveHistory(history)
  log("I", "checkpointTimer", string.format(
    "History saved: %s — %s (total %d)",
    entry.totalTimeFormatted, entry.route, #history
  ))
end

-- ===========================================================================
-- Push-обновление UI через guihooks.trigger
-- ===========================================================================

local function buildRoutesList()
  local out = {}
  if not M.state.routes then return out end
  for name, route in pairs(M.state.routes) do
    table.insert(out, {
      name      = name,
      cpCount   = #(route.checkpoints or {}),
      isActive  = runtime.activeRoute ~= nil and runtime.activeRoute.name == name,
    })
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function buildSplitsList()
  local out = {}
  for _, s in ipairs(runtime.splits) do
    local isBest  = false
    local isWorse = false
    local diff    = nil
    if s.bestDelta then
      diff = s.delta - s.bestDelta
      if diff < 0 then
        isBest = true
      elseif diff > 0 then
        isWorse = true
      end
    end
    table.insert(out, {
      name             = s.name,
      delta            = s.delta,
      total            = s.total,
      deltaFormatted   = formatTime(s.delta),
      totalFormatted   = formatTime(s.total),
      bestDelta        = s.bestDelta,
      bestDeltaFormatted = s.bestDelta and formatTime(s.bestDelta) or nil,
      isBest           = isBest,
      isWorse          = isWorse,
      diff             = diff,
      diffFormatted    = diff and string.format("%+.3f", diff) or nil,
    })
  end
  return out
end

local function buildHistoryList(maxN)
  maxN = maxN or 15
  local out = {}
  for i, e in ipairs(M.state.history or {}) do
    if i > maxN then break end
    local splitsShort = {}
    if e.splits then
      for _, s in ipairs(e.splits) do
        table.insert(splitsShort, {
          name           = s.name,
          deltaFormatted = s.deltaFormatted or formatTime(s.delta),
          totalFormatted = s.totalFormatted or formatTime(s.total),
        })
      end
    end
    table.insert(out, {
      date               = e.date,
      level              = e.level,
      route              = e.route,
      totalTime          = e.totalTime,
      totalTimeFormatted = e.totalTimeFormatted,
      splits             = splitsShort,
    })
  end
  return out
end

local function buildStatusPayload()
  local routeName = runtime.activeRoute and runtime.activeRoute.name or "none"
  local stageText = ""
  if runtime.recordingStage == 1 then stageText = "Waiting for START"
  elseif runtime.recordingStage == 2 then stageText = "Waiting for CP / FINISH"
  elseif runtime.recordingStage == 99 then stageText = "Waiting for FINISH" end

  return {
    level            = runtime.currentLevel or "unknown",
    route            = routeName,
    runActive        = runtime.runActive,
    currentTime      = runtime.runActive and (getSimTime() - runtime.runStartTime) or 0,
    currentTimeFormatted = runtime.runActive
                            and formatTime(getSimTime() - runtime.runStartTime)
                            or "00:00.000",
    recording        = runtime.recordingNewRoute,
    recordingName    = runtime.newRouteName,
    recordingStage   = stageText,
    cpPassed         = runtime.currentCheckpointIdx,
    cpTotal          = runtime.activeRoute and #(runtime.activeRoute.checkpoints or {}) or 0,
    splits           = buildSplitsList(),
    routes           = buildRoutesList(),
    history          = buildHistoryList(20),
    debugMode        = M.state.debugMode,
    showTriggerZones = M.state.showTriggerZones,
    showMapMarkers   = M.state.showMapMarkers,
    triggerRadius    = M.state.triggerRadius,
    triggerCheckHz   = M.state.triggerCheckHz,
    useSystemClock   = M.state.useSystemClock,
    bestSplitsCount  = (function()
      local n = 0
      for _ in pairs(runtime.bestSplits) do n = n + 1 end
      return n
    end)(),
  }
end

local function pushStatus()
  if not _G.guihooks or not _G.guihooks.trigger then return end
  local ok, payload = pcall(buildStatusPayload)
  if ok then
    pcall(_G.guihooks.trigger, "CTStatus", payload)
  end
end

-- ===========================================================================
-- Логика таймера
-- ===========================================================================

local function resetRun()
  runtime.runActive            = false
  runtime.runStartTime         = 0
  runtime.lastCheckpointTime   = 0
  runtime.currentCheckpointIdx = 0
  runtime.splits               = {}
  pushStatus()
end

local function startRun()
  local route = runtime.activeRoute
  if not route then
    log("W", "checkpointTimer", "Cannot start: no active route. Use 'ct sel <name>' first.")
    return
  end
  if runtime.runActive then resetRun() end
  runtime.runActive            = true
  runtime.runStartTime         = getSimTime()
  runtime.lastCheckpointTime   = runtime.runStartTime
  runtime.currentCheckpointIdx = 0
  runtime.splits               = {}
  table.insert(runtime.splits, {
    name  = "START",
    delta = 0,
    total = 0,
  })
  log("I", "checkpointTimer", string.format(
    "RUN STARTED on route '%s' (level '%s')",
    route.name, runtime.currentLevel
  ))
  pushStatus()
end

local function hitCheckpoint(idx)
  if not runtime.runActive then return end
  local now   = getSimTime()
  local total = now - runtime.runStartTime
  local delta = now - runtime.lastCheckpointTime
  runtime.lastCheckpointTime   = now
  runtime.currentCheckpointIdx = idx
  local cpName = (idx == -1) and "FINISH" or string.format("CP%d", idx)
  local bestDelta = nil
  local current_index = #runtime.splits + 1
  if runtime.bestSplits[current_index] then
    bestDelta = runtime.bestSplits[current_index].delta
  end
  table.insert(runtime.splits, {
    name      = cpName,
    delta     = delta,
    total     = total,
    bestDelta = bestDelta,
  })
  local cmpStr = ""
  if bestDelta then
    if delta < bestDelta then cmpStr = " (PERSONAL BEST!)"
    elseif delta > bestDelta then cmpStr = string.format(" (+%.3f)", delta - bestDelta) end
  end
  log("I", "checkpointTimer", string.format(
    "SPLIT %s: delta=%s total=%s%s",
    cpName, formatTime(delta), formatTime(total), cmpStr
  ))
  pushStatus()
end

local function finishRun()
  if not runtime.runActive then return end
  hitCheckpoint(-1)
  local totalTime = getSimTime() - runtime.runStartTime
  runtime.runActive = false
  local routeName = runtime.activeRoute and runtime.activeRoute.name or "?"
  local newBest = false
  for i, split in ipairs(runtime.splits) do
    if not runtime.bestSplits[i] or split.delta < (runtime.bestSplits[i].delta or math.huge) then
      runtime.bestSplits[i] = {
        name  = split.name,
        delta = split.delta,
      }
      newBest = true
    end
  end
  local entry = {
    date               = os.date("%Y-%m-%d %H:%M:%S"),
    timestamp          = os.time(),
    level              = runtime.currentLevel,
    route              = routeName,
    totalTime          = totalTime,
    totalTimeFormatted = formatTime(totalTime),
    splits             = {},
  }
  for _, s in ipairs(runtime.splits) do
    table.insert(entry.splits, {
      name             = s.name,
      delta            = s.delta,
      deltaFormatted   = formatTime(s.delta),
      total            = s.total,
      totalFormatted   = formatTime(s.total),
    })
  end
  addHistoryEntry(entry)
  local tag = newBest and " *** NEW BEST SPLITS ***" or ""
  log("I", "checkpointTimer", string.format(
    "RUN FINISHED: total=%s route='%s'%s",
    formatTime(totalTime), routeName, tag
  ))
  pushStatus()
end

local function checkTriggers()
  local route = runtime.activeRoute
  if not route then return end
  local pos = getVehiclePos()
  if not pos then return end
  if not runtime.runActive then
    if route.start then
      local d = dist3D(pos, route.start)
      if d < M.state.triggerRadius then
        startRun()
        return
      end
    end
    return
  end
  local cpIdx = runtime.currentCheckpointIdx
  local checkpoints = route.checkpoints or {}
  if cpIdx < #checkpoints then
    local nextCP = checkpoints[cpIdx + 1]
    if nextCP then
      local d = dist3D(pos, nextCP)
      if d < M.state.triggerRadius then
        hitCheckpoint(cpIdx + 1)
        return
      end
    end
  end
  if route.finish and cpIdx >= #checkpoints then
    local d = dist3D(pos, route.finish)
    if d < M.state.triggerRadius then
      finishRun()
    end
  end
end

-- ===========================================================================
-- Запись нового маршрута
-- ===========================================================================

local finalizeRecording

local function recordPosition(label)
  local pos = getVehiclePos()
  if not pos then
    log("W", "checkpointTimer", "No vehicle to record " .. tostring(label))
    return nil
  end
  if M.state.terrainSnap then
    local th = getTerrainHeight(pos.x, pos.y)
    if th and type(th) == "number" then
      local oldZ = pos.z
      pos.z = th
      log("I", "checkpointTimer", string.format(
        "  Terrain snap: Z %.2f -> %.2f (delta %.2f)",
        oldZ, th, th - oldZ
      ))
    end
  end
  log("I", "checkpointTimer", string.format(
    "RECORDED %s: (%.2f, %.2f, %.2f)",
    label, pos.x, pos.y, pos.z
  ))
  return pos
end

local function startRecordingRoute(name)
  if not name or name == "" then
    name = "Route_" .. os.date("%H%M%S")
  end
  runtime.recordingNewRoute  = true
  runtime.newRouteName       = name
  runtime.recordingStage     = 1
  runtime.activeRoute        = {
    name        = name,
    start       = nil,
    checkpoints = {},
    finish      = nil,
  }
  log("I", "checkpointTimer", "RECORDING new route: " .. name)
  log("I", "checkpointTimer", "  Drive to START position, then: ct rec next")
  pushStatus()
end

local function recordNext()
  if not runtime.recordingNewRoute then
    log("W", "checkpointTimer", "Not recording. Use 'ct rec start <name>' first.")
    return
  end
  local route = runtime.activeRoute
  if not route then return end
  if runtime.recordingStage == 1 then
    route.start = recordPosition("START")
    if route.start then
      runtime.recordingStage = 2
      log("I", "checkpointTimer", "START recorded. Drive to checkpoint, then: ct rec next")
      log("I", "checkpointTimer", "  Or: ct rec finish   to record FINISH directly")
      pushStatus()
    end
  elseif runtime.recordingStage == 2 then
    local cp = recordPosition("CP#" .. (#route.checkpoints + 1))
    if cp then
      table.insert(route.checkpoints, cp)
      log("I", "checkpointTimer", string.format(
        "CP#%d recorded. 'ct rec next' for more, or 'ct rec finish' for FINISH",
        #route.checkpoints
      ))
      pushStatus()
    end
  elseif runtime.recordingStage == 99 then
    route.finish = recordPosition("FINISH")
    if route.finish then
      finalizeRecording()
    end
  end
end

local function recordFinish()
  if not runtime.recordingNewRoute then
    log("W", "checkpointTimer", "Not recording.")
    return
  end
  runtime.recordingStage = 99
  recordNext()
end

finalizeRecording = function()
  local route = runtime.activeRoute
  if not route then return end
  if not route.start then
    log("W", "checkpointTimer", "Cannot finalize: START not recorded")
    return
  end
  if not route.finish then
    log("W", "checkpointTimer", "Cannot finalize: FINISH not recorded")
    return
  end
  M.state.routes = M.state.routes or {}
  M.state.routes[route.name] = route
  saveMapConfig(runtime.currentLevel, M.state.routes)
  runtime.recordingNewRoute = false
  runtime.recordingStage    = 0
  log("I", "checkpointTimer", string.format(
    "ROUTE SAVED: '%s' — START + %d CP + FINISH",
    route.name, #(route.checkpoints or {})
  ))
  updateMapMarkers()
  pushStatus()
end

local function cancelRecording()
  runtime.recordingNewRoute = false
  runtime.recordingStage    = 0
  runtime.activeRoute       = nil
  log("I", "checkpointTimer", "Recording cancelled.")
  pushStatus()
end

local function selectRoute(name)
  if not name or name == "" then
    log("W", "checkpointTimer", "Usage: ct sel <routeName>")
    return false
  end
  local routes = M.state.routes or {}
  if not routes[name] then
    log("W", "checkpointTimer", "Route not found: " .. tostring(name))
    return false
  end
  resetRun()
  runtime.activeRoute = routes[name]
  runtime.bestSplits  = {}
  updateMapMarkers()
  log("I", "checkpointTimer", "Route selected: " .. name)
  pushStatus()
  return true
end

local function deleteRoute(name)
  if not name or name == "" then return false end
  if not M.state.routes or not M.state.routes[name] then
    log("W", "checkpointTimer", "Route not found: " .. name)
    return false
  end
  M.state.routes[name] = nil
  saveMapConfig(runtime.currentLevel, M.state.routes)
  if runtime.activeRoute and runtime.activeRoute.name == name then
    runtime.activeRoute = nil
    resetRun()
  end
  log("I", "checkpointTimer", "Route deleted: " .. name)
  pushStatus()
  return true
end

local function clearHistory()
  M.state.history = {}
  saveHistory(M.state.history)
  log("I", "checkpointTimer", "History cleared.")
  pushStatus()
end

-- ===========================================================================
-- Консольный API (вызывается из консоли: checkpointTimer.ct_command("..."))
-- ===========================================================================

function M.ct_command(cmd)
  if not cmd or cmd == "" then
    M.ct_help()
    return
  end

  local parts = {}
  for part in cmd:gmatch("%S+") do
    table.insert(parts, part)
  end

  local action = parts[1] or ""
  local arg    = parts[2] or ""

  if action == "help" then
    M.ct_help()
  elseif action == "rec" then
    if arg == "start" then
      startRecordingRoute(parts[3])
    elseif arg == "next" then
      recordNext()
    elseif arg == "finish" then
      recordFinish()
    elseif arg == "cancel" then
      cancelRecording()
    else
      log("I", "checkpointTimer", "ct rec: start <name> | next | finish | cancel")
    end
  elseif action == "sel" then
    selectRoute(table.concat({select(3, unpack(parts))}, " ") or arg)
  elseif action == "del" then
    deleteRoute(arg)
  elseif action == "list" then
    M.ct_list()
  elseif action == "info" then
    M.ct_info()
  elseif action == "reset" then
    resetRun()
    log("I", "checkpointTimer", "Run reset")
  elseif action == "history" then
    M.ct_history()
  elseif action == "clearhistory" then
    clearHistory()
  elseif action == "debug" then
    M.state.debugMode = not M.state.debugMode
    log("I", "checkpointTimer", "Debug mode: " .. (M.state.debugMode and "ON" or "OFF"))
    pushStatus()
  elseif action == "zones" then
    M.state.showTriggerZones = not M.state.showTriggerZones
    log("I", "checkpointTimer", "Ground circles: " .. (M.state.showTriggerZones and "ON" or "OFF"))
    pushStatus()
  elseif action == "mapmarkers" then
    if arg == "on" then
      M.state.showMapMarkers = true
      log("I", "checkpointTimer", "Map markers: ON")
      updateMapMarkers()
    elseif arg == "off" then
      M.state.showMapMarkers = false
      clearMapMarkers()
      log("I", "checkpointTimer", "Map markers: OFF")
    else
      M.state.showMapMarkers = not M.state.showMapMarkers
      if M.state.showMapMarkers then
        updateMapMarkers()
      else
        clearMapMarkers()
      end
      log("I", "checkpointTimer", "Map markers: " .. tostring(M.state.showMapMarkers))
    end
    pushStatus()
  elseif action == "radius" then
    local r = tonumber(arg)
    if r and r > 0 then
      M.state.triggerRadius = r
      log("I", "checkpointTimer", "Trigger radius = " .. r .. "m")
      pushStatus()
    else
      log("W", "checkpointTimer", "Usage: ct radius <meters>")
    end
  elseif action == "hz" then
    local h = tonumber(arg)
    if h and h > 0 then
      M.state.triggerCheckHz = h
      log("I", "checkpointTimer", "Trigger check = " .. h .. " Hz")
      pushStatus()
    end
  elseif action == "start" then
    startRun()
  elseif action == "cp" then
    local idx = runtime.currentCheckpointIdx + 1
    local route = runtime.activeRoute
    if route and route.checkpoints and idx <= #route.checkpoints then
      hitCheckpoint(idx)
    else
      log("W", "checkpointTimer", "No more checkpoints in route")
    end
  elseif action == "finish" then
    finishRun()
  elseif action == "push" then
    pushStatus()
  elseif action == "diag" then
    runDiagnostics()
  elseif action == "reload" then
    runtime.currentLevel = getCurrentLevel()
    M.state.routes = loadMapConfig(runtime.currentLevel)
    M.state.history = loadHistory()
    log("I", "checkpointTimer", "Reloaded config for level: " .. runtime.currentLevel)
    updateMapMarkers()
    pushStatus()
  elseif action == "sysclock" then
    if arg == "on" then
      M.state.useSystemClock = true
      log("I", "checkpointTimer", "System clock timer: ON (using os.clock)")
    elseif arg == "off" then
      M.state.useSystemClock = false
      log("I", "checkpointTimer", "System clock timer: OFF (using game simulation time)")
    else
      M.state.useSystemClock = not M.state.useSystemClock
      log("I", "checkpointTimer", "System clock timer: " .. (M.state.useSystemClock and "ON (using os.clock)" or "OFF (using game simulation time)"))
    end
    pushStatus()
  elseif action == "circler" then
    local v = tonumber(arg)
    if v and v >= 0.5 and v <= 20 then
      M.state.circleRadius = v
      log("I", "checkpointTimer", "Circle radius: " .. v .. "m")
    else
      log("W", "checkpointTimer", "Usage: ct circler <0.5-20>")
    end
  elseif action == "pulse" then
    if arg == "on" then
      M.state.circlePulse = true
      log("I", "checkpointTimer", "Circle pulse: ON")
    elseif arg == "off" then
      M.state.circlePulse = false
      log("I", "checkpointTimer", "Circle pulse: OFF")
    else
      M.state.circlePulse = not M.state.circlePulse
      log("I", "checkpointTimer", "Circle pulse: " .. tostring(M.state.circlePulse))
    end
  elseif action == "segs" then
    local v = tonumber(arg)
    if v and v >= 8 and v <= 128 then
      M.state.circleSegments = math.floor(v)
      log("I", "checkpointTimer", "Circle segments: " .. M.state.circleSegments)
    else
      log("W", "checkpointTimer", "Usage: ct segs <8-128>")
    end
  else
    log("W", "checkpointTimer", "Unknown command: " .. action .. ". Type 'ct help'")
  end
end

function M.ct_help()
  log("I", "checkpointTimer", [[
=== CheckpointTimer v3.0 Commands ===
  ct help                  — This help
  ct rec start <name>      — Start recording a new route
  ct rec next              — Record current position as next waypoint
  ct rec finish            — Record FINISH and save route
  ct rec cancel            — Cancel recording
  ct sel <name>            — Select a route (shows map markers)
  ct del <name>            — Delete a route
  ct list                  — List all routes on current map
  ct info                  — Show current run status
  ct start                 — Manually start the run
  ct cp                    — Manually hit next checkpoint
  ct finish                — Manually finish the run
  ct reset                 — Reset current run
  ct history               — Show run history
  ct clearhistory          — Clear all history
  ct debug                 — Toggle debug mode
  ct zones                 — Toggle ground circles (debugDrawer)
  ct mapmarkers [on|off]   — Toggle map markers (minimap)
  ct radius <meters>       — Set trigger zone detection radius (default 3.0)
  ct hz <Hz>               — Set trigger check rate (default 20)
  ct circler <m>           — Set circle visual radius in meters (default 2.5)
  ct pulse [on|off]        — Toggle circle pulse animation (default on)
  ct segs <n>              — Set circle segments 8-128 (default 48)
  ct diag                  — Show diagnostics
  ct push                  — Force-push status to UI
  ct reload                — Reload config for current level

Auto-detection: drive through START zone to begin,
then through each checkpoint, finish at FINISH zone.

Map markers show checkpoint positions on the minimap (green=start, yellow=CP, red=finish).
Ground circles are drawn on the terrain via debugDrawer (GTA SA style).
]])
end

function M.ct_list()
  local routes = M.state.routes or {}
  local count = 0
  for name, route in pairs(routes) do
    count = count + 1
    local isActive = runtime.activeRoute and runtime.activeRoute.name == name
    local marker = isActive and " [ACTIVE]" or ""
    log("I", "checkpointTimer", string.format(
      "  %d. %s%s — START + %d CP + FINISH",
      count, name, marker, #(route.checkpoints or {})
    ))
  end
  if count == 0 then
    log("I", "checkpointTimer", "No routes on this map. Use 'ct rec start <name>'.")
  end
end

function M.ct_info()
  local level       = runtime.currentLevel or "?"
  local routeName   = runtime.activeRoute and runtime.activeRoute.name or "none"
  local runStatus   = runtime.runActive and "RUNNING" or "stopped"
  local recording   = runtime.recordingNewRoute and ("RECORDING " .. runtime.newRouteName) or "no"
  log("I", "checkpointTimer", string.format(
    "Map: %s | Route: %s | Run: %s | Recording: %s",
    level, routeName, runStatus, recording
  ))
  log("I", "checkpointTimer", string.format(
    "Map markers: %s | Ground circles: %s | Segments: %d | Radius: %.1fm | System clock: %s",
    tostring(M.state.showMapMarkers), tostring(M.state.showTriggerZones),
    M.state.circleSegments, M.state.circleRadius, tostring(M.state.useSystemClock)
  ))
  if runtime.runActive then
    local elapsed = getSimTime() - runtime.runStartTime
    log("I", "checkpointTimer", string.format(
      "  Elapsed: %s | CP: %d/%d",
      formatTime(elapsed),
      runtime.currentCheckpointIdx,
      #(runtime.activeRoute and runtime.activeRoute.checkpoints or {})
    ))
  end
  if #runtime.splits > 0 then
    log("I", "checkpointTimer", "  Splits:")
    for _, s in ipairs(runtime.splits) do
      local bestStr = ""
      if s.bestDelta then
        if s.delta < s.bestDelta then bestStr = " (BEST)"
        elseif s.delta > s.bestDelta then bestStr = string.format(" (+%.3f)", s.delta - s.bestDelta) end
      end
      log("I", "checkpointTimer", string.format(
        "    %s: %s (total %s)%s",
        s.name, formatTime(s.delta), formatTime(s.total), bestStr
      ))
    end
  end
end

function M.ct_history()
  local entries = M.state.history or {}
  if #entries == 0 then
    log("I", "checkpointTimer", "History is empty.")
    return
  end
  log("I", "checkpointTimer", string.format("=== HISTORY (%d entries) ===", #entries))
  for i, e in ipairs(entries) do
    if i > 15 then
      log("I", "checkpointTimer", string.format("  ... and %d more", #entries - 15))
      break
    end
    log("I", "checkpointTimer", string.format(
      "  %d. [%s] %s / %s — %s",
      i, e.date or "?", e.level or "?", e.route or "?", e.totalTimeFormatted or "?"
    ))
    if e.splits then
      for _, s in ipairs(e.splits) do
        log("I", "checkpointTimer", string.format(
          "       %s: %s (total %s)",
          s.name or "?", s.deltaFormatted or "?", s.totalFormatted or "?"
        ))
      end
    end
  end
end

-- ===========================================================================
-- debugDrawer утилиты
-- ===========================================================================
-- ВАЖНО: debugDrawer в GELUA требует строгой типизации:
--   позиции: Point3F (не vec3, не table!)
--   цвета: ColorF(r,g,b,a) (не table!)
--   текст: String(...) (не plain Lua string!)
-- ===========================================================================

local ddMethodCache = {}

local function ddCall(methodName, ...)
  local dd = debugDrawer or _G.debugDrawer
  if not dd then return false end
  if ddMethodCache[methodName] == false then return false end
  local fn = dd[methodName]
  if not fn then
    ddMethodCache[methodName] = false
    return false
  end
  local ok = pcall(fn, dd, ...)
  if not ok then
    ddMethodCache[methodName] = false
    return false
  end
  ddMethodCache[methodName] = true
  if methodName == "drawLine" or methodName == "drawCylinder" or
     methodName == "drawSphere" or methodName == "drawSphereDebug" or
     methodName == "drawTriSolid" or methodName == "drawSquarePrism" then
    pcall(function() dd:setLastZTest(false) end)
    pcall(function() dd:setLastTTL(0.1) end)
  end
  return true
end

local function makeColor(r, g, b, a)
  if type(_G.ColorF) == "function" then
    local ok, c = pcall(_G.ColorF, r, g, b, a)
    if ok then return c end
  end
  return nil
end

local function makeColorI(r, g, b, a)
  if type(_G.ColorI) == "function" then
    local ok, c = pcall(_G.ColorI, r, g, b, a)
    if ok then return c end
  end
  return nil
end

local function makeP3F(x, y, z)
  if type(_G.Point3F) == "function" or type(_G.Point3F) == "table" then
    local ok, p = pcall(_G.Point3F, x, y, z)
    if ok and p then
      if not ddMethodCache._p3fMethod then ddMethodCache._p3fMethod = "Point3F()" end
      return p
    end
  end
  if type(_G.vec3) == "function" then
    local ok, v = pcall(_G.vec3, x, y, z)
    if ok and v then
      if v.toPoint3F then
        local ok2, p = pcall(function() return v:toPoint3F() end)
        if ok2 and p then
          if not ddMethodCache._p3fMethod then ddMethodCache._p3fMethod = "vec3():toPoint3F()" end
          return p
        end
      end
      if not ddMethodCache._p3fMethod then ddMethodCache._p3fMethod = "vec3() direct" end
      return v
    end
  end
  if not ddMethodCache._p3fMethod then ddMethodCache._p3fMethod = "plain table" end
  return {x = x, y = y, z = z}
end

local function makeStr(s)
  if type(_G.String) == "function" then
    local ok, str = pcall(_G.String, tostring(s))
    if ok then return str end
  end
  return tostring(s)
end

-- ===========================================================================
-- Рисование наземного круга (GTA SA стиль) через debugDrawer
-- ===========================================================================

function drawGroundCircle(pos, color, label, activeNow)
  if not pos or not color then return end
  local dd = debugDrawer or _G.debugDrawer
  if not dd then return end

  local cx, cy, cz = pos.x or 0, pos.y or 0, pos.z or 0

  -- Пульсация
  local baseR = M.state.circleRadius or 2.5
  local r = baseR
  if M.state.circlePulse then
    local t = getSimTime() or 0
    local speed = M.state.circlePulseSpeed or 2.0
    local amp = M.state.circlePulseAmp or 0.4
    r = baseR + amp * math.sin(t * speed * math.pi * 2)
  end
  r = math.max(0.5, r)

  local segs = M.state.circleSegments or 48
  local groundZ = cz + 0.15

  -- Логирование P3F метода (один раз)
  if not ddMethodCache._p3fLogged then
    log("I", "checkpointTimer", "debugDrawer P3F method: " .. tostring(ddMethodCache._p3fMethod or "?"))
    ddMethodCache._p3fLogged = true
  end

  -- 1. Основной круг
  local prevPt = nil
  for i = 0, segs do
    local angle = (i / segs) * math.pi * 2
    local px = cx + r * math.cos(angle)
    local py = cy + r * math.sin(angle)
    local pt = makeP3F(px, py, groundZ)
    if prevPt and pt then
      ddCall("drawLine", prevPt, pt, color)
    end
    prevPt = pt
  end

  -- 2. Внутренний круг (половина радиуса)
  local innerR = r * 0.5
  prevPt = nil
  local innerColor = makeColor(
    (color.r or 0) * 0.7,
    (color.g or 0) * 0.7,
    (color.b or 0) * 0.7,
    0.6
  )
  for i = 0, segs do
    local angle = (i / segs) * math.pi * 2
    local px = cx + innerR * math.cos(angle)
    local py = cy + innerR * math.sin(angle)
    local pt = makeP3F(px, py, groundZ + 0.02)
    if prevPt and pt and innerColor then
      ddCall("drawLine", prevPt, pt, innerColor)
    end
    prevPt = pt
  end

  -- 3. Крест (+) в центре
  local crossSize = r * 0.35
  local crossZ = groundZ + 0.03
  local crossColor = makeColor(1, 1, 1, 0.8)
  if crossColor then
    local n = makeP3F(cx - crossSize, cy, crossZ)
    local s = makeP3F(cx + crossSize, cy, crossZ)
    local w = makeP3F(cx, cy - crossSize, crossZ)
    local e = makeP3F(cx, cy + crossSize, crossZ)
    if n and s then ddCall("drawLine", n, s, crossColor) end
    if w and e then ddCall("drawLine", w, e, crossColor) end
  end

  -- 4. Точка-маркер в центре (маленькая сфера)
  local centerPt = makeP3F(cx, cy, groundZ + 0.2)
  if centerPt then
    local sphereColor = makeColor(color.r or 0, color.g or 0, color.b or 0, 0.9)
    if sphereColor then
      if not ddCall("drawSphereDebug", centerPt, 0.3, sphereColor) then
        ddCall("drawSphere", centerPt, 0.3, sphereColor)
      end
    end
  end

  -- 5. 4 радиальные линии (12, 3, 6, 9 часов)
  local lineColor = makeColor(color.r or 0, color.g or 0, color.b or 0, 0.5)
  if lineColor then
    for k = 0, 3 do
      local angle = k * math.pi / 2
      local ex = cx + r * math.cos(angle)
      local ey = cy + r * math.sin(angle)
      local p1 = makeP3F(cx, cy, groundZ + 0.04)
      local p2 = makeP3F(ex, ey, groundZ + 0.04)
      if p1 and p2 then ddCall("drawLine", p1, p2, lineColor) end
    end
  end

  -- 6. Подпись над кругом
  local labelPos = makeP3F(cx, cy, cz + 2.5)
  local labelColor = makeColor(1, 1, 1, 1)
  local labelStr = makeStr(label)
  local bgColor = makeColorI(0, 0, 0, 200)
  if labelPos and labelColor and labelStr then
    if not ddCall("drawTextAdvanced", labelPos, labelStr, labelColor, true, false, bgColor) then
      ddCall("drawText", labelPos, labelStr, labelColor)
    end
  end
end

-- ===========================================================================
-- Метки чекпоинтов на миникарте мира (v3.0)
--
-- Пробуем несколько API через которые BeamNG отображает маркеры на карте:
--   1. core_map.setMarker(id, pos, label, color)  — основной BeamNG API
--   2. be:setMarker / be:addMarker               — engine interface
--   3. scenetree.createObject("Marker")          — Torque3D SceneObject
-- Все обёрнуты в pcall для безопасности.
-- ===========================================================================

-- Кэш: какой API для маркеров работает
local _mapMarkerApi = nil  -- "core_map" | "be" | "sceneobject" | nil

-- Установить одну метку на карте
-- id: string — уникальный ID (для последующего удаления)
-- pos: {x, y, z}
-- label: string — текст метки
-- r, g, b: 0-1 — цвет
local function setMapMarker(id, pos, label, r, g, b)
  if not pos then return false end
  local px, py, pz = pos.x or 0, pos.y or 0, pos.z or 0

  -- Способ 1: core_map.setMarker(id, pos, label, color)
  -- Это основной BeamNG API для меток на миникарте
  if not _mapMarkerApi or _mapMarkerApi == "core_map" then
    if type(_G.core_map) == "table" then
      -- Пробуем разные сигнатуры core_map
      -- Вариант A: core_map.setMarker(id, pos, label, color)
      if type(_G.core_map.setMarker) == "function" then
        local ok = pcall(function()
          local color = {r = r or 1, g = g or 1, b = b or 1, a = 1}
          _G.core_map.setMarker(id, {x = px, y = py, z = pz}, label, color)
        end)
        if ok then
          _mapMarkerApi = "core_map"
          return true
        end
      end
      -- Вариант B: core_map.addMarker(opts)
      if type(_G.core_map.addMarker) == "function" then
        local ok = pcall(function()
          _G.core_map.addMarker({
            id    = id,
            pos   = {x = px, y = py, z = pz},
            label = label,
            color = {r = r or 1, g = g or 1, b = b or 1, a = 1},
          })
        end)
        if ok then
          _mapMarkerApi = "core_map"
          return true
        end
      end
      -- Вариант C: core_map.set(id, {pos, label, color})
      if type(_G.core_map.set) == "function" then
        local ok = pcall(function()
          _G.core_map.set(id, {
            pos   = {x = px, y = py, z = pz},
            label = label,
            color = {r = r or 1, g = g or 1, b = b or 1, a = 1},
          })
        end)
        if ok then
          _mapMarkerApi = "core_map"
          return true
        end
      end
    end
  end

  -- Способ 2: be:setMarker / be:addMarker
  if not _mapMarkerApi or _mapMarkerApi == "be" then
    if type(_G.be) == "table" then
      if type(_G.be.setMarker) == "function" then
        local ok = pcall(function()
          _G.be:setMarker(id, _G.vec3 and _G.vec3(px, py, pz) or {x=px, y=py, z=pz}, label)
        end)
        if ok then
          _mapMarkerApi = "be"
          return true
        end
      end
      if type(_G.be.addMarker) == "function" then
        local ok = pcall(function()
          _G.be:addMarker(id, _G.vec3 and _G.vec3(px, py, pz) or {x=px, y=py, z=pz}, label)
        end)
        if ok then
          _mapMarkerApi = "be"
          return true
        end
      end
    end
  end

  -- Способ 3: Создание SimObject "Marker" в сцене
  -- Torque3D Marker объекты отображаются на миникарте автоматически
  if not _mapMarkerApi or _mapMarkerApi == "sceneobject" then
    if type(_G.createObject) == "function" then
      local ok = pcall(function()
        local obj = _G.createObject("Marker")
        if not obj then return false end
        if type(_G.vec3) == "function" then
          local v = _G.vec3(px, py, pz)
          pcall(function() obj:setPosition(v) end)
          pcall(function() obj.position = v end)
        end
        -- Устанавливаем имя для идентификации
        pcall(function() obj:setField("name", 0, id) end)
        pcall(function() obj:registerObject(id) end)
      end)
      if ok then
        _mapMarkerApi = "sceneobject"
        return true
      end
    end
  end

  return false
end

-- Удалить одну метку с карты по ID
local function removeMapMarker(id)
  -- Способ 1: core_map
  if type(_G.core_map) == "table" then
    if type(_G.core_map.removeMarker) == "function" then
      pcall(function() _G.core_map.removeMarker(id) end)
      return
    end
    if type(_G.core_map.deleteMarker) == "function" then
      pcall(function() _G.core_map.deleteMarker(id) end)
      return
    end
    if type(_G.core_map.remove) == "function" then
      pcall(function() _G.core_map.remove(id) end)
      return
    end
    if type(_G.core_map.clearMarker) == "function" then
      pcall(function() _G.core_map.clearMarker(id) end)
      return
    end
  end

  -- Способ 2: be
  if type(_G.be) == "table" then
    if type(_G.be.removeMarker) == "function" then
      pcall(function() _G.be:removeMarker(id) end)
      return
    end
    if type(_G.be.deleteMarker) == "function" then
      pcall(function() _G.be:deleteMarker(id) end)
      return
    end
  end

  -- Способ 3: scenetree — ищем и удаляем объект по имени
  if type(_G.scenetree) == "table" and type(_G.scenetree.findObject) == "function" then
    local ok, obj = pcall(function() return _G.scenetree.findObject(id) end)
    if ok and obj and type(obj.delete) == "function" then
      pcall(function() obj:delete() end)
    end
  end
end

-- Удалить все маркеры чекпоинтов с карты
function clearMapMarkers()
  for _, id in ipairs(runtime.mapMarkerIds) do
    removeMapMarker(id)
  end
  runtime.mapMarkerIds = {}
  runtime.mapMarkerRoute = nil
end

-- Обновить все маркеры на карте для текущего активного маршрута
-- Вызывается при смене маршрута, завершении записи, перезагрузке
function updateMapMarkers()
  -- Сначала удаляем старые
  clearMapMarkers()

  -- Если выключены или нет маршрута — выходим
  if not M.state.showMapMarkers then return end
  local route = runtime.activeRoute
  if not route then return end

  local prefix = "ct_map_"
  local markerCount = 0

  -- Логируем доступность API (один раз)
  if not runtime._mapApiLogged then
    log("I", "checkpointTimer", string.format(
      "Map marker APIs: core_map=%s be=%s createObject=%s",
      tostring(_G.core_map ~= nil), tostring(type(_G.be) == "table"),
      tostring(_G.createObject ~= nil)
    ))
    if type(_G.core_map) == "table" then
      for k, v in pairs(_G.core_map) do
        if type(v) == "function" and (k:find("marker") or k:find("Marker") or k:find("set") or k:find("add") or k:find("remove") or k:find("delete")) then
          log("I", "checkpointTimer", "  core_map." .. k .. " = function")
        end
      end
    end
    runtime._mapApiLogged = true
  end

  -- СТАРТ — зелёный
  if route.start then
    local id = prefix .. "start"
    if setMapMarker(id, route.start, "START", 0.1, 1.0, 0.3) then
      table.insert(runtime.mapMarkerIds, id)
      markerCount = markerCount + 1
    end
  end

  -- ЧЕКПОИНТЫ — жёлтые
  if route.checkpoints then
    for i, cp in ipairs(route.checkpoints) do
      local id = prefix .. "cp" .. i
      local label = "CP" .. i
      if setMapMarker(id, cp, label, 1.0, 0.85, 0.0) then
        table.insert(runtime.mapMarkerIds, id)
        markerCount = markerCount + 1
      end
    end
  end

  -- ФИНИШ — красный
  if route.finish then
    local id = prefix .. "finish"
    if setMapMarker(id, route.finish, "FINISH", 1.0, 0.15, 0.15) then
      table.insert(runtime.mapMarkerIds, id)
      markerCount = markerCount + 1
    end
  end

  runtime.mapMarkerRoute = route.name

  if markerCount > 0 then
    log("I", "checkpointTimer", string.format(
      "Map markers: %d placed via '%s' API for route '%s'",
      markerCount, _mapMarkerApi or "unknown", route.name
    ))
  else
    log("W", "checkpointTimer", "Map markers: FAILED to place any markers — no working API found")
    log("W", "checkpointTimer", "  Ground circles (debugDrawer) still work as fallback visual")
  end
end

-- ===========================================================================
-- Рендер триггер-зон (наземные круги через debugDrawer)
-- ===========================================================================

local function renderTriggerZones()
  -- 3D rendering is completely disabled.
end


-- ===========================================================================
-- Диагностика
-- ===========================================================================

runDiagnostics = function()
  log("I", "checkpointTimer", "=== DIAGNOSTICS v3.0 ===")

  -- debugDrawer
  local dd = debugDrawer or _G.debugDrawer
  log("I", "checkpointTimer", "  debugDrawer available: " .. tostring(dd ~= nil))
  if dd then
    local enabled = nil
    if dd.getDrawingEnabled then
      local ok, v = pcall(function() return dd:getDrawingEnabled() end)
      if ok then enabled = v end
    end
    log("I", "checkpointTimer", "  getDrawingEnabled: " .. tostring(enabled))
    if enabled == false then
      log("W", "checkpointTimer", "  -> Drawing DISABLED! Enabling...")
      pcall(function() dd:setDrawingEnabled(true) end)
    end
    local methods = {"drawLine", "drawSphere", "drawSphereDebug",
                     "drawText", "drawTextAdvanced",
                     "setLastZTest", "setLastTTL", "setDrawingEnabled"}
    for _, m in ipairs(methods) do
      log("I", "checkpointTimer", string.format("  dd:%s -> %s", m, tostring(dd[m] ~= nil)))
    end

    -- Тестовая сфера
    local veh = getPlayerVehicle()
    if veh then
      local pos = veh:getPosition()
      if pos then
        local testP3F = makeP3F(pos.x, pos.y, pos.z + 3)
        local testColor = makeColor(1, 0, 1, 0.8)
        if testP3F and testColor then
          pcall(function() dd:drawSphere(testP3F, 1.5, testColor) end)
          pcall(function() dd:setLastZTest(false) end)
          pcall(function() dd:setLastTTL(5) end)
          log("I", "checkpointTimer", "  TEST: purple sphere above car (5s)")
        end
      end
    end
  end

  -- Типы
  log("I", "checkpointTimer", "  vec3=" .. tostring(_G.vec3 ~= nil)
    .. "  Point3F=" .. tostring(_G.Point3F ~= nil)
    .. "  ColorF=" .. tostring(_G.ColorF ~= nil)
    .. "  ColorI=" .. tostring(_G.ColorI ~= nil)
    .. "  String=" .. tostring(_G.String ~= nil))

  -- Map marker API
  log("I", "checkpointTimer", "  --- Map Markers ---")
  log("I", "checkpointTimer", "  showMapMarkers: " .. tostring(M.state.showMapMarkers))
  log("I", "checkpointTimer", "  mapMarkerApi: " .. tostring(_mapMarkerApi or "not detected"))
  log("I", "checkpointTimer", "  core_map: " .. tostring(_G.core_map ~= nil))
  if type(_G.core_map) == "table" then
    local markerFns = {}
    for k, v in pairs(_G.core_map) do
      if type(v) == "function" then
        table.insert(markerFns, k)
      end
    end
    table.sort(markerFns)
    for _, fn in ipairs(markerFns) do
      log("I", "checkpointTimer", "    core_map." .. fn)
    end
  end
  log("I", "checkpointTimer", "  createObject: " .. tostring(_G.createObject ~= nil))
  log("I", "checkpointTimer", "  markers placed: " .. #runtime.mapMarkerIds)

  -- Маршрут
  log("I", "checkpointTimer", "  --- Route ---")
  log("I", "checkpointTimer", "  activeRoute: " .. tostring(runtime.activeRoute and runtime.activeRoute.name or "nil"))
  if runtime.activeRoute then
    local r = runtime.activeRoute
    log("I", "checkpointTimer", string.format("  route: %s | start=%s | CP=%d | finish=%s",
      r.name or "?", tostring(r.start ~= nil), #(r.checkpoints or {}), tostring(r.finish ~= nil)))
  end
  log("I", "checkpointTimer", "  circleRadius=" .. tostring(M.state.circleRadius)
    .. "m  segs=" .. tostring(M.state.circleSegments)
    .. "  pulse=" .. tostring(M.state.circlePulse))
  log("I", "checkpointTimer", "  triggerRadius=" .. tostring(M.state.triggerRadius) .. "m")
  log("I", "checkpointTimer", "=== /DIAGNOSTICS ===")
end

-- ===========================================================================
-- Хуки расширения
-- ===========================================================================

function M.onExtensionLoaded()
  log("I", "checkpointTimer", "=====================================")
  log("I", "checkpointTimer", "CheckpointTimer v3.0 loaded")
  log("I", "checkpointTimer", "Map markers + ground circles (debugDrawer)")
  log("I", "checkpointTimer", "Type 'checkpointTimer.ct_help()' or use UI app")
  log("I", "checkpointTimer", "=====================================")

  runtime.currentLevel = getCurrentLevel()
  log("I", "checkpointTimer", "Current level: " .. runtime.currentLevel)

  M.state.routes  = loadMapConfig(runtime.currentLevel)
  M.state.history = loadHistory()

  local routeCount = 0
  for _ in pairs(M.state.routes or {}) do routeCount = routeCount + 1 end
  log("I", "checkpointTimer", string.format("Loaded %d routes, %d history entries",
    routeCount, #(M.state.history or {})))

  -- Включаем debugDrawer
  local dd = debugDrawer or _G.debugDrawer
  if dd then
    if dd.setDrawingEnabled then
      pcall(function() dd:setDrawingEnabled(true) end)
    end
    local enabled = "?"
    if dd.getDrawingEnabled then
      local ok, v = pcall(function() return dd:getDrawingEnabled() end)
      if ok then enabled = tostring(v) end
    end
    log("I", "checkpointTimer", "debugDrawer: available (drawingEnabled=" .. enabled .. ")")
  else
    log("W", "checkpointTimer", "debugDrawer: NOT available — ground circles will not show")
  end

  pushStatus()
end

function M.onWorldReadyState(state)
  if state == 2 then
    local level = getCurrentLevel()
    if level and level ~= "" and level ~= "unknown" and level ~= runtime.currentLevel then
      log("I", "checkpointTimer", "World ready — level: " .. level)
      clearMapMarkers()
      resetRun()
      runtime.currentLevel = level
      M.state.routes  = loadMapConfig(level)
      M.state.history = loadHistory()
      runtime.activeRoute = nil
      runtime.bestSplits  = {}
      pushStatus()
    end
  end
end

function M.onClientPostStartMission(levelPath)
  if not levelPath or levelPath == "" then return end
  local level = levelPath:match("/levels/([^/]+)") or levelPath
  if level ~= runtime.currentLevel then
    log("I", "checkpointTimer", "Mission started — level: " .. level)
    clearMapMarkers()
    resetRun()
    runtime.currentLevel = level
    M.state.routes  = loadMapConfig(level)
    M.state.history = loadHistory()
    runtime.activeRoute = nil
    runtime.bestSplits  = {}
    pushStatus()
  end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  -- Fallback-проверка смены карты
  local level = getCurrentLevel()
  if level ~= runtime.currentLevel and level ~= "unknown" and level ~= "" then
    log("I", "checkpointTimer", "Level change detected: " .. runtime.currentLevel .. " -> " .. level)
    clearMapMarkers()
    resetRun()
    runtime.currentLevel = level
    M.state.routes  = loadMapConfig(level)
    M.state.history = loadHistory()
    runtime.activeRoute = nil
    runtime.bestSplits  = {}
  end

  -- Троттлинг проверки триггеров
  local checkInterval = 1.0 / (M.state.triggerCheckHz or 20)
  runtime.triggerTimer = runtime.triggerTimer + (dtSim or 0)
  if runtime.triggerTimer >= checkInterval then
    runtime.triggerTimer = 0
    checkTriggers()
  end

  -- Троттлинг push-обновлений UI (~10 Hz)
  runtime.statusPushTimer = runtime.statusPushTimer + (dtReal or 0)
  if runtime.statusPushTimer >= 0.1 then
    runtime.statusPushTimer = 0
    if runtime.runActive or M.state.debugMode then
      pushStatus()
    end
  end

  -- Рендер (наземные круги + обновление маркеров на карте)
  renderTriggerZones()
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  -- 3D rendering is completely disabled.
end

function M.onDrawOnMinimap(td)
  if not M.state.showMapMarkers then return end
  local route = runtime.activeRoute
  if not route then return end

  local utils = _G.ui_apps_minimap_utils or ui_apps_minimap_utils
  if not utils then return end

  -- Draw start checkpoint (Green)
  if route.start and type(route.start) == "table" then
    local p = _G.vec3 and _G.vec3(route.start.x or 0, route.start.y or 0, route.start.z or 0) or route.start
    local clr = color(46, 204, 113, 230)
    local borderClr = color(255, 255, 255, 200)
    pcall(function() utils.simpleCircleWithEdgePointer(p, clr, borderClr, 8) end)
  end

  -- Draw checkpoints (Yellow)
  if route.checkpoints then
    local clr = color(241, 196, 15, 230)
    local borderClr = color(255, 255, 255, 200)
    for i, cp in ipairs(route.checkpoints) do
      if type(cp) == "table" then
        local p = _G.vec3 and _G.vec3(cp.x or 0, cp.y or 0, cp.z or 0) or cp
        pcall(function() utils.simpleCircleWithEdgePointer(p, clr, borderClr, 6) end)
      end
    end
  end

  -- Draw finish checkpoint (Red)
  if route.finish and type(route.finish) == "table" then
    local p = _G.vec3 and _G.vec3(route.finish.x or 0, route.finish.y or 0, route.finish.z or 0) or route.finish
    local clr = color(231, 76, 60, 230)
    local borderClr = color(255, 255, 255, 200)
    pcall(function() utils.simpleCircleWithEdgePointer(p, clr, borderClr, 8) end)
  end
end

function M.onExtensionUnloaded()
  log("I", "checkpointTimer", "Extension unloaded")
  clearMapMarkers()
  resetRun()
end

-- ===========================================================================
-- Публичный API (для UI через bngApi.engineLua)
-- ===========================================================================

M.getRuntime       = function() return runtime end
M.getState         = function() return M.state end
M.getCurrentTime   = function()
  if not runtime.runActive then return 0 end
  return getSimTime() - runtime.runStartTime
end
M.getSplits        = function() return runtime.splits end
M.isRunActive      = function() return runtime.runActive end
M.getActiveRoute   = function() return runtime.activeRoute end
M.getStatusPayload = buildStatusPayload
M.pushStatus       = pushStatus

-- ===========================================================================
return M