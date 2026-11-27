/**
 * 主框架页（Home）—— 按主框架布局。
 * 侧滑抽屉导航 + Header + 5 页横向滑动 + 固定底部 PlayerBar + 播放详情页。
 * 由 M2 的 PlayController 统一驱动；M1 的验证页留档在 M1Verify.ets.txt。
 */
import { ControllerSnapshot, PlayController } from '../player/PlayController';
import { AppState, HeaderAction } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { ThemeInfo, getTheme } from '../theme/Themes';
import { ACTIVE_NAV_MENUS, SETTING_MENU, isDownloadEnabled, NavMenu } from '../config/AppConstants';
import { stateEvent, StateEvents } from '../store/EventBus';
import { AppLog } from '../core/AppLog';
import { getAppContext } from '../common/AppContext';
import { NoticeItem, NoticeLevel, userNotice } from '../core/UserNotice';
import { UIContext } from '@kit.ArkUI';
import { I18n } from '../core/I18n';
import { buildPalette } from '../theme/Themes';
import { PlayerBar } from '../components/PlayerBar';
import { MylistView } from './views/MylistView';
import { SonglistView, LeaderboardView, SearchView } from './views/OnlineViews';
import { SettingView } from './views/SettingView';
import { PlayDetail } from './PlayDetail';
import { DownloadPage } from './DownloadPage';
import { LocalPage } from './LocalPage';
import { APP_VERSION_NAME } from '../config/AppVersion';
import { CustomSourceSandbox } from '../components/CustomSourceSandbox';
import { CustomSourceManager, CustomSourceUpdateAlert } from '../components/CustomSourceDialog';
import { CacheLimitDialog } from '../components/CacheLimitDialog';
import { CacheStore, CacheAskHub } from '../core/CacheStore';
import { SourceServiceDialog } from '../components/SourceServiceDialog';
import { StartupNoticeDialog } from '../components/StartupNoticeDialog';
import { consumeFirstLaunchNotice } from '../core/FirstLaunchNotice';
import { takeBirthdayWish } from '../core/BirthdayWish';
import { CustomScriptRunner } from '../core/net/CustomScriptRunner';
import { MusicUrlResolver } from '../core/net/MusicUrlResolver';
import { screenWidthVp, initScreenMetrics } from '../config/ScreenMetrics';

const EMPTY_SNAPSHOT: ControllerSnapshot = {
  musicInfo: null, isPlay: false, nowPlayTime: 0, maxPlayTime: 0,
  playMode: 'listLoop', statusText: '', lyricLines: [], activeLyricIndex: -1,
  lyricWords: [], activeWordIndex: -1,
  listName: '我的歌单', listCount: 0, isFavorite: false, mediaMatching: false,
};

const NAV_LABELS: Record<string, string> = {
  'nav_love': 'nav_my_list',
  'nav_songlist': 'nav_songlist',
  'nav_top': 'nav_top',
  'nav_search': 'nav_search',
  'nav_download': 'nav_download',
  'nav_local': 'nav_local',
  'nav_setting': 'nav_setting',
};

