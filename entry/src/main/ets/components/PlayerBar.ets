/**
 * 全局迷你播放栏 —— 按本项目组件规范。
 * 封面 / 歌名 / 歌手状态 / 播放暂停，点击标题进播放详情页；
 * 歌名歌手下方有一条进度条（只在封面与播放键之间，点击或拖动可跳转），
 * 不再横跨整屏，配色跟随主题主色。
 */
import { ControllerSnapshot } from '../player/PlayController';
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { formatTime } from '../store/AppState';
import { resolveCoverUrl, resolveCoverUrlHd } from '../common/CoverUrl';
import { CoverImage } from './CoverImage';

@Component
export struct PlayerBar {
  @Prop snapshot: ControllerSnapshot = {
    musicInfo: null, isPlay: false, nowPlayTime: 0, maxPlayTime: 0,
    playMode: 'listLoop', statusText: '', lyricLines: [], activeLyricIndex: -1,
    lyricWords: [], activeWordIndex: -1,
    listName: '我的歌单', listCount: 0, isFavorite: false, mediaMatching: false,
  };
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  onBarClick: () => void = () => {};
  onTogglePlay: () => void = () => {};
  onPrev: () => void = () => {};
  onNext: () => void = () => {};
  /** 进度条跳转（毫秒） */
  onSeek: (timeMs: number) => void = () => {};

  /** 拖动中的预览比例（0–1），-1 表示跟随实际播放进度 */
  @State private previewRatio: number = -1;
  /** 进度条容器宽度（vp），由 onAreaChange 量出，用来把点击坐标换算成比例 */
  @State private barW: number = 0;
  /** 横屏（矮屏）时整条收矮：高度、封面、按钮同步缩一档，竖屏不变 */
  @StorageProp('screenCompact') private compact: boolean = false;
  /** 拖动起点比例：PanGesture 只给相对位移，需要基准 */
  private dragStartRatio: number = 0;

  /** 当前封面（无封面返回空串，走占位图）；取清晰版，与播放页共用同一份缓存 */
  private cover(): string {
    return resolveCoverUrlHd(this.snapshot.musicInfo);
  }

  /** 封面边长：横屏矮屏缩一档，留出高度给列表 */
  private barCoverSize(): number {
    return this.compact ? 36 : 44;
  }

  /** 清晰版取不到时的兜底地址（原始小图），正常情况不会用到 */
  private coverFallback(): string {
    return resolveCoverUrl(this.snapshot.musicInfo);
  }

  /** 播放进度文案：已播放 / 歌曲总时长（如 02/03:45） */
  private timeText(): string {
    const now: string = formatTime(this.snapshot.nowPlayTime);
    const total: string = formatTime(this.snapshot.maxPlayTime);
    return now + '/' + total;
  }

  /** 进度条显示比例：拖动时用预览值，否则按播放进度 */
  private ratio(): number {
    if (this.previewRatio >= 0) {
      return this.previewRatio;
    }
    const max = this.snapshot.maxPlayTime;
    if (max <= 0) {
      return 0;
    }
    const p = this.snapshot.nowPlayTime / max;
    if (isNaN(p) || p < 0) {
      return 0;
    }
    return p > 1 ? 1 : p;
  }

  /** 把点击/拖动位置换算成毫秒并提交跳转 */
  private commitRatio(r: number): void {
    const max = this.snapshot.maxPlayTime;
    const ready = max > 0 && this.snapshot.musicInfo !== null;
    this.previewRatio = -1;
    if (!ready) {
      return;
    }
    let v = r;
    if (isNaN(v) || v < 0) {
      v = 0;
    }
    if (v > 1) {
      v = 1;
    }
    this.onSeek(Math.floor(max * v));
  }

  private ratioOf(x: number): number {
    const w = this.barW;
    if (w <= 0) {
      return 0;
    }
    let v = x / w;
    if (v < 0) {
      v = 0;
    }
    if (v > 1) {
      v = 1;
    }
    return v;
  }

