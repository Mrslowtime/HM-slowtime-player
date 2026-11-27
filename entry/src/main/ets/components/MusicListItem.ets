/**
 * 通用歌曲行 —— 按本项目组件规范。
 * 交互：双击播放、长按进入多选、多选时单击切换选中；右侧显示音质 Badge、时长、更多按钮。
 */
import { MusicInfo, MusicInfoMetaLocal } from '../model/MusicTypes';
import { SOURCE_NAMES, SOURCE_ALIAS, isDownloadEnabled } from '../config/AppConstants';
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { LONG_PRESS_DURATION_MS } from '../config/GestureConfig';
import { setPopupAnchor } from '../core/Popup';
import { CoverImage } from './CoverImage';
import { resolveCoverUrl } from '../common/CoverUrl';

/** 双击判定窗口（毫秒）：两次按下间隔小于该值算双击 */
const DOUBLE_TAP_MS: number = 320;
/** 允许的抖动位移（vp）：超过即视为滑动列表，不响应点击/长按 */
const MOVE_TOLERANCE: number = 12;

@Component
export struct MusicListItem {
  @Prop music: MusicInfo = {
    id: '', name: '', singer: '', source: 'local', interval: null,
    meta: { songId: '', albumName: '', filePath: '', ext: '' },
  };
  @Prop index: number = 0;
  @Prop isActive: boolean = false;
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  @Prop showSource: boolean = true;
  @Prop showInterval: boolean = true;
  @Prop showAlbumName: boolean = false;
  /** 来源名展示方式：alias=短名（酷我）/ real=全名（酷我音乐） */
  @Prop sourceNameType: string = 'alias';
  /** 本地音乐：用封面替代序号（没有封面时仍显示序号） */
  @Prop showCover: boolean = false;
  /** 多选模式：左侧显示勾选框 */
  @Prop selecting: boolean = false;
  /** 本行是否选中（多选模式下高亮） */
  @Prop checked: boolean = false;
  /** 是否在时长后显示单曲下载按钮（仅在线歌曲、且父页面传了回调时显示） */
  @Prop showDownload: boolean = false;
  /** 单击（非双击）：多选模式下由页面切换选中，非多选模式不做播放 */
  onItemClick: (index: number) => void = () => {};
  /** 双击：播放该歌曲 */
  onItemDoubleClick: (index: number) => void = () => {};
  /** 长按：进入多选并选中该行 */
  onItemLongPress: (index: number) => void = () => {};
  onMoreClick: (index: number) => void = () => {};
  /** 单曲下载：由父页面决定直接下载还是弹出音质选择 */
  onDownloadClick: (index: number) => void = () => {};

  /**
   * 横屏（平板横屏 / 手机强制横屏）时可用高度只有竖屏一半，
   * 行高与字号同步收紧，一屏能多显示 2~3 首；竖屏保持原样。
   */
  @StorageProp('screenCompact') private compact: boolean = false;

  /**
   * 触摸判定：区分「单击 / 双击 / 长按 / 滑动」。
   *
   * 列表惯性滚动时手指按下去（刹车）不能算点击，所以用位移 + 时长判定：
   *  - 位移 > 12vp：滑动，不做任何响应；
   *  - 按住 > LONG_PRESS_DURATION_MS(260ms) 且未滑动：长按 → 进入多选；
   *  - 抬起时距上次点击 ≤ 320ms：双击 → 播放；
   *  - 否则：单击 → 交给页面（多选切换，普通状态下不播放）。
   */
  private downX: number = 0;
  private downY: number = 0;
  private dragMoved: boolean = false;
  /** 本次触摸已由 onTouch 处理，需吃掉系统随后派发的 click */
  private touchHandled: boolean = false;
  /** 长按已触发，抬起时不再算点击 */
  private longPressed: boolean = false;
  private pressTimer: number = -1;
  private lastTapAt: number = 0;
  private lastTapIndex: number = -1;

  aboutToDisappear(): void {
    this.clearPressTimer();
  }

  private clearPressTimer(): void {
    if (this.pressTimer >= 0) {
      clearTimeout(this.pressTimer);
      this.pressTimer = -1;
    }
  }

  private handleTouch(e: TouchEvent): void {
    const list: TouchObject[] = e.changedTouches.length > 0 ? e.changedTouches : e.touches;
    if (list.length === 0) {
      return;
    }
    const p: TouchObject = list[0];
    if (e.type === TouchType.Down) {
      this.downX = p.windowX;
      this.downY = p.windowY;
      this.dragMoved = false;
      this.longPressed = false;
      this.touchHandled = true;
      this.clearPressTimer();
      this.pressTimer = setTimeout((): void => {
        this.pressTimer = -1;
        if (this.dragMoved) {
          return;
        }
        this.longPressed = true;
        this.onItemLongPress(this.index);
      }, LONG_PRESS_DURATION_MS);
      return;
    }
    const dx: number = Math.abs(p.windowX - this.downX);
    const dy: number = Math.abs(p.windowY - this.downY);
    if (e.type === TouchType.Move) {
      if (dx > MOVE_TOLERANCE || dy > MOVE_TOLERANCE) {
        this.dragMoved = true;
        this.clearPressTimer();
      }
      return;
    }
    if (e.type === TouchType.Up) {
      this.clearPressTimer();
      if (this.longPressed || this.dragMoved || dx > MOVE_TOLERANCE || dy > MOVE_TOLERANCE) {
        this.longPressed = false;
        return;
      }
      const now: number = Date.now();
      if (now - this.lastTapAt <= DOUBLE_TAP_MS && this.lastTapIndex === this.index) {
        this.lastTapAt = 0;
        this.lastTapIndex = -1;
        this.onItemDoubleClick(this.index);
        return;
      }
      this.lastTapAt = now;
      this.lastTapIndex = this.index;
      this.onItemClick(this.index);
      return;
    }
    if (e.type === TouchType.Cancel) {
      this.clearPressTimer();
      this.dragMoved = true;
      this.longPressed = false;
    }
  }

