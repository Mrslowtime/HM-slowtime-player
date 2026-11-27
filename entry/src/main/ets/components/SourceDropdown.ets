import { ThemeInfo, buildPalette } from '../theme/Themes';
import { OnlineSource, ONLINE_SOURCES, sourceDisplay } from '../config/AppConstants';
import { SourceOrderManager } from '../core/SourceOrder';

const DEFAULT_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};

/**
 * 平台来源下拉面板（设计稿：点击右上角「当前平台名」弹出）。
 * 纯选择器：列出全部平台，当前项浅绿高亮 + ✓，点击即切换并关闭。
 * 不做抖动 / 编辑态 / 长按入口：列表的排序交互统一放在「我的列表」抽屉里完成。
 */
@Component
export struct SourceDropdown {
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  @Prop selected: OnlineSource = 'kw';
  /** 歌曲来源显示方式（简称/全名），由调用方传入 */
  @Prop sourceNameType: string = 'alias';
  onSelect: (s: OnlineSource) => void = () => {};
  onClose: () => void = () => {};

  @State private order: OnlineSource[] = ONLINE_SOURCES.slice();

  aboutToAppear(): void {
    SourceOrderManager.getInstance().ensure().then((): void => {
      this.order = SourceOrderManager.getInstance().getOrder();
    });
  }

  private isSel(s: OnlineSource): boolean {
    return this.selected === s;
  }

  private panelShadow(): ShadowOptions {
    return { radius: 14, color: '#33000000', offsetX: 0, offsetY: 4 };
  }

  @Builder
  private SourceRow(s: OnlineSource) {
    Row() {
      Text(sourceDisplay(s, this.sourceNameType))
        .fontSize(13)
        .fontColor(this.isSel(s) ? this.theme.primary : buildPalette(this.theme).subText)
        .fontWeight(this.isSel(s) ? FontWeight.Bold : FontWeight.Normal)
        .layoutWeight(1)
      if (this.isSel(s)) {
        Text('✓').fontSize(13).fontColor(this.theme.primary)
      }
    }
    .width('100%').height(40)
    .padding({ left: 12, right: 8 })
    .backgroundColor(this.isSel(s) ? buildPalette(this.theme).activeTint : '#00000000')
    .borderRadius(6)
    .onClick((): void => {
      this.onSelect(s);
      this.onClose();
    })
  }

  build() {
    Column() {
      Row() {
        Text('选择平台')
          .fontSize(11).fontColor(buildPalette(this.theme).subText).layoutWeight(1)
      }
      .width('100%').height(32).padding({ left: 12, right: 12 })

      ForEach(this.order, (s: OnlineSource): void => {
        this.SourceRow(s);
      }, (s: OnlineSource): string => s + '_' + this.sourceNameType)
    }
    .width(158)
    .padding({ top: 4, bottom: 6 })
    .backgroundColor(buildPalette(this.theme).card)
    .borderRadius(10)
    .shadow(this.panelShadow())
  }
}
