/**
 * 「缓存接近上限」询问弹窗。
 *
 * 触发条件见 core/CacheStore.enforce()：占用达到上限 99%，且上限还没到 6G、
 * 应用在前台。选「调高上限」→ +500MiB 继续用；选「保持并清理」→ 立刻按 49% 比例清理。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { CACHE_LIMIT_MAX_MB, CACHE_LIMIT_STEP_MB } from '../core/CacheStore';

@Component
export struct CacheLimitDialog {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 当前上限（MiB） */
  @Prop limitMb: number = 2000;
  onChoose: (raise: boolean) => void = () => {};

  private pal() {
    return buildPalette(this.theme);
  }

  private nextMb(): number {
    return Math.min(CACHE_LIMIT_MAX_MB, this.limitMb + CACHE_LIMIT_STEP_MB);
  }

  private sizeText(mb: number): string {
    return mb >= 1024 ? ((Math.round(mb / 1024 * 10) / 10).toString() + ' GB') : (mb.toString() + ' MB');
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onChoose(false); })

      Column() {
        Text('缓存已接近上限')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
        Text('当前上限 ' + this.sizeText(this.limitMb) + '，缓存已用到 99%。' +
          '调高上限可以保留已缓存的歌曲，继续听不用重新下载；' +
          '保持现状则会清理约一半旧缓存（先清最久没听的歌）。')
          .fontSize(12).fontColor(this.pal().subText)
          .lineHeight(19)
          .margin({ top: 10 })

        Row() {
          Button('保持并清理')
            .fontSize(13)
            .fontColor(this.pal().subText)
            .backgroundColor(this.pal().pillBg)
            .layoutWeight(1)
            .stateEffect(true)
            .onClick((): void => { this.onChoose(false); })
          Button('调高到 ' + this.sizeText(this.nextMb()))
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor(this.theme.primary)
            .layoutWeight(1)
            .margin({ left: 10 })
            .stateEffect(true)
            .onClick((): void => { this.onChoose(true); })
        }
        .width('100%')
        .margin({ top: 18 })
      }
      .width('84%')
      .padding({ left: 18, right: 18, top: 18, bottom: 16 })
      .backgroundColor(this.pal().card)
      .borderRadius(14)
      .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%').height('100%')
  }
}
