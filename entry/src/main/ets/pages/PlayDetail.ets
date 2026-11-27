/**
 * 播放详情页 —— 按播放页布局。
 * 竖屏 3 页横向滑动：封面 / 歌词 / 歌曲信息；底部固定播控 ProgressBar + ControlBtn + MoreBtn。
 */
import { ControllerSnapshot, PlayController } from '../player/PlayController';
import { DownloadManager } from '../core/DownloadManager';
import { mediaquery, window } from '@kit.ArkUI';
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { LyricLine, LyricWord, MusicInfo } from '../model/MusicTypes';
import { AppState, formatTime } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { I18n } from '../core/I18n';
import { stateEvent, StateEvents } from '../store/EventBus';
import { s2t } from '../common/S2tConverter';
import { QueuePanel } from './views/QueuePanel';
import { resolveCoverUrl, resolveCoverUrlHd } from '../common/CoverUrl';
import { CoverImage } from '../components/CoverImage';
import { LONG_PRESS_DURATION_MS } from '../config/GestureConfig';
import { isDownloadEnabled, Quality } from '../config/AppConstants';
import { availableDownloadQualities } from '../core/DownloadQualities';
import { DownloadQualityPicker } from '../components/DownloadQualityPicker';
import { screenHeightVp } from '../config/ScreenMetrics';
import { SongMatchResult } from '../core/SongMatch';
import { userNotice } from '../core/UserNotice';

/** 定时停止可选分钟数，0 = 关闭；按钮点按按 15 分钟步进到 120 再循环 */
const TIMER_OPTIONS: number[] = [0, 15, 30, 45, 60, 75, 90, 105, 120];

@Component
export struct PlayDetail {
  @Link showDetail: boolean;
  @Prop @Watch('onSnapshotUpdated') snapshot: ControllerSnapshot = {
    musicInfo: null, isPlay: false, nowPlayTime: 0, maxPlayTime: 0,
    playMode: 'listLoop', statusText: '', lyricLines: [], activeLyricIndex: -1,
    lyricWords: [], activeWordIndex: -1,
    listName: '我的歌单', listCount: 0, isFavorite: false, mediaMatching: false,
  };
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  @State private pageIndex: number = 0;
  /** 当前播放模式（图标化后用 @State 驱动，避免 @Prop 刷新不及时） */
  @State private modeKey: string = 'listLoop';
  /** 横屏时改为「封面 + 歌词」左右分栏；由 mediaquery 实时驱动 */
  @State private isLandscape: boolean = false;
  /** 自动旋转开关：开启后播放页跟随手机方向切横竖屏；仅作用于播放页，退出时恢复竖屏 */
  @State private autoRotateOn: boolean = false;
  /** 更多菜单（定时停止等） */
  @State private showMore: boolean = false;
  /** 定时停止剩余毫秒，0 = 未启用 */
  @State private timerRemain: number = 0;
  /** 当前选中的定时分钟数（0 = 关闭），用于菜单回显与图标内数字 */
  @State private timerMin: number = 0;
  /** 系统歌词（系统播控单行歌词）开关状态，驱动图标与颜色 */
  @State private lyricFloatOn: boolean = false;
  /** 主题增强：动态背景（封面模糊铺底）/ 深色下隐藏背景 / 歌词字体阴影 */
  @State private dynamicBg: boolean = false;
  @State private hideBgDark: boolean = false;
  @State private fontShadow: boolean = false;
  /** 歌词字号百分比（120–320，基准 8px × 百分比，210% ≈ 17px 与旧视觉一致） */
  @State private lyricPct: number = 210;
  /** 歌词对齐：left / center / right */
  @State private lyricAlignStr: string = 'center';
  /** 歌词简体转繁体 */
  @State private s2tOn: boolean = false;
  /** 背景模糊强度（对应 player.lockScreenBlur 0–100） */
  @State private bgBlurVal: number = 80;
  @State private langTick: number = 0;

  /** 播放队列面板 */
  @State private showQueue: boolean = false;
  /** 每次打开面板 +1，用于强制队列面板刷新 */
  @State private queueTick: number = 0;

  /** 手势浮层：音量（>=0 时显示音量条，单位 %） */
  @State private tipVol: number = -1;
  /** 手势浮层：纯文字提示（双击播放/暂停） */
  @State private tipText: string = '';
  /** 下载音质弹窗：候选音质非空时渲染 */
  @State private downloadQualities: Quality[] = [];
  /** 「自动匹配歌词和封面」进行中：按钮位置显示转圈，连点不会叠加请求 */
  @State private matching: boolean = false;

  /** 音量手势起点（滑动开始时记录，避免累加漂移） */
  private volBase: number = -1;
  private tipTimer: number = -1;

  /** 歌词列表滚动控制器：当前行变化时滚到视口中间 */
  private lyricScroller: Scroller = new Scroller();
  /** 用户手动滑动歌词的时间戳，5 秒内不自动跟随 */
  private lyricUserTouchAt: number = 0;
  /** 上一次已跟随的行号，避免每帧进度刷新都触发滚动 */
  private lastScrolledLyric: number = -1;

  private controller: PlayController = PlayController.getInstance();
  private settings: SettingStore = SettingStore.getInstance();
  private mqListener: mediaquery.MediaQueryListener | null = null;
  private timerTicker: number = -1;
  /** 事件回调引用：进出页面时精确解绑，避免监听器叠加导致重复刷新 */
  private langChangedHandler: () => void = (): void => { this.langTick = this.langTick + 1; };
  private configChangedHandler: () => void = (): void => {
    this.reloadThemeExtras();
    this.reloadLyricStyle();
    this.reloadTimerState();
    this.reloadLyricFloat();
  };
  /** 当前歌曲 id：切歌时重置歌词滚动跟随，避免旧行号/旧位置残留 */
  private currentSongId: string = '';
  /** 系统返回手势：先关内部浮层，再让页面收掉整个播放页 */
  private onUiBack = (): void => {
    if (this.showQueue) {
      this.showQueue = false;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.showMore) {
      this.showMore = false;
      AppState.getInstance().uiBackConsumed = true;
    }
  };

