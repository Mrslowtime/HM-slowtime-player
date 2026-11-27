/**
 * 我的列表管理 —— 按本项目的模块划分。
 * 我的歌单 / 我的收藏 / 播放列表 / 用户自建列表，增删移查、排序、去重。
 */
import { MusicInfo, UserListInfo } from '../model/MusicTypes';
import { ListIds, StorageKeys, isDownloadEnabled } from '../config/AppConstants';
import { AppState } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { listEvent, ListEvents, appEvent, AppEvents } from '../store/EventBus';
import { ListOrderStore } from './ListOrderStore';
import { ListDataStore } from './ListDataStore';

let sInstance: ListManager | null = null;

/** 播放历史最多保留的歌曲数：记满后每来一首新歌就淘汰最旧的一首 */
export const PLAY_HISTORY_LIMIT: number = 500;

export class ListManager {
  private state: AppState = AppState.getInstance();
  private settings: SettingStore = SettingStore.getInstance();

  static getInstance(): ListManager {
    if (sInstance === null) {
      sInstance = new ListManager();
    }
    return sInstance;
  }

  /**
   * 初始化默认列表：我的歌单 / 我的收藏 / 播放列表 / 播放历史 / 下载列表。
   * 「我的歌单」取代旧的「试听列表」：前者是收藏的歌单，数据在 PlaylistStore；
   * 后者在旧版里从来没有写入点，所以替换没有数据迁移成本。
   */
  initDefaultLists(): void {
    // 先还原上次保存的自建列表与各列表歌曲，再补默认列表，避免重启丢数据
    ListDataStore.getInstance().restoreInto(this.state);
    const now = Date.now();
    const defaults: UserListInfo[] = [
      { id: ListIds.PLAYLIST, name: '我的歌单', locationUpdateTime: now },
      { id: ListIds.LOVE, name: '我的收藏', locationUpdateTime: now },
      { id: ListIds.TEMP, name: '播放列表', locationUpdateTime: now },
      { id: ListIds.HISTORY, name: '播放历史', locationUpdateTime: now },
      // 下载列表：总开关关闭时不创建（源码保留，改 download.enable 即可恢复）
    ];
    if (isDownloadEnabled()) {
      defaults.push({ id: ListIds.DOWNLOAD, name: '下载列表', locationUpdateTime: now });
    }
    // 旧版「试听列表」分类已移除：清掉可能残留的内存项与空列表，避免旧 chip 继续出现
    this.state.userLists = this.state.userLists.filter((u: UserListInfo): boolean => u.id !== ListIds.DEFAULT);
    this.state.allMusicList.delete(ListIds.DEFAULT);
    // 下载功能关闭时只隐藏「下载列表」chip（入口），**保留列表里的歌曲数据**：
    // 总闸现在是可来回切换的用户设置，关掉再打开不能把已下载的歌曲清空。
    if (!isDownloadEnabled()) {
      this.state.userLists = this.state.userLists.filter((u: UserListInfo): boolean => u.id !== ListIds.DOWNLOAD);
    }
    // 保留已存在的用户列表，补上缺失的默认列表
    const existing = new Set<string>();
    for (const u of this.state.userLists) {
      existing.add(u.id);
    }
    // 播放历史是不是这一版新补的：只有首次出现时才强制放到「播放列表」后面，
    // 之后尊重用户自己拖出来的顺序（和别的固定列表一样可调位置）。
    const historyIsNew: boolean = !existing.has(ListIds.HISTORY);
    for (const d of defaults) {
      if (!existing.has(d.id)) {
        this.state.userLists.push(d);
      }
      if (!this.state.allMusicList.has(d.id)) {
        this.state.allMusicList.set(d.id, []);
      }
    }
    // 启动时套用持久化的显示顺序（只影响排列，不产生/删除列表）
    this.state.userLists = ListOrderStore.getInstance().applyOrder(this.state.userLists);
    if (historyIsNew) {
      this.placeHistoryAfterPlaylist();
      // 落盘：applyOrder 会把「不在旧顺序里的新列表」扔到末尾，
      // 不保存的话下次启动又被扔回去，用户会看到它自己跑到最后。
      this.persistOrder();
    }
    // 「临时列表」已更名为「播放列表」：旧快照里存的仍是旧名，这里统一改掉
    for (const u of this.state.userLists) {
      if (u.id === ListIds.TEMP && u.name !== '播放列表') {
        u.name = '播放列表';
        u.locationUpdateTime = u.locationUpdateTime > 0 ? u.locationUpdateTime : now;
      }
    }
    this.state.activeListId = ListIds.PLAYLIST;
    listEvent().emit(ListEvents.LIST_DATA_OVERWRITE);
  }

