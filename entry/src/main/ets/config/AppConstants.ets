// 由 tools/gen_assets.py 生成骨架，值按协议 本协议

/** 我的列表固定 id（与协议 LIST_IDS 一致） */
export class ListIds {
  static readonly PLAYLIST: string = 'playlist'    // 我的歌单（收藏的歌单，与「我的收藏」的歌曲收藏不同）
  static readonly LOVE: string = 'love'            // 我的收藏（收藏的歌曲）
  static readonly TEMP: string = 'temp'            // 播放列表（点歌时的临时队列，会持久化）
  static readonly DOWNLOAD: string = 'download'    // 下载列表
  static readonly PLAY_LATER: string = '__play_later__' // 稍后播放（安卓为 null）
  /**
   * 播放历史：固定列表，不可删除/重命名，内容由播放器自动维护
   * （最近播放的歌曲，按播放时间倒序，上限见 ListManager.PLAY_HISTORY_LIMIT）。
   */
  static readonly HISTORY: string = 'history'
  /** 旧版「试听列表」id：已从默认列表移除，仅用于兼容历史备份 */
  static readonly DEFAULT: string = 'default'
}

/**
 * 下载能力（DownloadManager / DownloadPage / 各处下载按钮 / 下载设置默认值 / i18n）
 * 完整编译进包；是否显示全部入口由运行时设置项 `download.enable` 决定，
 * 见下方 isDownloadEnabled() / applyDownloadFeature()。
 * 用户在「设置 → 下载设置」里打开并重启应用后所有下载入口恢复；
 * 关闭则隐藏导航页、下载管理页、歌曲行/播放页/三点菜单的下载按钮与下载设置项。
 * （原先还有一个编译期开关 DOWNLOAD_FEATURE_ENABLED 恒 true 且无人引用，已移除。）
 */

/** 运行时下载开关：启动时由设置项 download.enable 初始化，设置页切换后「重启生效」 */
let sDownloadEnabled: boolean = false

/** 当前是否显示下载入口（各处 if 判断统一走这里，保证与启动时的开关一致） */
export function isDownloadEnabled(): boolean {
  return sDownloadEnabled;
}

/**
 * 应用下载开关（在 EntryAbility 加载首页之前调用）。
 * 同时重建导航页数组：const 引用不变、内容原地替换，首页 ForEach 首帧就读到正确列表。
 */
export function applyDownloadFeature(enabled: boolean): void {
  sDownloadEnabled = enabled;
  ACTIVE_NAV_MENUS.splice(0, ACTIVE_NAV_MENUS.length);
  for (const m of NAV_MENUS) {
    if (m.id !== 'nav_download' || enabled) {
      ACTIVE_NAV_MENUS.push(m);
    }
  }
}

/**
 * 首页导航页（完整列表，顺序固定，与 Swiper 子页一一对应）。
 * 设置不在其中：它只在导航抽屉里有入口，点击后以全屏浮层打开，
 * 这样左右滑动到最后一页永远是「本地音乐」，不会多出一页设置。
 */
export interface NavMenu { id: string; icon: string }
export const NAV_MENUS: NavMenu[] = [
  { id: 'nav_love', icon: 'love' },
  { id: 'nav_songlist', icon: 'album' },
  { id: 'nav_top', icon: 'leaderboard' },
  { id: 'nav_search', icon: 'search' },
  { id: 'nav_local', icon: 'local' },
  { id: 'nav_download', icon: 'download' },
]

/** 当前实际启用的导航页：由 applyDownloadFeature() 在启动时按设置重建（默认含下载页） */
export const ACTIVE_NAV_MENUS: NavMenu[] = NAV_MENUS.slice()

/** 抽屉里的「设置」入口（不在 Swiper 序列内，点击打开全屏设置浮层） */
export const SETTING_MENU: NavMenu = { id: 'nav_setting', icon: 'setting' }

