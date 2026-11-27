/**
 * 收藏歌单存储 —— 「我的歌单」分类的唯一数据源。
 *
 * 与「我的收藏」区分：「我的收藏」是 ListManager 的 love 列表（收藏歌曲），
 * 这里是收藏的**歌单**（在线歌单 / 排行榜）。
 *
 * 用独立 preferences 文件（slowtime_playlist）而不是 SettingStore：
 * SettingStore.init() 只加载 DEFAULT_SETTING_ENTRIES 白名单里的键，
 * 任意 key 写进去重启后读不回来（旧版歌单收藏就踩了这个坑）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FavoritePlaylistInfo } from '../model/MusicTypes';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { getAppContext } from '../common/AppContext';
import { appEvent, AppEvents } from './EventBus';
import { FavSongIndex } from '../core/FavSongIndex';

const PREF_NAME: string = 'slowtime_playlist';
const KEY_ITEMS: string = 'favorite_playlists';

let sInstance: PlaylistStore | null = null;

export class PlaylistStore {
  private store: preferences.Preferences | null = null;
  private items: FavoritePlaylistInfo[] = [];
  private loaded: boolean = false;

  static getInstance(): PlaylistStore {
    if (sInstance === null) {
      sInstance = new PlaylistStore();
    }
    return sInstance;
  }

  /** 启动时调用一次，把磁盘上的收藏歌单读进内存 */
  async init(): Promise<void> {
    if (this.loaded) {
      return;
    }
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return;
    }
    try {
      this.store = await preferences.getPreferences(ctx, PREF_NAME);
      const raw = await this.store.get(KEY_ITEMS, '[]');
      if (typeof raw === 'string' && raw.length > 0) {
        const arr: FavoritePlaylistInfo[] = JSON.parse(raw) as FavoritePlaylistInfo[];
        if (arr !== null && arr !== undefined) {
          this.items = arr;
        }
      }
      this.loaded = true;
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'PlaylistStore init failed');
    }
  }

  /** 全部收藏歌单（最近收藏在前）；字段做一次兜底，避免旧数据缺字段导致 UI 取值崩溃 */
  list(): FavoritePlaylistInfo[] {
    return this.items.map((x: FavoritePlaylistInfo): FavoritePlaylistInfo => {
      return {
        source: x.source ?? '',
        sourceListId: x.sourceListId ?? '',
        name: x.name ?? '',
        author: x.author ?? '',
        img: x.img ?? '',
        playCount: x.playCount ?? '',
        total: x.total ?? 0,
        type: x.type ?? 'playlist',
        updateTime: x.updateTime ?? 0,
      };
    });
  }

  count(): number {
    return this.items.length;
  }

  isFavorite(source: string, id: string): boolean {
    return this.items.some((x: FavoritePlaylistInfo): boolean =>
      x.source === source && x.sourceListId === id);
  }

  /** 收藏 / 取消收藏，返回收藏后的状态 */
  async toggle(info: FavoritePlaylistInfo): Promise<boolean> {
    const i: number = this.items.findIndex((x: FavoritePlaylistInfo): boolean =>
      x.source === info.source && x.sourceListId === info.sourceListId);
    let fav: boolean = false;
    if (i >= 0) {
      this.items.splice(i, 1);
      fav = false;
    } else {
      this.items.unshift(info);
      fav = true;
    }
    await this.save();
    return fav;
  }

  async remove(source: string, id: string): Promise<void> {
    const next: FavoritePlaylistInfo[] = this.items.filter((x: FavoritePlaylistInfo): boolean =>
      !(x.source === source && x.sourceListId === id));
    if (next.length === this.items.length) {
      return;
    }
    this.items = next;
    await this.save();
  }

  /**
   * 批量移除（离开「我的列表」模块时，把本页点了取消收藏的歌单一次落盘）。
   * keys 为 source:sourceListId。
   */
  async removeMany(keys: string[]): Promise<void> {
    if (keys.length === 0) {
      return;
    }
    const set: Set<string> = new Set<string>(keys);
    const next: FavoritePlaylistInfo[] = this.items.filter((x: FavoritePlaylistInfo): boolean =>
      !set.has(x.source + ':' + x.sourceListId));
    if (next.length === this.items.length) {
      return;
    }
    this.items = next;
    await this.save();
  }

  /**
   * 按给定顺序重排收藏（「我的歌单」拖动排序用）。
   * 只调整顺序，不增不减；任何与现有集合不一致的情况直接放弃，避免误删。
   */
  async reorder(ordered: FavoritePlaylistInfo[]): Promise<void> {
    const map: Map<string, FavoritePlaylistInfo> = new Map<string, FavoritePlaylistInfo>();
    for (const x of this.items) {
      map.set(x.source + ':' + x.sourceListId, x);
    }
    const next: FavoritePlaylistInfo[] = [];
    for (const o of ordered) {
      const k: string = o.source + ':' + o.sourceListId;
      const real: FavoritePlaylistInfo | undefined = map.get(k);
      if (real !== undefined) {
        next.push(real);
        map.delete(k);
      }
    }
    map.forEach((v: FavoritePlaylistInfo): void => {
      next.push(v);
    });
    if (next.length !== this.items.length) {
      return;
    }
    this.items = next;
    await this.save();
  }

  private async save(): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put(KEY_ITEMS, JSON.stringify(this.items));
      await this.store.flush();
      // 已取消收藏的歌单同步清掉「歌曲 → 收藏歌单」索引，
      // 否则从播放列表点这些歌时，「我的歌单」卡片还会亮一个已删掉的歌单
      const alive: Set<string> = new Set<string>();
      for (const x of this.items) {
        alive.add('fav:' + x.source + ':' + x.sourceListId);
      }
      FavSongIndex.getInstance().pruneExcept(alive);
      // 让「我的歌单」分类立即重渲染
      appEvent().emit(AppEvents.MY_LIST_MUSIC_UPDATE);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'PlaylistStore save failed');
    }
  }
}
