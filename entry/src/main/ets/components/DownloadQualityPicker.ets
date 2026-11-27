/**
 * 下载音质选择弹窗 —— 本协议「选择下载音质」样式。
 *
 * 用法：挂在页面最外层 Stack 下，遮罩铺满全屏、卡片居中。
 * 候选音质由调用方按「歌曲支持的音质 ∩ 已启用音源服务支持的音质」算好后传入；
 * 只有 1 个候选时调用方应直接下载、不弹本组件。
 */
import { Quality } from '../config/AppConstants';
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { SettingStore } from '../store/SettingStore';
import { screenWidthVp } from '../config/ScreenMetrics';

@Component
export struct DownloadQualityPicker {
  @Prop qualities: Quality[] = [];
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  onPick: (quality: Quality) => void = () => {};
  onClose: () => void = () => {};

  /** 设置页的「默认音质」，在选项后标注「当前播放音质」 */
  private currentQuality(): string {
    return SettingStore.getInstance().getString('player.playQuality', '128k');
  }

  private label(q: Quality): string {
    let base: string = '';
    switch (q) {
      case 'flac24bit':
        base = '高解析 · FLAC 24bit';
        break;
      case 'flac':
        base = '无损 · FLAC';
        break;
      case 'wav':
        base = '高解析 · WAV';
        break;
      case 'ape':
        base = '无损 · APE';
        break;
      case '320k':
        base = '高品质 · 320 kbps';
        break;
      case '192k':
        base = '较高品质 · 192 kbps';
        break;
      case '128k':
        base = '标准 · 128 kbps';
        break;
      default:
        base = q;
        break;
    }
    return q === this.currentQuality() ? base + '（当前播放音质）' : base;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：点空白处关闭（与卡片是兄弟节点，点卡片不会穿透）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        // 顶部主题色细条
        Column()
          .width('100%')
          .height(6)
          .backgroundColor(this.theme.primary)

        Text('选择下载音质')
          .fontSize(18)
          .fontColor(this.theme.font)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 20, bottom: 10 })

        ForEach(this.qualities, (q: Quality): void => {
          Row() {
            Text(this.label(q))
              .fontSize(16)
              .fontColor(this.theme.font)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height(50)
          .padding({ left: 12, right: 12 })
          .justifyContent(FlexAlign.Center)
          .onClick((): void => { this.onPick(q); })
        }, (q: Quality): string => q)

        Column() {
          Text('取消')
            .fontSize(16)
            .fontColor(this.theme.primary)
            .width('100%')
            .height(44)
            .textAlign(TextAlign.Center)
            .backgroundColor(buildPalette(this.theme).pillBg)
            .borderRadius(8)
            .onClick((): void => { this.onClose(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 18 })
      }
      .width('86%')
      .constraintSize({ maxWidth: Math.min(480, screenWidthVp() * 0.86) })
      .backgroundColor(buildPalette(this.theme).card)
      .borderRadius(12)
      .clip(true)
      .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    .height('100%')
  }
}
