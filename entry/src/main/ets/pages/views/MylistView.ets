/**
 * 我的列表页 —— 按列表页布局。
 * 列表抽屉 + 歌曲列表 + 搜索 + 新建/重命名/多选删除/拖拽排序。
 */
import { router } from '@kit.ArkUI';
import { MusicInfo, UserListInfo, FavoritePlaylistInfo, PlayMusicInfo } from '../../model/MusicTypes';
import { ThemeInfo, buildPalette, ThemePalette } from '../../theme/Themes';
import { AppState, HeaderAction } from '../../store/AppState';
import { ListManager } from '../../core/ListManager';
import { ListIds } from '../../config/AppConstants';
import { MusicListItem } from '../../components/MusicListItem';
import { SongMenuPanel } from '../../components/SongMenuPanel';
import { DownloadManager } from '../../core/DownloadManager';
import { I18n } from '../../core/I18n';
import { stateEvent, StateEvents, appEvent, AppEvents, listEvent, ListEvents, EmptyCallback } from '../../store/EventBus';
import { SettingStore } from '../../store/SettingStore';
import { PlaylistStore } from '../../store/PlaylistStore';
import { userNotice } from '../../core/UserNotice';
import { ListDrawerPanel } from '../../components/ListDrawerPanel';
import { LONG_PRESS_DURATION_MS } from '../../config/GestureConfig';
import { CoverImage } from '../../components/CoverImage';
import { CoverCache } from '../../core/ImageCache';
import { hdCoverUrl } from '../../common/CoverUrl';
import { LocateButton } from '../../components/LocateButton';
import { VinylDisc } from '../../components/VinylDisc';
import { estimateTextWidth } from '../../core/Popup';
import { columnCount, screenWidthVp, initScreenMetrics } from '../../config/ScreenMetrics';

/** 顶部标签栏最多常驻 4 个列表，其余收进「更多」抽屉 */
const VISIBLE_LIST_COUNT: number = 4;
/** 标签胶囊统一最小宽度：保证末尾「⋯」与前面 4 个胶囊尺寸完全一致 */
const CHIP_MIN_WIDTH: number = 76;

/** 「我的歌单」两列网格：列间距 / 卡片高度（与 PlaylistCard 内容高度一致） */
const PL_GAP: number = 6;
const PL_CARD_H: number = 202;
/** 横屏卡片最小高度：两行放进可视区；封面高度再按此压缩 */
const PL_LAND_CARD_MIN_H: number = 96;

/**
 * 拖动排序的「贴边自动滚动」触发带高度（vp）。
 * 判定基于「窗口坐标」里的滚动视口边缘：手指或被拖卡片进入上边缘上方 72vp
 * （含网格上方的「我的歌单 · N 个歌单」标题条，坐标即为负值）就持续向下滚、
 * 把上方歌单带进来；进入下边缘下方 72vp（含底部播控条）就持续向上滚。
 */
const PL_AUTOSCROLL_BAND: number = 72;
/** 自动滚动每帧步长区间（vp/帧，16ms 一帧）：越贴近边缘越快 */
const PL_AUTOSCROLL_STEP_MIN: number = 5;
const PL_AUTOSCROLL_STEP_MAX: number = 15;

@Component
export struct MylistView {
  @State @Watch('syncHeader') private activeListId: string = ListIds.PLAYLIST;
  @State private songs: MusicInfo[] = [];
  /** 「我的歌单」分类：收藏的歌单（与「我的收藏」的歌曲收藏无关） */
  @State private playlists: FavoritePlaylistInfo[] = [];
  @State private userLists: UserListInfo[] = [];
  /**
   * 搜索词放到 AppStorage：横屏时搜索框渲染在首页标题行（Index），竖屏时仍在本模块内容区，
   * 两处用同一份状态双向绑定，切换方向不会丢关键词。
   */
  @StorageLink('mylist.keyword') @Watch('onKeywordChanged') private keyword: string = '';
  @StorageLink('mylist.keywordPlaceholder') private keywordPlaceholder: string = '搜索歌单';
  @State private showNewList: boolean = false;
  @State private newListName: string = '';
  /**
   * 「我的歌单」中已点取消收藏、但尚未真正落盘的歌单 key（source:sourceListId）。
   * 卡片先留在列表、心形变空心，允许反悔再点收藏；
   * 只有滑动离开「我的列表」模块时才提交删除。
   */
  @State private pendingOff: string[] = [];
  /** 全部列表抽屉（列表超过 4 个时由「更多」按钮打开） */
  @State private showListDrawer: boolean = false;
  /** 横屏：标签移到左侧竖排、⋯ 固定最下方，右侧视窗 4 列 × 2 行显示 8 张歌单卡片 */
  @StorageProp('screenLandscape') private isLandscape: boolean = false;
  /** 由主行 chip 长按打开抽屉时，直接高亮的列表 id */
  @State private drawerInitialSelectId: string = '';
  /** 待确认删除的自建列表 id */
  @State private pendingDelete: string[] = [];
  /** 编辑模式：多选 + 拖拽排序 */
  @State @Watch('syncHeader') private editMode: boolean = false;
  @State private selected: string[] = [];
  /** 批量操作菜单（多选后点「更多」打开，菜单项作用于全部选中歌曲） */
  @State private batchMenu: boolean = false;
  @State private langTick: number = 0;
  /** 列表展示开关（来自设置 list.isShow*，设置变更后实时刷新） */
  @State private showSource: boolean = true;
  @State private showAlbumName: boolean = false;
  @State private showInterval: boolean = true;
  /** 点按播放：true=点击列表项即播放该曲；false=仅选中高亮不切换播放 */
  @State private clickPlay: boolean = true;
  /** 当前打开的歌曲菜单下标，-1 = 关闭 */
  @State private menuIndex: number = -1;
  @State private tapIndex: number = -1;
  /** 真正在播放的歌曲 id：由切歌事件驱动，保证高亮与播放图标跟着音乐走 */
  @State private currentId: string = '';
  /** 播放器是否在播（暂停不亮黑胶） */
  @State private isPlaying: boolean = false;
  /** 当前播放队列的来源歌单 key（`fav:<source>:<listId>`，不在收藏歌单里播时为空串） */
  @State private playListKey: string = '';
  /** 本次播放是从哪个「我的列表」点进来的（空串=搜索/榜单/歌单详情等入口） */
  @State private playSourceListId: string = '';
  /**
   * 正在被临时置顶的收藏歌单 key（`source:sourceListId`），空串=没有置顶。
   * 「我的歌单」里它被画在第一格，停下/切走时滑回原位（translate 的动画）。
   */
  @State private pinnedFavKey: string = '';
  /** 置顶项在存储顺序里的原下标：拖动落盘时用它把卡片插回原处，保住用户排序 */
  private pinnedOriginIndex: number = -1;
  /** 标签胶囊实测宽度（id → vp）：置顶位移按真实宽度算，长列表名也不会算错 */
  private chipWidths: Map<string, number> = new Map();
  /** 标签宽度的刷新计数：onAreaChange 量到新宽度后自增，触发重新排版 */
  @State private chipTick: number = 0;
  /** 标签行横向滚动控制器（置顶出现时把行滚回最左，保证置顶项可见） */
  private tabScroller: Scroller = new Scroller();
  /** 横屏竖排标签栏滚动控制器（置顶出现时滚回顶部） */
  private railScroller: Scroller = new Scroller();
  /** 来源名展示：alias=短名（酷我）/ real=全名（酷我音乐） */
  @State private sourceNameType: string = 'alias';
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 父组件 PlayController.init() 完成后置 true，触发本视图重新读取数据 */
  @Prop @Watch('onReadyChange') ready: boolean = false;
  /** 当前是否为激活标签：激活时把本页操作注册到全局头部（≡ 左侧） */
  @Prop @Watch('onActiveChanged') active: boolean = false;
  onPlayMusic: (listId: string, index: number) => void = () => {};

  private state: AppState = AppState.getInstance();
  private listManager: ListManager = ListManager.getInstance();
  private dragIndex: number = -1;
  /** 「我的歌单」Gird 容器宽度（vp）：由 onAreaChange 量出，用于计算两列坐标 */
  @State private gridW: number = 0;
  /**
   * 「我的歌单」拖动状态（不用系统拖拽，避免与「中转站 / 拖给小艺」抢占手势）：
   * dragKey=正在拖的卡片 key，dragDX/DY=手指累计位移，
   * dragOriginX/Y=开始拖动时的槽位坐标（冻结，保证实时重排时卡片不跳）。
   */
  @State private dragKey: string = '';
  @State private dragDX: number = 0;
  @State private dragDY: number = 0;
  @State private dragOriginX: number = 0;
  @State private dragOriginY: number = 0;
  /** 拖动刚结束的时间戳：用来吞掉紧随其后的点击（避免松手就进歌单详情） */
  private dragEndTs: number = 0;
  /** 「我的歌单」网格滚动控制器（手动驱动边缘自动滚动） */
  private plScroller: Scroller = new Scroller();
  /** 当前滚动偏移（vp）与可视高度（vp） */
  @State private scrollY: number = 0;
  @State private viewportH: number = 0;
  /** 拖动开始时的滚动偏移：用来把被拖卡片固定在手指下，滚动时做补偿 */
  private scrollY0: number = 0;
  /** 拖动到边缘时自动滚动的定时器句柄（-1 表示未启用） */
  private autoTimer: number = -1;
  /** 滚动容器顶部在「窗口坐标」中的 y（vp，含状态栏区域）：由 Scroll.onAreaChange 的 globalPosition 写入，与手指 windowY 同一坐标系 */
  @State private scrollContainerGlobalY: number = 0;
  /**
   * 拖动中手指在「窗口坐标」中的 y（vp，含状态栏）：由 onTouch 的 windowY（px）换算而来。
   * -1 表示当前未取到手指位置（此时自动滚动回退到「被拖卡片中心」）。
   * 注意：不要用 GestureEvent.fingerList[i].globalY —— 该值本身就是 vp，再做 px2vp 会把手指坐标缩小约 2.75 倍，
   * 导致算出的视口坐标恒为负、自动滚动只会朝上且到顶后永久失效（这正是此前「贴边不滚」的真因）。
   */
  private dragTouchVpY: number = -1;
  private settings: SettingStore = SettingStore.getInstance();
  private listListenerBound: boolean = false;
  /** AppState.playMusicInfo 是普通字段，不订阅事件列表不会重渲染，切歌后高亮就会停在旧歌 */
  private onPlayMusicChanged = (): void => {
    const cur = this.state.playMusicInfo;
    this.currentId = cur === null ? '' : cur.musicInfo.id;
    this.tapIndex = -1;
    this.syncPlaybackHint();
  };
  /** 播放/暂停切换：黑胶只在「正在播」时出现 */
  private onPlayStateChanged = (): void => {
    this.syncPlaybackHint();
  };

