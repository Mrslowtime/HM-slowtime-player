/**
 * 设置模块「版本更新日志」。
 * 当前版本（CHANGELOG[0]）始终展示在卡片里；历史版本收敛到「历史版本」弹窗，
 * 点当前版本下方的按钮打开，避免设置页被几十条旧日志拉得很长。
 */
import { ThemeInfo, ThemePalette, buildPalette } from '../theme/Themes';
import { CHANGELOG, VersionLog, APP_VERSION_NAME } from '../config/AppVersion';
import { isFullChangelogUnlocked } from '../core/ChangeLogSecret';
import { recordVersionTap } from '../core/BirthdaySecret';

/** 历史版本默认只显示首版；密点达标并重启后显示全部（见 core/ChangeLogSecret） */
const FIRST_VERSION: string = '1.0.0.9527';

const DEFAULT_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};

/**
 * 历史版本弹窗：全部旧版本按时间倒序，默认展开最新一条，点标题展开/收起。
 * 用 customStyle 完全自绘，跟随应用主题（浅色/深色都不会出现系统白底黑字）。
 */
@CustomDialog
struct VersionHistoryDialog {
  controller?: CustomDialogController;
  theme: ThemeInfo = DEFAULT_THEME;
  logs: VersionLog[] = [];
  /** 当前展开的旧版本下标，默认展开第一条（最新的一条历史版本） */
  @State private expanded: number = 0;

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  /** 单条更新内容（· 前缀的一行） */
  @Builder
  private row(text: string) {
    Row() {
      Text('·')
        .fontSize(12).fontColor(this.theme.primary).width(12)
      Text(text)
        .fontSize(12).fontColor(this.theme.font).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column() {
      Row() {
        Text('历史版本')
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .layoutWeight(1)
        Text('关闭')
          .fontSize(13).fontColor(this.theme.primary)
          .onClick((): void => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Divider().color(this.pal().divider).strokeWidth(0.5)

      Scroll() {
        Column() {
          ForEach(this.logs, (log: VersionLog, idx: number): void => {
            Column() {
              Row() {
                Text('v' + log.version + ' · ' + log.date)
                  .fontSize(13).fontColor(this.theme.font)
                  .layoutWeight(1)
                Text(this.expanded === idx ? '▴' : '▾')
                  .fontSize(12).fontColor(this.theme.primary)
              }
              .width('100%')
              .onClick((): void => {
                this.expanded = this.expanded === idx ? -1 : idx;
              })
              if (this.expanded === idx) {
                Column() {
                  ForEach(log.items, (s: string, i: number): void => {
                    this.row(s)
                  }, (s: string, i: number): string => 'h_' + idx.toString() + '_' + i.toString())
                }
                .width('100%')
                .margin({ top: 4 })
              }
            }
            .width('100%').padding(12).margin({ bottom: 8 })
            .backgroundColor(this.pal().card).borderRadius(10)
            .alignItems(HorizontalAlign.Start)
          }, (log: VersionLog): string => log.version)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      }
      .width('100%')
      .constraintSize({ maxHeight: 460 })
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('88%')
    .backgroundColor(this.theme.mainBackground)
    .borderRadius(16)
    .clip(true)
  }
}

@Component
export struct VersionLogPanel {
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  /** 当前版本内容是否折叠（默认 false = 展开） */
  @State private curCollapsed: boolean = false;
  private historyCtrl: CustomDialogController | null = null;

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  private current(): VersionLog {
    return CHANGELOG[0];
  }

  /**
   * 历史版本列表：默认只留首版 1.0.0.9527；只有密点达标并重启后才给完整列表。
   * 当前版本卡片由 current() 单独渲染，始终可见，不受这里影响。
   */
  private oldLogs(): VersionLog[] {
    const all: VersionLog[] = CHANGELOG.slice(1);
    if (isFullChangelogUnlocked()) {
      return all;
    }
    return all.filter((log: VersionLog): boolean => log.version === FIRST_VERSION);
  }

  /** 打开历史版本弹窗（每次重建控制器：主题切换后弹窗也能拿到最新主题） */
  private openHistory(): void {
    if (this.oldLogs().length === 0) {
      return;
    }
    this.historyCtrl = new CustomDialogController({
      builder: VersionHistoryDialog({ theme: this.theme, logs: this.oldLogs() }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.historyCtrl.open();
  }

  /** 单条更新内容（· 前缀的一行） */
  @Builder
  private row(text: string) {
    Row() {
      Text('·')
        .fontSize(12).fontColor(this.theme.primary).width(12)
      Text(text)
        .fontSize(12).fontColor(this.theme.font).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private LogItems(items: string[], keyPrefix: string) {
    ForEach(items, (s: string, idx: number): void => {
      this.row(s)
    }, (s: string, idx: number): string => keyPrefix + '_' + idx.toString())
  }

  build() {
    // 嵌在设置页瀑布流内：自身不滚动，随页面一起上下滚；标题由外层分组卡片提供
    Column() {
      Column() {
        // 「当前版本」是生日彩蛋关闭手势的第 1 段，点击本身没有任何界面反馈
        Text('当前版本  ' + APP_VERSION_NAME)
          .fontSize(11).fontColor(this.pal().subText)
          .width('100%').margin({ top: 4, bottom: 10 })
          .onClick((): void => { recordVersionTap(); })

        // 当前版本：可点标题折叠，默认展开
        Column() {
          Row() {
            Text('v' + this.current().version)
              .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
              .layoutWeight(1)
            Text(this.current().date)
              .fontSize(11).fontColor(this.pal().subText).margin({ right: 6 })
            Text(this.curCollapsed ? '▾' : '▴')
              .fontSize(12).fontColor(this.theme.primary)
          }
          .width('100%').margin({ bottom: this.curCollapsed ? 0 : 6 })
          .onClick((): void => { this.curCollapsed = !this.curCollapsed; })
          if (!this.curCollapsed) {
            this.LogItems(this.current().items, 'cur')
          }
        }
        .width('100%').padding(14).margin({ bottom: 10 })
        .backgroundColor(this.pal().card).borderRadius(12)
        .alignItems(HorizontalAlign.Start)
        .border({ width: 1, color: this.theme.primary })

        // 历史版本：收进弹窗，点这里打开
        if (this.oldLogs().length > 0) {
          Button('历史版本（' + this.oldLogs().length.toString() + '）')
            .fontSize(13)
            .backgroundColor(this.pal().pillBg)
            .fontColor(this.pal().subText)
            .stateEffect(false)
            .width('100%')
            .onClick((): void => { this.openHistory(); })
        }

        Row().height(16)
      }
      .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 随内容自然展开（layoutWeight 在不定高父容器内会塌成 0）
    .alignItems(HorizontalAlign.Start)
  }
}
