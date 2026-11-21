'use strict';
// 画面側 (renderer) に見せる入口。画面側は Node の機能に直接は触れず、ここに並べた呼び出しだけを使う
const { contextBridge, ipcRenderer, webUtils } = require('electron');

const calls = [
  'init', 'setPref', 'saveTheme', 'saveUserProfiles', 'setMenuState', 'exportSettings', 'importSettings',
  'openDialog', 'saveDialog', 'readFile', 'writeFile', 'fileInfo', 'clearRecent',
  'totpBegin', 'makeKey', 'newKeyFile',
  'listDir', 'findFiles', 'createEntry', 'renameEntry', 'trashEntry', 'reveal', 'openPath', 'openExternal', 'copyText', 'pathInfo',
  'grepStart', 'grepCancel', 'furigana', 'serverSave', 'serverDelete', 'serverForgetKey', 'serverHasPassword', 'remoteCall', 'remoteRead', 'remoteWrite',
  'aiStatus', 'aiSetKey', 'aiListModels', 'aiSend', 'aiCancel', 'aiUsage', 'aiUsageClear', 'importPDF', 'assocStatus', 'assocApply',
  'exportPDF', 'print', 'exportDocx', 'screenshot',
  'collabHost', 'collabJoin', 'collabSend', 'collabClose', 'collabStop', 'attention',
  'editCommand', 'setTitle', 'closeWindow', 'quit', 'about', 'fileIcon', 'growWindow',
  'pluginList', 'pluginsFolder', 'pluginPrepare', 'pluginCommit', 'pluginDiscard', 'pluginUninstall', 'pluginTemplate', 'pluginDocs', 'pluginFetch', 'readClipboard', 'pluginToken', 'pluginReply',
  'llmStatus', 'llmRequiredBuild', 'llmInstall', 'llmCancelInstall', 'llmStart', 'llmPull', 'llmCancelPull', 'llmDelete',
];
const events = ['command', 'open-files', 'open-grep', 'collab:open', 'collab:message', 'collab:close', 'app:request-close', 'grep:matches', 'grep:done', 'ai:delta', 'ai:done', 'llm:install', 'llm:pull', 'plugin:call'];

const api = {};
for (const name of calls) api[name] = (...args) => ipcRenderer.invoke('api:' + name, ...args);
api.on = (channel, fn) => {
  if (!events.includes(channel)) return;
  ipcRenderer.on(channel, (event, ...args) => fn(...args));
};

// ウインドウに落としたファイルの場所
api.pathForFile = file => {
  try { return webUtils.getPathForFile(file); } catch (e) { return ''; }
};

contextBridge.exposeInMainWorld('api', api);
