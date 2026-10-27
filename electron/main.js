'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {
  app,
  BrowserWindow,
  Notification,
  Menu,
  nativeImage,
  clipboard,
  ipcMain,
  powerMonitor,
  screen,
  session,
  shell,
} = require('electron');

const { SettingsStore } = require('./settings');
const { compareDevices, scanAll } = require('./providers');
const { BatteryAlertManager } = require('./battery-alerts');
const { AppTray } = require('./tray');

const APP_NAME = '小鼠电量';
const APP_ID = 'com.mousebattery.app';
const WINDOW_WIDTH = 400;
const WINDOW_HEIGHT = 664;
const REFRESH_OPTIONS = [30, 60, 300];

app.setName(APP_NAME);
app.setAppUserModelId(APP_ID);
const customUserData = process.env.MOUSE_BATTERY_USER_DATA;
app.setPath(
  'userData',
  customUserData ? path.resolve(customUserData) : path.join(app.getPath('appData'), 'MouseBattery'),
);

const gotSingleInstanceLock = app.requestSingleInstanceLock();
if (!gotSingleInstanceLock) {
  app.quit();
}

let mainWindow = null;
let appTray = null;
let settingsStore = null;
let logPath = null;
let pollTimer = null;
let hideTimer = null;
let scanPromise = null;
let isQuitting = false;
let shouldShowOnReady = true;
let windowPinned = false;

const alertManager = new BatteryAlertManager();

const state = {
  devices: [],
  activeId: null,
  scanning: false,
  errors: [],
  lastUpdated: null,
};

const isDev = !app.isPackaged;

function initLogger() {
  const logDirectory = path.join(app.getPath('userData'), 'logs');
  logPath = path.join(logDirectory, 'app.log');
  try {
    fs.mkdirSync(logDirectory, { recursive: true });
    if (fs.existsSync(logPath) && fs.statSync(logPath).size > 1024 * 1024) {
      fs.renameSync(logPath, `${logPath}.1`);
    }
  } catch (error) {
    console.error('[logs] Could not prepare log directory:', error.message);
  }
}

function log(message, detail) {
  const suffix = detail === undefined ? '' : ` ${typeof detail === 'string' ? detail : JSON.stringify(detail)}`;
  const line = `[${new Date().toISOString()}] ${message}${suffix}`;
  if (isDev) console.log(line);
  if (!logPath) return;
  try {
    fs.appendFileSync(logPath, `${line}\n`);
  } catch {
    // Logging should never affect the app.
  }
}

function selectedDevice() {
  return (
    state.devices.find((device) => device.id === state.activeId) ||
    state.devices[0] ||
    null
  );
}

function publicState() {
  const activeDevice = selectedDevice();
  return {
    appName: APP_NAME,
    version: app.getVersion(),
    platform: process.platform,
    isPackaged: app.isPackaged,
    autoLaunchSupported: app.isPackaged,
    devices: state.devices,
    activeDevice,
    activeDeviceId: activeDevice?.id || null,
    scanning: state.scanning,
    errors: state.errors,
    lastUpdated: state.lastUpdated,
    settings: settingsStore ? settingsStore.get() : {},
    pinned: windowPinned,
    refreshOptions: REFRESH_OPTIONS,
  };
}

function sendState() {
  if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.webContents.isLoading()) {
    mainWindow.webContents.send('state:update', publicState());
  }
  if (appTray) appTray.update(publicState());
}

function updateTrayOnly() {
  if (appTray) appTray.update(publicState());
}

function preferredDisplay() {
  const trayBounds = appTray?.tray?.getBounds();
  return trayBounds ? screen.getDisplayMatching(trayBounds) : screen.getPrimaryDisplay();
}

function fitWindowToScreen() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const workArea = preferredDisplay().workArea;
  const width = Math.max(320, Math.min(WINDOW_WIDTH, workArea.width - 16));
  const height = Math.max(440, Math.min(WINDOW_HEIGHT, workArea.height - 16));
  const [currentWidth, currentHeight] = mainWindow.getSize();
  if (currentWidth !== width || currentHeight !== height) {
    mainWindow.setSize(width, height, false);
  }
}

