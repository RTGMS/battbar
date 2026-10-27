'use strict';

window.addEventListener('error', (event) => {
  console.error('renderer-error', event.error?.stack || event.message);
});

window.addEventListener('unhandledrejection', (event) => {
  console.error('renderer-rejection', event.reason?.stack || String(event.reason));
});

const api = window.mouseBattery;
const shell = document.querySelector('.window-shell');
const $ = (id) => document.getElementById(id);

const elements = {
  loadingState: $('loadingState'),
  emptyState: $('emptyState'),
  deviceView: $('deviceView'),
  deviceName: $('deviceName'),
  connectionChipText: $('connectionChipText'),
  percentValue: $('percentValue'),
  percentLabel: $('percentLabel'),
  gauge: $('batteryLabel'),
  gaugeProgress: $('gaugeProgress'),
  heroKicker: $('heroKicker'),
  batteryHeadline: $('batteryHeadline'),
  batteryMessage: $('batteryMessage'),
  heroMeta: $('heroMeta'),
  metricConnection: $('metricConnection'),
  metricCharging: $('metricCharging'),
  metricSource: $('metricSource'),
  updatedAt: $('updatedAt'),
  refreshButton: $('refreshButton'),
  emptyRefreshButton: $('emptyRefreshButton'),
  devicesSection: $('devicesSection'),
  deviceCount: $('deviceCount'),
  deviceList: $('deviceList'),
  errorBanner: $('errorBanner'),
  errorTitle: $('errorTitle'),
  errorText: $('errorText'),
  emptyError: $('emptyError'),
  emptyErrorText: $('emptyErrorText'),
  pinButton: $('pinButton'),
  settingsButton: $('settingsButton'),
  closeButton: $('closeButton'),
  settingsView: $('settingsView'),
  dashboardView: $('dashboardView'),
  backButton: $('backButton'),
  refreshSegments: $('refreshSegments'),
  alertSwitch: $('alertSwitch'),
  autoLaunchSwitch: $('autoLaunchSwitch'),
  autoLaunchHint: $('autoLaunchHint'),
  autoLaunchRow: $('autoLaunchRow'),
  copyDiagnosticsButton: $('copyDiagnosticsButton'),
  openLogsButton: $('openLogsButton'),
  quitButton: $('quitButton'),
  versionText: $('versionText'),
  autoRefreshText: $('autoRefreshText'),
  footerStatus: document.querySelector('.footer-status'),
  toast: $('toast'),
  mainScroll: $('mainScroll'),
};

const RADIUS = 65;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;
const MOUSE_ICON = `
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round">
    <path d="M12 4.2c3.85 0 5.95 2.85 5.95 6.8v2.6c0 4-2.28 6.2-5.95 6.2s-5.95-2.2-5.95-6.2V11c0-3.95 2.1-6.8 5.95-6.8Z"/>
    <path d="M12 4.4v5.3"/>
    <rect x="10.9" y="5.6" width="2.2" height="3.9" rx="1.1" fill="currentColor" stroke="none"/>
  </svg>`;

let currentState = null;
let settingsOpen = false;
let refreshing = false;
let pinBusy = false;
let toastTimer = null;
let relativeTimer = null;

function focusShell() {
  shell.focus({ preventScroll: true });
}

window.addEventListener('focus', () => {
  requestAnimationFrame(focusShell);
});

elements.gaugeProgress.style.strokeDasharray = `${CIRCUMFERENCE}`;
elements.gaugeProgress.style.strokeDashoffset = `${CIRCUMFERENCE}`;
elements.gauge.setAttribute('role', 'progressbar');
elements.gauge.setAttribute('aria-label', '鼠标剩余电量');
elements.gauge.setAttribute('aria-valuemin', '0');
elements.gauge.setAttribute('aria-valuemax', '100');

function clampBattery(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return null;
  return Math.max(0, Math.min(100, Math.round(numeric)));
}

function batteryColor(level) {
  if (level <= 20) return '#ff9a8b';
  if (level <= 40) return '#ffc571';
  return '#9be8b8';
}

function formatClock(timestamp) {
  if (!timestamp) return '';
  try {
    return new Intl.DateTimeFormat('zh-CN', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    }).format(new Date(timestamp));
  } catch {
    return '';
  }
}

