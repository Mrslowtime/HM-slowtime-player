/**
 * 全局状态仓库 —— 按本项目的模块划分*\/state.ts 的 13 个模块（合并为单例）。
 * 通过 EventBus 广播变更，UI 层订阅刷新。
 */
import {
  MusicInfo, PlayMusicInfo, PlayInfoState, TempPlayListItem,
  ProgressState, LyricInfo, UserListInfo, ListInfoItem, BoardItem,
  TagInfoItem, SortInfo, DislikeInfo,
} from '../model/MusicTypes';
import { OnlineSource, PlayMode, Quality } from '../config/AppConstants';
import { ThemeInfo, getTheme } from '../theme/Themes';
import { isSystemDarkMode } from '../common/SystemTheme';
import { stateEvent, StateEvents } from './EventBus';
import { SettingStore } from './SettingStore';

let sInstance: AppState | null = null;

/** 全局头部右侧操作项（由各模块激活时注册，Index 头部 ≡ 左侧渲染） */
export interface HeaderAction {
  /** 同模块内唯一键，用于 ForEach 复用 */
  key: string;
  text: string;
  fontSize: number;
  textColor: string;
  /** 有背景色时按 pill 样式渲染；省略则为透明文字按钮 */
  bg?: string;
  onClick: () => void;
}

export class AppState {
  /**
   * 应用是否在后台。自定义音源沙箱是隐藏 ArkWeb，切后台后渲染进程可能被冻结，
   * 此时探测/重建沙箱只会白等十几秒并把失败次数堆高（冷却越来越长），
   * 所以后台时不再重建、失败也不计入冷却。
   */
  appInBackground: boolean = false;

  // ---- player/state.ts ----
  playMusicInfo: PlayMusicInfo | null = null;
  playInfo: PlayInfoState = { playIndex: -1, playerListId: null, playerPlayIndex: -1 };
  isPlay: boolean = false;
  volume: number = 1;
  playRate: number = 1;
  statusText: string = '';
  /** 当前播放队列的来源歌单 key（`fav:<source>:<sourceListId>`）；非收藏歌单为空串 */
  playListKey: string = '';
  /**
   * playListKey 是否为调用方明确指定（歌单详情页播放 = true，包含明确指定为空）；
   * false 时表示来源由当前歌曲反查（播放列表 / 播放历史 / 我的收藏点歌），每次切歌重算。
   */
  playListKeyExplicit: boolean = false;
  /**
   * 当前播放队列是从哪个「我的列表」点进来的（列表 id，如自建列表的 id）。
   *
   * 与 playListKey 的区别：playListKey 描述「这首歌属于哪个收藏歌单」（用于黑胶图标），
   * 本字段描述「这次播放是从哪个列表页发起的」（用于「我的列表」标签行把正在播放的
   * 自建列表临时顶到 4 个固定列表后面）。从搜索结果 / 榜单 / 歌单详情等非列表页
   * 发起播放时为空串。
   */
  playSourceListId: string = '';
  playedList: MusicInfo[] = [];
  tempPlayList: TempPlayListItem[] = [];
  progress: ProgressState = {
    nowPlayTime: 0, maxPlayTime: 0, progress: 0,
    nowPlayTimeStr: '00:00', maxPlayTimeStr: '00:00',
  };
  lyricInfo: LyricInfo | null = null;
  lastLyric: string = '';
  /** 随机模式预选的下一首（按 randomNextMusicInfo） */
  randomNextMusicInfo: MusicInfo | null = null;

  // ---- list/state.ts ----
  allMusicList: Map<string, MusicInfo[]> = new Map();
  /**
   * 返回手势分发标记：页面 onBackPress 先清 false 再广播 UI_BACK，
   * 子组件关闭自己的弹窗/浮层后置 true，页面据此决定是否消费这次返回。
   */
  uiBackConsumed: boolean = false;
  userLists: UserListInfo[] = [];
  activeListId: string = 'default';
  /** 稍后播放时的回填列表 id */
  tempListMetaId: string = '';

  // ---- songlist / leaderboard / search ----
  songlistSources: OnlineSource[] = [];
  songlistTags: TagInfoItem[] = [];
  songlistSorts: SortInfo[] = [];
  songlistCards: ListInfoItem[] = [];
  boards: BoardItem[] = [];
  searchType: string = 'music';
  searchText: string = '';
  historyList: string[] = [];
  hotSearchList: string[] = [];
  tipList: string[] = [];

  // ---- dislike / theme / common ----
  dislikeInfo: DislikeInfo = { names: [], musicNames: [], singerNames: [], rules: [] };
  theme: ThemeInfo = getTheme('green');
  navActiveId: string = 'nav_love';