@Entry
@Component
struct Index {
  @State private snapshot: ControllerSnapshot = EMPTY_SNAPSHOT;
  /** Swiper 的索引，只由抽屉点击驱动，避免与 onChange 形成双向回环 */
  @State private swiperIndex: number = 0;
  /** 当前导航高亮/标题，由用户滑动或抽屉点击更新 */
  @State private navIndex: number = 0;
  @State private showDetail: boolean = false;
  @State private showDrawer: boolean = false;
  /**
   * 当前是否横屏（平板横屏 / 手机开启「强制横屏」）。
   * 由 ScreenMetrics 通过 mediaquery 写进 AppStorage，旋转或切设置立即生效。
   * 横屏可用高度通常只有竖屏一半，抽屉、列表行、底部播放栏都按它切紧凑尺寸；
   * 竖屏（=手机常态）完全不受影响。
   */
  @StorageProp('screenCompact') private compact: boolean = false;
  @StorageProp('screenLandscape') private isLandscape: boolean = false;
  /** 横屏时「我的列表」搜索框移到标题行，与 MylistView 共用同一份关键词/占位提示 */
  @StorageLink('mylist.keyword') private mylistKeyword: string = '';
  @StorageLink('mylist.keywordPlaceholder') private mylistPlaceholder: string = '搜索歌单';
  /**
   * 设置页全屏浮层是否打开。
   * 设置已从 Swiper 序列里移除（只在抽屉里有入口），打开时盖住当前模块页，
   * 关闭后原模块页原样还在，返回手势/返回键天然「回到进入设置前的页面」。
   */
  @State private showSetting: boolean = false;
  @State private theme: ThemeInfo = getTheme('green');
  @State private logs: string[] = [];
  @State private ready: boolean = false;
  @State private langTick: number = 0;
  /** 当前激活模块注册到全局头部的右侧操作（≡ 左侧渲染） */
  @State private headerActions: HeaderAction[] = [];
  /** 抽屉里的运行日志默认收起，保持与本协议 一致的干净版式 */
  @State private showLogs: boolean = false;
  /** 自定义音源管理弹窗 / 音源更新提示 / 音源服务（HTTP 端点）弹窗 */
  @State private showCustomManager: boolean = false;
  /** >0 表示正在询问「是否调高缓存上限」（值为当前上限 MiB） */
  @State private cacheAskMb: number = 0;
  @State private showCustomUpdate: boolean = false;
  @State private showSourceService: boolean = false;
  /** 首次安装风控提示 / 农历生日祝福（纯本地，按顺序弹，不叠加） */
  @State private showFirstLaunchNotice: boolean = false;
  @State private birthdayWish: string = '';
  @State private showBirthdayWish: boolean = false;
  @State private customUpdateName: string = '';
  @State private customUpdateLog: string = '';
  @State private customUpdateUrl: string = '';

  private controller: PlayController = PlayController.getInstance();
  /** Swiper 控制器：抽屉点击时显式切页，避免只改状态时页面偶尔不跟随 */
  private swiperCtl: SwiperController = new SwiperController();
  private state: AppState = AppState.getInstance();
  private settings: SettingStore = SettingStore.getInstance();
  /** 轻提示出口的 UI 上下文：core/player 层投递的失败提示都由这里弹给用户 */
  private uiCtx: UIContext | null = null;

  async aboutToAppear(): Promise<void> {
    this.uiCtx = this.getUIContext();
    // 横竖屏监听：结果写进 AppStorage，本页与列表/播放栏据此切换紧凑尺寸
    initScreenMetrics();
    this.bindUserNotice();
    // 头部操作订阅必须在首个 await 之前注册，否则首屏构建时子模块注册的操作会漏收
    stateEvent().on(StateEvents.HEADER_ACTION_UPDATED, (): void => {
      this.headerActions = AppState.getInstance().getHeaderActions();
    });
    stateEvent().on(StateEvents.CUSTOM_SOURCE_MANAGE, (): void => {
      this.showCustomManager = true;
    });
    // 缓存占用到 99% 且还有上调空间时，由 CacheStore 通过这个通道拉起询问弹窗
    CacheAskHub.bind((mb: number): void => { this.cacheAskMb = mb; });
    // 「音源服务」入口在自定义源管理按钮下方，点击后弹配置窗
    stateEvent().on(StateEvents.SOURCE_SERVICE_OPEN, (): void => {
      this.showSourceService = true;
    });
    stateEvent().on(StateEvents.CUSTOM_SOURCE_UPDATE, (): void => {
      const u = CustomScriptRunner.getInstance().takeUpdate();
      if (u === null) {
        return;
      }
      this.customUpdateName = u.name;
      this.customUpdateLog = u.log;
      this.customUpdateUrl = u.updateUrl;
      this.showCustomUpdate = true;
    });
    this.appendLog('M2 播放器启动中…');
    try {
      await I18n().init();
      await this.controller.init();
      this.theme = this.state.resolveActiveTheme();
      this.controller.onSnapshot = (s: ControllerSnapshot): void => {
        this.snapshot = s;
      };
      this.snapshot = this.controller.getSnapshot();
      this.ready = true;
      // 纯本地启动提示：首次安装说明风控约定；农历生日祝福排在它后面弹。
      // 两者都不发任何网络请求，不影响音源与取链风控。
      this.showFirstLaunchNotice = await consumeFirstLaunchNotice();
      const wish: string = await takeBirthdayWish();
      if (wish.length > 0) {
        this.birthdayWish = wish;
      }
      // 启动预热自定义音源沙箱：界面已上屏，隐藏 Web 这时候才能拿到控制器。
      // 不等待、不影响首屏；失败会走软冷却由心跳自动补上。
      void CustomScriptRunner.getInstance().warmUp();
      // 「启动后打开播放详情页」：等播放信息恢复完再进，避免先闪一个空页
      if (this.settings.getBoolean('player.startupPushPlayDetailScreen', false)) {
        this.showDetail = true;
      }
      this.appendLog('✅ 播放核心已就绪');
      this.appendLog('✅ 默认列表 ' + this.state.userLists.length.toString() + ' 个');
      this.appendLog('✅ 设置项 ' + this.settings.exportAll().size.toString() + ' 项');
      this.appendLog('✅ AVSession 系统卡片已注册');
      stateEvent().on(StateEvents.THEME_UPDATED, (): void => {
        this.theme = this.state.resolveActiveTheme();
      });
      stateEvent().on(StateEvents.LANGUAGE_CHANGED, (): void => {
        this.langTick = this.langTick + 1;
      });
    } catch (e) {
      this.appendLog('❌ 初始化失败: ' + JSON.stringify(e));
    }
  }

