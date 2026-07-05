-- ===========================================================================
-- CheckpointTimer — mod loader script
-- ===========================================================================
-- Этот файл вызывается игрой при загрузке мода.
-- Загружает GELUA-расширение и помечает его как "manual unload",
-- чтобы оно не выгружалось при каждой смене карты.
--
-- Документация:
--   https://documentation.beamng.com/modding/programming/extensions/
-- ===========================================================================

-- Загружаем расширение (стандартный shorthand load() в modScript.lua)
load("checkpointTimer")

-- Помечаем как manual — расширение остаётся загруженным между миссиями.
-- Старый API: setExtensionUnloadMode("checkpointTimer", "manual")
if setExtensionUnloadMode then
  setExtensionUnloadMode("checkpointTimer", "manual")
end
