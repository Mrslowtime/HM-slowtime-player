/**
 * 本地数据备份与恢复 —— 按「数据同步」里"导出/导入"的本地子集。
 *
 * 本应用为纯本地存储、无云端后端，因此"同步"落地为：
 *   1) 导出：把设置 + 我的列表（含歌曲）+ 用户自建列表序列化到
 *      **手机「下载/com.slowtime.hmplayer/备份」**（与下载文件同一个公共目录，
 *      卸载应用不会删除）；公共目录不可用时才回落到应用沙箱 filesDir/backup；
 *   2) 导入：读取备份文件恢复设置与列表；沙箱 + 公共目录一起列，
 *      另外支持「从文件中选择备份」——用系统文件选择器读任意位置的 json，
 *      这是卸载重装（沙箱被清空）后唯一可行的恢复入口。
 * App 不内置任何账号或网络同步服务；跨设备请自行拷贝该 json 文件。
 */
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingValue } from '../config/DefaultSetting';
import { SettingStore } from '../store/SettingStore';
import { AppState } from '../store/AppState';
import { MusicInfo, UserListInfo } from '../model/MusicTypes';
import { ListIds } from '../config/AppConstants';
import { listEvent, ListEvents, appEvent, AppEvents } from '../store/EventBus';
import { getAppContext } from '../common/AppContext';
import { publicDownloadBase } from './DownloadStorage';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

export interface BackupListEntry {
  id: string;
  musics: MusicInfo[];
}

export interface BackupPayload {
  app: string;
  schema: number;
  exportedAt: string;
  settings: Record<string, SettingValue>;
  lists: BackupListEntry[];
  userLists: UserListInfo[];
}

/** 导入结果（命名接口，ArkTS 禁止内联对象类型声明） */
export interface BackupResult {
  settings: number;
  lists: number;
}

/** 导出结果：path 是真实落盘路径，isPublic 表示在手机可见目录（卸载不丢） */
export interface BackupExportResult {
  path: string;
  isPublic: boolean;
}

/** 把 Map 形式的设置/列表转成纯对象，便于 JSON 序列化（纯函数，可单测） */
export function buildBackupPayload(
  settings: Map<string, SettingValue>,
  lists: Map<string, MusicInfo[]>,
  userLists: UserListInfo[]
): BackupPayload {
  const settingObj: Record<string, SettingValue> = {};
  settings.forEach((v: SettingValue, k: string): void => {
    settingObj[k] = v;
  });
  const listArr: BackupListEntry[] = [];
  lists.forEach((v: MusicInfo[], k: string): void => {
    listArr.push({ id: k, musics: v });
  });
  return {
    app: 'slowtime-hm',
    schema: 1,
    exportedAt: new Date().toISOString(),
    settings: settingObj,
    lists: listArr,
    userLists: userLists,
  };
}

/** 解析备份文本（纯函数，可单测）。失败返回 null。 */
export function parseBackupPayload(text: string): BackupPayload | null {
  let obj: Object | null = null;
  try {
    obj = JSON.parse(text);
  } catch (e) {
    return null;
  }
  if (obj === null || typeof obj !== 'object') {
    return null;
  }
  const o = obj as Record<string, Object>;
  if (o['app'] !== 'slowtime-hm') {
    return null;
  }
  const settingsRaw = o['settings'];
  const listsRaw = o['lists'];
  const userRaw = o['userLists'];
  if (typeof settingsRaw !== 'object' || settingsRaw === null ||
      !Array.isArray(listsRaw) || !Array.isArray(userRaw)) {
    return null;
  }
  const settings: Record<string, SettingValue> = {};
  const sr = settingsRaw as Record<string, SettingValue>;
  Object.keys(sr).forEach((k: string): void => {
    settings[k] = sr[k];
  });
  const lists: BackupListEntry[] = [];
  for (const item of listsRaw as Array<Object>) {
    const it = item as Record<string, Object>;
    if (typeof it['id'] === 'string' && Array.isArray(it['musics'])) {
      lists.push({ id: it['id'] as string, musics: it['musics'] as MusicInfo[] });
    }
  }
  const userLists: UserListInfo[] = [];
  for (const u of userRaw as Array<Object>) {
    const it = u as Record<string, Object>;
    if (typeof it['id'] === 'string' && typeof it['name'] === 'string') {
      userLists.push({
        id: it['id'] as string,
        name: it['name'] as string,
        locationUpdateTime: typeof it['locationUpdateTime'] === 'number'
          ? it['locationUpdateTime'] as number : Date.now(),
      });
    }
  }
  return {
    app: 'slowtime-hm',
    schema: typeof o['schema'] === 'number' ? o['schema'] as number : 1,
    exportedAt: typeof o['exportedAt'] === 'string' ? o['exportedAt'] as string : '',
    settings: settings,
    lists: lists,
    userLists: userLists,
  };
}

