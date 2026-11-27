/**
 * 播放队列与切歌逻辑 —— 严格按协议
 * src/core/player/player.ts + playInfo.ts + playedList.ts + tempPlayList.ts + utils.ts
 * 以及 plugins/player/playList.ts 的队列规则。
 *
 * 关键行为（调研「最易遗漏行为核对表」）：
 * 1. RNTP 队列恒定 2 个 track；鸿蒙侧改为单一 AVPlayer + 逻辑队列，语义等价。
 * 2. 随机不重复靠 playedList + filterMusicList（过滤不喜欢/未完成下载）。
 * 3. 手动「下一首」把 list/singleLoop/none 强转 listLoop；自动切歌才尊重 none/list。
 * 4. 稍后播放优先于一切，isTop 决定插队头，listId=null、isTempPlay=true。
 * 5. isAutoCleanPlayedList 或换列表时清空 playedList。
 * 6. 恢复播放由 SavedPlayInfo + isSavePlayTime 控制。
 * 7. 取 URL 失败重试、延迟跳下一首（由 PlayController 承接）。
 * 8. 定时停止 timeoutExitPlayed。
 * 9. 通知 5 键 / 锁屏元数据 extras（由 SessionManager 承接）。
 * 10. 音质降档 flac24bit→flac→320k→128k。
 * 11. 进度 1s 轮询、剩余 <10s 预加载下一首 URL。
 * 12. 持久化分键存储。
 */
import {
  MusicInfo, PlayMusicInfo, TempPlayListItem, MusicInfoMetaOnline,
} from '../model/MusicTypes';
import { PlayMode, Quality, TRY_QUALITYS_LIST, ListIds, MUSIC_TOGGLE_MODE_LIST, normalizePlayMode } from '../config/AppConstants';
import { AppState } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { appEvent, AppEvents } from '../store/EventBus';

export interface NextMusicResult {
  musicInfo: MusicInfo | null;
  listId: string | null;
  index: number;
  isTempPlay: boolean;
}

/** 过滤出可播放列表：去掉已播放项、不喜欢项、未完成下载项 */
export interface FilterResult {
  filteredList: MusicInfo[];
  canPlayList: MusicInfo[];
  playerIndex: number;
}

/** 不喜欢规则子集（按不喜欢规则数据结构，抽成具名接口供 ArkTS 严格模式使用） */
export interface DislikeRule {
  musicNames: string[];
  singerNames: string[];
  rules: string[];
}

export function filterMusicList(
  list: MusicInfo[],
  playedList: MusicInfo[],
  currentIndex: number,
  dislikeInfo: DislikeRule,
  randomMode: boolean,
): FilterResult {
  const playedIds: Set<string> = new Set();
  for (const m of playedList) {
    playedIds.add(m.id);
  }
  const canPlayList: MusicInfo[] = [];
  const filteredList: MusicInfo[] = [];
  let playerIndex = 0;
  for (let i = 0; i < list.length; i++) {
    const m = list[i];
    const disliked = isDisliked(m, dislikeInfo);
    if (disliked) {
      continue;
    }
    canPlayList.push(m);
    if (randomMode && playedIds.has(m.id) && i !== currentIndex) {
      continue;
    }
    if (i === currentIndex) {
      playerIndex = filteredList.length;
    }
    filteredList.push(m);
  }
  return { filteredList, canPlayList, playerIndex };
}

function isDisliked(m: MusicInfo, d: DislikeRule): boolean {
  for (const rule of d.rules) {
    if (rule.length > 0 && (m.name + ' ' + m.singer).includes(rule)) {
      return true;
    }
  }
  for (const n of d.musicNames) {
    if (n.length > 0 && n === m.name) {
      return true;
    }
  }
  for (const n of d.singerNames) {
    if (n.length > 0 && n === m.singer) {
      return true;
    }
  }
  return false;
}

/** 音质降级：按 TRY_QUALITYS_LIST 从设定档向下找可用档位（按音质选择逻辑） */
export function getPlayQuality(prefer: Quality, meta: MusicInfoMetaOnline): Quality {
  const support: Quality[] = [];
  for (const q of meta.qualitys) {
    support.push(q.type);
  }
  const start = TRY_QUALITYS_LIST.indexOf(prefer);
  const order: Quality[] = start >= 0 ? TRY_QUALITYS_LIST.slice(start) : [prefer, ...TRY_QUALITYS_LIST];
  for (const q of order) {
    if (support.includes(q)) {
      return q;
    }
  }
  return '128k';
}