  aboutToAppear(): void {
    this.modeKey = this.snapshot.playMode;
    // 自动旋转开关从设置读取；开启时把窗口切到「跟随重力全方向」，让播放页能随手机转横竖
    this.autoRotateOn = this.settings.getBoolean('player.autoRotate', false);
    this.applyPlayOrientation();
    this.reloadTimerState();
    this.reloadLyricFloat();
    this.currentSongId = this.snapshot.musicInfo === null ? '' : this.snapshot.musicInfo.id;
    this.timerTicker = setInterval((): void => {
      const left = this.controller.getTimeoutExitRemainMs();
      if (left !== this.timerRemain) {
        this.timerRemain = left;
      }
    }, 1000);
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.langChangedHandler);
    stateEvent().on(StateEvents.UI_BACK, this.onUiBack);
    this.reloadThemeExtras();
    // 注意：字号要按横/竖屏各自的 key 读，必须等 isLandscape 确定之后再 reload。
    // 原来放在这里（方向确定前）会用默认 false 误读竖屏 key，导致横屏字号调节「没变化」。
    stateEvent().on(StateEvents.CONFIG_UPDATED, this.configChangedHandler);
    try {
      this.mqListener = mediaquery.matchMediaSync('(orientation: landscape)');
      this.isLandscape = this.mqListener.matches;
      this.reloadLyricStyle();
      this.mqListener.on('change', (r: mediaquery.MediaQueryResult): void => {
        this.isLandscape = r.matches;
        // 横竖屏各有独立字号设置，转屏后需重新取
        this.reloadLyricStyle();
      });
    } catch (e) {
      this.isLandscape = false;
      this.reloadLyricStyle();
    }
  }

  aboutToDisappear(): void {
    // 退出播放页时恢复全局方向设定（自动旋转只作用于播放页）
    this.restoreGlobalOrientation();
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.langChangedHandler);
    stateEvent().off(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().off(StateEvents.CONFIG_UPDATED, this.configChangedHandler);
    if (this.timerTicker >= 0) {
      clearInterval(this.timerTicker);
      this.timerTicker = -1;
    }
    if (this.tipTimer >= 0) {
      clearTimeout(this.tipTimer);
      this.tipTimer = -1;
    }
    if (this.mqListener !== null) {
      this.mqListener.off('change');
      this.mqListener = null;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 动态背景：当前封面模糊铺底（开关开启 + 有封面 + 未在深色下隐藏）
      if (this.showDynamicBg()) {
        // 走 CoverCache：同一张封面在列表里下过就不必再走网络（本地歌走 file:// 直读）
        CoverImage({
          url: this.coverUrl(),
          theme: this.theme,
          radius: 0,
          blurRadius: this.bgBlur(),
          opacityValue: 0.4,
          transparentBg: true,
          showPlaceholder: false,
        })
      }
      Column() {
        // Header：返回 + 歌名/歌手 + 更多
        Row() {
          Button() {
            Image($r('app.media.ic_back')).width(24).height(24).fillColor(this.theme.font)
          }
            .type(ButtonType.Normal).width(40).height(40)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.showDetail = false; })
          if (this.isLandscape) {
            // 横屏：歌名/歌手留在标题栏，但整体左移到封面中轴线（约屏宽 25%）
            Column() {
              Text(this.snapshot.musicInfo === null ? this.tx('no_playing') : this.snapshot.musicInfo.name)
                .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.snapshot.musicInfo === null ? '' : this.snapshot.musicInfo.singer)
                .fontSize(11).fontColor(buildPalette(this.theme).subText).margin({ top: 2 })
            }
            .width('40%')
            .alignItems(HorizontalAlign.Center)
            Blank()
          } else {
            Column() {
              Text(this.snapshot.musicInfo === null ? this.tx('no_playing') : this.snapshot.musicInfo.name)
                .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.snapshot.musicInfo === null ? '' : this.snapshot.musicInfo.singer)
                .fontSize(11).fontColor(buildPalette(this.theme).subText).margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Blank()
            // 图标顺序（左→右）：收藏 → 歌词 → 唱片 → 自动旋转 → 定时停止
            // 1. 收藏：空心/实心心形，随主题染色
            Button() {
              Image(this.snapshot.isFavorite ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart'))
                .width(22).height(22).fillColor(this.theme.primary)
            }
              .type(ButtonType.Normal).width(40).height(40)
              .backgroundColor(Color.Transparent).stateEffect(false)
              .onClick((): void => { this.controller.toggleFavorite(); })
            // 2. 系统歌词：关闭用带斜杠 LRC（灰），打开用 LRC（主题色）
            Button() {
              Image(this.lyricFloatOn ? $r('app.media.ic_lyric') : $r('app.media.ic_lyric_off'))
                .width(22).height(22)
                .fillColor(this.lyricFloatOn ? this.theme.primary : buildPalette(this.theme).subText)
            }
              .type(ButtonType.Normal).width(40).height(40)
              .backgroundColor(Color.Transparent).stateEffect(false)
              .onClick((): void => {
                const on = !this.lyricFloatOn;
                this.settings.set('desktopLyric.enable', on);
                this.lyricFloatOn = on;
                this.controller.refreshSystemLyric();
              })
            // 3. 唱片（自动匹配歌词和封面）：按「歌名 + 歌手 + 时长」找同一首，
            // 命中后用那个源的封面和歌词。进行中显示转圈，连点不叠加请求。
            Button() {
              if (this.matching || this.snapshot.mediaMatching) {
                LoadingProgress().width(20).height(20).color(this.theme.primary)
              } else {
                Image($r('app.media.ic_disc'))
                  .width(22).height(22)
                  .fillColor(this.coverUrl().length > 0 ? this.theme.primary : buildPalette(this.theme).subText)
              }
            }
              .type(ButtonType.Normal).width(40).height(40)
              .backgroundColor(Color.Transparent).stateEffect(false)
              .onClick((): void => { void this.doRematch(); })
            // 4. 自动旋转：开启后播放页跟随手机方向切横竖屏（仅作用于播放页，退出恢复竖屏）
            Button() {
              Image($r('app.media.ic_auto_rotate'))
                .width(26).height(26)
                .fillColor(this.autoRotateOn ? this.theme.primary : buildPalette(this.theme).subText)
            }
              .type(ButtonType.Normal).width(40).height(40)
              .backgroundColor(Color.Transparent).stateEffect(false)
              .onClick((): void => { this.toggleAutoRotate(); })
            // 5. 定时停止：未启用灰色；启用后图标内显示分钟数、转主题色。
            // 点按 15→30→…→120→15 循环；长按打开定时面板（含关闭选项）。
            Button() {
              Stack() {
                Image($r('app.media.ic_timer_stop'))
                  .width(24).height(24)
                  .fillColor(this.timerMin > 0 ? this.theme.primary : buildPalette(this.theme).subText)
                if (this.timerMin > 0) {
                  Row()
                    .width(15).height(15)
                    .borderRadius(8)
                    .backgroundColor(this.theme.mainBackground)
                  Text(this.timerMin.toString())
                    .fontSize(this.timerMin >= 100 ? 6 : 8)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.theme.primary)
                    .textAlign(TextAlign.Center)
                }
              }
              .width(28).height(28)
            }
              .type(ButtonType.Normal).width(40).height(40)
              .backgroundColor(Color.Transparent).stateEffect(false)
              .onClick((): void => {
                const m = this.controller.cycleTimeoutExit();
                this.timerMin = m;
                this.timerRemain = m * 60 * 1000;
              })
              .gesture(
                LongPressGesture({ duration: LONG_PRESS_DURATION_MS }).onAction((): void => { this.showMore = true; })
              )
          }
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8 })

        if (this.isLandscape) {
          // 横屏：左半屏「封面 + 右侧竖排图标 + 播控」，右半屏歌词
          Row() {
            Column() {
              // 封面区：封面铺满左半屏并水平居中（按封面区域中轴线）；
              // 图标列改用 Stack 叠在右侧，不再占据封面宽度把封面挤偏
              Stack() {
                Column() {
                  this.CoverPage()
                }
                .width('100%')
                .height('100%')
                this.LandscapeIcons()
              }
              .width('100%')
              .layoutWeight(1)
              this.Controls()
            }
            .width('50%')
            .height('100%')
            Column() {
              this.LyricPage()
            }
            .layoutWeight(1)
            .height('100%')
          }
          .width('100%')
          .layoutWeight(1)
          // 横竖布局切换淡入，配合系统窗口旋转转场，视觉更顺滑
          .transition(TransitionEffect.OPACITY.animation({ duration: 240, curve: Curve.EaseInOut }))
        } else {
          // 竖屏：3 页横滑（封面 / 歌词 / 歌曲信息）
          Swiper() {
            this.CoverPage()
            this.LyricPage()
            SongInfoPageCard()
          }
          .index(this.pageIndex)
          .indicator(true)
          .loop(false)
          .duration(220)
          .layoutWeight(1)
          .width('100%')
          .onChange((idx: number): void => { this.pageIndex = idx; })
          // 横竖布局切换淡入，配合系统窗口旋转转场，视觉更顺滑
          .transition(TransitionEffect.OPACITY.animation({ duration: 240, curve: Curve.EaseInOut }))
        }

        // 竖屏：播控固定在页面底部、整屏宽（横屏已移进左半屏，与封面同宽）
        if (!this.isLandscape) {
          this.Controls()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.mainBackground)

      // 手势反馈浮层：音量条 / 播放暂停提示（不参与点击，避免挡住下层手势）
      if (this.tipVol >= 0 || this.tipText.length > 0) {
        Column() {
          Column() {
            if (this.tipVol >= 0) {
              Text(this.tipVol <= 0
                ? this.tx('vol_mute')
                : (this.tx('vol_prefix') + ' ' + this.tipVol.toString() + '%'))
                .fontSize(12).fontColor('#FFFFFF')
              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width(this.tipVol.toString() + '%')
                  .height(3)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(2)
              }
              .width(120)
              .height(3)
              .backgroundColor('#59FFFFFF')
              .borderRadius(2)
              .margin({ top: 7 })
            } else {
              Text(this.tipText).fontSize(12).fontColor('#FFFFFF')
            }
          }
          .padding({ left: 18, right: 18, top: 9, bottom: 9 })
          .backgroundColor('#B3000000')
          .borderRadius(12)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 96 })
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.showMore) {
        // 遮罩：点击任意空白处收起
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.showMore = false; })

        this.MorePanel()
      }

      if (this.showQueue) {
        QueuePanel({
          show: this.showQueue,
          theme: this.theme,
          listName: this.snapshot.listName,
          tick: this.queueTick,
          landscape: this.isLandscape,
        })
      }

      // 下载音质弹窗：盖在最上层，选好音质后入队
      if (isDownloadEnabled() && this.downloadQualities.length > 0 && this.snapshot.musicInfo !== null) {
        DownloadQualityPicker({
          qualities: this.downloadQualities,
          theme: this.theme,
          onPick: (q: Quality): void => {
            const info = this.snapshot.musicInfo;
            this.downloadQualities = [];
            if (info !== null) {
              DownloadManager.getInstance().enqueue(info, q);
            }
          },
          onClose: (): void => { this.downloadQualities = []; },
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 点下载：先算可用音质，多于一种弹窗让用户挑，只有一种直接下载（与歌单页一致） */
  /**
   * 把窗口方向切到「跟随重力全方向」。AUTO_ROTATION 让横竖屏随手机物理方向变化，
   * mediaquery 监听随之驱动播放页在横/竖布局间切换（系统自带丝滑旋转转场动画）。
   */
  private applyPlayOrientation(): void {
    if (!this.autoRotateOn) {
      return;
    }
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window): void => {
        win.setPreferredOrientation(window.Orientation.AUTO_ROTATION)
          .catch((): void => { /* 方向切换失败时忽略，保持当前方向 */ });
      }).catch((): void => { /* 取不到窗口时忽略 */ });
    } catch (e) {
      // 同步异常（无上下文等）忽略
    }
  }

  /**
   * 退出播放页时恢复全局方向设定：自动旋转只作用于播放页。
   * 全局「强制横屏」开着就回 AUTO_ROTATION_LANDSCAPE，否则回 PORTRAIT。
   */
  private restoreGlobalOrientation(): void {
    if (!this.autoRotateOn) {
      return;
    }
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window): void => {
        const forceLandscape: boolean = this.settings.getBoolean('common.forceLandscape', false);
        const target: window.Orientation = forceLandscape
          ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT;
        win.setPreferredOrientation(target)
          .catch((): void => { /* 恢复失败时忽略，下次启动 EntryAbility 会按设置重应用 */ });
      }).catch((): void => { /* 取不到窗口时忽略 */ });
    } catch (e) {
      // 同步异常忽略
    }
  }

  /** 切换自动旋转开关：持久化 + 立即应用/恢复方向 */
  private toggleAutoRotate(): void {
    const on: boolean = !this.autoRotateOn;
    this.autoRotateOn = on;
    this.settings.set('player.autoRotate', on);
    if (on) {
      this.applyPlayOrientation();
    } else {
      this.restoreGlobalOrientation();
    }
  }

  /**
   * 「自动匹配歌词和封面」：按本协议的做法，用「歌名 + 歌手 + 时长」到各音源找同一首歌，
   * 命中后用那个源的封面（本地歌存进封面缓存）和歌词。结果用提示条说明，不做弹窗打断播放。
   * 播放时也会自动跑一次，所以这个按钮通常是「没匹配到之后手动重试」。
   */
  private async doRematch(): Promise<void> {
    if (this.matching || this.snapshot.mediaMatching) {
      return;
    }
    if (this.snapshot.musicInfo === null) {
      userNotice().info('当前没有正在播放的歌曲');
      return;
    }
    this.matching = true;
    try {
      const r: SongMatchResult = await this.controller.rematchCurrentMedia();
      if (!r.matched) {
        userNotice().info('没有搜到匹配的歌曲，可先在歌曲信息里修正歌名 / 歌手后再试');
        return;
      }
      const parts: string[] = [];
      parts.push(r.picOk ? '封面已更新' : '封面没取到');
      parts.push(r.lyricOk ? '歌词已匹配' : '歌词没找到');
      userNotice().info(parts.join('，') + '：' + r.name + ' - ' + r.singer + '（' + r.sourceLabel + '）');
    } finally {
      this.matching = false;
    }
  }

  private openDownload(): void {
    const info = this.snapshot.musicInfo;
    if (info === null) {
      return;
    }
    const qs: Quality[] = availableDownloadQualities(info);
    if (qs.length <= 1) {
      DownloadManager.getInstance().enqueue(info, qs.length > 0 ? qs[0] : '128k');
      return;
    }
    this.downloadQualities = qs;
  }

  /**
   * 横屏封面边长（vp）：封面区域固定占左半屏，封面按屏高比例放大，
   * 夹在 120~210 之间，始终小于左栏留给封面的 62% 高度，不会顶到进度条。
   */
  private landscapeCoverSize(): string {
    const h: number = screenHeightVp();
    const s: number = Math.min(240, Math.max(130, h * 0.55));
    return s.toFixed(0) + 'vp';
  }

  /**
   * 横屏：封面右侧竖排图标列，从上到下依次为
   * 定时停止 / 唱片(自动匹配) / 自动旋转 / 歌词 / 收藏 / 播放模式 / 播放队列，间距均等。
   * 用 position 叠在封面区右缘，不占封面宽度——封面才能对齐中轴线。
   * 竖屏不使用——竖屏图标仍在标题栏与底部播控区。
   */
  @Builder
  LandscapeIcons() {
    Column() {
      // 1. 定时停止
      Button() {
        Stack() {
          Image($r('app.media.ic_timer_stop'))
            .width(20).height(20)
            .fillColor(this.timerMin > 0 ? this.theme.primary : buildPalette(this.theme).subText)
          if (this.timerMin > 0) {
            Text(this.timerMin.toString())
              .fontSize(this.timerMin >= 100 ? 6 : 8)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.primary)
              .textAlign(TextAlign.Center)
          }
        }
        .width(24).height(24)
      }
        .type(ButtonType.Normal).width(34).height(34)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => {
          const m = this.controller.cycleTimeoutExit();
          this.timerMin = m;
          this.timerRemain = m * 60 * 1000;
        })
        .gesture(
          LongPressGesture({ duration: LONG_PRESS_DURATION_MS }).onAction((): void => { this.showMore = true; })
        )

      // 2. 自动匹配歌词和封面（唱片图标，与竖屏标题栏同一个入口）
      Button() {
        if (this.matching || this.snapshot.mediaMatching) {
          LoadingProgress().width(18).height(18).color(this.theme.primary)
        } else {
          Image($r('app.media.ic_disc'))
            .width(20).height(20)
            .fillColor(this.coverUrl().length > 0 ? this.theme.primary : buildPalette(this.theme).subText)
        }
      }
        .type(ButtonType.Normal).width(34).height(34)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => { void this.doRematch(); })

      // 2.5 自动旋转：与竖屏同一开关，开启后播放页跟随手机方向切横竖屏
      Button() {
        Image($r('app.media.ic_auto_rotate'))
          .width(24).height(24)
          .fillColor(this.autoRotateOn ? this.theme.primary : buildPalette(this.theme).subText)
      }
        .type(ButtonType.Normal).width(34).height(34)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => { this.toggleAutoRotate(); })

      // 3. 歌词开关
      Button() {
        Image(this.lyricFloatOn ? $r('app.media.ic_lyric') : $r('app.media.ic_lyric_off'))
          .width(20).height(20)
          .fillColor(this.lyricFloatOn ? this.theme.primary : buildPalette(this.theme).subText)
      }
        .type(ButtonType.Normal).width(34).height(34)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => {
          const on = !this.lyricFloatOn;
          this.settings.set('desktopLyric.enable', on);
          this.lyricFloatOn = on;
          this.controller.refreshSystemLyric();
        })

      // 3. 收藏按钮
      Button() {
        Image(this.snapshot.isFavorite ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart'))
          .width(20).height(20).fillColor(this.theme.primary)
      }
        .type(ButtonType.Normal).width(34).height(34)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => { this.controller.toggleFavorite(); })

      // 4. 播放模式
      Button() {
        Image(this.modeIcon()).width(20).height(20).fillColor(this.theme.primary)
      }
        .type(ButtonType.Normal).width(34).height(34)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => {
          this.controller.togglePlayMode();
          this.modeKey = this.controller.getSnapshot().playMode;
        })

      // 5. 播放队列
      Button() {
        Image($r('app.media.ic_menu')).width(18).height(18).fillColor(this.theme.primary)
      }
        .type(ButtonType.Normal).width(34).height(34)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => {
          this.queueTick = this.queueTick + 1;
          this.showQueue = true;
        })
    }
    .width(40)
    .justifyContent(FlexAlign.SpaceEvenly)
    .height('100%')
    .position({ right: 0, top: 0 })
  }

  /**
   * 播控区（进度条 + 主控键 + 列表信息）。
   * 竖屏在页面底部、整屏宽；横屏放进左半屏，宽度与封面区域对齐，
   * 且只保留「上一首 / 播放 / 下一首」——模式与列表按钮已移到歌名行。
   */
  @Builder
  Controls() {
    Column() {
      // 进度条
      Row() {
        Text(formatTime(this.snapshot.nowPlayTime)).fontSize(11)
          .fontColor(buildPalette(this.theme).subText).width(42)
        Slider({
          value: this.snapshot.nowPlayTime,
          min: 0,
          max: this.snapshot.maxPlayTime > 0 ? this.snapshot.maxPlayTime : 24000,
          step: 1000,
          style: SliderStyle.OutSet,
        })
          .layoutWeight(1)
          .height(this.isLandscape ? 14 : 40)
          .selectedColor(this.theme.primary)
          .onChange((v: number, mode: SliderChangeMode): void => {
            if (mode === SliderChangeMode.End) {
              this.controller.seek(v);
            }
          })
        Text(formatTime(this.snapshot.maxPlayTime)).fontSize(11)
          .fontColor(buildPalette(this.theme).subText).width(42)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      if (this.isLandscape) {
        // 横屏任意控件：播控三键统一 30vp 图标 + 44vp 按钮，整块再压矮
        Row() {
          Button() {
            Image($r('app.media.ic_prev'))
              .width(30).height(30)
              .fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(46).height(44)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.controller.playPrev(); })
          Button() {
            Image(this.snapshot.isPlay ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
              .width(30).height(30)
              .fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(46).height(44)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.controller.togglePlay(); })
          Button() {
            Image($r('app.media.ic_next'))
              .width(30).height(30)
              .fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(46).height(44)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.controller.playNext(false); })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
        .margin({ top: 0 })

        Text(this.listInfoText())
          .fontSize(11)
          .fontColor(buildPalette(this.theme).subText)
          .margin({ top: 0, bottom: 0 })
      } else {
        // 竖屏：与改造前完全一致（模式 / 上一首 / 播放 / 下一首 / 列表）
        Row() {
          Button() {
            Image(this.modeIcon()).width(26).height(26).fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(56).height(44)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => {
              this.controller.togglePlayMode();
              this.modeKey = this.controller.getSnapshot().playMode;
            })
          Button() {
            Image($r('app.media.ic_prev'))
              .width(36).height(36)
              .fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(60).height(60)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.controller.playPrev(); })
          Button() {
            Image(this.snapshot.isPlay ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
              .width(50).height(50)
              .fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(76).height(76)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.controller.togglePlay(); })
          Button() {
            Image($r('app.media.ic_next'))
              .width(36).height(36)
              .fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(60).height(60)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => { this.controller.playNext(false); })
          Button() {
            Image($r('app.media.ic_menu')).width(20).height(20).fillColor(this.theme.primary)
          }
            .type(ButtonType.Normal).width(56).height(44)
            .backgroundColor(Color.Transparent).stateEffect(false)
            .onClick((): void => {
              this.queueTick = this.queueTick + 1;
              this.showQueue = true;
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
        .margin({ top: 6 })

        Text(this.listInfoText())
          .fontSize(11)
          .fontColor(buildPalette(this.theme).subText)
          .margin({ top: 4, bottom: 8 })
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: this.isLandscape ? 0 : 6 })
  }

  @Builder
  CoverPage() {
    Column() {
      Stack() {
        if (this.coverUrl().length > 0) {
          CoverImage({
            url: this.coverUrl(), fallbackUrl: this.coverUrlFallback(), theme: this.theme, radius: 18,
            placeholder: $r('app.media.ic_music'), placeholderSize: 80,
          })
        } else {
          Image($r('app.media.ic_music')).width(80).height(80).fillColor('#FFFFFF')
        }
      }
      .width(this.isLandscape ? this.landscapeCoverSize() : '72%')
      .aspectRatio(1)
      .borderRadius(18)
      .backgroundColor(this.theme.primary)
      .margin({ top: this.isLandscape ? 4 : 20 })
      // 横屏：封面下方不再重复显示歌名/歌手（已移到顶部标题栏）；竖屏保留原样
      if (!this.isLandscape) {
        Text(this.snapshot.musicInfo === null ? '' : this.snapshot.musicInfo.name)
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 22 })
        Text(this.snapshot.musicInfo === null ? '' : this.snapshot.musicInfo.singer)
          .fontSize(13).fontColor(buildPalette(this.theme).subText)
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 封面手势：上下滑调音量，双击播放/暂停。
    // 用 Parallel 组合，两者互不抢占；Swiper 只认横向，不会和竖向 Pan 打架。
    .gesture(
      GestureGroup(GestureMode.Parallel,
        TapGesture({ count: 2 })
          .onAction((): void => {
            const wasPlaying = this.snapshot.isPlay;
            this.controller.togglePlay();
            this.flashTip(wasPlaying ? this.tx('tip_paused') : this.tx('tip_playing'));
          }),
        PanGesture({ direction: PanDirection.Vertical, distance: 8 })
          .onActionStart((): void => {
            this.volBase = this.controller.getVolume();
          })
          .onActionUpdate((e: GestureEvent): void => {
            if (this.volBase < 0) {
              this.volBase = this.controller.getVolume();
            }
            // 420px 覆盖 0–100%，上滑变大、下滑变小
            let v: number = this.volBase - e.offsetY / 420;
            v = v < 0 ? 0 : (v > 1 ? 1 : v);
            this.controller.setVolume(v, false);
            this.showVolume(Math.round(v * 100));
          })
          .onActionEnd((): void => {
            this.controller.setVolume(this.controller.getVolume(), true);
            this.volBase = -1;
            this.hideTipSoon(900);
          })
          .onActionCancel((): void => {
            this.volBase = -1;
            this.hideTipSoon(900);
          })
      )
    )
  }

  /** 显示音量浮层（滑动过程中持续刷新，结束后淡出） */
  private showVolume(pct: number): void {
    this.tipText = '';
    this.tipVol = pct;
    if (this.tipTimer >= 0) {
      clearTimeout(this.tipTimer);
      this.tipTimer = -1;
    }
  }

  /** 显示一次性文字提示（双击播放/暂停） */
  private flashTip(text: string): void {
    this.tipVol = -1;
    this.tipText = text;
    this.hideTipSoon(1000);
  }

  private hideTipSoon(delay: number): void {
    if (this.tipTimer >= 0) {
      clearTimeout(this.tipTimer);
    }
    this.tipTimer = setTimeout((): void => {
      this.tipVol = -1;
      this.tipText = '';
      this.tipTimer = -1;
    }, delay);
  }

  /**
   * snapshot 每次刷新（进度、歌词行）都会触发；只有「当前行真的变了」才滚动，
   * 否则每秒一次的进度更新会把列表反复拽动。
   */
  private onSnapshotUpdated(): void {
    // 切歌：立即重置歌词滚动跟随，避免新歌沿用上一首的行号与滚动位置
    const id: string = this.snapshot.musicInfo === null ? '' : this.snapshot.musicInfo.id;
    if (id !== this.currentSongId) {
      this.currentSongId = id;
      this.lastScrolledLyric = -1;
      this.lyricUserTouchAt = 0;
      try {
        this.lyricScroller.scrollToIndex(0);
      } catch (e) {
        // 列表尚未渲染时忽略
      }
    }
    if (this.modeKey !== this.snapshot.playMode) {
      this.modeKey = this.snapshot.playMode;
    }
    const idx: number = this.snapshot.activeLyricIndex;
    if (idx < 0) {
      // 切歌或前奏：行号回 -1，重置跟随状态并回到顶部
      if (this.lastScrolledLyric !== -1) {
        this.lastScrolledLyric = -1;
        try {
          this.lyricScroller.scrollToIndex(0);
        } catch (e) {
          // 列表尚未渲染时忽略
        }
      }
      return;
    }
    if (idx === this.lastScrolledLyric) {
      return;
    }
    if (Date.now() - this.lyricUserTouchAt < 5000) {
      return;
    }
    this.lastScrolledLyric = idx;
    try {
      this.lyricScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    } catch (e) {
      // 滚动失败不影响播放
    }
  }

  @Builder
  LyricPage() {
    Column() {
      if (this.snapshot.lyricLines.length === 0) {
        Text(this.tx('no_lyric')).fontSize(14).fontColor(buildPalette(this.theme).subText)
      } else {
        // 用 List 而不是 Scroll：自动跟随要靠 scrollToIndex，List 天然按下标定位，
        // 也不怕行高随字号 / 翻译行 / 逐字高亮变化。
        List({ scroller: this.lyricScroller }) {
          ForEach(this.snapshot.lyricLines, (line: LyricLine, idx: number): void => {
            ListItem() {
              Column() {
                if (idx === this.snapshot.activeLyricIndex && this.snapshot.lyricWords.length > 0) {
                  // 逐字高亮：已唱到的字用主题色加粗，未唱到的用暗色（卡拉OK式）
                  Row() {
                    ForEach(this.snapshot.lyricWords, (w: LyricWord, wi: number): void => {
                      Text(s2t(w.text, this.s2tOn))
                        .fontSize(this.lyricSize())
                        .fontColor(wi <= this.snapshot.activeWordIndex ? this.theme.primary : buildPalette(this.theme).subText)
                        .fontWeight(wi <= this.snapshot.activeWordIndex ? FontWeight.Bold : FontWeight.Normal)
                        .textShadow(this.lyricShadow())
                    }, (w: LyricWord, wi: number): string => wi.toString())
                  }
                  .width('100%')
                  .justifyContent(this.lyricFlex())
                  .margin({ top: this.isLandscape ? 8 : 16, bottom: this.isLandscape ? 6 : 10 })
                } else {
                  Text(s2t(line.text, this.s2tOn))
                    .fontSize(idx === this.snapshot.activeLyricIndex ? this.lyricSize() : this.lyricSubSize())
                    .fontColor(idx === this.snapshot.activeLyricIndex ? this.theme.primary : buildPalette(this.theme).subText)
                    .fontWeight(idx === this.snapshot.activeLyricIndex ? FontWeight.Bold : FontWeight.Normal)
                    .textAlign(this.lyricTextAlign())
                    .width('100%')
                    .textShadow(this.lyricShadow())
                    .margin({ top: this.isLandscape ? 8 : 16, bottom: this.isLandscape ? 6 : 10 })
                }
                if (line.translation !== undefined && line.translation.length > 0) {
                  Text(s2t(line.translation, this.s2tOn)).fontSize(this.lyricTransSize()).fontColor(buildPalette(this.theme).subText).textAlign(this.lyricTextAlign()).width('100%')
                    .textShadow(this.lyricShadow())
                }
              }
              .width('100%')
              .onClick((): void => {
                if (this.settings.getBoolean('playDetail.isShowLyricProgressSetting', false)) {
                  this.controller.seek(line.time);
                }
              })
            }
            .width('100%')
          }, (line: LyricLine, idx: number): string => idx.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ top: this.isLandscape ? 8 : 20, bottom: this.isLandscape ? 16 : 40 })
        .onTouch((e: TouchEvent): void => {
          // 用户手动滑动歌词后 5 秒内不自动跟随，避免边看边被拽回
          if (e.type === TouchType.Down) {
            this.lyricUserTouchAt = Date.now();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20 })
    .justifyContent(FlexAlign.Center)
  }


  /**
   * 定时面板（长按定时图标打开）：关闭 / 15~120 分钟 + 剩余时间。
   * 系统歌词开关已移到 Header 下载按钮旁，不再放在这里。
   */
  @Builder
  MorePanel() {
    Column() {
      Row() {
        Text(this.tx('more_title'))
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
        Blank()
        Button() { Image($r('app.media.ic_close')).width(18).height(18).fillColor(buildPalette(this.theme).subText) }
          .type(ButtonType.Normal).width(32).height(32)
          .backgroundColor(Color.Transparent).stateEffect(false)
          .onClick((): void => { this.showMore = false; })
      }
      .width('100%')
      .margin({ bottom: 10 })

      Row() {
        Image($r('app.media.ic_timer_stop')).width(18).height(18)
          .fillColor(this.theme.primary).margin({ right: 6 })
        Text(this.tx('timer_title'))
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.theme.primary)
      }
      .width('100%').margin({ bottom: 8 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(TIMER_OPTIONS, (m: number): void => {
          Text(m === 0 ? this.tx('timer_off') : (m.toString() + ' ' + this.tx('min_unit')))
            .fontSize(12)
            .fontColor(this.timerMin === m ? '#FFFFFF' : buildPalette(this.theme).pillText)
            .backgroundColor(this.timerMin === m ? this.theme.primary : buildPalette(this.theme).pillBg)
            .borderRadius(14)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: 8, bottom: 8 })
            .onClick((): void => {
              this.timerMin = m;
              this.controller.setTimeoutExit(m);
              this.timerRemain = m > 0 ? m * 60 * 1000 : 0;
            })
        }, (m: number): string => 'timer_' + m.toString())
      }
      .width('100%')

      if (this.timerRemain > 0) {
        Row() {
          Image($r('app.media.ic_timer_stop')).width(14).height(14)
            .fillColor(this.theme.primary).margin({ right: 5 })
          Text(this.tx('timer_prefix') + ' ' + this.formatRemain(this.timerRemain))
            .fontSize(12).fontColor(this.theme.primary)
        }
        .width('100%').margin({ top: 2 })
      }
      Text(this.tx('timer_desc'))
        .fontSize(10).fontColor(buildPalette(this.theme).subText)
        .width('100%').margin({ top: 6 })
      Text(this.tx('gesture_hint'))
        .fontSize(10).fontColor(buildPalette(this.theme).subText)
        .width('100%').margin({ top: 2 })

      Text('点按定时图标按 15 分钟递增至 120 后循环，长按可打开本面板关闭定时')
        .fontSize(10).fontColor(buildPalette(this.theme).subText)
        .width('100%').margin({ top: 8 })
    }
    .width(300)
    .padding(14)
    .backgroundColor(buildPalette(this.theme).card)
    .borderRadius(16)
    .border({ width: 1, color: buildPalette(this.theme).divider })
    .shadow({ radius: 18, color: '#33000000', offsetX: 0, offsetY: 8 })
    .margin({ top: 56, right: 12 })
  }

  /** 底部信息行：列表名 · 首数（+ 定时剩余 / 渐弱状态） */
  private listInfoText(): string {
    const base = this.snapshot.listName + ' · ' + this.snapshot.listCount.toString() + ' ' + this.tx('unit_song');
    if (this.timerRemain > 0) {
      let s: string = base + '  ·  ' + this.tx('timer_prefix') + ' ' + this.formatRemain(this.timerRemain);
      if (this.controller.isFading()) {
        s = s + ' · ' + this.tx('fading');
      }
      return s;
    }
    return base;
  }

  /** 剩余毫秒 → mm:ss / h:mm:ss */
  private formatRemain(ms: number): string {
    const total = Math.ceil(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const p = (n: number): string => (n < 10 ? '0' : '') + n.toString();
    return h > 0 ? h.toString() + ':' + p(m) + ':' + p(s) : p(m) + ':' + p(s);
  }

  /** 定时按钮状态：以控制器里真实生效的定时器为准，避免重启后误显示上次设置 */
  private reloadTimerState(): void {
    this.timerMin = this.controller.getTimeoutExitMinutes();
    this.timerRemain = this.controller.getTimeoutExitRemainMs();
  }

  /** 系统歌词开关状态（设置页也能改，统一从 SettingStore 读） */
  private reloadLyricFloat(): void {
    this.lyricFloatOn = this.settings.getBoolean('desktopLyric.enable', false);
  }

  /** 读取主题增强三项（动态背景 / 深色隐藏背景 / 歌词字体阴影） */
  private reloadThemeExtras(): void {
    this.dynamicBg = this.settings.getBoolean('theme.dynamicBg', false);
    this.hideBgDark = this.settings.getBoolean('theme.hideBgDark', false);
    this.fontShadow = this.settings.getBoolean('theme.fontShadow', false);
  }

  /** 读取歌词字号（横竖屏各自独立）/ 对齐 / 简繁开关 */
  private reloadLyricStyle(): void {
    const key: string = this.isLandscape
      ? 'playDetail.horizontal.style.lrcFontSize'
      : 'playDetail.vertical.style.lrcFontSize';
    this.lyricPct = this.settings.getNumber(key, this.isLandscape ? 220 : 210);
    this.lyricAlignStr = this.settings.getString('playDetail.style.align', 'center');
    this.s2tOn = this.settings.getBoolean('player.isS2t', false);
    this.bgBlurVal = this.settings.getNumber('player.lockScreenBlur', 80);
  }

  /** 背景模糊像素：0–100 映射到 0–60px（默认 80 → 48，与旧固定值 50 观感一致） */
  private bgBlur(): number {
    const v: number = this.bgBlurVal;
    if (v <= 0) {
      return 0;
    }
    return Math.round(v * 0.6);
  }

  /** 当前歌词字号：基准 8px × 百分比（210% → 17px，与旧版写死值一致） */
  private lyricSize(): number {
    const px: number = Math.round(8 * this.lyricPct / 100);
    return px < 9 ? 9 : (px > 40 ? 40 : px);
  }

  /** 非当前行字号（旧版为当前行的 0.82 倍） */
  private lyricSubSize(): number {
    const px: number = Math.round(this.lyricSize() * 0.82);
    return px < 8 ? 8 : px;
  }

  /** 翻译行字号（旧版为当前行的 0.71 倍） */
  private lyricTransSize(): number {
    const px: number = Math.round(this.lyricSize() * 0.71);
    return px < 7 ? 7 : px;
  }

  private lyricTextAlign(): TextAlign {
    if (this.lyricAlignStr === 'left') {
      return TextAlign.Start;
    }
    if (this.lyricAlignStr === 'right') {
      return TextAlign.End;
    }
    return TextAlign.Center;
  }

  /** 逐字高亮用 Row 布局，对齐方式需转成 FlexAlign */
  private lyricFlex(): FlexAlign {
    if (this.lyricAlignStr === 'left') {
      return FlexAlign.Start;
    }
    if (this.lyricAlignStr === 'right') {
      return FlexAlign.End;
    }
    return FlexAlign.Center;
  }

  /** 当前歌曲封面 URL（清晰版）；与底部播控栏共用同一套解析，同一份磁盘缓存 */
  private coverUrl(): string {
    return resolveCoverUrlHd(this.snapshot.musicInfo);
  }

  /** 清晰版取不到时的兜底地址；正常情况不会用到 */
  private coverUrlFallback(): string {
    return resolveCoverUrl(this.snapshot.musicInfo);
  }

  /** 是否展示动态背景：开关开 + 有封面 + 未在「深色隐藏背景」下 */
  private showDynamicBg(): boolean {
    if (!this.dynamicBg) {
      return false;
    }
    if (this.hideBgDark && this.theme.isDark) {
      return false;
    }
    return this.coverUrl().length > 0;
  }

  /** 歌词/文字阴影：开启时按主题明暗给不同深浅，保证可读 */
  private lyricShadow(): ShadowOptions {
    if (!this.fontShadow) {
      return { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 };
    }
    const c: string = this.theme.isDark ? '#CC000000' : '#4D000000';
    return { radius: 4, color: c, offsetX: 0, offsetY: 1 };
  }

  /** i18n 取串（读 langTick 以在语言切换时重渲染） */
  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  /** 5 种播放模式各用一个不同图标，全部取自本协议 的 icomoon 图标库 */
  /** 4 态播放模式图标（与系统播控卡片的 loopMode 一一对应） */
  private modeIcon(): Resource {
    if (this.modeKey === 'random') { return $r('app.media.ic_mode_random'); }
    if (this.modeKey === 'list') { return $r('app.media.ic_mode_list_order'); }
    if (this.modeKey === 'singleLoop') { return $r('app.media.ic_mode_single_loop'); }
    return $r('app.media.ic_mode_list_loop');
  }
}

/**
 * 歌曲信息页（播放详情 Swiper 第三页）。
 *
 * 为什么改成本组件自驱动（不再用父组件 @Prop 传 music/maxTime/theme）：
 * Swiper 会缓存离屏子页，且对离屏的「自定义组件子页」不做细粒度 @Prop 同步，
 * 这正是此前两次修复（@Builder 内联 / 独立组件 + @Prop）切歌后第三页不刷新的根因——
 * 父组件把新 @Prop 传给离屏第三页时，ArkUI 不会触发其实例重渲染。
 *
 * 现在组件自己订阅事件，直接从单例读最新数据并用自身 @State 触发重渲染：
 *  - PLAY_MUSIC_INFO_CHANGED：每次切歌（播列表 / 上一首 / 下一首）都由 PlayQueue 广播；
 *  - THEME_UPDATED：主题变化时刷新配色。
 * 事件回调与 Swiper 离屏缓存无关，因此无论第三页是否处于前台都能实时更新。
 */
@Component
export struct SongInfoPageCard {
  @State music: MusicInfo | null = null;
  @State maxTime: number = 0;
  @State theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };

  /** 事件回调：用箭头函数属性固定 this，进出页面精确解绑，避免重复订阅 */
  private onMusicChanged: () => void = (): void => {
    const s = PlayController.getInstance().getSnapshot();
    this.music = s.musicInfo;
    this.maxTime = s.maxPlayTime;
  };
  private onThemeChanged: () => void = (): void => {
    this.theme = AppState.getInstance().theme;
  };

  aboutToAppear(): void {
    // 进入即先拉一次当前快照/主题，保证离屏首显也是最新值
    this.onMusicChanged();
    this.onThemeChanged();
    stateEvent().on(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onMusicChanged);
    stateEvent().on(StateEvents.THEME_UPDATED, this.onThemeChanged);
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onMusicChanged);
    stateEvent().off(StateEvents.THEME_UPDATED, this.onThemeChanged);
  }

  private tx(key: string): string {
    return I18n().t(key);
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(12).fontColor(buildPalette(this.theme).subText).width(70)
      Text(value).fontSize(12).fontColor(this.theme.font).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
    .border({ width: { bottom: 0.5 }, color: buildPalette(this.theme).divider })
  }

  build() {
    Column() {
      Text(this.tx('song_info'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
        .width('100%').textAlign(TextAlign.Start)
        .margin({ bottom: 14 })
      this.InfoRow(this.tx('field_name'), this.music === null ? '-' : this.music.name)
      this.InfoRow(this.tx('field_singer'), this.music === null ? '-' : this.music.singer)
      this.InfoRow(this.tx('field_album'), this.music === null ? '-' : this.music.meta.albumName)
      this.InfoRow(this.tx('field_source'), this.music === null ? '-' : this.music.source)
      // 时长优先用音源返回的格式化 interval（切歌即可用）；兜底用播放器 maxTime
      this.InfoRow(this.tx('field_duration'), this.durationText())
      this.InfoRow(this.tx('field_quality'), SettingStore.getInstance().getString('player.playQuality', '128k'))
      this.InfoRow(this.tx('field_format'), '-')
      this.InfoRow(this.tx('field_rate'), this.tx('unknown'))
      this.InfoRow(this.tx('field_depth'), this.tx('unknown'))
      this.InfoRow(this.tx('field_bitrate'), '-')
      this.InfoRow(this.tx('field_channel'), this.tx('unknown'))
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .justifyContent(FlexAlign.Center)
  }

  private durationText(): string {
    if (this.music !== null && this.music.interval !== null && this.music.interval.length > 0) {
      return this.music.interval;
    }
    return formatTime(this.maxTime);
  }
}