/**
 * 4 种播放模式，切换顺序固定。
 *
 * 曾有过第 5 态 `none`（播完即停），但系统播控卡片没有对应枚举
 * （loopMode 的 SEQUENCE 已用于「顺序播放」），两边永远对不齐，
 * 因此按用户要求移除，应用内与系统保持 4 态一一对应。
 */
export type PlayMode = 'listLoop' | 'random' | 'list' | 'singleLoop'
export const MUSIC_TOGGLE_MODE_LIST: PlayMode[] = [
  'listLoop', 'random', 'list', 'singleLoop',
]

/**
 * 把持久化的历史值收敛成合法 4 态。
 * 旧版本存过 `none`，直接丢弃会读到非法值，统一回落到列表循环。
 */
export function normalizePlayMode(raw: string): PlayMode {
  if (raw === 'singleLoop' || raw === 'random' || raw === 'list') {
    return raw;
  }
  return 'listLoop';
}

/** 音质（与协议 LX.Quality 一致） */
export type Quality = '128k' | '192k' | '320k' | 'flac' | 'flac24bit' | 'wav' | 'ape'
export const QUALITY_LIST: Quality[] = ['128k', '192k', '320k', 'flac', 'flac24bit', 'wav', 'ape']
/** 高音质降级尝试序列（与 core/music/utils.ts TRY_QUALITYS_LIST 一致） */
export const TRY_QUALITYS_LIST: Quality[] = ['flac24bit', 'flac', '320k', '128k']

/** 在线音源 */
export type OnlineSource = 'kw' | 'kg' | 'tx' | 'wy' | 'mg'
export const ONLINE_SOURCES: OnlineSource[] = ['kw', 'kg', 'tx', 'wy', 'mg']
export const SOURCE_NAMES: Record<string, string> = {
  'kw': '酷我音乐', 'kg': '酷狗音乐', 'tx': 'QQ音乐',
  'wy': '网易云音乐', 'mg': '咪咕音乐', 'local': '本地音乐', 'all': '全部',
}

/** 音源短名（common.sourceNameType = 'alias' 时列表标签使用，避免长名挤压歌手行） */
export const SOURCE_ALIAS: Record<string, string> = {
  'kw': '莴苣', 'kg': '旺旺', 'tx': 'Rico',
  'wy': '云朵', 'mg': '喵喵', 'local': '本地',
}

/** 按「歌曲来源显示」设置返回平台名：real=全名，其余=简称（找不到简称则回落全名） */
export function sourceDisplay(key: string, type: string): string {
  if (type === 'real') {
    return SOURCE_NAMES[key] ?? key;
  }
  return SOURCE_ALIAS[key] ?? SOURCE_NAMES[key] ?? key;
}

/** 持久化 key 前缀（按持久化约定） */
export class StorageKeys {
  static readonly SETTING: string = 'setting_v1'
  static readonly USER_LIST: string = 'user_list'
  static readonly LIST_PREFIX: string = 'list__'
  static readonly PLAY_INFO: string = 'play_info'
  static readonly LYRICS_PREFIX: string = 'lyric__'
  static readonly MUSIC_URL_PREFIX: string = 'music_url__'
  static readonly SEARCH_HISTORY: string = 'search_history_list'
  static readonly DISLIKE_LIST: string = 'dislike_list'
  static readonly THEME: string = 'theme'
  static readonly FONT_SIZE: string = 'font_size'
  static readonly LIST_ORDER: string = 'list_display_order'
  /** 收藏歌单（「我的歌单」分类）持久化键，独立 preferences：slowtime_playlist */
  static readonly PLAYLIST_FAV: string = 'favorite_playlists'
}

/** 布局尺寸（按） */
export const HEADER_HEIGHT: number = 42
export const LIST_ITEM_HEIGHT: number = 54
export const PLAYER_BAR_HEIGHT: number = 60
export const LIST_LOAD_LIMIT: number = 30