  private appendLog(msg: string): void {
    AppLog().log(msg);
    this.logs = AppLog().getAll();
  }


  /**
   * 订阅统一提示出口：任何层（取链/播放/下载/缓存/备份）投递的失败提示，
   * 都在这里变成系统轻提示，同时把日志抽屉刷成最新，保证用户看得见、也查得到。
   */
  private bindUserNotice(): void {
    userNotice().subscribe((item: NoticeItem): void => {
      this.logs = AppLog().getAll();
      if (this.uiCtx === null) {
        return;
      }
      try {
        this.uiCtx.getPromptAction().showToast({
          message: item.text,
          duration: item.level === NoticeLevel.Error ? 4000 : 2500,
        });
      } catch (e) {
        // 提示失败不影响主流程
      }
    });
  }

  /** 导航标签（读取 langTick 以在语言切换时重渲染） */
  private navLabel(id: string): string {
    const _tick = this.langTick;
    const key = NAV_LABELS[id] ?? id;
    return I18n().t(key) + (_tick >= 0 ? '' : '');
  }

  /** 抽屉各模块图标：全部取自本协议（单色 SVG，随主题染色） */
  private navIcon(id: string): Resource {
    switch (id) {
      case 'nav_love':
        return $r('app.media.ic_heart');
      case 'nav_songlist':
        return $r('app.media.ic_playlist');
      case 'nav_top':
        return $r('app.media.ic_equalizer');
      case 'nav_search':
        return $r('app.media.ic_search');
      case 'nav_download':
        return $r('app.media.ic_download');
      case 'nav_local':
        return $r('app.media.ic_sdcard');
      case 'nav_setting':
        return $r('app.media.ic_hex');
      default:
        return $r('app.media.ic_music');
    }
  }

  /** 退出应用：鸿蒙以结束当前 Ability 实例代替「真退出」 */
  private doExit(): void {
    const ctx = getAppContext();
    if (ctx === null) {
      return;
    }
    ctx.terminateSelf().catch((e: Error): void => {
      AppLog().log('退出应用失败：' + (e.message ?? ''));
    });
  }

