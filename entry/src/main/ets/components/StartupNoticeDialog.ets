/**
 * 启动时的纯本地提示弹窗：首次安装风控提示 / 农历生日祝福共用。
 * 不触发任何网络请求。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';

@Component
export struct StartupNoticeDialog {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop buttonText: string = '我知道了';
  onClose: () => void = () => {};

  private pal() {
    return buildPalette(this.theme);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        Text(this.title)
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .width('100%')
        Text(this.message)
          .fontSize(13).fontColor(this.pal().subText)
          .lineHeight(21)
          .width('100%')
          .margin({ top: 12 })
          .textAlign(TextAlign.Start)
        Button(this.buttonText)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor(this.theme.primary)
          .stateEffect(true)
          .width('100%')
          .margin({ top: 20 })
          .onClick((): void => { this.onClose(); })
      }
      .width('84%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 18, right: 18, top: 20, bottom: 18 })
      .backgroundColor(this.pal().card)
      .borderRadius(14)
      .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%').height('100%')
  }
}
