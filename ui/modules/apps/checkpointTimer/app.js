// ===========================================================================
// CheckpointTimer — BeamNG.drive UI App (AngularJS 1.5.8)
// ===========================================================================
// v2.3 — FIXED 3D rendering: Point3F + ColorF + String types, setDrawingEnabled, setLastZTest, setLastTTL.
// v2.2 — 3D-ворота, настройка ширины/высоты, диагностика debugDrawer.
// v2.1 — русский UI, непрозрачный фон, push-обновления через CTStatus.
//
// Документация:
//   https://documentation.beamng.com/modding/ui/app_creation/
// ===========================================================================

angular.module('beamng.apps')
.directive('checkpointTimer', ['$interval', function ($interval) {
  return {
    template:
      '<div class="ct-container">' +
      // Header
      '  <div class="ct-header">' +
      '    <div class="ct-brand">' +
      '      <span class="ct-icon">⏱</span>' +
      '      <span class="ct-title">TELEMETRY</span>' +
      '    </div>' +
      '    <span class="ct-version">v3.1</span>' +
      '  </div>' +
      
      // Status Info
      '  <div class="ct-status-bar">' +
      '    <div class="ct-status-item"><span class="ct-status-label">MAP:</span> <span class="ct-status-val">{{status.level}}</span></div>' +
      '    <div class="ct-status-item"><span class="ct-status-label">ROUTE:</span> <span class="ct-status-val" ng-class="{\'ct-active-route\': status.route != \'нет\'}">{{status.route}}</span></div>' +
      '  </div>' +
      
      // Timer / Recorder Panel
      '  <div class="ct-panel" ng-class="{\'ct-running\': status.runActive, \'ct-recording\': status.recording}">' +
      '    <div ng-if="status.runActive">' +
      '      <div class="ct-current-time">{{status.currentTimeFormatted}}</div>' +
      '      <div class="ct-cp-progress">CHECKPOINTS: {{status.cpPassed}} / {{status.cpTotal}}</div>' +
      '    </div>' +
      '    <div ng-if="!status.runActive && !status.recording" class="ct-waiting">' +
      '      <span class="ct-pulse-dot"></span> STANDBY' +
      '    </div>' +
      '    <div ng-if="status.recording" class="ct-recording-banner">' +
      '      <div class="ct-rec-indicator"><span class="ct-rec-dot"></span> RECORDING</div>' +
      '      <div class="ct-rec-name">{{status.recordingName}}</div>' +
      '      <div class="ct-rec-stage">{{status.recordingStage}}</div>' +
      '    </div>' +
      '  </div>' +

      // Splits
      '  <div class="ct-splits" ng-if="status.splits.length > 0">' +
      '    <div class="ct-section-title">Splits ({{status.splits.length}})</div>' +
      '    <div class="ct-split-header">' +
      '      <span>POINT</span>' +
      '      <span>DELTA</span>' +
      '      <span>TOTAL</span>' +
      '      <span style="text-align: right;">DIFF</span>' +
      '    </div>' +
      '    <div class="ct-split-list">' +
      '      <div ng-repeat="s in status.splits" class="ct-split-row" ng-class="{\'ct-best\': s.isBest, \'ct-worse\': s.isWorse}">' +
      '        <span class="ct-split-name">{{s.name}}</span>' +
      '        <span class="ct-split-delta">{{s.deltaFormatted}}</span>' +
      '        <span class="ct-split-total">{{s.totalFormatted}}</span>' +
      '        <span class="ct-split-diff" ng-class="{\'ct-diff-plus\': s.diffFormatted && s.diffFormatted.indexOf(\'+\')===0, \'ct-diff-minus\': s.diffFormatted && s.diffFormatted.indexOf(\'-\')===0}" style="text-align: right;">{{s.diffFormatted || \'—\'}}</span>' +
      '      </div>' +
      '    </div>' +
      '  </div>' +

      // Route Recorder Buttons
      '  <div class="ct-section-title">📍 Record Route</div>' +
      '  <div class="ct-input-group">' +
      '    <input class="ct-input" ng-model="routeNameInput" placeholder="Route name..." ng-keypress="onRouteNameKeypress($event)" />' +
      '  </div>' +
      '  <div class="ct-grid-buttons">' +
      '    <button class="ct-btn ct-btn-green" ng-click="cmd(\'rec start\')">New</button>' +
      '    <button class="ct-btn ct-btn-yellow" ng-click="cmd(\'rec next\')">Add Point</button>' +
      '    <button class="ct-btn ct-btn-red" ng-click="cmd(\'rec finish\')">Finish</button>' +
      '    <button class="ct-btn ct-btn-gray" ng-click="cmd(\'rec cancel\')">Cancel</button>' +
      '  </div>' +

      // Run Control Buttons
      '  <div class="ct-section-title">⏱ Race Control</div>' +
      '  <div class="ct-grid-buttons">' +
      '    <button class="ct-btn ct-btn-green" ng-click="cmd(\'start\')">Start</button>' +
      '    <button class="ct-btn ct-btn-yellow" ng-click="cmd(\'cp\')">CP</button>' +
      '    <button class="ct-btn ct-btn-red" ng-click="cmd(\'finish\')">Finish</button>' +
      '    <button class="ct-btn ct-btn-gray" ng-click="cmd(\'reset\')">Reset</button>' +
      '  </div>' +

      // Route List
      '  <div class="ct-section-title">🗺 Routes on Map ({{status.routes.length}})</div>' +
      '  <div class="ct-route-list">' +
      '    <div ng-repeat="r in status.routes" class="ct-route-item" ng-class="{\'ct-route-selected\': r.isActive}" ng-click="cmd(\'sel \' + r.name)">' +
      '      <span class="ct-route-name">🏁 {{r.name}}</span>' +
      '      <div style="display: flex; align-items: center; gap: 8px;">' +
      '        <span class="ct-route-cp-count">{{r.cpCount}} pts</span>' +
      '        <span class="ct-route-del" ng-click="cmd(\'del \' + r.name); $event.stopPropagation()">✖</span>' +
      '      </div>' +
      '    </div>' +
      '    <div ng-if="status.routes.length == 0" class="ct-empty-state">No routes saved on this map.</div>' +
      '  </div>' +

      // History
      '  <div class="ct-section-title">📜 History ({{status.history.length}})</div>' +
      '  <div class="ct-history-list">' +
      '    <div ng-repeat="h in status.history | limitTo:10" class="ct-history-item" ng-click="toggleHistoryItem($index)" ng-class="{\'ct-history-expanded\': expandedHistory[$index]}">' +
      '      <div class="ct-history-row">' +
      '        <span class="ct-history-time">{{h.totalTimeFormatted}}</span>' +
      '        <span class="ct-history-route">{{h.route}}</span>' +
      '        <span class="ct-history-date">{{h.date}}</span>' +
      '      </div>' +
      '      <div class="ct-history-splits" ng-if="expandedHistory[$index]">' +
      '        <div ng-repeat="s in h.splits" class="ct-history-split">' +
      '          <span class="ct-history-split-name">{{s.name}}</span>' +
      '          <span>{{s.deltaFormatted}}</span>' +
      '          <span style="text-align: right;">{{s.totalFormatted}}</span>' +
      '        </div>' +
      '      </div>' +
      '    </div>' +
      '    <div ng-if="status.history.length == 0" class="ct-empty-state">No history recorded yet.</div>' +
      '    <button ng-if="status.history.length > 0" class="ct-btn ct-btn-gray ct-btn-xs ct-btn-full" ng-click="cmd(\'clearhistory\')" style="margin-top: 6px;">🗑 Clear History</button>' +
      '  </div>' +

      // Settings
      '  <div class="ct-section-title">⚙ Configuration</div>' +
      '  <div class="ct-settings-grid">' +
      '    <div class="ct-settings-item">' +
      '      <label class="ct-label">Radius (m)</label>' +
      '      <input class="ct-input ct-input-sm" type="number" min="0.5" step="0.5" ng-model="radiusInput" ng-change="onRadiusChange()" />' +
      '    </div>' +
      '    <div class="ct-settings-item">' +
      '      <label class="ct-label">Rate (Hz)</label>' +
      '      <input class="ct-input ct-input-sm" type="number" min="1" max="120" step="1" ng-model="hzInput" ng-change="onHzChange()" />' +
      '    </div>' +
      '  </div>' +
      '  <div class="ct-grid-buttons" style="margin-top: 6px;">' +
      '    <button class="ct-btn ct-btn-gray ct-btn-sm" ng-click="cmd(\'mapmarkers\')">👁 Map: {{status.showMapMarkers ? "ON" : "OFF"}}</button>' +
      '    <button class="ct-btn ct-btn-gray ct-btn-sm" ng-click="cmd(\'reload\')">🔄 Reload</button>' +
      '    <button class="ct-btn ct-btn-gray ct-btn-sm ct-btn-full" ng-click="cmd(\'sysclock\')">⏱ SysClock: {{status.useSystemClock ? "ON" : "OFF"}}</button>' +
      '  </div>' +

      // Footer Tools
      '  <div class="ct-footer">' +
      '    <button class="ct-btn ct-btn-gray ct-btn-xs" ng-click="cmd(\'list\')">List</button>' +
      '    <button class="ct-btn ct-btn-gray ct-btn-xs" ng-click="cmd(\'info\')">Info</button>' +
      '    <button class="ct-btn ct-btn-gray ct-btn-xs" ng-click="cmd(\'history\')">Log</button>' +
      '    <button class="ct-btn ct-btn-gray ct-btn-xs" ng-click="cmd(\'help\')">Help</button>' +
      '    <button class="ct-btn ct-btn-gray ct-btn-xs" ng-click="cmd(\'push\')">Sync</button>' +
      '  </div>' +
      '</div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {

      // =====================================================================
      // Состояние (инициализируется ДО первого push из Lua)
      // =====================================================================
      scope.status = {
        level: '…',
        route: 'нет',
        runActive: false,
        currentTimeFormatted: '00:00.000',
        recording: false,
        recordingName: '',
        recordingStage: '',
        cpPassed: 0,
        cpTotal: 0,
        splits: [],
        routes: [],
        history: [],
        debugMode: false,
        showMapMarkers: true,
        useSystemClock: true,
        triggerRadius: 3.0
      };

      scope.routeNameInput = '';
      scope.radiusInput = 3.0;
      scope.hzInput = 20;

      scope.expandedHistory = {};

      // =====================================================================
      // Отправка Lua-команды в GELUA VM.
      // bngApi.engineLua возвращает Promise при наличии 'return' в коде —
      // здесь команды fire-and-forget, поэтому Promise игнорируем.
      // Аргумент JSON-кодируется, чтобы исключить инъекцию кавычек.
      // =====================================================================
      function engineLua(code) {
        try {
          if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
            return bngApi.engineLua(code);
          }
        } catch (e) {
          console.warn('[CheckpointTimer] engineLua failed:', e.message);
        }
        return null;
      }

      scope.cmd = function (command) {
        if (!command) return;
        // Для 'rec start' подставляем имя из поля ввода
        if (command.indexOf('rec start') === 0) {
          var name = (scope.routeNameInput || '').trim();
          command = 'rec start ' + name;
          scope.routeNameInput = '';
        }
        // Безопасно экранируем аргумент для Lua-строки
        var safe = JSON.stringify(command);
        engineLua('checkpointTimer.ct_command(' + safe + ')');
        // Просим Lua прислать свежий статус
        engineLua('checkpointTimer.pushStatus()');
      };

      scope.onRouteNameKeypress = function (event) {
        if (event.keyCode === 13) { // Enter
          scope.cmd('rec start');
        }
      };

      scope.onRadiusChange = function () {
        var r = parseFloat(scope.radiusInput);
        if (!isNaN(r) && r > 0) {
          scope.cmd('radius ' + r);
        }
      };

      scope.onHzChange = function () {
        var h = parseInt(scope.hzInput, 10);
        if (!isNaN(h) && h > 0) {
          scope.cmd('hz ' + h);
        }
      };

      scope.toggleHistoryItem = function (idx) {
        scope.expandedHistory[idx] = !scope.expandedHistory[idx];
      };

      // =====================================================================
      // Подписка на push-события из Lua.
      // Lua вызывает: guihooks.trigger('CTStatus', payload)
      // JS получает это как $scope-событие с именем 'CTStatus'.
      // =====================================================================
      scope.$on('CTStatus', function (event, data) {
        if (!data || typeof data !== 'object') return;
        try {
          var s = scope.status;
          s.level                = data.level || s.level;
          s.route                = (data.route && data.route !== 'none') ? data.route : 'нет';
          s.runActive            = !!data.runActive;
          s.currentTimeFormatted = data.currentTimeFormatted || '00:00.000';
          s.recording            = !!data.recording;
          s.recordingName        = data.recordingName || '';
          s.recordingStage       = data.recordingStage || '';
          s.cpPassed             = data.cpPassed || 0;
          s.cpTotal              = data.cpTotal || 0;
          s.splits               = data.splits || [];
          s.routes               = data.routes || [];
          s.history              = data.history || [];
          s.debugMode            = !!data.debugMode;
          s.showMapMarkers       = !!data.showMapMarkers;
          s.useSystemClock       = !!data.useSystemClock;
          s.triggerRadius        = data.triggerRadius || 3.0;

          // Синхронизируем поля ввода
          scope.radiusInput     = s.triggerRadius;
          scope.hzInput         = data.triggerCheckHz || scope.hzInput;
        } catch (e) {
          console.warn('[CheckpointTimer] CTStatus parse error:', e.message);
        }
        scope.$applyAsync();
      });

      // =====================================================================
      // Периодический запрос статуса (fallback на случай пропуска push-а).
      // =====================================================================
      var refreshInterval = $interval(function () {
        engineLua('checkpointTimer.pushStatus()');
      }, 2000);

      // =====================================================================
      // Старт: запрашиваем первый статус через короткую задержку
      // (даём расширению время загрузиться)
      // =====================================================================
      var initTimeout = setTimeout(function () {
        engineLua('checkpointTimer.pushStatus()');
      }, 500);

      // =====================================================================
      // Очистка
      // =====================================================================
      scope.$on('$destroy', function () {
        if (refreshInterval) {
          $interval.cancel(refreshInterval);
          refreshInterval = null;
        }
        if (initTimeout) {
          clearTimeout(initTimeout);
          initTimeout = null;
        }
      });
    }
  };
}]);