  onBackPress(): boolean {
    // 先让播放详情页关掉它自己的浮层（播放列表 / 定时面板），
    // 否则按返回会直接把整个播放页退掉，用户会觉得「退多了」。
    const st = AppState.getInstance();
    st.uiBackConsumed = false;
    stateEvent().emit(StateEvents.UI_BACK);
    if (st.uiBackConsumed) {
      return true;
    }
    if (this.cacheAskMb > 0) {
      // 返回键等同「保持并清理」，不能把询问卡在半路
      this.cacheAskMb = 0;
      CacheStore.resolveAsk(false);
      return true;
    }
    if (this.showCustomManager) {
      this.showCustomManager = false;
      return true;
    }
    if (this.showSourceService) {
      this.showSourceService = false;
      return true;
    }
    if (this.showCustomUpdate) {
      this.showCustomUpdate = false;
      return true;
    }
    // 抽屉可能盖在设置页/主界面上，优先关它
    if (this.showDrawer) {
      this.showDrawer = false;
      return true;
    }
    // 设置页是从某个模块页打开的全屏浮层：关掉即回到进入设置前所在的模块页
    if (this.showSetting) {
      this.showSetting = false;
      return true;
    }
    if (this.showDetail) {
      this.showDetail = false;
      return true;
    }
    return false;
  }

  /** 切到某个模块页（抽屉点模块时统一走这里，顺带关掉设置浮层与抽屉） */
  private openModule(idx: number): void {
    this.showSetting = false;
    this.showDrawer = false;
    this.navIndex = idx;
    this.state.navActiveId = ACTIVE_NAV_MENUS[idx].id;
    this.swiperIndex = idx;
    // 双保险：Swiper 的 .index() 在页面重建后偶尔不同步（旧版切设置页就有此问题），
    // 再显式切一次，保证「导航栏标题」与「实际页面」永远一致
    try {
      this.swiperCtl.changeIndex(idx, false);
    } catch (e) {
      AppLog().log('switch module failed: ' + JSON.stringify(e));
    }
  }

  /** 打开设置页：记下当前模块，关闭后回到这里 */
  private openSetting(): void {
    this.showDrawer = false;
    this.showSetting = true;
    this.state.navActiveId = SETTING_MENU.id;
  }