  /** 全局头部右侧操作区（由当前激活模块注册；非激活模块不触碰，由新激活模块整体覆盖） */
  private headerActions: HeaderAction[] = [];

  getHeaderActions(): HeaderAction[] {
    return this.headerActions;
  }

  setHeaderActions(list: HeaderAction[]): void {
    this.headerActions = list;
    stateEvent().emit(StateEvents.HEADER_ACTION_UPDATED);
  }


  static getInstance(): AppState {
    if (sInstance === null) {
      sInstance = new AppState();
    }
    return sInstance;
  }

  /** 从设置同步运行时值（按 initSetting 后的状态初始化） */
  applySettings(): void {
    const s = SettingStore.getInstance();
    this.volume = s.getNumber('player.volume', 1);
    this.playRate = s.getNumber('player.playbackRate', 1);
    this.theme = this.resolveActiveTheme();
  }

  /**
   * 解析当前生效主题：
   *  - common.isAutoTheme=true  → 跟随系统明暗，深色用 theme.darkId、浅色用 theme.lightId
   *  - common.isAutoTheme=false → 用用户手选的 theme.id
   */
  resolveActiveTheme(): ThemeInfo {
    const s = SettingStore.getInstance();
    if (s.getBoolean('common.isAutoTheme', false)) {
      const id: string = isSystemDarkMode()
        ? s.getString('theme.darkId', 'black')
        : s.getString('theme.lightId', 'green');
      return getTheme(id);
    }
    return getTheme(s.getString('theme.id', 'green'));
  }

  /** 主题相关设置变更（theme.id / lightId / darkId / isAutoTheme）后重新解析并广播 */
  refreshTheme(): void {
    this.theme = this.resolveActiveTheme();
    stateEvent().emit(StateEvents.THEME_UPDATED);
  }

  /** 当前播放列表（切歌的真相来源，按当前播放列表读取） */
  getList(listId: string | null): MusicInfo[] {
    if (listId === null) {
      return [];
    }
    const list = this.allMusicList.get(listId);
    return list === undefined ? [] : list;
  }

  setPlayMusicInfo(info: PlayMusicInfo | null): void {
    this.playMusicInfo = info;
    stateEvent().emit(StateEvents.PLAY_MUSIC_INFO_CHANGED);
  }

  setPlayInfo(info: PlayInfoState): void {
    this.playInfo = info;
    stateEvent().emit(StateEvents.PLAY_INFO_CHANGED);
  }

  setIsPlay(isPlay: boolean): void {
    this.isPlay = isPlay;
    stateEvent().emit(StateEvents.PLAY_STATE_CHANGED);
  }

  setProgress(nowPlayTime: number, maxPlayTime: number): void {
    const p = maxPlayTime > 0 ? nowPlayTime / maxPlayTime : 0;
    this.progress = {
      nowPlayTime: nowPlayTime,
      maxPlayTime: maxPlayTime,
      progress: p,
      nowPlayTimeStr: formatTime(nowPlayTime),
      maxPlayTimeStr: formatTime(maxPlayTime),
    };
    stateEvent().emit(StateEvents.PLAY_PROGRESS_CHANGED);
  }

  setPlayedList(list: MusicInfo[]): void {
    this.playedList = list;
    stateEvent().emit(StateEvents.PLAY_PLAYED_LIST_CHANGED);
  }

  /**
   * 当前播放队列的来源歌单 key（形如 `fav:<source>:<sourceListId>`，不是收藏歌单时为空串）。
   * 「我的歌单」用它判断哪张卡片正在播放，从而在收藏按钮旁显示转动的黑胶。
   * 只存在于内存，不持久化：重启后恢复播放也不会误亮。
   *
   * explicit=true 表示「调用方明确指定了来源」（歌单详情页播放，包含明确指定为空），
   * 切歌时原样保留；false 表示来源要按当前歌曲反查（从播放列表 / 播放历史 / 我的收藏点歌），
   * 每次切歌都会重新查一次，避免列表里放的是别的歌单的歌时唱片一直亮着上一个。
   */
  setPlayListKey(key: string, explicit: boolean = false): void {
    this.playListKey = key;
    this.playListKeyExplicit = explicit;
  }

  setTempPlayList(list: TempPlayListItem[]): void {
    this.tempPlayList = list;
    stateEvent().emit(StateEvents.PLAY_TEMP_PLAY_LIST_CHANGED);
  }

  setTheme(id: string): void {
    this.theme = getTheme(id);
    stateEvent().emit(StateEvents.THEME_UPDATED);
  }
}

/** 毫秒 → mm:ss（按秒数格式化约定2） */
export function formatTime(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) {
    return '00:00';
  }
  const total: number = Math.floor(ms / 1000);
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  return (m < 10 ? '0' : '') + m.toString() + ':' + (s < 10 ? '0' : '') + s.toString();
}
