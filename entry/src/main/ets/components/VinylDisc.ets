/**
 * 旋转黑胶（带唱臂）—— 只有「当前歌单正在播放」时才在收藏按钮旁出现。
 *
 * 唱片本体旋转、唱臂静止，所以是两张 SVG 叠加，不能整图旋转（那样唱臂会跟着转）。
 * 动画放在组件内部：角度变化只重绘这 28vp 的小组件，不会牵动整页卡片。
 *
 * 暂停时图标不消失，只是停止转动：这里把一圈切成 12 段（每段 30°、300ms），
 * 段与段之间检查 playing，一旦暂停就不再排下一段 —— 所以停在最近的那个 30° 节点上，
 * 不会跳回原点。恢复播放由 @Watch 重新续上。
 */
@Component
export struct VinylDisc {
  /** 直径（vp）。注意不能叫 size：那是内置通用属性名，会与基类冲突 */
  @Prop diameter: number = 28;
  /** 是否转动（暂停传 false → 原地停住，图标仍然显示） */
  @Prop @Watch('onPlayingChanged') playing: boolean = true;
  @State private angle: number = 0;
  /** 段间延时的句柄，-1 表示当前没有在等下一段 */
  private segTimer: number = -1;
  private disposed: boolean = false;

  /** 每段 30°、300ms：12 段正好一圈 3.6s */
  private static readonly SEG_DEGREE: number = 30;
  private static readonly SEG_MS: number = 300;

  aboutToAppear(): void {
    if (this.playing) {
      this.startTurn();
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.clearTimer();
  }

  onPlayingChanged(): void {
    if (this.playing) {
      this.startTurn();
    }
  }

  private clearTimer(): void {
    if (this.segTimer >= 0) {
      clearTimeout(this.segTimer);
      this.segTimer = -1;
    }
  }

  private startTurn(): void {
    if (this.disposed || !this.playing || this.segTimer >= 0) {
      return;
    }
    this.nextSeg();
  }

  private nextSeg(): void {
    if (this.disposed || !this.playing) {
      return;
    }
    const from: number = this.angle;
    const to: number = from + VinylDisc.SEG_DEGREE;
    animateTo({
      duration: VinylDisc.SEG_MS,
      curve: Curve.Linear,
      onFinish: (): void => {
        // 满 360 归零再继续：360 与 0 视觉一致，这一步不会跳变
        this.angle = to >= 360 ? to - 360 : to;
        if (this.disposed || !this.playing) {
          return;
        }
        this.segTimer = setTimeout((): void => {
          this.segTimer = -1;
          this.nextSeg();
        }, 16);
      },
    }, (): void => {
      this.angle = to;
    });
  }

  build() {
    Stack() {
      Image($r('app.media.ic_vinyl'))
        .width('100%').height('100%')
        .rotate({ angle: this.angle })
      // 唱臂固定：叠在唱片上方，指针压住盘面
      Image($r('app.media.ic_vinyl_arm'))
        .width('100%').height('100%')
    }
    .width(this.diameter)
    .height(this.diameter)
  }
}