function formatWindowPosition() {
  const trayBounds = appTray?.tray?.getBounds();
  const display = preferredDisplay();
  const workArea = display.workArea;
  const [width, height] = mainWindow.getSize();

  let x;
  let y;

  if (trayBounds && trayBounds.width > 0 && trayBounds.height > 0) {
    x = Math.round(trayBounds.x + trayBounds.width / 2 - width / 2);
    const above = trayBounds.y - height - 8;
    const below = trayBounds.y + trayBounds.height + 8;
    const trayIsNearTop = trayBounds.y < workArea.y + workArea.height / 2;
    y = trayIsNearTop ? below : above;
    if (y + height > workArea.y + workArea.height) y = above;
    if (y < workArea.y) y = workArea.y + 8;
  } else {
    x = workArea.x + workArea.width - width - 18;
    y = workArea.y + workArea.height - height - 18;
  }

  x = Math.max(workArea.x + 8, Math.min(x, workArea.x + workArea.width - width - 8));
  y = Math.max(workArea.y + 8, Math.min(y, workArea.y + workArea.height - height - 8));
  return { x, y };
}

function positionWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const { x, y } = formatWindowPosition();
  mainWindow.setPosition(x, y, false);
}

function clearHideTimer() {
  if (hideTimer) {
    clearTimeout(hideTimer);
    hideTimer = null;
  }
}

function hideWindow() {
  clearHideTimer();
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.hide();
}

function showWindow(options = {}) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  clearHideTimer();
  fitWindowToScreen();
  positionWindow();
  if (process.platform === 'darwin') app.dock?.hide();
  mainWindow.show();
  mainWindow.focus();
  app.focus({ steal: true });

  if (options.openSettings) {
    setTimeout(() => {
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('ui:open-settings');
      }
    }, 120);
  }

  if (state.lastUpdated && Date.now() - state.lastUpdated < 12000) {
    return;
  }
  void scanDevices();
}

function toggleWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.isVisible()) {
    hideWindow();
  } else {
    showWindow();
  }
}

function schedulePolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  const seconds = settingsStore.get().refreshInterval || 60;
  pollTimer = setInterval(() => {
    void scanDevices();
  }, seconds * 1000);
  log(`Auto refresh scheduled every ${seconds}s`);
}

function showBatteryNotification(event) {
  if (!Notification.isSupported()) return;
  const options = {
    title: event.title,
    body: event.body,
    silent: false,
  };
  if (process.platform === 'win32') {
    options.icon = nativeImage.createFromPath(
      path.join(__dirname, '..', 'assets', 'notification.png'),
    );
  }
  const notification = new Notification(options);
  notification.on('click', () => showWindow());
  notification.show();
  log('Battery notification shown', {
    device: event.device.id,
    type: event.type,
    battery: event.device.battery,
  });
}

async function scanDevices(options = {}) {
  if (scanPromise) return scanPromise;

  state.scanning = true;
  sendState();
  updateTrayOnly();

  scanPromise = (async () => {
    const started = Date.now();
    let result;
    try {
      result = await scanAll();
    } catch (error) {
      log('Scan crashed', error.message);
      result = {
        devices: [],
        errors: [
          {
            code: 'SCAN_FAILED',
            message: '读取鼠标电量时发生错误。',
            detail: error.message,
          },
        ],
      };
    }

    const now = Date.now();
    const previousDevices = state.devices;
    state.errors = result.errors || [];
    const freshDevices = (result.devices || []).map((device) => ({
      ...device,
      stale: false,
      lastSeen: now,
    }));

    // If a provider fails temporarily (for example the ATK receiver is waiting
    // for the mouse to wake up), keep showing its last reading instead of
    // making the whole panel empty. The UI marks these devices as stale.
    const failedProviders = new Set(
      state.errors.map((error) => error?.provider).filter(Boolean),
    );
    const retainedDevices = previousDevices
      .filter((device) => failedProviders.has(device.provider))
      .filter((device) => !freshDevices.some((fresh) => fresh.provider === device.provider))
      .map((device) => ({ ...device, stale: true }));

    state.devices = [...freshDevices, ...retainedDevices].sort(compareDevices);
    state.lastUpdated = now;

    const settings = settingsStore.get();
    const preferred = state.devices.find((device) => device.id === settings.selectedDeviceId);
    state.activeId = (preferred || state.devices[0])?.id || null;
    state.scanning = false;

    log('Scan finished', {
      devices: state.devices.map((device) => ({
        provider: device.provider,
        name: device.name,
        battery: device.battery,
      })),
      errors: state.errors.map((error) => error.code),
      ms: now - started,
    });

    sendState();
    updateTrayOnly();

    if (options.notify !== false) {
      const events = alertManager.evaluate(state.devices, settings.lowBatteryAlerts);
      for (const event of events) showBatteryNotification(event);
    }

    return publicState();
  })();

  try {
    return await scanPromise;
  } finally {
    scanPromise = null;
    if (state.scanning) {
      state.scanning = false;
      sendState();
      updateTrayOnly();
    }
  }
}