function backupDir(): string {
  const ctx = getAppContext();
  if (ctx === null) {
    return '';
  }
  return ctx.filesDir + '/backup';
}

/** 公共目录下的备份子目录名（与下载文件同根：下载/com.slowtime.hmplayer/备份） */
const PUBLIC_BACKUP_SUB: string = '/备份';

/**
 * 公共备份目录（手机「下载/com.slowtime.hmplayer/备份」）。
 * 拿不到公共目录（设备不支持 / 权限异常）时返回空串，调用方回落沙箱。
 */
async function publicBackupDir(): Promise<string> {
  const base: string = await publicDownloadBase();
  if (base.length === 0) {
    return '';
  }
  const dir: string = base + PUBLIC_BACKUP_SUB;
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
  } catch (e) {
    // 已存在 / 并发创建都算成功，只有真的不可用才当失败
    try {
      if (!fs.accessSync(dir)) {
        return '';
      }
    } catch (e2) {
      return '';
    }
  }
  return dir;
}

function tsName(): string {
  const d = new Date();
  const p = (n: number): string => (n < 10 ? '0' : '') + n.toString();
  return d.getFullYear().toString() + p(d.getMonth() + 1) + p(d.getDate())
    + '-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
}

/** 系统列表默认中文名（规避 ArkTS 计算属性名限制） */
function sysNameOf(id: string): string {
  if (id === ListIds.PLAYLIST || id === ListIds.DEFAULT) { return '我的歌单'; }
  if (id === ListIds.LOVE) { return '我的收藏'; }
  if (id === ListIds.TEMP) { return '播放列表'; }
  if (id === ListIds.DOWNLOAD) { return '下载列表'; }
  return '未命名列表';
}

export class BackupManager {
  static getInstance(): BackupManager {
    if (sInstance === null) {
      sInstance = new BackupManager();
    }
    return sInstance;
  }

