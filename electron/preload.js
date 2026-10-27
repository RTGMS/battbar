'use strict';

const { contextBridge, ipcRenderer } = require('electron');

function subscribe(channel, callback) {
  if (typeof callback !== 'function') return () => {};
  const handler = (_event, payload) => callback(payload);
  ipcRenderer.on(channel, handler);
  return () => ipcRenderer.removeListener(channel, handler);
}

contextBridge.exposeInMainWorld('mouseBattery', {
  getState: () => ipcRenderer.invoke('app:get-state'),
  refresh: () => ipcRenderer.invoke('app:refresh'),
  selectDevice: (deviceId) => ipcRenderer.invoke('app:select-device', deviceId),
  updateSettings: (patch) => ipcRenderer.invoke('app:update-settings', patch),
  hideWindow: () => ipcRenderer.invoke('window:hide'),
  setPinned: (pinned) => ipcRenderer.invoke('window:set-pinned', Boolean(pinned)),
  copyDiagnostics: () => ipcRenderer.invoke('app:copy-diagnostics'),
  openLogs: () => ipcRenderer.invoke('app:open-logs'),
  quit: () => ipcRenderer.invoke('app:quit'),
  onState: (callback) => subscribe('state:update', callback),
  onOpenSettings: (callback) => subscribe('ui:open-settings', callback),
});
