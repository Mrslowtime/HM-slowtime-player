/**
 * 「我的列表」完整数据持久化 —— 自建列表 + 每个列表里的歌曲，重启后保留。
 *
 * 之前只有显示顺序落盘（ListOrderStore），列表本身是内存态，
 * 启动时由 initDefaultLists 重建 4 个默认列表，自建列表与其中的歌曲会丢失。
 * 本模块把 userLists 与 allMusicList 整体快照落盘。
 *
 * 存储介质：**沙箱文件**（filesDir/my_list_data_v1.json），不再用 preferences。
 * 原因（1.0.1.3xxx 修复）：preferences 的 string 值有 8192 字节上限，
 * 列表快照（尤其「播放列表」里几十首歌的 meta/_qualitys）轻易超过这个长度，
 * put 会失败而只留一条 hilog，表现为「用一段时间后退出重进，播放列表被清空」。
 * 现在的写法是「整份 JSON 写临时文件 → renameSync 原子替换」，无长度上限、
 * 断电也不会留下半截文件；旧版本留在 preferences 里的数据只读一次做迁移。
 *
 * 关键坑：MusicInfoMetaOnline._qualitys 是 Map<string, string|null>，
 * JSON.stringify 会把它变成 {}，直接反序列化后音源换链调用 .get() 会抛异常。
 * 所以每首歌额外保存 q 数组（键值对），恢复时再把 _qualitys 还原成真正的 Map。
 *
 * 写入采用「最新快照 + 串行合并」：任何一次列表变更都立刻生成完整快照，
 * 若上一次写入尚未结束，只替换待写内容，结束后用最新快照补写一次，
 * 避免并发写造成旧数据覆盖新数据。
 */
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicInfo, MusicInfoMetaOnline, UserListInfo } from '../model/MusicTypes';
import { AppState } from '../store/AppState';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

/** 旧版 preferences 库名 / 键名：只用于一次性迁移 */
const PREF_NAME: string = 'slowtime_data';
const KEY_LIST_DATA: string = 'my_list_data_v1';
const FILE_NAME: string = 'my_list_data_v1.json';

/** 音质 hash 表的一项（Map 无法直接 JSON 化） */
interface QPair {
  k: string;
  v: string | null;
}

/** 一首歌 + 它的音质 hash 表快照 */
interface StoredMusic {
  m: MusicInfo;
  q: QPair[];
}

interface StoredList {
  id: string;
  songs: StoredMusic[];
}

interface StoredData {
  v: number;
  userLists: UserListInfo[];
  lists: StoredList[];
}

export class ListDataStore {
  private static _inst: ListDataStore | null = null;
  private loaded: boolean = false;
  private restored: boolean = false;
  private data: StoredData | null = null;
  /** 待写入的最新快照 */
  private latest: string = '';
  private saving: boolean = false;

  static getInstance(): ListDataStore {
    if (ListDataStore._inst === null) {
      ListDataStore._inst = new ListDataStore();
    }
    return ListDataStore._inst;
  }

  private filePath(): string {
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + FILE_NAME;
  }