  build() {
    Stack() {
      // 自定义音源脚本的隔离运行环境：1x1 全透明，放在最底层不遮挡任何交互
      CustomSourceSandbox()

      Column() {
        // Header：标题在左、汉堡菜单在右（本协议 的歌单页）
        // 横屏且停在「我的列表」时，把搜索框挪到标题同一行：标题改为定宽，腾出的空间放搜索框，
        // 这样下方歌单视窗不再被搜索框占去一行，能多显示一排卡片。竖屏布局完全不变。
        Row() {
          Text(this.navLabel(ACTIVE_NAV_MENUS[this.navIndex].id))
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
            .layoutWeight(this.isLandscape && this.navIndex === 0 ? 0 : 1)
            .margin({ left: 8 })
          // 横屏「我的列表」：搜索框（最右侧 ❌ 清除）+ 关键词与 MylistView 共用
          if (this.isLandscape && this.navIndex === 0) {
            Stack({ alignContent: Alignment.End }) {
              TextInput({ placeholder: this.mylistPlaceholder, text: this.mylistKeyword })
                .height(34)
                .fontSize(13)
                .backgroundColor(buildPalette(this.theme).card)
                .fontColor(this.theme.font)
                .placeholderColor(buildPalette(this.theme).subText)
                .borderRadius(8)
                .padding({ right: 38 })
                .onChange((v: string): void => { this.mylistKeyword = v; })
              if (this.mylistKeyword.length > 0) {
                Image($r('app.media.ic_close_thin'))
                  .width(16).height(16).fillColor(buildPalette(this.theme).subText)
                  .margin({ right: 26 })
                  .onClick((): void => { this.mylistKeyword = ''; })
              }
            }
            .layoutWeight(1)
            .margin({ left: 12, right: 12 })
          }
          // 当前模块注册到头部的右侧操作（≡ 左侧，字号/颜色由模块原样指定）
          ForEach(this.headerActions, (a: HeaderAction): void => {
            Text(a.text)
              .fontSize(a.fontSize)
              .fontColor(a.textColor)
              .borderRadius(a.bg !== undefined ? 12 : 0)
              .backgroundColor(a.bg !== undefined ? a.bg : Color.Transparent)
              .padding(a.bg !== undefined
                ? { left: 10, right: 10, top: 4, bottom: 4 }
                : { left: 8, right: 8 })
              .textAlign(TextAlign.Center)
              .onClick(a.onClick)
            // key 必须带上 text 和颜色：ForEach 对相同 key 的项只复用不重建，
            // 平台名切换时 key 恒为 'source' 文案不更新；同理「歌曲 / 歌单」这类
            // 只改文字颜色的头部按钮，不带颜色也会一直显示旧色。
          }, (a: HeaderAction): string => a.key + '|' + a.text + '|' + a.textColor)
          Button() { Image($r('app.media.ic_menu')).width(22).height(22).fillColor(this.theme.font) }
            .type(ButtonType.Normal).width(42).height(42)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.showDrawer = !this.showDrawer; })
        }
        .width('100%')
        .padding({ left: 12, right: 8 })

        // Swiper：我的列表/歌单/排行榜/搜索/本地（下载开关打开时多一页下载）
        // 设置不在这里，已改为抽屉入口 + 全屏浮层
        Swiper(this.swiperCtl) {
          MylistView({
            theme: this.theme,
            ready: this.ready,
            active: this.navIndex === 0,
            onPlayMusic: (listId: string, index: number): void => {
              this.controller.playList(listId, index);
              this.appendLog('▶ 播放列表 ' + listId + ' 第 ' + (index + 1).toString() + ' 首');
            },
          })
          SonglistView({ theme: this.theme, active: this.navIndex === 1 })
          LeaderboardView({ theme: this.theme, active: this.navIndex === 2 })
          SearchView({ theme: this.theme, active: this.navIndex === 3 })
          LocalPage({ theme: this.theme, active: this.navIndex === 4 })
          // 下载管理页：由总开关控制是否挂载（关闭时不占 Swiper 索引）
          if (isDownloadEnabled()) {
            DownloadPage({ theme: this.theme, active: this.navIndex === 5 })
          }
          // 设置不在滑动序列内：只在抽屉里有入口，见下方全屏设置浮层
        }
        .index(this.swiperIndex)
        .loop(false)
        .indicator(false)
        .duration(220)
        .layoutWeight(1)
        .width('100%')
        .onChange((idx: number): void => {
          // 初始化阶段 ArkUI 会误触发一次 onChange，忽略以免跳到最后一页
          if (!this.ready) {
            return;
          }
          this.navIndex = idx;
          this.state.navActiveId = ACTIVE_NAV_MENUS[idx].id;
        })

        // 底部迷你播放条（按 PlayerBar）
        PlayerBar({
          snapshot: this.snapshot,
          theme: this.theme,
          onBarClick: (): void => { this.showDetail = true; },
          onTogglePlay: (): void => { this.controller.togglePlay(); },
          onPrev: (): void => { this.controller.playPrev(); },
          onNext: (): void => { this.controller.playNext(false); },
          onSeek: (ms: number): void => { this.controller.seek(ms); },
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.mainBackground)

      // 设置页全屏浮层：盖住当前模块页，返回即回到进入设置前的模块
      if (this.showSetting) {
        Column() {
          Row() {
            Button() {
              Image($r('app.media.ic_back')).width(22).height(22).fillColor(this.theme.font)
            }
              .type(ButtonType.Normal).width(42).height(42)
              .backgroundColor(Color.Transparent).stateEffect(false)
              .onClick((): void => { this.showSetting = false; })
            Text(this.navLabel(SETTING_MENU.id))
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
              .layoutWeight(1)
              .margin({ left: 4 })
            // 设置页里也能直接开抽屉跳到别的模块（免得必须先返回再开抽屉）
            Button() {
              Image($r('app.media.ic_menu')).width(22).height(22).fillColor(this.theme.font)
            }
              .type(ButtonType.Normal).width(42).height(42)
              .backgroundColor(Color.Transparent).stateEffect(false)
              .onClick((): void => { this.showDrawer = true; })
          }
          .width('100%')
          .padding({ left: 12, right: 8 })

          // active: false —— 设置页有自己的头部，不去清空全局头部操作（否则返回后
          // 原模块的「音源平台」等按钮会丢，且不会自动重注册）
          SettingView({
            theme: this.theme,
            active: false,
            onThemeChange: (id: string): void => { this.theme = getTheme(id); },
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme.mainBackground)
      }

      // 侧滑抽屉（本协议：右侧白底 + 左侧暗化遮罩 + 浅绿 logo 头部）
      if (this.showDrawer) {
        Row() {
          Column()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => { this.showDrawer = false; })

          Column() {
            // 头部：APK logo（C 形圆环 + 音符）+ 应用名 + 鸿蒙原生版标识
            Column() {
              Row() {
                Image($r('app.media.ic_logo'))
                  .width(this.compact ? 38 : 52)
                  .height(this.compact ? 38 : 52)
                  .fillColor(this.theme.primary)
                Text(I18n().t('app_name'))
                  .fontSize(this.compact ? 19 : 23).fontWeight(FontWeight.Bold).fontColor(this.theme.primary)
                  .margin({ left: 12 })
              }
              .justifyContent(FlexAlign.Center)
              Text('鸿蒙原生版  v' + APP_VERSION_NAME)
                .fontSize(this.compact ? 11 : 12)
                .fontColor(this.theme.primary)
                .opacity(0.75)
                .margin({ top: this.compact ? 4 : 10 })
            }
            .width('100%')
            .height(this.compact ? 92 : 170)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(buildPalette(this.theme).activeTint)

            // 菜单区可滚动：横屏高度只有竖屏一半，6 项菜单 + 日志必然超高，
            // 固定布局会把「设置」挤出屏幕外点不到。滚动后任何高度都能点到。
            Scroll() {
              Column() {
              ForEach(ACTIVE_NAV_MENUS, (m: NavMenu, idx: number): void => {
                Row() {
                  Image(this.navIcon(m.id))
                    .width(this.compact ? 20 : 22)
                    .height(this.compact ? 20 : 22)
                    .fillColor(!this.showSetting && this.navIndex === idx
                      ? this.theme.primary : buildPalette(this.theme).subText)
                  Text(this.navLabel(m.id))
                    .fontSize(this.compact ? 15 : 16)
                    .fontColor(!this.showSetting && this.navIndex === idx
                      ? this.theme.primary : this.theme.font)
                    .margin({ left: 18 })
                }
                .width('100%')
                .height(this.compact ? 46 : 56)
                .padding({ left: 24 })
                .backgroundColor(!this.showSetting && this.navIndex === idx
                  ? buildPalette(this.theme).activeTint : Color.Transparent)
                .onClick((): void => { this.openModule(idx); })
              }, (m: NavMenu): string => m.id)

              // 设置：只在这里提供入口（不在左右滑动序列里）
              Row() {
                Image(this.navIcon(SETTING_MENU.id))
                  .width(this.compact ? 20 : 22)
                  .height(this.compact ? 20 : 22)
                  .fillColor(this.showSetting ? this.theme.primary : buildPalette(this.theme).subText)
                Text(this.navLabel(SETTING_MENU.id))
                  .fontSize(this.compact ? 15 : 16)
                  .fontColor(this.showSetting ? this.theme.primary : this.theme.font)
                  .margin({ left: 18 })
              }
              .width('100%')
              .height(this.compact ? 46 : 56)
              .padding({ left: 24 })
              .backgroundColor(this.showSetting ? buildPalette(this.theme).activeTint : Color.Transparent)
              .onClick((): void => { this.openSetting(); })
            }
            .width('100%')
            .margin({ top: 8 })
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)

            // 运行日志：默认收起，保留调试能力但不破坏抽屉版式
            Row() {
              Text(I18n().t('tool_log')).fontSize(12).fontColor(buildPalette(this.theme).subText)
              Image($r('app.media.ic_chevron_right')).width(12).height(12)
                .fillColor(buildPalette(this.theme).subText)
            }
            .width('100%')
            .padding({ left: 24, right: 24, top: 6, bottom: 6 })
            .onClick((): void => { this.showLogs = !this.showLogs; })

            if (this.showLogs) {
              Scroll() {
                Column() {
                  ForEach(this.logs, (line: string, idx: number): void => {
                    Text(line).fontSize(10).fontColor(buildPalette(this.theme).subText).width('100%')
                      .textAlign(TextAlign.Start)
                  }, (line: string, idx: number): string => idx.toString())
                }
                .width('100%')
              }
              .height(120)
              .width('100%')
            }

            // 退出应用（本协议 抽屉底部）
            Column() {
              Divider().color(buildPalette(this.theme).divider)
              Row() {
                Image($r('app.media.ic_power'))
                  .width(this.compact ? 18 : 20)
                  .height(this.compact ? 18 : 20)
                  .fillColor(buildPalette(this.theme).subText)
                Text(I18n().t('nav_exit')).fontSize(15).fontColor(this.theme.font)
                  .margin({ left: 18 })
              }
              .width('100%')
              .height(this.compact ? 44 : 56)
              .padding({ left: 24 })
              .onClick((): void => { this.doExit(); })
            }
            .width('100%')
            .padding({ bottom: this.compact ? 0 : 16 })
          }
          // 竖屏（手机常态）仍是 72% 宽；横屏按用户要求整体缩一半（约 190vp），
          // 只在右侧留一条，不把列表盖掉
          .width(this.compact
            ? Math.min(screenWidthVp() * 0.26, 190)
            : Math.min(screenWidthVp() * 0.72, 360))
          .height('100%')
          .backgroundColor(buildPalette(this.theme).card)
        }
        .width('100%')
        .height('100%')
        // 在导航界面（抽屉）中向右横滑即退出导航（关闭抽屉）
        .gesture(
          PanGesture({ direction: PanDirection.Right, distance: 24 })
            .onActionEnd((event: GestureEvent): void => {
              if (event.offsetX > 24 && this.showDrawer) {
                this.showDrawer = false;
              }
            })
        )
      }

      // 播放详情页（全屏覆盖，按全屏播放页跳转）
      if (this.showDetail) {
        PlayDetail({
          showDetail: this.showDetail,
          snapshot: this.snapshot,
          theme: this.theme,
        })
      }

      // 自定义源管理 / 音源更新提示 / 音源服务（全局浮层，由设置页与脚本运行时发事件唤起）
      if (this.showCustomManager) {
        CustomSourceManager({
          theme: this.theme,
          onClose: (): void => { this.showCustomManager = false; },
        })
      }
      if (this.showSourceService) {
        SourceServiceDialog({
          theme: this.theme,
          onClose: (): void => { this.showSourceService = false; },
        })
      }
      if (this.cacheAskMb > 0) {
        CacheLimitDialog({
          theme: this.theme,
          limitMb: this.cacheAskMb,
          onChoose: (raise: boolean): void => {
            this.cacheAskMb = 0;
            CacheStore.resolveAsk(raise);
          },
        })
      }
      if (this.showCustomUpdate) {
        CustomSourceUpdateAlert({
          theme: this.theme,
          name: this.customUpdateName,
          log: this.customUpdateLog,
          updateUrl: this.customUpdateUrl,
          onClose: (): void => { this.showCustomUpdate = false; },
        })
      }
      // 首次使用提示关掉后，若今天正好是农历生日，接着显示祝福（不叠加）
      if (this.showFirstLaunchNotice) {
        StartupNoticeDialog({
          theme: this.theme,
          title: '首次使用提示',
          message: '为避免 IP 被音源封禁，请遵守以下约定：\n' +
            '1、请勿连续快速切歌；\n' +
            '2、不能批量下载，应遵循应用设定。',
          buttonText: '我知道了',
          onClose: (): void => {
            this.showFirstLaunchNotice = false;
            if (this.birthdayWish.length > 0) {
              this.showBirthdayWish = true;
            }
          },
        })
      }
      if (this.showBirthdayWish) {
        StartupNoticeDialog({
          theme: this.theme,
          title: '生日快乐',
          message: this.birthdayWish,
          buttonText: '收下祝福',
          onClose: (): void => {
            this.showBirthdayWish = false;
            this.birthdayWish = '';
          },
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
