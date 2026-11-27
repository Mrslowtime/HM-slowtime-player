/**
 * 缓存设置面板 —— 追加在「缓存设置」分组底部。
 *
 * 只负责「展示 + 立即清理」。整曲音频缓存启用后（AUDIO_CACHE_ENABLED=true）
 * 统计里会多出「歌曲 N 首」；三层缓存都是复用已经拿到的内容，不产生额外请求。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { CacheStore, CacheStats, cacheFormatSize, AUDIO_CACHE_ENABLED } from '../core/CacheStore';
import { userNotice } from '../core/UserNotice';

@Component
export struct CachePanel {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 设置页版本号：任何设置变更后跟着刷新一次占用 */
  @Prop @Watch('onVersionChanged') version: number = 0;
  @State private stats: CacheStats = {
    audioBytes: 0, coverBytes: 0, lyricBytes: 0, totalBytes: 0,
    audioCount: 0, coverCount: 0, lyricCount: 0,
  };
  @State private clearing: boolean = false;
  /** 清理二次确认：true 才弹出确认层，点取消或遮罩即关闭 */
  @State private askingClear: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  private onVersionChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    this.stats = CacheStore.getInstance().stats();
  }

  private pal() {
    return buildPalette(this.theme);
  }

  private async clearAll(): Promise<void> {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    try {
      const freed: number = CacheStore.getInstance().clearAll();
      this.refresh();
      userNotice().info(freed > 0 ? ('已清理 ' + cacheFormatSize(freed)) : '缓存已是空的');
    } finally {
      this.clearing = false;
    }
  }

  build() {
    Column() {
      Divider()
        .width('100%')
        .color(this.pal().divider)
        .strokeWidth(0.5)
        .margin({ left: 16, right: 16 })

      Row() {
        Column() {
          Text('当前缓存占用')
            .fontSize(13).fontColor(this.theme.font)
          Text(this.detailText())
            .fontSize(11).fontColor(this.pal().subText)
            .margin({ top: 3 })
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(cacheFormatSize(this.stats.totalBytes))
          .fontSize(12)
          .fontColor(this.theme.primary)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      Row() {
        Button(this.clearing ? '清理中…' : '立即清理缓存')
          .fontSize(13)
          .fontColor(this.theme.primary)
          .backgroundColor(this.pal().pillBg)
          .stateEffect(true)
          .layoutWeight(1)
          .enabled(!this.clearing)
          .onClick((): void => { this.askingClear = true; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })

      // 立即清理：二次确认，避免误触清空整曲 / 封面 / 歌词
      if (this.askingClear) {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => { this.askingClear = false; })
          Column() {
            Text('清理缓存')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
            Text('将清空已缓存的整曲歌曲、封面与歌词，下次播放需重新获取。此操作不可撤销。')
              .fontSize(12).fontColor(this.pal().subText)
              .margin({ top: 10 }).lineHeight(18)
            Row() {
              Button('取消')
                .onClick((): void => { this.askingClear = false; })
                .backgroundColor(this.pal().pillBg).stateEffect(false)
                .fontColor(this.pal().pillText).fontSize(13).layoutWeight(1)
              Button('确认清理')
                .onClick((): void => {
                  this.askingClear = false;
                  this.clearAll();
                })
                .backgroundColor('#C0553F').stateEffect(false)
                .fontColor('#FFFFFF').fontSize(13).layoutWeight(1)
                .margin({ left: 10 })
            }
            .width('100%').margin({ top: 16 })
          }
          .width('84%').padding(18)
          .backgroundColor(this.pal().card).borderRadius(14)
        }
        .width('100%').height('100%')
      }
    }
    .width('100%')
  }

  private detailText(): string {
    const s: CacheStats = this.stats;
    const parts: string[] = [];
    if (AUDIO_CACHE_ENABLED) {
      parts.push('歌曲 ' + s.audioCount.toString() + ' 首 ' + cacheFormatSize(s.audioBytes));
    }
    parts.push('封面 ' + s.coverCount.toString() + ' 张 ' + cacheFormatSize(s.coverBytes));
    parts.push('歌词 ' + s.lyricCount.toString() + ' 条 ' + cacheFormatSize(s.lyricBytes));
    return parts.join(' · ');
  }
}
