/**
 * 收藏歌单 → 歌曲索引。
 *
 * 用途：从「播放列表 / 播放历史 / 我的收藏」点歌时，判断这首歌属于哪个**收藏的歌单**，
 * 从而把 AppState.playListKey 设成对应歌单，让「我的歌单」卡片与歌单详情页的黑胶
 * 显示完全同步（原来的 key 只由歌单详情页的播放动作写入，从别的列表点歌就点不亮）。
 *
 * 数据来源：歌单详情页每次加载歌曲时（且该歌单已收藏）写入一份 id 清单。
 * 不额外发任何网络请求，可离线使用。
 *
 * 存储：沙箱文件 filesDir/fav_song_index.json，形如
 *   { "fav:tx:123": ["tx|songId1", "tx|songId2"] }
 * 用文件而不是 preferences：一个几百首的歌单就接近 preferences 的 8192 字节上限。
 * 写入合并到一次 setTimeout，避免翻页时反复整文件重写。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicInfo } from '../model/MusicTypes';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

const FILE_NAME: string = 'fav_song_index.json';
/** 最多保留多少个歌单的索引（超出按插入顺序丢最早的一个） */
const MAX_GROUPS: number = 80;

export function favKeyOf(source: string, listId: string): string {
  return 'fav:' + source + ':' + listId;
}

let sInstance: FavSongIndex | null = null;

export class FavSongIndex {
  /** 歌单 key → 歌曲 key 列表 */
  private groups: Map<string, string[]> = new Map<string, string[]>();
  /** 歌曲 key（source|id）→ 歌单 key */
  private flat: Map<string, string> = new Map<string, string>();
  private loaded: boolean = false;
  private saveTimer: number = -1;

  static getInstance(): FavSongIndex {
    if (sInstance === null) {
      sInstance = new FavSongIndex();
    }
    return sInstance;
  }

  private filePath(): string {
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + FILE_NAME;
  }

  private readFile(path: string): string {
    if (path.length === 0) {
      return '';
    }
    try {
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

  /** 首次使用时同步读入（文件很小，单次几十 KB，播放入口调用一次可接受） */
  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const raw: string = this.readFile(this.filePath());
    if (raw.length === 0) {
      return;
    }
    try {
      const obj = JSON.parse(raw) as Record<string, string[]>;
      if (obj === null || obj === undefined) {
        return;
      }
      const keys: string[] = Object.keys(obj);
      for (const k of keys) {
        const arr: string[] = obj[k];
        if (arr === undefined || arr === null || arr.length === 0) {
          continue;
        }
        const list: string[] = [];
        for (const sk of arr) {
          if (typeof sk === 'string' && sk.length > 0) {
            list.push(sk);
            this.flat.set(sk, k);
          }
        }
        if (list.length > 0) {
          this.groups.set(k, list);
        }
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'FavSongIndex: loaded %{public}d playlists', this.groups.size);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'FavSongIndex: parse failed');
    }
  }

  /** 记录某个收藏歌单当前的歌曲清单（替换式，翻页时带上全量） */
  indexPlaylist(key: string, songs: MusicInfo[]): void {
    if (key.length === 0 || songs.length === 0) {
      return;
    }
    this.ensureLoaded();
    const old: string[] | undefined = this.groups.get(key);
    if (old !== undefined) {
      for (const sk of old) {
        if (this.flat.get(sk) === key) {
          this.flat.delete(sk);
        }
      }
    }
    const list: string[] = [];
    for (const m of songs) {
      const sk: string = m.source + '|' + m.id;
      list.push(sk);
      this.flat.set(sk, key);
    }
    this.groups.set(key, list);
    // 歌单数量太多时丢掉最早写入的一个，避免文件无限增长
    if (this.groups.size > MAX_GROUPS) {
      let firstKey: string = '';
      this.groups.forEach((_v: string[], k: string): void => {
        if (firstKey.length === 0) {
          firstKey = k;
        }
      });
      if (firstKey.length > 0) {
        this.dropPlaylist(firstKey);
      }
    }
    this.scheduleSave();
  }

  /** 取消收藏 / 歌单被移除时清掉它的索引 */
  dropPlaylist(key: string): void {
    if (key.length === 0) {
      return;
    }
    this.ensureLoaded();
    const old: string[] | undefined = this.groups.get(key);
    if (old === undefined) {
      return;
    }
    for (const sk of old) {
      if (this.flat.get(sk) === key) {
        this.flat.delete(sk);
      }
    }
    this.groups.delete(key);
    this.scheduleSave();
  }

  /** 这首歌属于哪个收藏歌单；不属于任何收藏歌单返回空串 */
  lookup(source: string, id: string): string {
    this.ensureLoaded();
    const k: string | undefined = this.flat.get(source + '|' + id);
    return k === undefined ? '' : k;
  }

  /** 只保留 alive 里的歌单索引（收藏集合变化时做一次一致性校正） */
  pruneExcept(alive: Set<string>): void {
    this.ensureLoaded();
    const dead: string[] = [];
    this.groups.forEach((_v: string[], k: string): void => {
      if (!alive.has(k)) {
        dead.push(k);
      }
    });
    for (const k of dead) {
      this.dropPlaylist(k);
    }
  }

  private scheduleSave(): void {
    if (this.saveTimer !== -1) {
      return;
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      this.saveNow();
    }, 1200);
  }

  private saveNow(): void {
    const path: string = this.filePath();
    if (path.length === 0) {
      return;
    }
    try {
      const out: Record<string, string[]> = {};
      this.groups.forEach((v: string[], k: string): void => {
        out[k] = v;
      });
      const text: string = JSON.stringify(out);
      const tmp: string = path + '.tmp';
      const f = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
      fs.renameSync(tmp, path);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'FavSongIndex: save failed');
    }
  }
}