function applyLaunchAtLogin(enabled) {
  if (!app.isPackaged) {
    log('Skipped launch-at-login change outside a packaged app');
    return;
  }
  try {
    if (process.platform === 'darwin') {
      app.setLoginItemSettings({ openAtLogin: enabled, openAsHidden: true });
    } else if (process.platform === 'win32') {
      app.setLoginItemSettings({
        openAtLogin: enabled,
        args: ['--hidden'],
      });
    }
  } catch (error) {
    log('Could not update launch-at-login', error.message);
  }
}

function updateSettings(patch) {
  if (!patch || typeof patch !== 'object') return publicState();
  if (!app.isPackaged && 'launchAtLogin' in patch) {
    patch = { ...patch };
    delete patch.launchAtLogin;
  }
  const before = settingsStore.get();
  const next = settingsStore.update(patch);

  if (next.launchAtLogin !== before.launchAtLogin) {
    applyLaunchAtLogin(next.launchAtLogin);
  }
  if (next.refreshInterval !== before.refreshInterval) {
    schedulePolling();
  }
  if (next.lowBatteryAlerts !== before.lowBatteryAlerts) {
    if (!next.lowBatteryAlerts) {
      alertManager.reset();
    } else {
      const events = alertManager.evaluate(state.devices, true);
      for (const event of events) showBatteryNotification(event);
    }
  }

  sendState();
  updateTrayOnly();
  return publicState();
}

function installApplicationMenu() {
  if (process.platform !== 'darwin') {
    Menu.setApplicationMenu(null);
    return;
  }

  const template = [
    {
      label: APP_NAME,
      submenu: [
        { role: 'about', label: `关于${APP_NAME}` },
        { type: 'separator' },
        {
          label: '显示面板',
          accelerator: 'Command+Shift+B',
          click: () => showWindow(),
        },
        {
          label: '隐藏面板',
          accelerator: 'Command+W',
          click: () => hideWindow(),
        },
        { type: 'separator' },
        { role: 'hide', label: `隐藏${APP_NAME}` },
        { role: 'hideOthers', label: '隐藏其他' },
        { type: 'separator' },
        { role: 'quit', label: `退出${APP_NAME}` },
      ],
    },
    {
      label: '编辑',
      submenu: [
        { role: 'undo', label: '撤销' },
        { role: 'redo', label: '重做' },
        { type: 'separator' },
        { role: 'cut', label: '剪切' },
        { role: 'copy', label: '复制' },
        { role: 'paste', label: '粘贴' },
        { role: 'selectAll', label: '全选' },
      ],
    },
    {
      label: '视图',
      submenu: [
        { role: 'reload', label: '重新载入', visible: isDev },
        { role: 'toggleDevTools', label: '开发者工具', visible: isDev },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: WINDOW_WIDTH,
    height: WINDOW_HEIGHT,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    hasShadow: true,
    roundedCorners: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    title: APP_NAME,
    icon: path.join(__dirname, '..', 'assets', 'icon-512.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
      devTools: isDev,
    },
  });

  if (process.platform === 'darwin') {
    mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  }

  mainWindow.loadFile(path.join(__dirname, '..', 'src', 'index.html'));

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event) => event.preventDefault());

  mainWindow.on('blur', () => {
    if (windowPinned || isQuitting) return;
    if (mainWindow.webContents.isDevToolsOpened()) return;
    clearHideTimer();
    hideTimer = setTimeout(() => {
      if (!mainWindow || mainWindow.isDestroyed()) return;
      if (!mainWindow.isFocused()) hideWindow();
    }, 260);
  });

  mainWindow.on('focus', clearHideTimer);

  mainWindow.on('close', (event) => {
    if (isQuitting) return;
    event.preventDefault();
    hideWindow();
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  mainWindow.webContents.on('did-finish-load', () => {
    sendState();
    if (shouldShowOnReady) {
      showWindow();
    }
  });

  mainWindow.webContents.on('console-message', (event) => {
    log('Renderer console', {
      level: event.level,
      message: event.message,
      line: event.lineNumber,
      sourceId: event.sourceId,
    });
  });

  mainWindow.webContents.on('render-process-gone', (_event, details) => {
    log('Renderer process gone', details);
  });

  if (!isDev) {
    mainWindow.webContents.on('context-menu', (event) => event.preventDefault());
  }
}

function buildDiagnostics() {
  const snapshot = publicState();
  return [
    `${APP_NAME} ${snapshot.version}`,
    `Electron ${process.versions.electron} · Chromium ${process.versions.chrome} · Node ${process.versions.node}`,
    `Platform: ${process.platform} ${process.arch} · ${process.getSystemVersion?.() || ''}`,
    `Updated: ${snapshot.lastUpdated ? new Date(snapshot.lastUpdated).toISOString() : 'never'}`,
    `Active: ${snapshot.activeDevice ? `${snapshot.activeDevice.name} ${snapshot.activeDevice.battery}%` : 'none'}`,
    '',
    'Devices:',
    ...snapshot.devices.map(
      (device) =>
        `- ${device.provider} | ${device.name} | ${device.battery}% | charging=${String(
          device.charging,
        )} | ${JSON.stringify(device.hardware || {})}`,
    ),
    '',
    'Errors:',
    ...(snapshot.errors.length
      ? snapshot.errors.map((error) => `- ${error.code}: ${error.message} (${error.detail || ''})`)
      : ['- none']),
    '',
    `Settings: ${JSON.stringify(snapshot.settings)}`,
    `Log: ${logPath || 'not available'}`,
  ].join('\n');
}

function registerIpc() {
  ipcMain.handle('app:get-state', () => publicState());

  ipcMain.handle('app:refresh', async () => scanDevices());

  ipcMain.handle('app:select-device', (_event, deviceId) => {
    if (typeof deviceId !== 'string') return publicState();
    const device = state.devices.find((candidate) => candidate.id === deviceId);
    if (!device) return publicState();
    state.activeId = device.id;
    settingsStore.update({ selectedDeviceId: device.id });
    sendState();
    updateTrayOnly();
    return publicState();
  });

  ipcMain.handle('app:update-settings', (_event, patch) => {
    if (!patch || typeof patch !== 'object') return publicState();
    return updateSettings(patch);
  });

  ipcMain.handle('window:hide', () => {
    hideWindow();
    return true;
  });

  ipcMain.handle('window:set-pinned', (_event, pinned) => {
    windowPinned = Boolean(pinned);
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.setAlwaysOnTop(windowPinned, process.platform === 'darwin' ? 'floating' : 'normal');
      if (windowPinned && !mainWindow.isVisible()) showWindow();
    }
    sendState();
    return { pinned: windowPinned };
  });

  ipcMain.handle('app:copy-diagnostics', () => {
    const diagnostics = buildDiagnostics();
    clipboard.writeText(diagnostics);
    return true;
  });

  ipcMain.handle('app:open-logs', () => {
    if (!logPath) return false;
    if (!fs.existsSync(logPath)) {
      try {
        fs.appendFileSync(logPath, '');
      } catch {
        return false;
      }
    }
    shell.showItemInFolder(logPath);
    return true;
  });

  ipcMain.handle('app:quit', () => {
    app.quit();
    return true;
  });
}