  /**
   * 导出当前设置 + 列表。
   * 默认写到公共目录「下载/com.slowtime.hmplayer/备份」（卸载应用不会删掉），
   * 公共目录不可用时回落到应用沙箱 filesDir/backup（旧行为）。
   */
  async exportBackup(): Promise<BackupExportResult> {
    const store = SettingStore.getInstance();
    const state = AppState.getInstance();
    const payload = buildBackupPayload(store.exportAll(), state.allMusicList, state.userLists);
    const text = JSON.stringify(payload);
    const fileName: string = 'backup-' + tsName() + '.json';

    const dirs: string[] = [];
    const isPublicFlags: boolean[] = [];
    const pub: string = await publicBackupDir();
    if (pub.length > 0) {
      dirs.push(pub);
      isPublicFlags.push(true);
    }
    const sb: string = backupDir();
    if (sb.length > 0) {
      dirs.push(sb);
      isPublicFlags.push(false);
    }
    if (dirs.length === 0) {
      throw new Error('上下文未就绪');
    }
    let lastErr: string = '';
    for (let i = 0; i < dirs.length; i++) {
      const dir: string = dirs[i];
      try {
        try {
          fs.mkdirSync(dir, true);
        } catch (e) {
          void e;
        }
        const path: string = dir + '/' + fileName;
        const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          // SDK: writeSync(fd, buffer: ArrayBuffer | string)，传 Uint8Array 会抛 Invalid argument
          fs.writeSync(f.fd, text);
        } finally {
          fs.closeSync(f);
        }
        hilog.info(LOG_DOMAIN, LOG_TAG, 'BackupManager export -> %{public}s', path);
        return { path: path, isPublic: isPublicFlags[i] };
      } catch (e) {
        lastErr = (e as Error).message;
      }
    }
    throw new Error(lastErr.length > 0 ? lastErr : '导出失败');
  }

  /**
   * 列出所有备份文件路径（新的在前）。
   * 同时看公共目录与沙箱：重装后沙箱是空的，但公共目录里的备份还在。
   */
  async listBackups(): Promise<string[]> {
    const dirs: string[] = [];
    const pub: string = await publicBackupDir();
    if (pub.length > 0) {
      dirs.push(pub);
    }
    const sb: string = backupDir();
    if (sb.length > 0 && sb !== pub) {
      dirs.push(sb);
    }
    const files: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (const dir of dirs) {
      let names: string[] = [];
      try {
        names = fs.listFileSync(dir);
      } catch (e) {
        continue;
      }
      for (const name of names) {
        if (!name.startsWith('backup-') || !name.endsWith('.json')) {
          continue;
        }
        // 两个目录可能有同名备份：只列一份，优先公共目录
        if (seen.has(name)) {
          continue;
        }
        seen.add(name);
        files.push(dir + '/' + name);
      }
    }
    // 按文件名（内含时间戳）倒序，同名的按目录保持先来后到
    files.sort((a: string, b: string): number => {
      const na: string = a.substring(a.lastIndexOf('/') + 1);
      const nb: string = b.substring(b.lastIndexOf('/') + 1);
      if (na > nb) { return -1; }
      if (na < nb) { return 1; }
      return 0;
    });
    return files;
  }

  /** 读取备份文件文本 */
  private async readFile(path: string): Promise<string> {
    // 文件选择器返回的是 URI（datashare:// / file://），拿不到 stat 时用 readTextSync 兜底
    try {
      const direct: string = fs.readTextSync(path);
      if (direct.length > 0) {
        return direct;
      }
    } catch (e) {
      void e;
    }
    const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(path);
      const buf = new Uint8Array(stat.size);
      fs.readSync(f.fd, buf);
      return new util.TextDecoder().decodeToString(buf);
    } finally {
      fs.closeSync(f);
    }
  }

  /** 导入指定备份，恢复设置与列表。返回恢复的设置项数与列表数 */
  async importBackup(path: string): Promise<BackupResult> {
    const text = await this.readFile(path);
    const payload = parseBackupPayload(text);
    if (payload === null) {
      throw new Error('备份文件格式不正确');
    }
    const store = SettingStore.getInstance();
    const settingMap = new Map<string, SettingValue>();
    Object.keys(payload.settings).forEach((k: string): void => {
      settingMap.set(k, payload.settings[k]);
    });
    await store.setMany(settingMap);

    const state = AppState.getInstance();
    // 重建用户列表（保留 4 个系统列表，缺失则补上）
    const systemIds: string[] = [ListIds.DEFAULT, ListIds.LOVE, ListIds.TEMP, ListIds.DOWNLOAD];
    const merged: UserListInfo[] = [];
    const seen = new Set<string>();
    for (const id of systemIds) {
      const hit = payload.userLists.find((u: UserListInfo): boolean => u.id === id);
      if (hit !== undefined) {
        merged.push(hit);
      } else {
        merged.push({ id, name: sysNameOf(id), locationUpdateTime: Date.now() });
      }
      seen.add(id);
      if (!state.allMusicList.has(id)) {
        state.allMusicList.set(id, []);
      }
    }
    for (const u of payload.userLists) {
      if (!seen.has(u.id)) {
        merged.push(u);
        seen.add(u.id);
      }
    }
    state.userLists = merged;
    // 恢复各列表歌曲
    for (const entry of payload.lists) {
      state.allMusicList.set(entry.id, entry.musics);
    }
    listEvent().emit(ListEvents.LIST_DATA_OVERWRITE);
    appEvent().emit(AppEvents.MY_LIST_MUSIC_UPDATE);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'BackupManager import <- %{public}s', path);
    return { settings: settingMap.size, lists: payload.lists.length };
  }

  /** 导入最新一份备份 */
  async importLatest(): Promise<BackupResult> {
    const files = await this.listBackups();
    if (files.length === 0) {
      throw new Error('没有可用的备份文件');
    }
    return this.importBackup(files[0]);
  }

  /**
   * 从系统文件选择器选一份备份 json 导入。
   * 这是「卸载重装后沙箱被清空」时唯一可行的恢复入口：用户把之前导出/拷贝的
   * backup-*.json 放在任意位置都能读。导入成功后顺手复制一份到公共备份目录，
   * 下次「导入最近备份」就能一点即用，也不会随卸载消失。
   * @returns 导入结果；用户取消选择返回 null
   */
  async importFromPicker(): Promise<BackupResult | null> {
    const ctx = getAppContext();
    if (ctx === null) {
      return null;
    }
    const p = new picker.DocumentViewPicker(ctx);
    const opt = new picker.DocumentSelectOptions();
    opt.maxSelectNumber = 1;
    opt.fileSuffixFilters = ['.json'];
    const uris: string[] = await p.select(opt);
    if (uris.length === 0 || uris[0].length === 0) {
      return null;
    }
    const uri: string = uris[0];
    const text: string = await this.readFile(uri);
    const result: BackupResult = await this.importBackup(uri);
    // 保留一份到公共备份目录（失败不影响已完成的恢复）
    await this.copyIntoPublicBackup(uri, text);
    return result;
  }

  /** 把外部选中的备份文本存进公共备份目录，供以后一键导入 */
  private async copyIntoPublicBackup(uri: string, text: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    const dir: string = await publicBackupDir();
    if (dir.length === 0) {
      return;
    }
    let name: string = uri.substring(uri.lastIndexOf('/') + 1);
    try {
      name = decodeURIComponent(name);
    } catch (e) {
      void e;
    }
    if (!name.startsWith('backup-') || !name.endsWith('.json')) {
      name = 'backup-' + tsName() + '-imported.json';
    }
    try {
      const path: string = dir + '/' + name;
      const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'backup copy into public failed');
    }
  }
}

let sInstance: BackupManager | null = null;