  /** 读文件正文；不存在 / 读取失败返回 '' */
  private readFile(path: string): string {
    if (path.length === 0) {
      return '';
    }
    try {
      // 用 openSync 试探存在性（部分机型 fs.accessSync 返回值不可靠）
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const st = fs.statSync(path);
        if (st.size <= 0) {
          return '';
        }
        const buf = new ArrayBuffer(st.size);
        const n = fs.readSync(f.fd, buf, { offset: 0, length: st.size });
        return new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf, 0, n));
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      return '';
    }
  }

  /** 兼容旧版 preferences 快照（只迁移一次） */
  private async readLegacy(): Promise<string> {
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return '';
    }
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
      const raw = await store.get(KEY_LIST_DATA, '') as string;
      return typeof raw === 'string' ? raw : '';
    } catch (e) {
      return '';
    }
  }

  /** 启动时异步载入（必须在 ListManager.initDefaultLists 之前 await） */
  async ensure(): Promise<void> {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    let raw: string = this.readFile(this.filePath());
    let migrated: boolean = false;
    if (raw.length === 0) {
      raw = await this.readLegacy();
      migrated = raw.length > 0;
    }
    if (raw.length === 0) {
      return;
    }
    try {
      const d = JSON.parse(raw) as StoredData;
      if (d !== null && d.v === 1 && d.userLists !== undefined && d.lists !== undefined) {
        this.data = d;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'ListDataStore: loaded %{public}d lists (migrated=%{public}s)',
          d.lists.length, migrated ? 'true' : 'false');
        if (migrated) {
          // 旧 preferences 数据原样搬到文件（直接写这段正文，不能用当前 AppState 重新快照，
          // 此刻全局状态还是空的，重拍会把老数据覆盖成空列表）
          try {
            this.writeAtomic(raw);
            hilog.info(LOG_DOMAIN, LOG_TAG, 'ListDataStore: migrated from preferences');
          } catch (e) {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'ListDataStore: migrate write failed');
          }
        }
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'ListDataStore: load failed, use defaults');
    }
  }

  /** 把快照写回全局状态；只在本次启动执行一次，且必须在 initDefaultLists 之前调用 */
  restoreInto(state: AppState): void {
    if (this.restored) {
      return;
    }
    this.restored = true;
    const d = this.data;
    if (d === null) {
      return;
    }
    try {
      const lists: UserListInfo[] = [];
      for (const u of d.userLists) {
        if (u !== null && typeof u.id === 'string' && u.id.length > 0 && typeof u.name === 'string') {
          lists.push({
            id: u.id,
            name: u.name,
            source: u.source,
            sourceListId: u.sourceListId,
            locationUpdateTime: typeof u.locationUpdateTime === 'number' ? u.locationUpdateTime : Date.now(),
          });
        }
      }
      const all = new Map<string, MusicInfo[]>();
      for (const l of d.lists) {
        if (l === null || typeof l.id !== 'string' || l.id.length === 0) {
          continue;
        }
        const songs: MusicInfo[] = [];
        for (const it of l.songs) {
          if (it === null || it.m === null || typeof it.m.id !== 'string') {
            continue;
          }
          const m: MusicInfo = it.m;
          const meta = m.meta as MusicInfoMetaOnline;
          // JSON 里的 _qualitys 是 {}（或不存在），还原成 Map 供音源换链使用
          if (meta !== null && meta !== undefined && meta._qualitys !== undefined) {
            const map = new Map<string, string | null>();
            if (it.q !== undefined && it.q !== null) {
              for (const p of it.q) {
                map.set(p.k, p.v);
              }
            }
            meta._qualitys = map;
          }
          songs.push(m);
        }
        all.set(l.id, songs);
      }
      state.userLists = lists;
      state.allMusicList = all;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'ListDataStore: restored %{public}d lists', lists.length);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'ListDataStore: restore failed, use defaults');
    }
  }

  /** 从当前全局状态生成完整快照（不含顺序，顺序由 ListOrderStore 单独维护） */
  private snapshot(): string {
    const state = AppState.getInstance();
    const lists: StoredList[] = [];
    state.allMusicList.forEach((songs: MusicInfo[], id: string): void => {
      const items: StoredMusic[] = [];
      for (const m of songs) {
        const q: QPair[] = [];
        const meta = m.meta as MusicInfoMetaOnline;
        if (meta !== null && meta !== undefined && meta._qualitys instanceof Map) {
          meta._qualitys.forEach((v: string | null, k: string): void => {
            q.push({ k: k, v: v });
          });
        }
        items.push({ m: m, q: q });
      }
      lists.push({ id: id, songs: items });
    });
    const data: StoredData = {
      v: 1,
      userLists: state.userLists.slice(),
      lists: lists,
    };
    return JSON.stringify(data);
  }

  /** 任意列表/歌曲变更后调用：幂等、并发安全、失败不影响主流程 */
  async saveFromState(): Promise<void> {
    try {
      this.latest = this.snapshot();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'ListDataStore: snapshot failed');
      return;
    }
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      // 循环期间若有新变更，latest 会变化，用最新快照再写一轮
      while (true) {
        const text = this.latest;
        this.writeAtomic(text);
        if (this.latest === text) {
          break;
        }
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'ListDataStore: persist failed');
    } finally {
      this.saving = false;
    }
  }

  /** 临时文件 + rename 原子替换：中途被杀也不会留下半截 JSON */
  private writeAtomic(text: string): void {
    const path: string = this.filePath();
    if (path.length === 0) {
      return;
    }
    const tmp: string = path + '.tmp';
    const f = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      // writeSync 第二个参数只接受 ArrayBuffer | string，传 Uint8Array 会抛 Invalid argument
      fs.writeSync(f.fd, text);
    } finally {
      fs.closeSync(f);
    }
    try {
      fs.renameSync(tmp, path);
    } catch (e) {
      // 个别机型 rename 覆盖已存在文件会失败：先删再改名
      try {
        fs.unlinkSync(path);
      } catch (e2) {
        // 目标不存在时忽略
      }
      fs.renameSync(tmp, path);
    }
  }
}