  /** 把「播放历史」挪到「播放列表」后面一位（仅首次创建时调用） */
  private placeHistoryAfterPlaylist(): void {
    const arr: UserListInfo[] = this.state.userLists;
    let hi: number = -1;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].id === ListIds.HISTORY) {
        hi = i;
        break;
      }
    }
    if (hi < 0) {
      return;
    }
    const item: UserListInfo = arr.splice(hi, 1)[0];
    let target: number = -1;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].id === ListIds.TEMP) {
        target = i + 1;
        break;
      }
    }
    if (target < 0) {
      arr.push(item);
    } else {
      arr.splice(target, 0, item);
    }
  }

  /**
   * 记录一次播放：写入「播放历史」列表（最新在最前）。
   * - 同一首歌再次播放 → 从原位置删掉后插到最前（不会出现两条）；
   * - 超过 PLAY_HISTORY_LIMIT(500) 就从尾部丢掉最旧的；
   * - 只动内存 + 触发一次落盘，不弹任何提示。
   * 暂停/恢复、失败重试都不会走到这里（只在真正切歌成功时调用）。
   */
  recordPlayHistory(music: MusicInfo): void {
    if (music.id.length === 0) {
      return;
    }
    const list: MusicInfo[] = this.state.getList(ListIds.HISTORY).slice();
    const idx: number = list.findIndex((x: MusicInfo): boolean => x.id === music.id);
    if (idx === 0) {
      // 已经在最前：不用改顺序，也不必重新落盘
      return;
    }
    if (idx > 0) {
      list.splice(idx, 1);
    }
    list.unshift(music);
    if (list.length > PLAY_HISTORY_LIMIT) {
      list.length = PLAY_HISTORY_LIMIT;
    }
    this.state.allMusicList.set(ListIds.HISTORY, list);
    listEvent().emit(ListEvents.LIST_MUSIC_ADD);
    appEvent().emit(AppEvents.MY_LIST_MUSIC_UPDATE);
    ListDataStore.getInstance().saveFromState().catch((): void => {});
  }

  createUserList(name: string): UserListInfo {    const item: UserListInfo = {
      id: 'user_' + Date.now().toString() + '_' + Math.floor(Math.random() * 1000).toString(),
      name,
      locationUpdateTime: Date.now(),
    };
    this.state.userLists.push(item);
    this.state.allMusicList.set(item.id, []);
    listEvent().emit(ListEvents.LIST_CREATE);
    this.persistOrder();
    return item;
  }

  removeUserList(id: string): void {
    if (this.isFixedList(id)) {
      return;
    }
    const arr = this.state.userLists.filter((u: UserListInfo): boolean => u.id !== id);
    this.state.userLists = arr;
    this.state.allMusicList.delete(id);
    listEvent().emit(ListEvents.LIST_REMOVE);
    this.persistOrder();
  }

  renameUserList(id: string, name: string): void {
    for (const u of this.state.userLists) {
      if (u.id === id) {
        u.name = name;
        u.locationUpdateTime = Date.now();
        break;
      }
    }
    listEvent().emit(ListEvents.LIST_UPDATE);
  }

  /** 显示顺序调整（按列表顺序管理逻辑） */
  moveListToPosition(id: string, toIndex: number): void {
    const arr = this.state.userLists;
    let from = -1;
    for (let i = 0; i < arr.length; i++) {
      if (arr[i].id === id) {
        from = i;
        break;
      }
    }
    if (from < 0 || toIndex < 0 || toIndex >= arr.length) {
      return;
    }
    const item = arr.splice(from, 1)[0];
    arr.splice(toIndex, 0, item);
    listEvent().emit(ListEvents.LIST_UPDATE);
    this.persistOrder();
  }

  /** 固定列表（含播放历史）：不可删除，但可以调整显示位置 */
  isFixedList(id: string): boolean {
    return id === ListIds.PLAYLIST || id === ListIds.LOVE ||
      id === ListIds.TEMP || id === ListIds.HISTORY || id === ListIds.DOWNLOAD;
  }

  /**
   * 按给定 id 顺序整体重排（列表抽屉的「多选 + 拖动」用）。
   * ids 里没有的列表按原顺序追加，避免升级或并发改动时丢列表。
   */
  reorderLists(ids: string[]): void {
    const rank: Map<string, number> = new Map();
    for (let i = 0; i < ids.length; i++) {
      rank.set(ids[i], i);
    }
    const known: UserListInfo[] = [];
    const rest: UserListInfo[] = [];
    for (const u of this.state.userLists) {
      if (rank.has(u.id)) {
        known.push(u);
      } else {
        rest.push(u);
      }
    }
    known.sort((a: UserListInfo, b: UserListInfo): number =>
      (rank.get(a.id) ?? 0) - (rank.get(b.id) ?? 0));
    this.state.userLists = known.concat(rest);
    listEvent().emit(ListEvents.LIST_UPDATE);
    this.persistOrder();
  }

  private persistOrder(): void {
    const ids: string[] = this.state.userLists.map((u: UserListInfo): string => u.id);
    ListOrderStore.getInstance().save(ids).catch((): void => {});
  }

  /** 添加歌曲（按 list.addMusicLocationType: top/bottom） */
  addListMusics(listId: string, musics: MusicInfo[], toTop: boolean = true): number {
    const list = this.state.getList(listId).slice();
    let added = 0;
    for (const m of musics) {
      if (list.some((x: MusicInfo): boolean => x.id === m.id)) {
        continue;
      }
      if (toTop) {
        list.unshift(m);
      } else {
        list.push(m);
      }
      added++;
    }
    this.state.allMusicList.set(listId, list);
    listEvent().emit(ListEvents.LIST_MUSIC_ADD);
    appEvent().emit(AppEvents.MY_LIST_MUSIC_UPDATE);
    return added;
  }

  removeListMusics(listId: string, ids: string[]): void {
    const set = new Set<string>(ids);
    const list = this.state.getList(listId).filter((m: MusicInfo): boolean => !set.has(m.id));
    this.state.allMusicList.set(listId, list);
    this.syncPlayIndex(listId, list);
    listEvent().emit(ListEvents.LIST_MUSIC_REMOVE);
    appEvent().emit(AppEvents.MY_LIST_MUSIC_UPDATE);
  }

  /** 用另一条记录替换列表里的一首（歌曲换源用：id 会变，但不能丢位置） */
  replaceMusic(listId: string, oldId: string, next: MusicInfo): boolean {
    const list = this.state.getList(listId).slice();
    const idx = list.findIndex((x: MusicInfo): boolean => x.id === oldId);
    if (idx < 0) {
      return false;
    }
    list[idx] = next;
    this.state.allMusicList.set(listId, list);
    listEvent().emit(ListEvents.LIST_MUSIC_UPDATE);
    appEvent().emit(AppEvents.MY_LIST_MUSIC_UPDATE);
    return true;
  }

  moveListMusic(listId: string, from: number, to: number): void {
    const list = this.state.getList(listId).slice();
    if (from < 0 || from >= list.length || to < 0 || to >= list.length) {
      return;
    }
    const item = list.splice(from, 1)[0];
    list.splice(to, 0, item);
    this.state.allMusicList.set(listId, list);
    this.syncPlayIndex(listId, list);
    listEvent().emit(ListEvents.LIST_MUSIC_UPDATE);
  }

  /**
   * 列表增删/换序后按当前播放曲目 id 重算 playIndex。
   * 不修正会让「下一首」和队列高亮错位（列表页删歌时同样受益）。
   */
  private syncPlayIndex(listId: string, list: MusicInfo[]): void {
    const cur = this.state.playMusicInfo;
    if (cur === null || cur.listId !== listId) {
      return;
    }
    let idx = -1;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === cur.musicInfo.id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      // 当前曲已被移出列表：索引夹取到有效范围，避免越界取歌
      idx = Math.min(this.state.playInfo.playIndex, list.length - 1);
      if (idx < 0) {
        idx = 0;
      }
    }
    if (idx === this.state.playInfo.playIndex) {
      return;
    }
    this.state.setPlayInfo({ playIndex: idx, playerListId: listId, playerPlayIndex: idx });
  }

  clearList(listId: string): void {
    this.state.allMusicList.set(listId, []);
    listEvent().emit(ListEvents.LIST_MUSIC_CLEAR);
    appEvent().emit(AppEvents.MY_LIST_MUSIC_UPDATE);
  }

  /** 收藏 / 取消收藏（按收藏 / 取消收藏语义） */
  toggleFavorite(m: MusicInfo): boolean {
    const love = this.state.getList(ListIds.LOVE);
    const idx = love.findIndex((x: MusicInfo): boolean => x.id === m.id);
    if (idx >= 0) {
      this.removeListMusics(ListIds.LOVE, [m.id]);
      return false;
    }
    // 「新歌添加位置」设置：top = 放列表最前，bottom = 追加到末尾
    const toTop: boolean = this.settings.getString('list.addMusicLocationType', 'top') !== 'bottom';
    this.addListMusics(ListIds.LOVE, [m], toTop);
    return true;
  }

  isFavorite(id: string): boolean {
    return this.state.getList(ListIds.LOVE).some((x: MusicInfo): boolean => x.id === id);
  }

  /** 去重（按 id 去重，按 id） */
  static deduplicationList(list: MusicInfo[]): MusicInfo[] {
    const seen = new Set<string>();
    const out: MusicInfo[] = [];
    for (const m of list) {
      if (!seen.has(m.id)) {
        seen.add(m.id);
        out.push(m);
      }
    }
    return out;
  }

  /** 导出列表数据（备份用，key 按列表键格式） */
  exportAll(): Map<string, MusicInfo[]> {
    const m = new Map<string, MusicInfo[]>();
    this.state.allMusicList.forEach((v: MusicInfo[], k: string): void => {
      m.set(StorageKeys.LIST_PREFIX + k, v);
    });
    return m;
  }
}
