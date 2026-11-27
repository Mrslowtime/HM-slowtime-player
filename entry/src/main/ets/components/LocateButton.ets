/**
 * 浮动的「定位到正在播放歌曲」按钮。
 *
 * 图标是瞄准镜形状的单色 SVG（media/ic_locate.svg），三处颜色全部取自当前主题：
 * 底色 = 卡片色、描边 = 主题色的半透明、图标 = 主题色，深色主题下自动变成深底浅线。
 * 只负责外观与点击，定位逻辑由调用方（我的列表 / 歌单详情）实现。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';

@Component
export struct LocateButton {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  onLocate: () => void = () => {};

  build() {
    Stack() {
      Image($r('app.media.ic_locate'))
        .width(18)
        .height(18)
        .fillColor(this.theme.primary)
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor(buildPalette(this.theme).card)
    .border({ width: 1, color: this.theme.primary + '4D' })
    .shadow({ radius: 12, color: '#26000000', offsetX: 0, offsetY: 2 })
    .onClick((): void => { this.onLocate(); })
  }
}