  private syncPlaybackHint(): void {
    const prevKey: string = this.playListKey;
    const prevSrc: string = this.playSourceListId;
    this.isPlaying = this.state.isPlay;
    this.playListKey = this.state.playListKey;
    this.playSourceListId = this.state.playSourceListId;
    // 播放来源换到别的收藏歌单（或切走）：置顶项换成新的，旧的那张滑回原位
    if (prevKey !== this.playListKey) {
      this.rebuildPlaylists();
    }
    // 标签行刚出现「正在播放的自建列表」：滚回最左，让「4 个固定 + 置顶项」都在视野里
    if (prevSrc !== this.playSourceListId && this.pinnedTabIndex() >= 0) {
      setTimeout((): void => { this.scrollTabsToStart(); }, 30);
    }
  }
  /** 列表内容变更（播放新歌单、收藏/取消收藏歌单）后立即重读，切到分类即可看到新数据 */
  private onListMusicUpdate = (): void => { this.refresh(); };
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => { this.langTick = this.langTick + 1; };
  /** 列表展示设置变更后刷新来源/专辑/间隔/点按播放等开关 */
  private onConfigUpdated: EmptyCallback = (): void => { this.reloadListDisplay(); };
  /**
   * 列表本身变化（新建 / 删除 / 重命名 / 备份恢复）也要刷顶部标签：
   * 歌曲菜单里「新增列表」建完就该在这里出现，不用手动切一次分类。
   */
  private onListsChanged = (): void => {
    this.refresh();
    this.syncHeader();
  };
  /** 系统返回手势：先关批量菜单 / 单曲菜单 / 新建列表弹窗 / 退出编辑态，再让页面处理 */
  private onUiBack = (): void => {
    // 7 个模块常驻同一个 Swiper，非激活模块不能抢这次返回
    if (!this.active) {
      return;
    }
    if (this.pendingDelete.length > 0) {
      this.pendingDelete = [];
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    // 抽屉打开时由 ListDrawerPanel 自己分层消费（先退管理态，再关抽屉）
    if (this.showListDrawer) {
      return;
    }
    if (this.batchMenu) {
      this.batchMenu = false;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.menuIndex >= 0) {
      this.menuIndex = -1;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.showNewList) {
      this.showNewList = false;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.editMode) {
      this.editMode = false;
      this.selected = [];
      AppState.getInstance().uiBackConsumed = true;
    }
  };
  /** 歌曲列表滚动控制器 + 各歌单记忆的滚动位置（受 list.isSaveScrollLocation 控制） */
  private listScroller: Scroller = new Scroller();
  private scrollOffsets: Map<string, number> = new Map();

  aboutToAppear(): void {
    // 先按「上次播放歌曲所在的列表」定位分类，再 refresh，避免先渲染成「我的歌单」再跳
    this.restoreActiveList();
    this.refresh();
    this.currentId = this.state.playMusicInfo === null ? '' : this.state.playMusicInfo.musicInfo.id;
    stateEvent().on(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
    stateEvent().on(StateEvents.PLAY_STATE_CHANGED, this.onPlayStateChanged);
    this.syncPlaybackHint();
    appEvent().on(AppEvents.MY_LIST_MUSIC_UPDATE, this.onListMusicUpdate);
    listEvent().on(ListEvents.LIST_CREATE, this.onListsChanged);
    listEvent().on(ListEvents.LIST_REMOVE, this.onListsChanged);
    listEvent().on(ListEvents.LIST_UPDATE, this.onListsChanged);
    listEvent().on(ListEvents.LIST_DATA_OVERWRITE, this.onListsChanged);
    stateEvent().on(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    this.reloadListDisplay();
    if (!this.listListenerBound) {
      this.listListenerBound = true;
      stateEvent().on(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    }
    this.syncHeader();
  }

  /**
   * 退出应用重进后，把「当前分类」恢复成上次播放歌曲所在的列表。
   * AppState.activeListId 由 PlayController 恢复播放信息时写入；
   * 列表可能已被删除，所以只接受仍然存在的 id。
   */
  private restoreActiveList(): void {
    const want: string = this.state.activeListId;
    if (want.length === 0) {
      return;
    }
    for (const u of this.state.userLists) {
      if (u.id === want) {
        this.activeListId = want;
        return;
      }
    }
  }

  aboutToDisappear(): void {
    // 组件真正销毁前兜底提交：避免「取消收藏」的临时态丢失后歌单又回来
    this.commitPendingOff();
    this.stopAutoScroll();
    appEvent().off(AppEvents.MY_LIST_MUSIC_UPDATE, this.onListMusicUpdate);
    listEvent().off(ListEvents.LIST_CREATE, this.onListsChanged);
    listEvent().off(ListEvents.LIST_REMOVE, this.onListsChanged);
    listEvent().off(ListEvents.LIST_UPDATE, this.onListsChanged);
    listEvent().off(ListEvents.LIST_DATA_OVERWRITE, this.onListsChanged);
    stateEvent().off(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().off(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
    stateEvent().off(StateEvents.PLAY_STATE_CHANGED, this.onPlayStateChanged);
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    stateEvent().off(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
  }

  /** 顺序被锁定的列表（播放历史按播放时间倒序，不允许拖动改顺序） */
  private orderLocked(): boolean {
    return this.activeListId === ListIds.HISTORY;
  }

  /** 当前是否在「我的歌单」分类 */
  private isPlaylistMode(): boolean {
    return this.activeListId === ListIds.PLAYLIST;
  }

  /**
   * 顶部标签栏：全部列表都放进横向滚动区（能滑到后面任意一个），
   * 只有当前屏放得下时它就用不上滚动；「⋯」固定右侧作为抽屉入口。
   */
  private visibleLists(): UserListInfo[] {
    return this.userLists;
  }

  private currentListName(): string {
    for (const u of this.userLists) {
      if (u.id === this.activeListId) {
        return u.name;
      }
    }
    return '';
  }

  /**
   * 「⋯」溢出按钮是否高亮：只有当当前列表本身被折叠进抽屉时，
   * 这个按钮才代表「当前所在」，才用主题色；否则保持普通胶囊色。
   */
  private isMoreActive(): boolean {
    for (let i = VISIBLE_LIST_COUNT; i < this.userLists.length; i++) {
      if (this.userLists[i].id === this.activeListId) {
        return true;
      }
    }
    return false;
  }

  private openListDrawer(initialId: string): void {
    this.drawerInitialSelectId = initialId;
    this.showListDrawer = true;
  }

  private closeListDrawer(): void {
    this.showListDrawer = false;
    this.drawerInitialSelectId = '';
  }

  private applyListOrder(ids: string[]): void {
    this.listManager.reorderLists(ids);
    this.refresh();
  }

  private doDeleteLists(): void {
    const ids: string[] = this.pendingDelete.slice();
    this.pendingDelete = [];
    if (ids.length === 0) {
      return;
    }
    for (const id of ids) {
      this.listManager.removeUserList(id);
    }
    if (ids.indexOf(this.activeListId) >= 0) {
      this.activeListId = ListIds.PLAYLIST;
      this.state.activeListId = ListIds.PLAYLIST;
      this.keyword = '';
    }
    this.refresh();
    userNotice().info('已删除 ' + ids.length.toString() + ' 个列表');
  }

  /** 从设置读取列表展示开关（来源/专辑/间隔）与点按播放 */
  private reloadListDisplay(): void {
    this.showSource = this.settings.getBoolean('list.isShowSource', true);
    this.showAlbumName = this.settings.getBoolean('list.isShowAlbumName', false);
    this.showInterval = this.settings.getBoolean('list.isShowInterval', true);
    this.clickPlay = this.settings.getBoolean('list.isClickPlayList', true);
    this.sourceNameType = this.settings.getString('common.sourceNameType', 'alias');
  }

  /** init 完成后父组件把 ready 置 true，此处补一次刷新（按 initWatchList） */
  onReadyChange(): void {
    if (this.ready) {
      // 播放信息恢复完成后（PlayController.init 末尾）再定位一次：
      // 组件可能先于 init 建好，此时 state.activeListId 还没写入
      this.restoreActiveList();
      this.refresh();
    }
  }

  /**
   * 顶层模块切换（Swiper 滑走 / 滑回）。
   * 滑走：把本页点了「取消收藏」的歌单真正提交删除，回来就看不到；
   * 滑回：重新按存储刷新，确保被删的歌单不再出现。
   */
  private onActiveChanged(): void {
    if (this.active) {
      this.refresh();
      this.syncHeader();
    } else {
      this.commitPendingOff();
      // 切走时关掉本页所有浮窗/确认框，避免浮窗留在别的模块上
      this.menuIndex = -1;
      this.batchMenu = false;
      this.showNewList = false;
      this.showListDrawer = false;
      this.pendingDelete = [];
      this.selected = [];
    }
  }

  /**
   * 把本页的头部操作（编辑 / 新建）注册到全局头部 ≡ 左侧。
   * 仅在激活标签时执行；非激活时由新激活的标签整体覆盖，这里不清理。
   * 歌单分类下不显示这些操作（与原内部头部一致）。
   */
  private syncHeader(): void {
    if (!this.active) {
      return;
    }
    const st = AppState.getInstance();
    const acts: HeaderAction[] = [];
    if (!this.isPlaylistMode()) {
      acts.push({
        key: 'edit',
        text: this.editMode ? this.tx('edit_done') : this.tx('edit_mode'),
        fontSize: 13,
        textColor: this.theme.primary,
        onClick: (): void => { this.toggleEditMode(); },
      });
      if (!this.editMode) {
        acts.push({
          key: 'new',
          text: '＋ ' + this.tx('new_list'),
          fontSize: 13,
          textColor: this.theme.primary,
          onClick: (): void => { this.showNewList = true; },
        });
      }
    }
    st.setHeaderActions(acts);
  }

  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  /**
   * 顶部标签栏的统一胶囊（含末尾「⋯」）。
   * 全部走同一个 Builder：字号、高度、最小宽度、圆角一致，
   * 避免「⋯」被渲染成一个比其它胶囊更大/更圆的独立按钮。
   */
  /**
   * 胶囊是否选中。必须在这里（Builder 的属性表达式中）读取 activeListId：
   * @Builder 的参数是「按值传递」的，若由调用方算好 boolean 传进来，
   * 状态变化不会触发刷新（ForEach 复用 key 时尤其明显，高亮会一直停在第一项）。
   */
  private chipOn(id: string, more: boolean): boolean {
    return more ? this.isMoreActive() : this.activeListId === id;
  }

  @Builder
  private TabChip(label: string, id: string, more: boolean, onTap: () => void, onLong: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(this.chipOn(id, more) ? '#FFFFFF' : this.pal().pillText)
      .backgroundColor(this.chipOn(id, more) ? this.theme.primary : this.pal().pillBg)
      .borderRadius(14)
      .constraintSize({ minWidth: more ? 26 : CHIP_MIN_WIDTH })
      .height(28)
      .textAlign(TextAlign.Center)
      .padding({ left: more ? 8 : 12, right: more ? 8 : 12 })
      .margin({ right: 8 })
      // 临时置顶：只挪视觉位置、不改布局顺序，所以切走时能原路滑回去
      .translate({ x: more ? 0 : this.chipShift(id) })
      .animation({ duration: 260, curve: Curve.Friction })
      // 记录真实宽度：置顶位移按实测宽度累加，长列表名也不会算偏
      .onAreaChange((_old: Area, area: Area): void => {
        this.captureChipWidth(id, Number(area.width));
      })
      .onClick((): void => { onTap(); })
      .gesture(LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS }).onAction((): void => {
        onLong();
      }))
  }

  /** 预取歌单封面（与歌单广场共用 CoverCache，进过广场的基本已命中） */
  private prefetchPlaylistCovers(): void {
    const n: number = this.playlists.length > 20 ? 20 : this.playlists.length;
    if (n === 0) {
      return;
    }
    const urls: string[] = [];
    for (let i = 0; i < n; i++) {
      // 与卡片同一个高清地址：预取和上屏命中的是同一份缓存
      urls.push(hdCoverUrl(this.playlists[i].img));
    }
    CoverCache.getInstance().prefetch(urls);
  }

  /** 搜索词变化（含首页标题行清除按钮）时重新过滤列表 */
  private onKeywordChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    this.userLists = this.state.userLists.slice();
    // 搜索框横屏在首页标题行渲染，占位提示经 AppStorage 同步过去
    this.keywordPlaceholder = this.isPlaylistMode() ? '搜索歌单' : this.tx('search_in_list');
    if (this.isPlaylistMode()) {
      // 「我的歌单」不存歌曲，数据来自 PlaylistStore（已收藏的歌单）
      // 顺序 = 存储顺序 + 正在播放的那张临时置顶（见 rebuildPlaylists）
      this.rebuildPlaylists();
      this.songs = [];
      this.selected = [];
      this.prefetchPlaylistCovers();
      return;
    }
    this.playlists = [];
    const all = this.state.getList(this.activeListId);
    if (this.keyword.length === 0) {
      this.songs = all.slice();
    } else {
      const k = this.keyword;
      this.songs = all.filter((m: MusicInfo): boolean => m.name.includes(k) || m.singer.includes(k));
    }
    // 剔除已不存在的选中项
    if (this.selected.length > 0) {
      const ids = new Set<string>(this.songs.map((m: MusicInfo): string => m.id));
      this.selected = this.selected.filter((id: string): boolean => ids.has(id));
    }
  }

  /** 头部「＋ 新建」：建完直接切到新列表；名字留空时用默认名，避免点了没反应 */
  private createNewList(): void {
    const typed: string = this.newListName.trim();
    const name: string = typed.length > 0 ? typed : '新建列表';
    const u: UserListInfo = this.listManager.createUserList(name);
    this.newListName = '';
    this.showNewList = false;
    this.switchList(u.id);
  }

  private switchList(id: string): void {
    const saveScroll: boolean = this.settings.getBoolean('list.isSaveScrollLocation', true);
    // 「我的歌单」分类下没有 List 组件，Scroller 未绑定任何组件，
    // 直接读 currentOffset() 会抛异常，导致整个 switchList 中断
    //（表现就是：点分类没任何反应）。
    if (saveScroll && !this.isPlaylistMode()) {
      try {
        this.scrollOffsets.set(this.activeListId, this.listScroller.currentOffset().yOffset);
      } catch (e) {
        this.scrollOffsets.set(this.activeListId, 0);
      }
    }
    this.activeListId = id;
    this.state.activeListId = id;
    this.keyword = '';
    this.selected = [];
    this.tapIndex = -1;
    this.editMode = false;
    this.refresh();
    const target: number = saveScroll ? (this.scrollOffsets.get(id) ?? 0) : 0;
    // 等列表按新数据完成一帧布局后再定位
    setTimeout((): void => {
      try {
        this.listScroller.scrollTo({ xOffset: 0, yOffset: target });
      } catch (e) {
        // 歌单分类没有列表，忽略
      }
    }, 0);
  }

  /** 该列表是否还存在于「我的列表」里（自建列表可能已被删除） */
  private listExists(id: string): boolean {
    for (const u of this.userLists) {
      if (u.id === id) {
        return true;
      }
    }
    return false;
  }

  /** 浮动定位按钮是否显示：只有歌曲列表分类才有行可跳，「我的歌单」与多选态不显示 */
  private canLocate(): boolean {
    return !this.isPlaylistMode() && !this.editMode && this.songs.length > 0 && this.currentId.length > 0;
  }

  /**
   * 定位到正在播放的歌曲：
   * ① 当前分类不是这首歌所在的列表 → 先切过去（用户自建列表可能已删，先校验）；
   * ② 搜索关键字把它过滤掉了 → 先清空关键字；
   * ③ 在列表里滚动到该行并居中显示。
   */
  private locatePlaying(): void {
    const cur: PlayMusicInfo | null = this.state.playMusicInfo;
    if (cur === null) {
      userNotice().info('还没有正在播放的歌曲');
      return;
    }
    const id: string = cur.musicInfo.id;
    const listId: string = cur.listId === null ? '' : cur.listId;
    if (listId.length > 0 && listId !== this.activeListId && this.listExists(listId)) {
      this.switchList(listId);
      setTimeout((): void => { this.scrollToSong(id, 2); }, 90);
      return;
    }
    if (this.keyword.length > 0) {
      this.keyword = '';
      this.refresh();
      setTimeout((): void => { this.scrollToSong(id, 2); }, 90);
      return;
    }
    this.scrollToSong(id, 0);
  }

  /** 按歌曲 id 找行并居中；列表刚切换时布局还没完成，留几次重试 */
  private scrollToSong(id: string, retry: number): void {
    let idx: number = -1;
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      if (retry > 0) {
        setTimeout((): void => { this.scrollToSong(id, retry - 1); }, 120);
        return;
      }
      userNotice().info('正在播放的歌曲不在当前列表');
      return;
    }
    try {
      this.listScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    } catch (e) {
      // 列表尚未挂载（例如分类刚切换）：忽略，再点一次即可
    }
  }

  /** 竖屏顶部横排标签栏：保持原样，胶囊/⋯ 与横屏竖排共用同一套高亮逻辑 */
  @Builder
  private PortraitTabRow() {
    // 列表 tab：只常驻前 4 个；超过 4 个时在末尾放「⋯」入口打开全部列表抽屉。
    // 5 个胶囊共用同一个 Builder，字号/高度/最小宽度/圆角完全一致（不再出现圆点按钮）。
    // 「⋯」固定在右侧、不随标签横向滚动：标签变多时它不会跟着滑走，随时能点开全部列表。
    Row() {
      Scroll(this.tabScroller) {
        Row() {
          ForEach(this.visibleLists(), (u: UserListInfo): void => {
            this.TabChip(u.name, u.id, false,
              (): void => { this.switchList(u.id); },
              (): void => { this.openListDrawer(u.id); });
          }, (u: UserListInfo): string => u.id)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .height(40)
      .padding({ left: 16 })

      if (this.userLists.length > VISIBLE_LIST_COUNT) {
        Row() {
          this.TabChip('⋯', '', true,
            (): void => { this.openListDrawer(''); },
            (): void => { this.openListDrawer(''); });
        }
        .height(40)
        .padding({ left: 2 })
      }
    }
    .width('100%')
    .height(40)

  }

  /** 搜索框 + 工具栏/统计 + 歌单网格/歌曲列表：横竖屏共用的主体内容 */
  @Builder
  private ContentArea() {
    // 横屏搜索框移到首页标题行（Index.ets），本模块只保留竖屏的搜索框
    if (!this.editMode && !this.isLandscape) {
      Stack({ alignContent: Alignment.End }) {
        TextInput({ placeholder: this.isPlaylistMode() ? '搜索歌单' : this.tx('search_in_list'), text: this.keyword })
          .height(36)
          .fontSize(13)
          .backgroundColor(this.pal().card)
          .fontColor(this.theme.font)
          .placeholderColor(this.pal().subText)
          .borderRadius(8)
          .margin({ left: 16, right: 16, top: 4, bottom: 4 })
          .padding({ right: 38 })
          .onChange((v: string): void => {
            this.keyword = v;
            this.refresh();
          })
        if (this.keyword.length > 0) {
          Image($r('app.media.ic_close_thin'))
            .width(16).height(16).fillColor(this.pal().subText)
            .margin({ right: 26 })
            .onClick((): void => {
              this.keyword = '';
              this.refresh();
            })
        }
      }
      .width('100%')
    }

    // 工具栏 / 统计行
    if (this.editMode) {
      Row() {
        Text(this.tx('sel_prefix') + ' ' + this.selected.length.toString() + ' ' + this.tx('unit_song'))
          .fontSize(12)
          .fontColor(this.theme.primary)
        Blank()
        Text(this.tx('select_all'))
          .fontSize(12)
          .fontColor(this.pal().subText)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick((): void => { this.toggleSelectAll(); })
        Text('更多')
          .fontSize(12)
          .fontColor(this.selected.length > 0 ? this.theme.primary : this.pal().subText)
          .border({ width: 1, color: this.selected.length > 0 ? this.theme.primary : this.pal().pillBg })
          .borderRadius(12)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .onClick((): void => { this.openBatchMenu(); })
        Text(this.tx('delete_selected'))
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor(this.selected.length > 0 ? '#C0553F' : this.pal().pillBg)
          .borderRadius(12)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .margin({ left: 8 })
          .onClick((): void => { this.deleteSelected(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 6 })
    } else {
      Row() {
        // 列表名称用主题色，歌曲数量保持次级文字色
        Text(this.currentListName())
          .fontSize(12)
          .fontColor(this.theme.primary)
        Text(this.isPlaylistMode()
          ? ' · ' + this.playlists.length.toString() + ' 个歌单'
          : ' · ' + this.songs.length.toString() + ' ' + this.tx('unit_song'))
          .fontSize(12)
          .fontColor(this.pal().subText)
        Blank()
        Text(this.isPlaylistMode() ? '点击歌单查看详情' : this.tx('tap_to_play'))
          .fontSize(11)
          .fontColor(this.pal().subText)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
    }

    if (this.isPlaylistMode()) {
      // 「我的歌单」：两列封面网格；长按卡片抬起后跟手拖动，其它卡片自动让位。
      // 这里刻意不用系统拖拽（onItemDragStart/onItemDrop）——那套是全局统一拖拽，
      // 长按会被「中转站 / 拖给小艺」一起接管；改成自己的 长按→平移 手势，
      // 配合 translate + animation 做「桌面整理图标」那种滑动让位动画。
      if (this.playlists.length === 0) {
        Column() {
          Image($r('app.media.ic_playlist')).width(46).height(46).fillColor(this.pal().subText)
          Text('还没有收藏的歌单').fontSize(13).fontColor(this.pal().subText).margin({ top: 12 })
          Text('在「歌单」页点 ♡ 收藏，就会出现在这里')
            .fontSize(11).fontColor(this.pal().subText).margin({ top: 4 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Scroll(this.plScroller) {
          Stack({ alignContent: Alignment.TopStart }) {
            ForEach(this.playlists, (p: FavoritePlaylistInfo): void => {
              this.PlaylistGridCell(p)
            }, (p: FavoritePlaylistInfo): string => p.source + ':' + p.sourceListId)
          }
          .width('100%')
          .height(this.gridHeight())
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            const w: number = Number(newArea.width);
            // 只有取到有效宽度且确实变了才写，避免布局回调里反复触发状态更新
            if (!Number.isNaN(w) && w > 0 && Math.abs(w - this.gridW) > 0.5) {
              this.gridW = w;
            }
          })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        // 回调里的 yOffset 语义随 API 版本变化（增量 / 状态值都可能），不采信它，统一读 currentOffset() 取绝对值
        .onScroll((_x: number, _y: number): void => { this.syncScrollY(); })
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          const h: number = Number(newArea.height);
          if (!Number.isNaN(h) && h > 0 && Math.abs(h - this.viewportH) > 0.5) {
            this.viewportH = h;
          }
          // 容器顶部在窗口坐标中的位置（含状态栏），与手指 globalY 同一坐标系，便于相减得到视口内坐标
          const gy: number = Number(newArea.globalPosition.y);
          if (!Number.isNaN(gy)) {
            this.scrollContainerGlobalY = gy;
          }
        })
        // 拖动期间禁止滚动，避免平移手势与滚动打架（自动滚动由我们手动驱动）
        .enableScrollInteraction(this.dragKey.length === 0)
      }
    } else {
    List({ scroller: this.listScroller }) {
      ForEach(this.songs, (m: MusicInfo, idx: number): void => {
        ListItem() {
          Row() {
            MusicListItem({
              music: m,
              index: idx,
              isActive: (this.currentId.length > 0 && this.currentId === m.id) || this.tapIndex === idx,
              theme: this.theme,
              showSource: this.showSource,
              showAlbumName: this.showAlbumName,
              showInterval: this.showInterval,
              sourceNameType: this.sourceNameType,
              selecting: this.editMode,
              checked: this.isSelected(m.id),
              onItemClick: (i: number): void => {
                // 单击：多选模式下切换选中；普通状态下不播放（播放改为双击），也不弹任何提示
                if (this.editMode) {
                  this.toggleSelect(this.songs[i].id);
                }
              },
              onItemDoubleClick: (i: number): void => {
                if (this.editMode) {
                  // 双击的第一下已经切换过选中，这里不再重复切换
                  return;
                }
                if (this.clickPlay) {
                  this.tapIndex = -1;
                  this.onPlayMusic(this.activeListId, i);
                } else {
                  this.tapIndex = i;
                }
              },
              onItemLongPress: (i: number): void => {
                // 长按：进入多选并选中该行（先取 id 再切模式，避免 refresh 后下标错位）
                const id: string = this.songs[i].id;
                if (!this.editMode) {
                  this.toggleEditMode();
                }
                if (!this.isSelected(id)) {
                  this.selected = this.selected.concat([id]);
                }
              },
              onMoreClick: (i: number): void => { this.showItemMenu(i); },
            })
              .layoutWeight(1)
            if (this.editMode && !this.orderLocked()) {
              Row() {
                Image($r('app.media.ic_menu')).width(18).height(18).fillColor(this.pal().subText)
              }
              .width(34)
              .justifyContent(FlexAlign.Center)
            }
          }
          .width('100%')
        }
      }, (m: MusicInfo): string => m.id + '_' + this.sourceNameType)
    }
    .layoutWeight(1)
    .width('100%')
    .divider({ strokeWidth: 0.5, color: this.pal().divider })
    // 拖拽排序（编辑模式下长按拖动）
    .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
      this.dragIndex = itemIndex;
      return this.DragPreview(itemIndex);
    })
    .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean): void => {
      if (!this.editMode || !isSuccess || insertIndex < 0 || this.orderLocked()) {
        return;
      }
      this.moveSong(itemIndex, insertIndex);
    })
    }

    if (this.editMode && !this.orderLocked()) {
      Text(this.tx('drag_hint'))
        .fontSize(10)
        .fontColor(this.pal().subText)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 4 })
    }

  }

  /**
   * 横屏左侧标签栏宽度：右边缘与标题「我的列表」的「表」字对齐。
   * 标题起点 = header padding 12 + Text margin 8，「我的列表」4 个 20vp 字 ≈ 80vp，右边缘约 100vp。
   * 仍夹一个下限保证「我的收藏」这类四字标签单行显示。
   */
  private railWidth(): number {
    return Math.max(88, Math.min(100, screenWidthVp() * 0.14));
  }

  /** 横屏竖排标签的临时置顶位移（vp）：与 chipShift 同逻辑，按行高而非列宽计算 */
  private chipShiftY(id: string): number {
    const k: number = this.pinnedTabIndex();
    if (k < 0 || id.length === 0) {
      return 0;
    }
    const lists: UserListInfo[] = this.userLists;
    let t: number = 0;
    for (let i = 0; i < lists.length; i++) {
      if (!this.isFixedListId(lists[i].id)) {
        t = i;
        break;
      }
    }
    const step: number = 34;
    if (id === lists[k].id) {
      return -(k - t) * step;
    }
    for (let i = t; i < k; i++) {
      if (lists[i].id === id) {
        return step;
      }
    }
    return 0;
  }

  /** 横屏左侧竖排胶囊：宽度撑满标签栏，⋯ 恒在最下方 */
  @Builder
  private LandscapeChip(label: string, id: string, more: boolean, onTap: () => void, onLong: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(this.chipOn(id, more) ? '#FFFFFF' : this.pal().pillText)
      .backgroundColor(this.chipOn(id, more) ? this.theme.primary : this.pal().pillBg)
      .borderRadius(14)
      .width('100%')
      .height(30)
      .textAlign(TextAlign.Center)
      .margin({ bottom: 4 })
      .translate({ y: more ? 0 : this.chipShiftY(id) })
      .animation({ duration: 260, curve: Curve.Friction })
      .onClick((): void => { onTap(); })
      .gesture(LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS }).onAction((): void => {
        onLong();
      }))
  }