  build() {
    Column() {
      Row() {
        // 封面：与播放详情页共用 resolveCoverUrl，实时跟随当前歌曲；
        // 没封面（或 URL 不可解析）时才用主题色 + 音符占位。
        if (this.cover().length > 0) {
          CoverImage({
            url: this.cover(), fallbackUrl: this.coverFallback(), theme: this.theme, radius: 8,
            placeholder: $r('app.media.ic_music'), placeholderSize: 24,
          })
            .width(this.barCoverSize()).height(this.barCoverSize())
        } else {
          Stack() {
            Image($r('app.media.ic_music'))
              .width(24).height(24)
              .fillColor('#FFFFFF')
          }
          .width(this.barCoverSize()).height(this.barCoverSize())
          .borderRadius(8)
          .clip(true)
          .backgroundColor(this.theme.primary)
        }

        Column() {
          Text(this.snapshot.musicInfo === null ? '慢时光音乐' : this.snapshot.musicInfo.name)
            .fontSize(14)
            .fontColor(this.theme.font)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.snapshot.musicInfo === null ? '暂无播放'
            : this.snapshot.musicInfo.singer + ' · ' + this.timeText())
            .fontSize(11)
            .fontColor(buildPalette(this.theme).subText)
            .maxLines(1)
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: 2 })

          // 进度条：夹在封面与播放键之间 —— 左端与上面的歌名/歌手对齐，
          // 右端直接贴播放键左边界；粗细取歌手文字高度量级（10vp），
          // 比原来横跨整屏的 2vp 细线明显得多，点击与拖动都更准。
          // 未播放部分不画底色（透明），只显示已播部分，避免出现一条灰带。
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width((this.ratio() * 100).toFixed(2) + '%')
              .height(this.compact ? 8 : 10)
              .borderRadius(5)
              .backgroundColor(this.theme.primary)
          }
          .width('100%')
          .height(this.compact ? 14 : 18)
          .margin({ top: this.compact ? 1 : 3 })
          .onAreaChange((_old: Area, now: Area): void => {
            this.barW = Number(now.width);
          })
          .onClick((e: ClickEvent): void => {
            this.commitRatio(this.ratioOf(e.x));
          })
          .gesture(
            PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 2 })
              .onActionStart((e: GestureEvent): void => {
                const f = e.fingerList.length > 0 ? e.fingerList[0] : null;
                this.dragStartRatio = f === null ? this.ratio() : this.ratioOf(f.localX);
                this.previewRatio = this.dragStartRatio;
              })
              .onActionUpdate((e: GestureEvent): void => {
                const w = this.barW;
                if (w <= 0) {
                  return;
                }
                let v = this.dragStartRatio + e.offsetX / w;
                if (v < 0) {
                  v = 0;
                }
                if (v > 1) {
                  v = 1;
                }
                this.previewRatio = v;
              })
              .onActionEnd((): void => {
                this.commitRatio(this.previewRatio);
              })
              .onActionCancel((): void => {
                this.previewRatio = -1;
              })
          )
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 10 })
        .onClick((): void => { this.onBarClick(); })

        Button() {
          Image($r('app.media.ic_prev'))
            .width(this.compact ? 24 : 28)
            .height(this.compact ? 24 : 28)
            .fillColor(this.theme.primary)
        }
        .type(ButtonType.Normal)
        .width(this.compact ? 38 : 44)
        .height(this.compact ? 38 : 44)
        .backgroundColor(Color.Transparent)
        .stateEffect(false)
        .onClick((): void => { this.onPrev(); })

        Button() {
          Image(this.snapshot.isPlay ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
            .width(this.compact ? 26 : 30)
            .height(this.compact ? 26 : 30)
            .fillColor(this.theme.primary)
        }
        .type(ButtonType.Normal)
        .width(this.compact ? 42 : 48)
        .height(this.compact ? 42 : 48)
        .backgroundColor(Color.Transparent)
        .stateEffect(false)
        .onClick((): void => { this.onTogglePlay(); })

        Button() {
          Image($r('app.media.ic_next'))
            .width(this.compact ? 24 : 28)
            .height(this.compact ? 24 : 28)
            .fillColor(this.theme.primary)
        }
        .type(ButtonType.Normal)
        .width(this.compact ? 38 : 44)
        .height(this.compact ? 38 : 44)
        .backgroundColor(Color.Transparent)
        .stateEffect(false)
        .onClick((): void => { this.onNext(); })
      }
      .width('100%')
      .height(this.compact ? 50 : 62)
      .padding({ left: 12, right: 8 })
      .onClick((): void => { this.onBarClick(); })
    }
    .width('100%')
    .backgroundColor(buildPalette(this.theme).card)
    .border({ width: { top: 1 }, color: buildPalette(this.theme).divider })
  }
}