/** 循环模式切换（固定顺序，直接复用统一的 4 态列表） */
export function nextPlayMode(current: PlayMode): PlayMode {
  const i: number = MUSIC_TOGGLE_MODE_LIST.indexOf(current);
  return MUSIC_TOGGLE_MODE_LIST[(i + 1) % MUSIC_TOGGLE_MODE_LIST.length];
}

let sInstance: PlayQueue | null = null;

export class PlayQueue {
  private state: AppState = AppState.getInstance();
  private settings: SettingStore = SettingStore.getInstance();

  static getInstance(): PlayQueue {
    if (sInstance === null) {
      sInstance = new PlayQueue();
    }
    return sInstance;
  }

  private getMode(): PlayMode {
    return normalizePlayMode(this.settings.getString('player.togglePlayMethod', 'listLoop'));
  }

  /** 播放指定列表的第 index 首（按指定列表播放约定） */
  playList(listId: string, index: number): MusicInfo | null {
    const list = this.state.getList(listId);
    if (index < 0 || index >= list.length) {
      return null;
    }
    const musicInfo = list[index];
    const prev = this.state.playMusicInfo;
    // 换列表或开启自动清理时清空已播列表
    if ((prev !== null && prev.listId !== listId) ||
      this.settings.getBoolean('player.isAutoCleanPlayedList', false)) {
      this.state.setPlayedList([]);
    }
    // 清空稍后播放（按 handlePlay 的 clearTempPlayeList）
    this.state.setTempPlayList([]);
    this.state.setPlayMusicInfo({ musicInfo, listId, isTempPlay: false });
    this.state.setPlayInfo({ playIndex: index, playerListId: listId, playerPlayIndex: index });
    appEvent().emit(AppEvents.MUSIC_TOGGLED);
    return musicInfo;
  }