  /** 横屏左侧竖排标签栏：全部列表自上而下，⋯ 固定在最下方 */
  @Builder
  private LandscapeRail() {
    Column() {
      Scroll(this.railScroller) {
        Column() {
          ForEach(this.visibleLists(), (u: UserListInfo): void => {
            this.LandscapeChip(u.name, u.id, false,
              (): void => { this.switchList(u.id); },
              (): void => { this.openListDrawer(u.id); });
          }, (u: UserListInfo): string => u.id)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .width('100%')

      this.LandscapeChip('⋯', '', true,
        (): void => { this.openListDrawer(''); },
        (): void => { this.openListDrawer(''); });
    }
    .width(this.railWidth())
    .height('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 8 })
    .backgroundColor(this.pal().card)
  }

  build() {
    Stack() {
      Column() {
        if (this.isLandscape) {
          Row() {
            this.LandscapeRail()
            Column() {
              this.ContentArea()
            }
            .layoutWeight(1)
            .height('100%')
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          Column() {
            this.PortraitTabRow()
            this.ContentArea()
          }
          .layoutWeight(1)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.mainBackground)

      // 新建列表弹窗：挂在页面最外层 Stack 并整体居中。
      // 原来用 position(7%, 30%) 定位在列表 Column 内，父容器宽度在某些布局时机
      // 还没测量出来时，弹窗会偏到屏幕右侧、被右边缘裁掉，按钮文字也压成省略号。
      // 现在不依赖父容器宽度：整层铺满 + 居中，卡片宽度按屏幕百分比并夹上限。
      if (this.showNewList) {
        Column() {
          Column() {
            Text(this.tx('new_list_title'))
              .width('100%')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.font)
            TextInput({ placeholder: this.tx('list_name_ph'), text: this.newListName })
              .width('100%')
              .height(38)
              .backgroundColor(this.pal().pillBg)
              .fontColor(this.theme.font)
              .placeholderColor(this.pal().subText)
              .borderRadius(8)
              .margin({ top: 12 })
              .id('newListInput')
              .enableKeyboardOnFocus(true)
              .onAppear((): void => {
                // 弹窗出现后自动聚焦，光标落入输入框并唤起键盘
                setTimeout((): void => {
                  focusControl.requestFocus('newListInput');
                }, 60);
              })
              .onChange((v: string): void => { this.newListName = v; })
              .onSubmit((): void => { this.createNewList(); })
            Row() {
              // 两个按钮都按内容单行显示：文字不换行、不省略，宽度平分剩余空间
              Button() {
                Text(this.tx('cancel'))
                  .fontSize(13).fontColor(this.pal().pillText).maxLines(1)
              }
              .type(ButtonType.Normal).stateEffect(false)
              .backgroundColor(this.pal().pillBg)
              .borderRadius(8).height(38)
              .layoutWeight(1)
              .onClick((): void => { this.showNewList = false; })
              Button() {
                Text(this.tx('create'))
                  .fontSize(13).fontColor('#FFFFFF').maxLines(1)
              }
              .type(ButtonType.Normal).stateEffect(false)
              .backgroundColor(this.theme.primary)
              .borderRadius(8).height(38)
              .layoutWeight(1).margin({ left: 10 })
              .onClick((): void => { this.createNewList(); })
            }
            .width('100%')
            .margin({ top: 14 })
          }
          .width('80%')
          .constraintSize({ maxWidth: Math.min(480, screenWidthVp() * 0.8) })
          .padding(18)
          .backgroundColor(this.pal().card)
          .borderRadius(14)
          .border({ width: 1, color: this.theme.primary })
          // 吃掉卡片内的点击，避免冒泡到遮罩把自己关掉
          .onClick((): void => {})
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick((): void => { this.showNewList = false; })
      }

      // 浮动「定位到正在播放的歌曲」按钮：右下角悬浮在列表之上。
      // 外层 Column 只用来把按钮推到右下角，hitTestBehavior(None) 让空白处不吃触摸，
      // 列表照常可以滑动、点按（否则整块透明区域会把列表的手势全挡掉）。
      if (this.canLocate()) {
        Column() {
          LocateButton({
            theme: this.theme,
            onLocate: (): void => { this.locatePlaying(); },
          })
        }
        .width('100%')
        .height('100%')
        .padding({ right: 14, bottom: 18 })
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.None)
      }

      // 三点菜单挂在页面最外层 Stack：一旦放进上面的 Column，它会作为普通子项
      // 参与竖向排版，遮罩盖不满整页、卡片 78% 高度按剩余空间算，底部菜单被裁
      if (this.menuIndex >= 0 && this.menuIndex < this.songs.length) {
        SongMenuPanel({
          music: this.songs[this.menuIndex],
          listId: this.activeListId,
          index: this.menuIndex,
          // 播放历史按播放时间倒序，不给「调整位置」
          fixedOrder: this.activeListId === ListIds.HISTORY,
          theme: this.theme,
          onClose: (): void => { this.menuIndex = -1; },
          onChanged: (): void => { this.refresh(); },
        })
      }

      // 批量菜单：一次对选中的多首歌执行同一操作
      if (this.batchMenu) {
        SongMenuPanel({
          musics: this.selectedSongs(),
          listId: this.activeListId,
          index: 0,
          fixedOrder: this.activeListId === ListIds.HISTORY,
          theme: this.theme,
          onClose: (): void => {
            this.batchMenu = false;
            // 移除/移动后选中项可能已不在列表，过滤掉避免计数虚高
            const ids = new Set<string>(this.songs.map((m: MusicInfo): string => m.id));
            this.selected = this.selected.filter((id: string): boolean => ids.has(id));
            if (this.selected.length === 0) {
              this.editMode = false;
            }
          },
          onChanged: (): void => { this.refresh(); },
        })
      }

      // 全部列表抽屉：超过 4 个列表时由「更多」按钮打开；内部自行处理系统返回手势
      if (this.showListDrawer) {
        ListDrawerPanel({
          theme: this.theme,
          lists: this.userLists,
          activeId: this.activeListId,
          initialSelectId: this.drawerInitialSelectId,
          onSelect: (id: string): void => {
            this.switchList(id);
            this.closeListDrawer();
          },
          onReorder: (ids: string[]): void => { this.applyListOrder(ids); },
          onDelete: (ids: string[]): void => { this.pendingDelete = ids; },
          onChanged: (): void => { this.refresh(); },
          onClose: (): void => { this.closeListDrawer(); },
        })
      }

      // 删除自建列表的二次确认（固定列表在组件侧已被过滤）
      if (this.pendingDelete.length > 0) {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => { this.pendingDelete = []; })
          Column() {
            Text('删除列表')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
            Text('将删除选中的 ' + this.pendingDelete.length.toString() +
              ' 个列表及其中的歌曲，固定列表不会被删除。')
              .fontSize(12).fontColor(this.pal().subText)
              .margin({ top: 10 })
            Row() {
              Button('取消')
                .onClick((): void => { this.pendingDelete = []; })
                .backgroundColor(this.pal().pillBg).stateEffect(false)
                .fontColor(this.pal().pillText).fontSize(13).layoutWeight(1)
              Button('删除')
                .onClick((): void => { this.doDeleteLists(); })
                .backgroundColor('#C0553F').stateEffect(false)
                .fontColor('#FFFFFF').fontSize(13).layoutWeight(1)
                .margin({ left: 10 })
            }
            .width('100%').margin({ top: 16 })
          }
          .width('84%').padding(18)
          .backgroundColor(this.pal().card).borderRadius(14)
        }
        .width('100%').height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 歌单唯一键：来源 + 源歌单 id */
  /** 卡片第二行文案：作者/播放量 + 歌曲数 */
  private cellSubtitle(p: FavoritePlaylistInfo): string {
    const base: string = p.author.length > 0 ? p.author : p.playCount;
    if (p.total <= 0) {
      return base;
    }
    const tail: string = p.total.toString() + ' 首';
    return base.length > 0 ? base + ' · ' + tail : tail;
  }

  private pkey(p: FavoritePlaylistInfo): string {
    return p.source + ':' + p.sourceListId;
  }

  /** 该歌单是否已点「取消收藏」但尚未落盘（空心） */
  private isPendingOff(p: FavoritePlaylistInfo): boolean {
    return this.pendingOff.indexOf(this.pkey(p)) >= 0;
  }

  /** 切换待取消状态：空心 ↔ 实心，均不立即落盘 */
  private togglePendingOff(p: FavoritePlaylistInfo): void {
    const k: string = this.pkey(p);
    if (this.pendingOff.indexOf(k) >= 0) {
      this.pendingOff = this.pendingOff.filter((x: string): boolean => x !== k);
    } else {
      this.pendingOff = this.pendingOff.concat([k]);
    }
  }

  /** 离开模块时，把「取消收藏」的歌单真正从存储删除（一次落盘） */
  private commitPendingOff(): void {
    if (this.pendingOff.length === 0) {
      return;
    }
    const keys: string[] = this.pendingOff.slice();
    this.pendingOff = [];
    PlaylistStore.getInstance().removeMany(keys);
  }

  // ─────────────────── 「我的歌单」网格 + 自定义拖动排序 ───────────────────

  /**
   * 当前列数：
   *  - 竖屏：手机恒为 2，平板按容器宽度扩到 3~4 列（目标列宽 180vp）；
   *  - 横屏：标签让到左侧后视窗更宽，目标列宽 150vp，取 3~5 列（手机通常 4 列 → 2 行 8 张）。
   */
  private cols(): number {
    const w: number = this.gridW > 0 ? this.gridW : 336;
    if (this.isLandscape) {
      return columnCount(w, 150, 3, 5);
    }
    return columnCount(w, 180, 2, 4);
  }

  /** 单卡高度：竖屏原值；横屏按「可视高 ÷ 2」压缩，两行正好放满视窗 */
  private cardH(): number {
    if (!this.isLandscape) {
      return PL_CARD_H;
    }
    const vh: number = this.viewportH > 0 ? this.viewportH : 240;
    const h: number = Math.floor((vh - PL_GAP) / 2);
    return Math.max(PL_LAND_CARD_MIN_H, Math.min(h, 160));
  }

  /** 封面高度：竖屏原值；横屏 = 卡片高度 - 标题/副标题/内边距预留 */
  private coverH(): number {
    if (!this.isLandscape) {
      return 148;
    }
    return Math.max(48, this.cardH() - 46);
  }

  /** 单列宽度（vp）。容器宽度由 onAreaChange 量出，未量到时给个保守兜底 */
  private cellW(): number {
    const w: number = this.gridW > 0 ? this.gridW : 336;
    const cols: number = this.cols();
    return (w - (cols - 1) * PL_GAP) / cols;
  }

  /** 网格总高度（rows 行，行间留 PL_GAP） */
  private gridHeight(): number {
    const rows: number = Math.ceil(this.playlists.length / this.cols());
    return rows * this.cardH() + (rows > 0 ? (rows - 1) * PL_GAP : 0);
  }

  /** 歌单在「当前顺序」里的下标，找不到返回 -1 */
  private indexOfPlaylist(p: FavoritePlaylistInfo): number {
    const k: string = this.pkey(p);
    for (let i = 0; i < this.playlists.length; i++) {
      if (this.pkey(this.playlists[i]) === k) {
        return i;
      }
    }
    return -1;
  }

  /** 第 idx 个槽位的横向偏移 */
  private slotX(idx: number): number {
    return (idx % this.cols()) * (this.cellW() + PL_GAP);
  }

  /** 第 idx 个槽位的纵向偏移 */
  private slotY(idx: number): number {
    return Math.floor(idx / this.cols()) * (this.cardH() + PL_GAP);
  }

  /**
   * 卡片应该画在哪儿（用 translate 而不是 Grid 定位，
   * 这样顺序一变 translate 就会有过渡动画）。
   * 必须在这里读取 playlists / dragKey / dragDX，@Builder 按值传参不会刷新。
   */
  private cellTX(p: FavoritePlaylistInfo): number {
    if (this.cellDragging(p)) {
      // 被拖的卡片：冻结起点 + 手指位移（横向不滚动，无需补偿）
      return this.dragOriginX + this.dragDX;
    }
    const idx: number = this.indexOfPlaylist(p);
    return this.slotX(idx < 0 ? 0 : idx);
  }

  private cellTY(p: FavoritePlaylistInfo): number {
    if (this.cellDragging(p)) {
      // 冻结起点 + 手指位移；再补「滚动补偿」：容器自动滚动时卡片仍黏在手指下
      return this.dragOriginY + this.dragDY + (this.scrollY - this.scrollY0);
    }
    const idx: number = this.indexOfPlaylist(p);
    return this.slotY(idx < 0 ? 0 : idx);
  }

  private cellDragging(p: FavoritePlaylistInfo): boolean {
    return this.dragKey.length > 0 && this.dragKey === this.pkey(p);
  }

  /** 让位动画：被拖的卡片跟手（0ms），其它卡片用弹性曲线滑到新槽位 */
  private cellAnim(p: FavoritePlaylistInfo): AnimateParam {
    if (this.cellDragging(p)) {
      return { duration: 0, curve: Curve.Linear };
    }
    return { duration: 240, curve: Curve.Friction };
  }

  /** 长按抬起卡片：记录起点槽位与当前滚动偏移，之后靠 translate 跟手 */
  private beginPlaylistDrag(p: FavoritePlaylistInfo): void {
    // 正在播放的置顶卡片占的是「临时第一格」，不是它的真实位置：
    // 允许拖会和置顶/收回的动画打架，也会把存储顺序搞乱，所以这次长按不进入拖动
    if (this.pinnedFavKey.length > 0 && this.pinnedFavKey === this.pkey(p)) {
      return;
    }
    const idx: number = this.indexOfPlaylist(p);
    if (idx < 0) {
      return;
    }
    this.dragOriginX = this.slotX(idx);
    this.dragOriginY = this.slotY(idx);
    this.dragDX = 0;
    this.dragDY = 0;
    // 取一次真实滚动位置，作为补偿基准（此前若手动滚动过，@State 可能已过期）
    this.syncScrollY();
    this.scrollY0 = this.scrollY;
    this.dragKey = this.pkey(p);
    this.dragEndTs = Date.now();
    // 手指位置待 onTouch 首帧写入
    this.dragTouchVpY = -1;
  }

  /** 把真实滚动偏移同步到 @State（渲染补偿与自动滚动判断都以它为准） */
  private syncScrollY(): void {
    const off: number = this.plScroller.currentOffset().yOffset;
    if (!Number.isNaN(off) && off >= 0 && Math.abs(off - this.scrollY) > 0.5) {
      this.scrollY = off;
    }
  }

  /** 当前真实滚动偏移（vp）：优先读 Scroller，取不到时退回 @State 缓存 */
  private curScrollY(): number {
    const off: number = this.plScroller.currentOffset().yOffset;
    if (!Number.isNaN(off) && off >= 0) {
      return off;
    }
    return this.scrollY;
  }

  /** 网格最大可滚动距离（vp）：内容高度 - 视口高度（含上下 padding） */
  private maxScrollY(): number {
    const content: number = this.gridHeight() + 8;
    return Math.max(0, content - this.viewportH);
  }

  /** 被拖卡片「内容坐标」的中心 Y（含滚动补偿，与 cellTY 的渲染一致） */
  private dragCenterY(): number {
    return this.dragOriginY + this.dragDY + (this.scrollY - this.scrollY0) + this.cardH() / 2;
  }

  /**
   * 拖动中：把手指位置换算成目标槽位，一旦跨格就实时重排数组。
   * 数组一变，其它卡片的 translate 目标随之改变，配合 cellAnim 自动滑开让位。
   * 手指的绝对位置由 onTouch（windowY）单独跟踪，这里只负责位移与重排。
   */
  private updatePlaylistDrag(dx: number, dy: number): void {
    if (this.dragKey.length === 0) {
      return;
    }
    this.dragDX = dx;
    this.dragDY = dy;
    this.playlistReorder();
    this.checkAutoScroll();
  }

  /**
   * 按当前拖拽位置计算目标槽位并重排（被 updatePlaylistDrag 与自动滚动共用）
   */
  private playlistReorder(): void {
    if (this.dragKey.length === 0) {
      return;
    }
    const n: number = this.playlists.length;
    if (n <= 1) {
      return;
    }
    const cw: number = this.cellW();
    const cols: number = this.cols();
    // 中心用「内容坐标 + 滚动补偿」，这样自动滚动后重排仍然正确
    const cx: number = this.dragOriginX + this.dragDX + cw / 2;
    const cy: number = this.dragCenterY();
    let col: number = Math.round((cx - cw / 2) / (cw + PL_GAP));
    if (col < 0) {
      col = 0;
    }
    if (col > cols - 1) {
      col = cols - 1;
    }
    let row: number = Math.round((cy - this.cardH() / 2) / (this.cardH() + PL_GAP));
    if (row < 0) {
      row = 0;
    }
    let target: number = row * cols + col;
    if (target > n - 1) {
      target = n - 1;
    }
    // 有置顶项时它固定霸占第一格：其余卡片最多挪到第 2 格，不能把它挤下去
    if (this.pinnedFavKey.length > 0 && target < 1) {
      target = 1;
    }
    // 当前拖的是哪一项（顺序会随手指变化，必须每次重查）
    let cur: number = -1;
    for (let i = 0; i < n; i++) {
      if (this.pkey(this.playlists[i]) === this.dragKey) {
        cur = i;
        break;
      }
    }
    if (cur < 0 || cur === target) {
      return;
    }
    const arr: FavoritePlaylistInfo[] = this.playlists.slice();
    const item: FavoritePlaylistInfo = arr.splice(cur, 1)[0];
    arr.splice(target, 0, item);
    this.playlists = arr;
  }

  /**
   * 贴边判定用的纵向坐标（vp，视口内坐标：0 = 视口顶）。
   * 只用**单一来源**：优先手指真实位置；只有在手指坐标尚未取到时才退回被拖卡片中心。
   * （此前把两者取 min/max 混用，任一侧偏差都会把方向带偏，导致「向下拖反而向上滚」。）
   */
  private probeViewportY(): number {
    if (this.dragTouchVpY >= 0 && this.scrollContainerGlobalY > 0) {
      return this.dragTouchVpY - this.scrollContainerGlobalY;
    }
    return this.dragCenterY() - this.curScrollY();
  }

  /**
   * 当前应滚动的方向：-1 = 内容下移（把上方歌单带进视口），1 = 内容上移（把下方歌单带进视口），0 = 不动。
   * 触发带从视口上/下边缘向两侧延伸 PL_AUTOSCROLL_BAND：
   * 手指移到网格上方的「我的歌单 · N 个歌单」标题条时视口坐标为负、移到下方播控条时大于视口高度，
   * 两种情况都满足判定，因此贴到这两个位置就开始持续滚动。
   */
  private autoScrollDir(): number {
    if (this.dragKey.length === 0 || this.viewportH <= 0) {
      return 0;
    }
    const band: number = PL_AUTOSCROLL_BAND;
    const probe: number = this.probeViewportY();
    const cur: number = this.curScrollY();
    const maxScroll: number = this.maxScrollY();
    const wantUp: boolean = probe < band && cur > 0;
    const wantDown: boolean = probe > this.viewportH - band && cur < maxScroll;
    if (wantUp && wantDown) {
      // 视口太矮时两条触发带会重叠：按手指偏向哪半边决定方向
      return probe < this.viewportH / 2 ? -1 : 1;
    }
    if (wantUp) {
      return -1;
    }
    if (wantDown) {
      return 1;
    }
    return 0;
  }

  /** 越贴近边缘滚得越快（5 ~ 15vp/帧，16ms 一帧），手感连续不突兀 */
  private autoScrollStep(dir: number): number {
    const band: number = PL_AUTOSCROLL_BAND;
    const probe: number = this.probeViewportY();
    const depth: number = dir < 0 ? (band - probe) : (probe - (this.viewportH - band));
    const ratio: number = depth <= 0 ? 0 : Math.min(depth / band, 1);
    return PL_AUTOSCROLL_STEP_MIN + (PL_AUTOSCROLL_STEP_MAX - PL_AUTOSCROLL_STEP_MIN) * ratio;
  }

  /** 手指/卡片进入触发带就启动常驻定时器，离开则停（贴住不动也会一直滚） */
  private checkAutoScroll(): void {
    if (this.autoScrollDir() === 0) {
      this.stopAutoScroll();
    } else {
      this.startAutoScroll();
    }
  }

  private startAutoScroll(): void {
    if (this.autoTimer !== -1) {
      return;
    }
    this.autoTimer = setInterval((): void => { this.tickAutoScroll(); }, 16);
  }

  private stopAutoScroll(): void {
    if (this.autoTimer !== -1) {
      clearInterval(this.autoTimer);
      this.autoTimer = -1;
    }
  }

  /** 每帧把容器朝触发带所在方向滚动一小步，被拖卡片因渲染含滚动补偿而始终黏在手指下 */
  private tickAutoScroll(): void {
    const dir: number = this.autoScrollDir();
    if (dir === 0) {
      this.stopAutoScroll();
      return;
    }
    const cur: number = this.curScrollY();
    const maxScroll: number = this.maxScrollY();
    const step: number = this.autoScrollStep(dir);
    let newY: number = cur + dir * step;
    if (newY < 0) {
      newY = 0;
    }
    if (newY > maxScroll) {
      newY = maxScroll;
    }
    if (Math.abs(newY - cur) < 0.5) {
      this.stopAutoScroll();
      return;
    }
    // 先写 @State，让被拖卡片的 translate 补偿与本次滚动同步生效
    this.scrollY = newY;
    this.plScroller.scrollTo({ xOffset: 0, yOffset: newY, animation: false });
    this.playlistReorder();
  }

  /** 松手：停止自动滚动、清理拖动态，并按最终顺序一次性落盘 */
  private endPlaylistDrag(): void {
    this.stopAutoScroll();
    if (this.dragKey.length === 0) {
      return;
    }
    this.dragKey = '';
    this.dragDX = 0;
    this.dragDY = 0;
    this.dragEndTs = Date.now();
    this.dragTouchVpY = -1;
    this.syncScrollY();
    // 落盘前把「临时置顶」那张卡片插回它在存储顺序里的位置：
    // 置顶只是视觉，用户拖出来的是其余卡片的相对顺序，不能把置顶位固化进存储
    let arr: FavoritePlaylistInfo[] = this.playlists.slice();
    if (this.pinnedFavKey.length > 0) {
      let at: number = -1;
      for (let i = 0; i < arr.length; i++) {
        if (this.pkey(arr[i]) === this.pinnedFavKey) {
          at = i;
          break;
        }
      }
      if (at >= 0) {
        const item: FavoritePlaylistInfo = arr.splice(at, 1)[0];
        let target: number = this.pinnedOriginIndex;
        if (target < 0) {
          target = 0;
        }
        if (target > arr.length) {
          target = arr.length;
        }
        arr.splice(target, 0, item);
      }
    }
    PlaylistStore.getInstance().reorder(arr);
    // 落盘后按「新存储顺序 + 当前播放」重建显示顺序（置顶项仍在第一格，视觉不跳动）
    this.rebuildPlaylists();
  }

  /**
   * 当前播放队列对应的收藏歌单 key（`source:sourceListId`，与 pkey 同构）。
   * playListKey 形如 `fav:tx:123456`，去掉前缀即卡片 key；不是从收藏歌单播放时返回空串。
   */
  private playingFavKey(): string {
    if (this.playListKey.startsWith('fav:')) {
      return this.playListKey.substring(4);
    }
    return '';
  }

  /**
   * 重建「我的歌单」的显示顺序：以存储顺序为基准，
   * 把「当前正在播放的那张收藏歌单」临时搬到第一格。
   *
   * 只改内存里的数组、不落盘 —— 用户拖出来的顺序是持久的，置顶只是临时的视觉状态：
   * 切到别的歌单（playListKey 变化）时再重建一次，卡片靠 translate 的动画滑回原位。
   * pinnedOriginIndex 记录它在存储顺序里的位置，拖动落盘时用它插回原处。
   */
  private rebuildPlaylists(): void {
    if (!this.isPlaylistMode()) {
      return;
    }
    const all: FavoritePlaylistInfo[] = PlaylistStore.getInstance().list();
    const kw: string = this.keyword;
    let arr: FavoritePlaylistInfo[] = kw.length === 0 ? all.slice()
      : all.filter((p: FavoritePlaylistInfo): boolean => p.name.includes(kw) || p.author.includes(kw));
    const key: string = this.playingFavKey();
    this.pinnedFavKey = '';
    this.pinnedOriginIndex = -1;
    if (key.length > 0) {
      for (let i = 0; i < arr.length; i++) {
        if (this.pkey(arr[i]) === key) {
          this.pinnedFavKey = key;
          this.pinnedOriginIndex = i;
          if (i > 0) {
            const item: FavoritePlaylistInfo = arr.splice(i, 1)[0];
            arr.unshift(item);
          }
          break;
        }
      }
    }
    this.playlists = arr;
  }

  // ─────────────────── 顶部标签行的「正在播放列表」临时置顶 ───────────────────

  /** 列表是否固定（固定列表不参与置顶） */
  private isFixedListId(id: string): boolean {
    return this.listManager.isFixedList(id);
  }

  /**
   * 需要临时置顶的标签下标：从「我的列表」页点歌播放时，来源列表若属于
   * 「4 个固定列表之外的自建列表」，它要顶到第一个自建列表的位置。
   * 返回 -1 表示不置顶（来源是固定列表 / 空 / 已经在最前面）。
   */
  private pinnedTabIndex(): number {
    const id: string = this.playSourceListId;
    if (id.length === 0) {
      return -1;
    }
    const lists: UserListInfo[] = this.userLists;
    let k: number = -1;
    for (let i = 0; i < lists.length; i++) {
      if (lists[i].id === id) {
        k = i;
        break;
      }
    }
    if (k < 0 || this.isFixedListId(lists[k].id)) {
      return -1;
    }
    let t: number = -1;
    for (let i = 0; i < lists.length; i++) {
      if (!this.isFixedListId(lists[i].id)) {
        t = i;
        break;
      }
    }
    return (t < 0 || k <= t) ? -1 : k;
  }

  /** 标签胶囊宽度：优先用实测值，未量到时按文案估算（与 TabChip 的字号/内边距一致） */
  private chipWidthOf(u: UserListInfo): number {
    const w: number = this.chipWidths.get(u.id) ?? 0;
    if (w > 0) {
      return w;
    }
    return Math.max(CHIP_MIN_WIDTH, estimateTextWidth(u.name, 13) + 24);
  }

  /**
   * 标签胶囊的临时横向位移（vp）：只移动、不改布局顺序。
   *
   *  - 正在播放的自建列表：左移「中间这些胶囊宽度之和」，落到第一个自建列表的位置；
   *  - 被它跨过的那些胶囊：统一右移它的宽度，正好让出一个格子。
   * 纯 translate + animation，所以切走时会平滑滑回原位；Scroll 的内容宽度不变，不会跳。
   */
  private chipShift(id: string): number {
    const k: number = this.pinnedTabIndex();
    if (k < 0 || id.length === 0) {
      return 0;
    }
    const lists: UserListInfo[] = this.userLists;
    let t: number = 0;
    for (let i = 0; i < lists.length; i++) {
      if (!this.isFixedListId(lists[i].id)) {
        t = i;
        break;
      }
    }
    if (id === lists[k].id) {
      let sum: number = 0;
      for (let i = t; i < k; i++) {
        sum += this.chipWidthOf(lists[i]) + 8;
      }
      return -sum;
    }
    for (let i = t; i < k; i++) {
      if (lists[i].id === id) {
        return this.chipWidthOf(lists[k]) + 8;
      }
    }
    return 0;
  }

  /** 把标签滚回起点：竖屏滚到最左，横屏滚到最顶部（置顶项出现时调用） */
  private scrollTabsToStart(): void {
    try {
      this.tabScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: true });
      this.railScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: true });
    } catch (e) {
      // 标签栏尚未挂载：忽略，置顶本身已经生效
    }
  }

  /** 记录标签胶囊实测宽度（量到变化才写，避免布局回调反复触发刷新） */
  private captureChipWidth(id: string, w: number): void {
    if (id.length === 0 || Number.isNaN(w) || w <= 0) {
      return;
    }
    const old: number = this.chipWidths.get(id) ?? 0;
    if (Math.abs(old - w) < 0.5) {
      return;
    }
    this.chipWidths.set(id, w);
    this.chipTick = (this.chipTick + 1) % 10000;
  }

  /**
   * 卡片是否显示黑胶：当前播放队列就是从这张收藏歌单进来的。
   * 暂停不算「没了」——图标继续显示、只是停止转动；只有切到别的歌单（或别的入口播放）
   * 把 playListKey 换掉/清空时才消失。
   */
  private discVisibleFor(p: FavoritePlaylistInfo): boolean {
    if (this.playListKey.length === 0) {
      return false;
    }
    return this.playListKey === ('fav:' + p.source + ':' + p.sourceListId);
  }

  /** 点击歌单卡片 → 歌单详情页（复用在线歌单同一条路由） */
  private openPlaylist(p: FavoritePlaylistInfo): void {
    // 刚拖动完松手的那一下不当作点击，避免误进详情页
    if (Date.now() - this.dragEndTs < 300) {
      return;
    }
    router.pushUrl({
      url: 'pages/PlaylistDetail',
      params: {
        source: p.source,
        id: p.sourceListId,
        title: p.name,
        type: p.type,
        author: p.author,
        playCount: p.playCount,
        img: hdCoverUrl(p.img),
      },
    });
  }

  /**
   * 网格里的一个歌单卡片：绝对定位（translate）+ 长按抬起拖动。
   * 手势用 Sequence(长按 → 平移)：长按 260ms 后卡片抬起，接着跟手移动。
   */
  @Builder
  PlaylistGridCell(p: FavoritePlaylistInfo) {
    Stack({ alignContent: Alignment.TopStart }) {
      this.PlaylistCard(p)
    }
    .width(this.cellW())
    .height(this.cardH())
    .borderRadius(12)
    .backgroundColor(this.cellDragging(p) ? this.pal().card : Color.Transparent)
    .shadow(this.cellDragging(p)
      ? { radius: 18, color: '#40000000', offsetX: 0, offsetY: 8 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .scale({
      x: this.cellDragging(p) ? 1.05 : 1,
      y: this.cellDragging(p) ? 1.05 : 1,
    })
    .zIndex(this.cellDragging(p) ? 3 : 1)
    // 抬起动效（放大 + 投影）
    .animation({ duration: 160, curve: Curve.Friction })
    // 位置：跟手移动 / 让位滑动
    .translate({ x: this.cellTX(p), y: this.cellTY(p) })
    .animation(this.cellAnim(p))
    // 手指绝对位置：TouchObject.windowY 本身单位就是 vp（相对窗口左上角，含状态栏），
    // 与 Scroll 的 globalPosition.y 同一坐标系，直接相减即得手指在滚动视口中的位置。
    // 注意不要再套 px2vp：那会把数值缩小约 2.75 倍，导致视口坐标恒为负、方向判定永远偏向「向上」。
    .onTouch((e: TouchEvent): void => {
      if (this.dragKey.length === 0) {
        return;
      }
      if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.dragTouchVpY = -1;
        return;
      }
      if (e.touches.length > 0) {
        this.dragTouchVpY = e.touches[0].windowY;
      }
    })
    .priorityGesture(
      GestureGroup(GestureMode.Sequence,
        LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS })
          .onAction((): void => { this.beginPlaylistDrag(p); }),
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 1 })
          .onActionUpdate((event: GestureEvent): void => {
            this.updatePlaylistDrag(event.offsetX, event.offsetY);
          })
          .onActionEnd((): void => { this.endPlaylistDrag(); })
          .onActionCancel((): void => { this.endPlaylistDrag(); })
      )
    )
  }

  @Builder
  PlaylistCard(p: FavoritePlaylistInfo) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        // 仅「我的歌单」（已收藏）用高清地址：源站支持的平台升到 800px，
        // 高清图取不到时 CoverImage 自动回退原始图，不会出现裂图。
        // 歌单广场等其它列表仍用各自原图，不受影响。
        CoverImage({
          url: hdCoverUrl(p.img), fallbackUrl: p.img, theme: this.theme, radius: 10,
          placeholder: $r('app.media.ic_playlist'), placeholderSize: 36,
        })
          .width('100%').height(this.coverH())
        // 已收藏/待取消：实心=已收藏；空心=已点取消但卡片暂留，可再点恢复
        // 本歌单正在播放时，收藏按钮左侧多一张转动的黑胶（唱臂不转）
        Row() {
          if (this.discVisibleFor(p)) {
            Stack() {
              // 唱片直径与白底一致；暂停时图标留着，只是不转
              VinylDisc({ diameter: 28, playing: this.isPlaying })
            }
            .width(28).height(28)
            .borderRadius(14)
            .backgroundColor('#E6FFFFFF')
            .margin({ right: 4 })
          }
          Button() {
            Image(this.isPendingOff(p) ? $r('app.media.ic_heart') : $r('app.media.ic_heart_fill'))
              .width(15).height(15)
              .fillColor(this.isPendingOff(p) ? this.pal().subText : this.theme.primary)
          }
          .type(ButtonType.Normal).width(28).height(28)
          .backgroundColor('#E6FFFFFF').borderRadius(14)
          .stateEffect(false)
          .onClick((): void => {
            // 不立即落盘：先在本页切换实心/空心，真正删除留到离开模块时
            this.togglePendingOff(p);
          })
        }
        .margin({ top: 6, right: 6 })
      }
      .width('100%').height(this.coverH())

      Text(p.name)
        .fontSize(13).fontColor(this.theme.font)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').margin({ top: 6 })
      // 第二行：作者（没有作者时用播放量），末尾带歌曲数
      Text(this.cellSubtitle(p))
        .fontSize(11).fontColor(this.pal().subText)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').margin({ top: 2 })
    }
    .width('100%')
    .padding(6)
    .onClick((): void => { this.openPlaylist(p); })
  }

  /** 拖拽跟手预览 */
  @Builder
  DragPreview(index: number) {
    Row() {
      Text(index >= 0 && index < this.songs.length ? this.songs[index].name : '')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('72%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.theme.primary)
    .borderRadius(10)
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 6 })
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  /** 当前选中的歌曲对象（按列表顺序），供批量菜单使用 */
  private selectedSongs(): MusicInfo[] {
    return this.songs.filter((m: MusicInfo): boolean => this.isSelected(m.id));
  }

  private openBatchMenu(): void {
    if (this.selected.length === 0) {
      userNotice().info('先长按或点击选中歌曲');
      return;
    }
    this.batchMenu = true;
  }

  private toggleSelect(id: string): void {
    const i = this.selected.indexOf(id);
    if (i >= 0) {
      this.selected = this.selected.filter((x: string): boolean => x !== id);
    } else {
      this.selected = this.selected.concat([id]);
    }
  }

  private toggleSelectAll(): void {
    if (this.selected.length === this.songs.length) {
      this.selected = [];
    } else {
      this.selected = this.songs.map((m: MusicInfo): string => m.id);
    }
  }

  private toggleEditMode(): void {
    this.editMode = !this.editMode;
    if (this.editMode) {
      // 编辑模式针对完整列表操作，清掉搜索过滤，避免下标错位
      this.keyword = '';
      this.refresh();
    } else {
      this.selected = [];
    }
  }

  private deleteSelected(): void {
    if (this.selected.length === 0) {
      return;
    }
    this.listManager.removeListMusics(this.activeListId, this.selected);
    this.selected = [];
    this.refresh();
  }

  private moveSong(from: number, to: number): void {
    if (from === to || from < 0 || to < 0) {
      return;
    }
    this.listManager.moveListMusic(this.activeListId, from, to);
    this.refresh();
  }

  private showItemMenu(index: number): void {
    // 多选模式下 ⋮ 作用于「当前选中的全部歌曲」：该行未选中时先补选，再开批量菜单
    if (this.editMode) {
      if (index >= 0 && index < this.songs.length) {
        const id: string = this.songs[index].id;
        if (!this.isSelected(id)) {
          this.selected = this.selected.concat([id]);
        }
      }
      this.openBatchMenu();
      return;
    }
    if (index >= 0 && index < this.songs.length) {
      this.menuIndex = index;
    }
  }
}