  /**
   * 本地歌曲封面 URI（在线歌返回空串，走原序号显示）。
   * 本地扫描给的是同目录图片的 file://，用户手动编辑时也可能填网络地址，
   * 两种都放行：file:// 直接显示，http(s) 走 CoverCache（有缓存、按需压缩）。
   */
  private coverUri(): string {
    if (this.music.source !== 'local') {
      return '';
    }
    // 走统一解析：本地歌会按文件路径查同目录图与封面缓存，
    // 不依赖这个对象（下载列表 / 我的列表里的旧对象）有没有写 picUrl
    const url: string = resolveCoverUrl(this.music);
    if (url.indexOf('file://') === 0 || url.indexOf('http://') === 0 || url.indexOf('https://') === 0) {
      return url;
    }
    return '';
  }

  /** 按设置返回来源标签文案 */
  private sourceLabel(): string {
    const key: string = this.music.source;
    const real: string = SOURCE_NAMES[key] ?? key;
    if (this.sourceNameType === 'real') {
      return real;
    }
    return SOURCE_ALIAS[key] ?? real;
  }

  build() {
    Row() {
      // 多选模式：勾选框替换序号，选中行整行高亮
      if (this.selecting) {
        Row() {
          Image(this.checked ? $r('app.media.ic_check') : $r('app.media.ic_checkbox_empty'))
            .width(20).height(20)
            .fillColor(this.checked ? this.theme.primary : buildPalette(this.theme).subText)
        }
        .width(30)
        .justifyContent(FlexAlign.Center)
      } else if (this.showCover && this.coverUri().length > 0) {
        // 本地音乐封面：同目录同名图片 / cover.jpg（扫描时已解析成 file:// URI），
        // 也兼容用户在「编辑歌曲信息」里填的网络封面
        CoverImage({ url: this.coverUri(), theme: this.theme, radius: 5, placeholderSize: 20 })
          .width(this.compact ? 32 : 38).height(this.compact ? 32 : 38)
          .margin({ right: 2 })
      } else if (this.isActive) {
        // 序号 / 播放中标记：用 APK 的圆角三角播放键（空心描边），替代 logo 占位
        Image($r('app.media.ic_play_outline')).width(18).height(18).fillColor(this.theme.primary)
      } else {
        Text((this.index + 1).toString())
          .fontSize(13)
          .fontColor(buildPalette(this.theme).subText)
          .width(30)
          .textAlign(TextAlign.Center)
      }

      Column() {
        Text(this.music.name)
          .fontSize(this.compact ? 14 : 15)
          .fontColor((this.isActive || this.checked) ? this.theme.primary : this.theme.font)
          .fontWeight((this.isActive || this.checked) ? FontWeight.Bold : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          if (this.showSource) {
            Text(this.sourceLabel())
              .fontSize(10)
              .fontColor('#FFFFFF')
              .backgroundColor(this.theme.primary)
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ right: 5 })
          }
          Text(this.music.singer)
            .fontSize(12)
            .fontColor(buildPalette(this.theme).subText)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.showAlbumName && this.music.meta.albumName.length > 0) {
            Text(this.music.meta.albumName)
              .fontSize(11)
              .fontColor(buildPalette(this.theme).subText)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .margin({ top: this.compact ? 1 : 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.showInterval) {
        Text(this.music.interval ?? '--:--')
          .fontSize(11)
          .fontColor(buildPalette(this.theme).subText)
          .margin({ left: 6 })
      }
      // 单曲下载：放在时长与「⋮」之间，灰色托盘箭头图标，与本协议 一致
      // 下载功能总开关关闭时不渲染（源码保留，改 download.enable 即可恢复）
      if (isDownloadEnabled() && this.showDownload && this.music.source !== 'local') {
        Button() {
          Image($r('app.media.ic_download')).width(17).height(17).fillColor(buildPalette(this.theme).subText)
        }
        .type(ButtonType.Normal)
        .width(28).height(this.compact ? 34 : 40)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((): void => { this.onDownloadClick(this.index); })
      }
      Button() {
        Image($r('app.media.ic_more')).width(18).height(18).fillColor(buildPalette(this.theme).subText)
      }
      .type(ButtonType.Normal)
      .width(30).height(this.compact ? 34 : 40)
      .backgroundColor(Color.Transparent).stateEffect(false)
      .onClick((e: ClickEvent): void => {
        // 记录点击位置，让弹出的 ⋮ 菜单贴近本次点击处
        setPopupAnchor(e.windowX, e.windowY);
        this.onMoreClick(this.index);
      })
    }
    .width('100%')
    .height(this.compact ? 46 : 56)
    .padding({ left: 12, right: 8 })
    .backgroundColor((this.checked || this.isActive) ? buildPalette(this.theme).activeTint : Color.Transparent)
    .onTouch((e: TouchEvent): void => { this.handleTouch(e); })
    .onClick((): void => {
      // 触摸已在 onTouch 中处理（单击/双击/长按/滑动）→ 丢弃系统补发的 click；
      // 无障碍 / 键盘触发的 click 没有前置 Down，走这里按单击处理。
      if (this.touchHandled) {
        this.touchHandled = false;
        return;
      }
      this.onItemClick(this.index);
    })
  }
}
