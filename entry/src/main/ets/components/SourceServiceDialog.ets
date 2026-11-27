/**
 * 「音源服务」弹窗 —— 入口在设置页「自定义源」分组里「自定义源管理」按钮下方（2026-11-17 用户要求）。
 *
 * 以前音源服务是设置页里独立的一整组（HTTP 端点兜底配置），现在收进弹窗：
 * 点「音源服务」按钮就地弹出，填完保存即关，不再占一整块设置位置。
 * 表单本身复用 SourceSettingPanel（保存 / 测试 / URL 风格逻辑一份，避免两处出现不一致）。
 *
 * 由 Index 根 Stack 承载（与自定义源管理弹窗同一层级），保证不被设置页的
 * Scroll 裁切、也不会压到全局头部的操作区。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { SourceSettingPanel } from '../pages/views/SourceSettingView';

@Component
export struct SourceServiceDialog {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  onClose: () => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 半透明遮罩：点空白处关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        Row() {
          Text('音源服务')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.font)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text('✕')
            .fontSize(18)
            .fontColor(buildPalette(this.theme).subText)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .onClick((): void => { this.onClose(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 14, bottom: 6 })

        // 表单随内容滚动：小屏 + 键盘弹起时也能看全「保存 / 测试」按钮
        Scroll() {
          SourceSettingPanel({ theme: this.theme })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('88%')
      .height('72%')
      .backgroundColor(buildPalette(this.theme).card)
      .borderRadius(14)
      .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }
}