  /** 按歌曲 id 播放（按 playListById） */
  playListById(listId: string, id: string): MusicInfo | null {
    const list = this.state.getList(listId);
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return this.playList(listId, i);
      }
    }
    return null;
  }

  /** 稍后播放（按 addTempPlayList）：优先级最高，isTop 插队头 */
  addTempPlayList(musicInfo: MusicInfo, isTop: boolean = false): void {
    const item: TempPlayListItem = { listId: null, musicInfo, isTop };
    const arr = this.state.tempPlayList.slice();
    if (isTop) {
      arr.unshift(item);
    } else {
      arr.push(item);
    }
    this.state.setTempPlayList(arr);
    // 无当前曲时自动播下一首
    if (this.state.playMusicInfo === null) {
      this.getNextPlayMusicInfo(true);
    }
  }

  removeTempPlayList(index: number): void {
    const arr = this.state.tempPlayList.slice();
    if (index >= 0 && index < arr.length) {
      arr.splice(index, 1);
      this.state.setTempPlayList(arr);
    }
  }

  clearTempPlayList(): void {
    this.state.setTempPlayList([]);
  }

  /** 计算下一首（不落盘，供预加载与 UI 显示，按下一首计算逻辑） */
  getNextPlayMusicInfo(isAutoToggle: boolean = false): NextMusicResult {
    const empty: NextMusicResult = { musicInfo: null, listId: null, index: -1, isTempPlay: false };

    // 1) 稍后播放优先于一切
    if (this.state.tempPlayList.length > 0) {
      const item = this.state.tempPlayList[0];
      return { musicInfo: item.musicInfo, listId: item.listId, index: -1, isTempPlay: true };
    }

    const cur = this.state.playMusicInfo;
    if (cur === null) {
      return empty;
    }
    const listId = cur.listId;
    const list = this.state.getList(listId);
    if (list.length === 0) {
      return empty;
    }
    const curIndex = this.state.playInfo.playIndex;
    let mode = this.getMode();

    // 2) 手动切歌时 list / singleLoop 退化成列表循环（连续播放）；
    //    自动切歌则严格按当前模式走。`none` 已在 4 态改造中移除，不再有「播完即停」。
    if (!isAutoToggle && (mode === 'list' || mode === 'singleLoop')) {
      mode = 'listLoop';
    }

    if (mode === 'singleLoop' && isAutoToggle) {
      return { musicInfo: cur.musicInfo, listId, index: curIndex, isTempPlay: false };
    }

    if (mode === 'random') {
      const d = this.state.dislikeInfo;
      const rule: DislikeRule = {
        musicNames: d.musicNames,
        singerNames: d.singerNames,
        rules: d.rules,
      };
      const r = filterMusicList(list, this.state.playedList, curIndex, rule, true);
      if (r.filteredList.length === 0) {
        return empty;
      }
      const idx = Math.floor(Math.random() * r.filteredList.length);
      return { musicInfo: r.filteredList[idx], listId, index: list.indexOf(r.filteredList[idx]), isTempPlay: false };
    }

    // listLoop / list：顺序前进
    let next = curIndex + 1;
    if (next >= list.length) {
      if (mode === 'list' && isAutoToggle) {
        return empty; // 顺序播放到末尾停止
      }
      next = 0;
    }
    return { musicInfo: list[next], listId, index: next, isTempPlay: false };
  }

  /** 上一首（按 playPrev）：优先回溯 playedList */
  getPrevPlayMusicInfo(): NextMusicResult {
    const cur = this.state.playMusicInfo;
    if (cur === null) {
      return { musicInfo: null, listId: null, index: -1, isTempPlay: false };
    }
    const played = this.state.playedList;
    if (played.length > 0) {
      const last = played[played.length - 1];
      const list = this.state.getList(cur.listId);
      let idx = -1;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === last.id) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        this.state.setPlayedList(played.slice(0, played.length - 1));
        return { musicInfo: last, listId: cur.listId, index: idx, isTempPlay: false };
      }
    }
    const list = this.state.getList(cur.listId);
    if (list.length === 0) {
      return { musicInfo: null, listId: null, index: -1, isTempPlay: false };
    }
    let prev = this.state.playInfo.playIndex - 1;
    if (prev < 0) {
      prev = list.length - 1;
    }
    return { musicInfo: list[prev], listId: cur.listId, index: prev, isTempPlay: false };
  }

  /** 提交切歌结果（把计算出的下一首写入状态） */
  commitNext(result: NextMusicResult): MusicInfo | null {
    if (result.musicInfo === null) {
      return null;
    }
    if (result.isTempPlay) {
      const arr = this.state.tempPlayList.slice();
      if (arr.length > 0) {
        arr.splice(0, 1);
        this.state.setTempPlayList(arr);
      }
      this.state.setPlayMusicInfo({
        musicInfo: result.musicInfo, listId: result.listId, isTempPlay: true,
      });
    } else {
      // 随机模式把当前曲加入已播
      const cur = this.state.playMusicInfo;
      if (cur !== null && this.getMode() === 'random') {
        const played = this.state.playedList.slice();
        played.push(cur.musicInfo);
        this.state.setPlayedList(played);
      }
      this.state.setPlayMusicInfo({
        musicInfo: result.musicInfo, listId: result.listId, isTempPlay: false,
      });
      this.state.setPlayInfo({
        playIndex: result.index,
        playerListId: result.listId,
        playerPlayIndex: result.index,
      });
    }
    appEvent().emit(AppEvents.MUSIC_TOGGLED);
    return result.musicInfo;
  }

  /** 单曲循环：completed 事件时若 singleLoop 返回 true 表示重播当前曲 */
  shouldReplayCurrent(): boolean {
    return this.getMode() === 'singleLoop' && this.state.tempPlayList.length === 0;
  }

  /** 当前列表名 + 总数（锁屏第三页用，按锁屏列表构建逻辑） */
  getCurrentListSnapshot(): ListSnapshot {
    const cur = this.state.playMusicInfo;
    const listId = cur === null ? ListIds.DEFAULT : (cur.listId ?? ListIds.DEFAULT);
    const list = this.state.getList(listId);
    const songs: string[][] = [];
    // 按锁屏列表上限 = 2000
    const limit = Math.min(list.length, 2000);
    for (let i = 0; i < limit; i++) {
      songs.push([list[i].name, list[i].singer]);
    }
    let name = '我的歌单';
    for (const u of this.state.userLists) {
      if (u.id === listId) {
        name = u.name;
        break;
      }
    }
    if (listId === ListIds.LOVE) {
      name = '我的收藏';
    }
    const snapshot: ListSnapshot = {
      id: listId,
      name: name,
      index: this.state.playInfo.playIndex,
      songs: songs,
    };
    return snapshot;
  }
}

/** 当前播放列表快照（锁屏第三页 / 系统队列用） */
export interface ListSnapshot {
  id: string;
  name: string;
  index: number;
  songs: string[][];
}