function relativeUpdated(timestamp) {
  if (!timestamp) return '尚未读取';
  const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000));
  if (seconds < 10) return '刚刚更新';
  if (seconds < 60) return `${seconds} 秒前更新`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟前更新`;
  return `${formatClock(timestamp)} 更新`;
}

function updateRelativeTime() {
  if (!currentState?.lastUpdated) return;
  const active = currentState.activeDevice;
  if (active?.stale) {
    const timestamp = active.lastSeen || currentState.lastUpdated;
    elements.updatedAt.textContent = `上次读取 ${formatClock(timestamp)}`;
    elements.updatedAt.title = new Date(timestamp).toLocaleString('zh-CN', { hour12: false });
    return;
  }
  const timestamp = currentState.lastUpdated;
  elements.updatedAt.textContent = relativeUpdated(timestamp);
  elements.updatedAt.title = new Date(timestamp).toLocaleString('zh-CN', { hour12: false });
}

function describeBattery(device) {
  const battery = clampBattery(device.battery);
  if (device.stale) {
    return {
      kicker: '等待唤醒',
      headline: '保持上次读数',
      message: '接收器暂时没有响应，唤醒鼠标后会自动更新。',
    };
  }
  if (device.charging) {
    if (battery >= 100) {
      return {
        kicker: '已充满',
        headline: '能量满格',
        message: '电池已经充满，可以拔掉线继续使用。',
      };
    }
    return {
      kicker: '正在充电',
      headline: '电量回升中',
      message: '接收器正在为鼠标补能，可以安心继续使用。',
    };
  }
  if (battery === null) {
    return {
      kicker: '等待数据',
      headline: '暂时没有读数',
      message: '设备已连接，但还没有拿到有效的电量数据。',
    };
  }
  if (battery <= 10) {
    return {
      kicker: '需要注意',
      headline: '电量告急',
      message: '建议立即充电，避免关键操作时突然掉线。',
    };
  }
  if (battery <= 20) {
    return {
      kicker: '低电量',
      headline: '电量偏低',
      message: '建议尽快充电，别让关键一局没电。',
    };
  }
  if (battery <= 40) {
    return {
      kicker: '还可再战',
      headline: '电量不多',
      message: '已接近低电量，建议尽快找个时间补电。',
    };
  }
  if (battery <= 70) {
    return {
      kicker: '状态稳定',
      headline: '状态良好',
      message: '电量健康，放心继续使用。',
    };
  }
  return {
    kicker: '能量充沛',
    headline: '电量充足',
    message: '电量充足，随时可以开一局。',
  };
}

function setShellTheme(device) {
  shell.classList.remove('low', 'mid', 'high', 'charging');
  if (!device) {
    shell.classList.add('high');
    return;
  }
  const battery = clampBattery(device.battery);
  if (device.charging) {
    shell.classList.add('charging');
  } else if (battery !== null && battery <= 20) {
    shell.classList.add('low');
  } else if (battery !== null && battery <= 40) {
    shell.classList.add('mid');
  } else {
    shell.classList.add('high');
  }
}

function setViewVisibility() {
  elements.settingsView.hidden = !settingsOpen;
  elements.dashboardView.hidden = settingsOpen;
  elements.settingsButton.setAttribute('aria-pressed', String(settingsOpen));

  if (settingsOpen) return;

  const hasDevice = Boolean(currentState?.activeDevice);
  const scanning = Boolean(currentState?.scanning);
  elements.loadingState.hidden = hasDevice || !scanning;
  elements.emptyState.hidden = hasDevice || scanning;
  elements.deviceView.hidden = !hasDevice;
}

function renderError() {
  const errors = Array.isArray(currentState?.errors) ? currentState.errors : [];
  const hasErrors = errors.length > 0;
  const message = hasErrors
    ? `${errors[0].message || '读取电量时遇到问题。'}${
        errors.length > 1 ? `（另有 ${errors.length - 1} 条提示）` : ''
      }`
    : '';

  const atkError = errors.some((error) => String(error.code || '').startsWith('ATK_'));
  elements.errorTitle.textContent = atkError ? 'ATK 读取提示' : '读取提示';
  elements.errorText.textContent = message;
  elements.errorBanner.hidden = !hasErrors;
  elements.emptyErrorText.textContent = message;
  elements.emptyError.hidden = !hasErrors;
}

function setBusyVisual(busy) {
  elements.refreshButton.disabled = busy;
  elements.emptyRefreshButton.disabled = busy;
  elements.refreshButton.classList.toggle('is-loading', busy);
  elements.footerStatus.classList.toggle('scanning', busy);
}

function setRefreshBusy(busy) {
  refreshing = busy;
  setBusyVisual(busy || Boolean(currentState?.scanning));
  renderFooter();
}

function renderGauge(device) {
  const battery = clampBattery(device?.battery);
  if (battery === null) {
    elements.percentValue.textContent = '--';
    elements.gaugeProgress.style.strokeDashoffset = `${CIRCUMFERENCE}`;
    elements.gauge.setAttribute('aria-valuenow', '0');
    elements.gauge.setAttribute('aria-valuetext', '电量未知');
  } else {
    elements.percentValue.textContent = String(battery);
    const offset = CIRCUMFERENCE * (1 - battery / 100);
    elements.gaugeProgress.style.strokeDashoffset = `${offset}`;
    elements.gauge.setAttribute('aria-valuenow', String(battery));
    elements.gauge.setAttribute('aria-valuetext', `剩余电量 ${battery}%`);
  }
  elements.percentLabel.textContent = '剩余电量';
}

function renderDevice(device) {
  if (!device) return;
  const battery = clampBattery(device.battery);
  const description = describeBattery(device);
  const connectionLabel = device.connectionLabel || (device.connection === 'bluetooth' ? '蓝牙' : '2.4 GHz');

  elements.deviceName.textContent = device.name || '无线鼠标';
  elements.deviceName.title = device.subtitle || device.name || '';
  elements.connectionChipText.textContent = connectionLabel;
  elements.heroKicker.textContent = description.kicker;
  elements.batteryHeadline.textContent = description.headline;
  elements.batteryMessage.textContent = description.message;
  elements.heroMeta.textContent = `${device.source || (device.provider === 'atk' ? 'ATK HID' : '系统蓝牙')} · ${connectionLabel}`;
  elements.metricConnection.textContent = connectionLabel;
  elements.metricCharging.textContent = device.stale
    ? '等待响应'
    : device.charging === true
      ? '充电中'
      : device.charging === false
        ? '使用中'
        : '未知';
  elements.metricSource.textContent = device.source || '系统蓝牙';
  elements.metricSource.title = device.subtitle || '';

  renderGauge(device);
  if (device.stale) elements.percentLabel.textContent = '上次读数';
  updateRelativeTime();
  document.title =
    battery === null
      ? '电量栏'
      : `${device.stale ? '~' : ''}${battery}% · 电量栏`;
}

function makeDeviceRow(device) {
  const active = currentState?.activeDeviceId === device.id;
  const battery = clampBattery(device.battery);
  const row = document.createElement('button');
  row.type = 'button';
  row.className = `device-row${active ? ' is-active' : ''}${device.stale ? ' is-stale' : ''}`;
  row.setAttribute('aria-pressed', String(active));
  row.title = device.subtitle || device.name || '';

  const icon = document.createElement('span');
  icon.className = 'device-icon';
  icon.innerHTML = MOUSE_ICON;

  const copy = document.createElement('span');
  copy.className = 'device-row-copy';
  const name = document.createElement('span');
  name.className = 'device-row-name';
  name.textContent = device.name || '无线鼠标';
  const meta = document.createElement('span');
  meta.className = 'device-row-meta';
  meta.textContent = device.stale
    ? `等待响应 · ${device.connectionLabel || '无线'}`
    : `${device.connectionLabel || '无线'} · ${device.source || ''}`;
  copy.append(name, meta);

  const batteryWrap = document.createElement('span');
  batteryWrap.className = 'device-row-battery';
  const bar = document.createElement('span');
  bar.className = 'mini-battery';
  const fill = document.createElement('span');
  fill.style.width = `${battery === null ? 0 : battery}%`;
  bar.style.setProperty('--accent-row', battery === null ? '#65766b' : batteryColor(battery));
  bar.appendChild(fill);
  const percent = document.createElement('span');
  percent.className = 'device-row-percent';
  percent.textContent = battery === null ? '--' : `${battery}%`;
  batteryWrap.append(bar, percent);

  row.append(icon, copy, batteryWrap);
  row.addEventListener('click', async () => {
    if (!api || currentState?.activeDeviceId === device.id) return;
    row.disabled = true;
    try {
      const nextState = await api.selectDevice(device.id);
      if (nextState) applyState(nextState);
    } catch {
      showToast('切换设备失败，请重试');
    } finally {
      row.disabled = false;
    }
  });
  return row;
}

function renderDeviceList(devices) {
  const list = Array.isArray(devices) ? devices : [];
  elements.deviceList.replaceChildren(...list.map(makeDeviceRow));
  elements.deviceCount.textContent = String(list.length);
  elements.devicesSection.hidden = list.length === 0;
}

function renderFooter() {
  const interval = currentState?.settings?.refreshInterval;
  const scanning = refreshing || currentState?.scanning;
  elements.footerStatus.classList.toggle('scanning', Boolean(scanning));
  if (scanning) {
    elements.autoRefreshText.textContent = '正在读取电量…';
    return;
  }
  if (interval === 30) elements.autoRefreshText.textContent = '每 30 秒自动刷新';
  else if (interval === 300) elements.autoRefreshText.textContent = '每 5 分钟自动刷新';
  else elements.autoRefreshText.textContent = '每分钟自动刷新';
}

function renderSettings() {
  if (!currentState) return;
  const settings = currentState.settings || {};
  const interval = settings.refreshInterval || 60;
  for (const button of elements.refreshSegments.querySelectorAll('button[data-interval]')) {
    button.classList.toggle('is-selected', Number(button.dataset.interval) === interval);
    button.setAttribute('aria-pressed', String(Number(button.dataset.interval) === interval));
  }
  elements.alertSwitch.setAttribute('aria-checked', String(Boolean(settings.lowBatteryAlerts)));
  elements.autoLaunchSwitch.setAttribute('aria-checked', String(Boolean(settings.launchAtLogin)));
  const launchSupported = Boolean(currentState.autoLaunchSupported);
  elements.autoLaunchSwitch.disabled = !launchSupported;
  elements.autoLaunchRow.classList.toggle('is-disabled', !launchSupported);
  elements.autoLaunchHint.textContent = launchSupported
    ? '安静地待在菜单栏'
    : '安装版中可用';
  elements.autoLaunchSwitch.title = launchSupported ? '开机自动启动' : '安装版中可用';
  elements.versionText.textContent = `v${currentState.version || '2.2.0'}`;
}

function renderPin() {
  const pinned = Boolean(currentState?.pinned);
  elements.pinButton.setAttribute('aria-pressed', String(pinned));
  elements.pinButton.title = pinned ? '取消置顶' : '固定在最前';
  elements.pinButton.setAttribute('aria-label', pinned ? '取消置顶' : '固定在最前');
}

function applyState(nextState) {
  if (!nextState || typeof nextState !== 'object') return;
  currentState = nextState;
  const device = nextState.activeDevice || null;

  setShellTheme(device);
  renderPin();
  renderSettings();
  renderError();
  renderDeviceList(nextState.devices);

  if (device) renderDevice(device);
  setViewVisibility();

  elements.alertSwitch.disabled = false;
  setBusyVisual(Boolean(nextState.scanning) || refreshing);
  renderFooter();
  updateRelativeTime();
}

function showToast(message, duration = 2200) {
  elements.toast.textContent = message;
  elements.toast.classList.add('is-visible');
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    elements.toast.classList.remove('is-visible');
    toastTimer = null;
  }, duration);
}

function openSettings() {
  settingsOpen = true;
  elements.mainScroll.scrollTop = 0;
  setViewVisibility();
  elements.backButton.focus({ preventScroll: true });
}

function closeSettings() {
  settingsOpen = false;
  elements.mainScroll.scrollTop = 0;
  setViewVisibility();
  elements.settingsButton.focus({ preventScroll: true });
}

async function refreshNow() {
  if (!api || refreshing) return;
  setRefreshBusy(true);
  try {
    const nextState = await api.refresh();
    if (nextState) applyState(nextState);
  } catch {
    showToast('读取失败，请稍后再试');
  } finally {
    setRefreshBusy(false);
  }
}

async function mutateSettings(patch) {
  if (!api) return;
  try {
    const nextState = await api.updateSettings(patch);
    if (nextState) applyState(nextState);
  } catch {
    showToast('设置保存失败，请重试');
  }
}

function bindEvents() {
  elements.closeButton.addEventListener('click', () => {
    api?.hideWindow();
  });

  elements.settingsButton.addEventListener('click', () => {
    if (settingsOpen) closeSettings();
    else openSettings();
  });

  elements.backButton.addEventListener('click', closeSettings);

  elements.pinButton.addEventListener('click', async () => {
    if (!api || pinBusy) return;
    pinBusy = true;
    try {
      const result = await api.setPinned(!currentState?.pinned);
      if (currentState) currentState.pinned = Boolean(result?.pinned);
      renderPin();
      showToast(result?.pinned ? '已固定在最前' : '已取消置顶', 1400);
    } catch {
      showToast('操作失败，请重试');
    } finally {
      pinBusy = false;
    }
  });

  elements.refreshButton.addEventListener('click', refreshNow);
  elements.emptyRefreshButton.addEventListener('click', refreshNow);

  elements.refreshSegments.addEventListener('click', (event) => {
    const button = event.target.closest('button[data-interval]');
    if (!button) return;
    const interval = Number(button.dataset.interval);
    if (![30, 60, 300].includes(interval)) return;
    showToast(`已改为${interval === 30 ? '每 30 秒' : interval === 300 ? '每 5 分钟' : '每分钟'}刷新`, 1400);
    void mutateSettings({ refreshInterval: interval });
  });

  elements.alertSwitch.addEventListener('click', () => {
    const enabled = elements.alertSwitch.getAttribute('aria-checked') !== 'true';
    elements.alertSwitch.setAttribute('aria-checked', String(enabled));
    void mutateSettings({ lowBatteryAlerts: enabled });
  });

  elements.autoLaunchSwitch.addEventListener('click', () => {
    if (elements.autoLaunchSwitch.disabled) return;
    const enabled = elements.autoLaunchSwitch.getAttribute('aria-checked') !== 'true';
    elements.autoLaunchSwitch.setAttribute('aria-checked', String(enabled));
    void mutateSettings({ launchAtLogin: enabled });
  });

  elements.copyDiagnosticsButton.addEventListener('click', async () => {
    try {
      await api?.copyDiagnostics();
      showToast('诊断信息已复制到剪贴板');
    } catch {
      showToast('复制失败');
    }
  });

  elements.openLogsButton.addEventListener('click', async () => {
    try {
      const opened = await api?.openLogs();
      if (!opened) showToast('没有找到日志文件');
    } catch {
      showToast('无法打开日志文件夹');
    }
  });

  elements.quitButton.addEventListener('click', () => {
    api?.quit();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      if (settingsOpen) closeSettings();
      else api?.hideWindow();
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'r') {
      event.preventDefault();
      void refreshNow();
    }
  });

  api?.onState((nextState) => applyState(nextState));
  api?.onOpenSettings(() => openSettings());
}

async function start() {
  if (relativeTimer) clearInterval(relativeTimer);
  relativeTimer = setInterval(updateRelativeTime, 10000);
  focusShell();

  if (!api) {
    elements.loadingState.hidden = true;
    elements.emptyState.hidden = false;
    elements.emptyError.hidden = false;
    elements.emptyErrorText.textContent = '应用界面没有连接到后台进程，请重新启动。';
    return;
  }

  bindEvents();

  try {
    const initialState = await api.getState();
    applyState(initialState);
  } catch {
    elements.loadingState.hidden = true;
    elements.emptyState.hidden = false;
    elements.emptyError.hidden = false;
    elements.emptyErrorText.textContent = '读取应用状态失败，请重新启动。';
  }
}

start();