async function bootstrap() {
  settingsStore = new SettingsStore(app.getPath('userData'));
  initLogger();
  log('Starting', {
    version: app.getVersion(),
    platform: process.platform,
    arch: process.arch,
    packaged: app.isPackaged,
  });

  if (process.platform === 'darwin') app.dock?.hide();
  app.setAboutPanelOptions({
    applicationName: APP_NAME,
    applicationVersion: app.getVersion(),
    version: app.getVersion(),
    copyright: 'Powering your wireless setup.',
  });

  installApplicationMenu();
  registerIpc();
  createWindow();

  const hiddenLaunch =
    process.argv.includes('--hidden') ||
    (process.platform === 'darwin' && app.getLoginItemSettings().wasOpenedAtLogin);
  shouldShowOnReady = !hiddenLaunch;

  appTray = new AppTray({
    onToggleWindow: toggleWindow,
    onRefresh: () => {
      void scanDevices();
    },
    onShowWindow: () => showWindow(),
    onOpenSettings: () => showWindow({ openSettings: true }),
    onUpdateSettings: (patch) => updateSettings(patch),
    onQuit: () => app.quit(),
  });
  appTray.create(publicState());

  session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => {
    callback(false);
  });

  schedulePolling();
  void scanDevices();

  powerMonitor.on('resume', () => {
    log('System resumed, refreshing');
    void scanDevices();
  });
}

if (gotSingleInstanceLock) {
  app.on('second-instance', () => {
    showWindow();
  });

  app.whenReady().then(bootstrap).catch((error) => {
    log('Startup failed', error.stack || error.message);
    app.quit();
  });

  app.on('activate', () => {
    if (!mainWindow) createWindow();
    showWindow();
  });

  app.on('window-all-closed', () => {
    if (isQuitting) app.quit();
  });

  app.on('before-quit', () => {
    isQuitting = true;
    if (pollTimer) clearInterval(pollTimer);
    clearHideTimer();
    if (appTray) appTray.destroy();
  });
}

process.on('uncaughtException', (error) => {
  log('Uncaught exception', error.stack || error.message);
});

process.on('unhandledRejection', (reason) => {
  log('Unhandled rejection', reason?.stack || String(reason));
});
