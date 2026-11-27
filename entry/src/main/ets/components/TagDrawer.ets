import { ThemeInfo, buildPalette } from '../theme/Themes';
import { TagInfoItem } from '../model/MusicTypes';

const DEFAULT_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};

/**
 * 歌单分类左侧抽屉（设计稿：点「默认 / 打开」或侧边栏滑出）。
 * 标签以浅绿胶囊按分组自动换行铺排，点击即切换歌单分类并关闭抽屉。
 */
@Component
export struct TagDrawer {
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  @Prop tags: TagInfoItem[] = [];
  @Prop currentId: string = '';
  onPick: (id: string) => void = () => {};
  onClose: () => void = () => {};

  private isSel(id: string): boolean {
    return this.currentId === id;
  }

  @Builder
  private Pill(t: TagInfoItem) {
    Text(t.name)
      .fontSize(12)
      .fontColor(this.isSel(t.id) ? this.theme.primary : buildPalette(this.theme).pillText)
      .backgroundColor(this.isSel(t.id) ? buildPalette(this.theme).activeTint : buildPalette(this.theme).pillBg)
      .borderRadius(14)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ right: 8, bottom: 8 })
      .onClick((): void => {
        this.onPick(t.id);
        this.onClose();
      })
  }

  build() {
    Scroll() {
      Column() {
        Text('默认')
          .fontSize(12).fontColor(buildPalette(this.theme).subText)
          .width('100%').margin({ bottom: 10 })
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          ForEach(this.tags, (t: TagInfoItem): void => {
            if (t.id === '') {
              this.Pill(t);
            }
          }, (t: TagInfoItem): string => 'rec_' + t.id)
        }.width('100%')

        Text('热门')
          .fontSize(12).fontColor(buildPalette(this.theme).subText)
          .width('100%').margin({ top: 18, bottom: 10 })
        Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
          ForEach(this.tags, (t: TagInfoItem): void => {
            if (t.id !== '') {
              this.Pill(t);
            }
          }, (t: TagInfoItem): string => 'tag_' + t.id)
        }.width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 20, bottom: 24 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(buildPalette(this.theme).card)
  }
}
