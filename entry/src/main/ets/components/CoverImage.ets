/**
 * 带磁盘缓存的封面图组件。
 *
 * 直接 `Image(url)` 的问题是：每次滚进视野都要重新走网络 + 解码原图
 * （咪咕单张 1.8MB），滚动越快越卡，封面永远"慢半拍"。
 * 这里统一走 CoverCache：本地已有就同步命中立刻出图，没有则后台取（取到自动刷新），
 * 取图期间显示主题色底 + 图标占位，视觉上不会突然从空白变成图。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { CoverCache } from '../core/ImageCache';

const FALLBACK_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};

@Component
export struct CoverImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  /**
   * 兜底地址：主地址取不到图时再试一次（例如清晰版封面在老专辑上不存在）。
   * 只会在主地址失败时发请求，正常情况下不会多一次。
   */
  @Prop fallbackUrl: string = '';
  @Prop theme: ThemeInfo = FALLBACK_THEME;
  /** 圆角 */
  @Prop radius: number = 4;
  /** 占位图标（歌单用 ic_logo，歌曲封面可传 ic_music） */
  @Prop placeholder: Resource = $r('app.media.ic_logo');
  @Prop placeholderSize: number = 34;
  /** 铺满方式（大封面用 Cover，占位图标的容器用 Cover 即可） */
  @Prop fit: ImageFit = ImageFit.Cover;
  /** 模糊半径（播放页背景层用，0 = 不模糊） */
  @Prop blurRadius: number = 0;
  /** 整体不透明度（播放页背景层用） */
  @Prop opacityValue: number = 1;
  /** 占位底色是否透明（铺在模糊背景上时不能压一层不透明底色） */
  @Prop transparentBg: boolean = false;
  /** 是否显示占位图标（全屏模糊背景层不需要） */
  @Prop showPlaceholder: boolean = true;

  @State private src: string = '';
  private alive: boolean = true;
  private token: number = 0;

  aboutToAppear(): void {
    this.start();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private onUrlChanged(): void {
    this.src = '';
    this.start();
  }

  private start(): void {
    const u: string = this.url;
    if (u.length === 0) {
      return;
    }
    // 本地音乐封面已经是 file:// URI（同目录同名图片），直接显示，不走网络缓存
    if (u.indexOf('file://') === 0) {
      this.src = u;
      return;
    }
    // 内存命中：同步赋值，避免「占位闪一下再出图」
    const hit: string = CoverCache.getInstance().peek(u);
    if (hit.length > 0) {
      this.src = hit;
      return;
    }
    const t: number = ++this.token;
    CoverCache.getInstance().get(u).then((p: string): void => {
      if (!this.alive || t !== this.token) {
        return;
      }
      if (p.length > 0) {
        this.src = p;
        return;
      }
      this.tryFallback(t);
    }).catch((): void => {
      // 取图失败保持占位，不弹提示（列表里弹窗会打断浏览）
      this.tryFallback(t);
    });
  }

  /** 主地址失败：用兜底地址（通常是原始小图）再试一次 */
  private tryFallback(t: number): void {
    const alt: string = this.fallbackUrl;
    if (alt.length === 0 || alt === this.url) {
      return;
    }
    if (alt.indexOf('file://') === 0) {
      this.src = alt;
      return;
    }
    CoverCache.getInstance().get(alt).then((p: string): void => {
      if (this.alive && t === this.token && p.length > 0) {
        this.src = p;
      }
    }).catch((): void => {
      // 兜底也失败：保持占位
    });
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.transparentBg ? Color.Transparent : buildPalette(this.theme).pillBg)
      // 占位与实图互斥：少一层节点，滚动时更省
      if (this.src.length > 0) {
        Image(this.src)
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
          .blur(this.blurRadius)
          .opacity(this.opacityValue)
          .interpolation(ImageInterpolation.Medium)
          .draggable(false)
      } else if (this.showPlaceholder) {
        Image(this.placeholder)
          .width(this.placeholderSize)
          .height(this.placeholderSize)
          .fillColor(buildPalette(this.theme).divider)
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(this.radius)
    .clip(true)
  }
}
