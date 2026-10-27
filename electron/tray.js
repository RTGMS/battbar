'use strict';

const path = require('node:path');
const { Menu, Tray, nativeImage } = require('electron');

function formatTime(timestamp) {
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

function refreshLabel(seconds) {
  if (seconds === 30) return '每 30 秒';
  if (seconds === 300) return '每 5 分钟';
  return '每分钟';
}

class AppTray {
  constructor(options) {
    this.options = options;
    this.tray = null;
    this.menu = null;
    this.state = null;
  }

  create(state) {
    const iconName = process.platform === 'darwin' ? 'trayTemplate.png' : 'tray-win.png';
    const iconPath = path.join(__dirname, '..', 'assets', iconName);
    let image = nativeImage.createFromPath(iconPath);
    if (image.isEmpty()) {
      console.warn('[tray] Tray icon could not be loaded:', iconPath);
      image = nativeImage.createEmpty();
    }
    if (process.platform === 'darwin') {
      image.setTemplateImage(true);
    }

    this.tray = new Tray(image);
    this.tray.setIgnoreDoubleClickEvents(true);
    this.tray.on('click', () => this.options.onToggleWindow());
    this.tray.on('right-click', () => {
      if (this.menu) this.tray.popUpContextMenu(this.menu);
    });

    this.update(state);
    return this.tray;
  }

  update(state) {
    if (!this.tray) return;
    this.state = state;
    this.rebuildMenu();

    const active = state?.activeDevice;
    const tooltip = active
      ? `${state.appName} · ${active.name} ${active.battery}%${
          active.charging ? '，正在充电' : ''
        }${active.stale ? '，显示上次读数' : ''}`
      : `${state?.appName || '电量栏'} · 未发现鼠标`;
    this.tray.setToolTip(tooltip);

    if (process.platform === 'darwin') {
      if (active) {
        this.tray.setTitle(`${active.stale ? '~' : ''}${active.battery}%`, {
          fontType: 'monospacedDigit',
        });
      } else if (state?.scanning) {
        this.tray.setTitle('…', { fontType: 'monospacedDigit' });
      } else {
        this.tray.setTitle('', { fontType: 'monospacedDigit' });
      }
    }
  }

  rebuildMenu() {
    if (!this.tray) return;
    const state = this.state || {};
    const active = state.activeDevice;
    const settings = state.settings || { refreshInterval: 60, lowBatteryAlerts: true };
    const updated = formatTime(state.lastUpdated);

    const items = [];

    if (active) {
      items.push(
        { label: active.name, enabled: false },
        {
          label: `电量 ${active.battery}%${active.charging ? ' · 充电中' : ''}${
            active.stale ? ' · 等待唤醒' : ''
          }${updated ? `  ·  ${updated}` : ''}`,
          enabled: false,
        },
      );
    } else if (state.scanning) {
      items.push({ label: '正在读取鼠标电量…', enabled: false });
    } else {
      items.push({ label: '未发现支持的鼠标', enabled: false });
    }

    items.push(
      { type: 'separator' },
      { label: '刷新电量', click: () => this.options.onRefresh() },
      { label: '显示面板', click: () => this.options.onShowWindow() },
      { label: '打开设置…', click: () => this.options.onOpenSettings() },
      { type: 'separator' },
      {
        label: '低电量提醒',
        type: 'checkbox',
        checked: Boolean(settings.lowBatteryAlerts),
        click: (menuItem) => {
          this.options.onUpdateSettings({ lowBatteryAlerts: Boolean(menuItem.checked) });
        },
      },
      {
        label: '开机自动启动',
        type: 'checkbox',
        checked: Boolean(settings.launchAtLogin),
        enabled: Boolean(state.autoLaunchSupported),
        click: (menuItem) => {
          this.options.onUpdateSettings({ launchAtLogin: Boolean(menuItem.checked) });
        },
      },
      {
        label: '自动刷新',
        submenu: [
          { label: '每 30 秒', type: 'radio', checked: settings.refreshInterval === 30 },
          { label: '每分钟', type: 'radio', checked: settings.refreshInterval === 60 },
          { label: '每 5 分钟', type: 'radio', checked: settings.refreshInterval === 300 },
        ].map((item, index) => ({
          ...item,
          click: () => this.options.onUpdateSettings({ refreshInterval: [30, 60, 300][index] }),
        })),
      },
      { type: 'separator' },
      {
        label: `上次更新：${updated || '尚未读取'} · ${refreshLabel(settings.refreshInterval)}`,
        enabled: false,
      },
      { type: 'separator' },
      { label: '退出电量栏', click: () => this.options.onQuit() },
    );

    this.menu = Menu.buildFromTemplate(items);
  }

  destroy() {
    if (this.tray) {
      this.tray.destroy();
      this.tray = null;
    }
  }
}

module.exports = { AppTray, formatTime, refreshLabel };
