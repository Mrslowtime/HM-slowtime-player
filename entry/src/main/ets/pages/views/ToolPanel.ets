/**
 * 设置里的「动作型」面板 —— 关于 / 运行日志 / 不喜欢列表 / 数据备份与恢复。
 *
 * 2026-11-17 用户要求：设置页不再有「工具」这个合并分组，四项各自独立成组，
 * 顺序为「不喜欢列表 → 数据备份与恢复 → 运行日志 → 更新日志 → 关于」。
 * 因此本组件通过 `part` 只渲染其中一块，分组标题由设置页的 GroupCard 提供，
 * 这里不再重复画标题卡片，也不再套白色底（与普通设置行保持同一视觉层级）。
 *
 * 「退出应用」卡片已移除（2026-11-16 用户要求）：抽屉底部仍有退出入口，
 * 工具面板不再重复放一份；相关开关 common.showExitBtn 同步从设置页隐藏。
 */
import { ThemeInfo, buildPalette } from '../../theme/Themes';
import { BackupManager } from '../../core/BackupManager';
import { AppLog, LogListener } from '../../core/AppLog';
import { userNotice } from '../../core/UserNotice';
import { AppState } from '../../store/AppState';
import { dislikeEvent, stateEvent, StateEvents, EmptyCallback } from '../../store/EventBus';
import { I18n } from '../../core/I18n';

@Component
export struct ToolPanel {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 只渲染哪一块：about / log / dislike / backup（缺省渲染全部，兼容旧调用） */
  @Prop part: string = 'all';

  @State private showLog: boolean = false;
  @State private logLines: string[] = [];
  @State private dislikeNames: number = 0;
  @State private dislikeMusic: number = 0;
  @State private dislikeSinger: number = 0;
  @State private dislikeRules: number = 0;
  @State private backupMsg: string = '';
  @State private backupBusy: boolean = false;
  @State private backups: string[] = [];
  @State private langTick: number = 0;

  private state: AppState = AppState.getInstance();
  /** 日志行回调：显式引用，卸载时用同一引用 unsubscribe，避免匿名监听泄漏 */
  private onLogLines: LogListener = (lines: string[]): void => { this.logLines = lines; };
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案 */
  private onLangChanged: EmptyCallback = (): void => { this.langTick = this.langTick + 1; };

  aboutToAppear(): void {
    if (this.part === 'all' || this.part === 'log') {
      this.logLines = AppLog().getAll();
      AppLog().subscribe(this.onLogLines);
    }
    if (this.part === 'all' || this.part === 'dislike') {
      this.refreshDislike();
    }
    if (this.part === 'all' || this.part === 'backup') {
      this.refreshBackups();
    }
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
  }

  aboutToDisappear(): void {
    AppLog().unsubscribe(this.onLogLines);
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
  }

  /** 取翻译（读取 langTick 以在语言切换时刷新） */
  private tx(key: string): string {
    const _t = this.langTick;
    return I18n().t(key) + (_t >= 0 ? '' : '');
  }

  private show(p: string): boolean {
    return this.part === 'all' || this.part === p;
  }

  private refreshDislike(): void {
    const d = this.state.dislikeInfo;
    this.dislikeNames = d.names.length;
    this.dislikeMusic = d.musicNames.length;
    this.dislikeSinger = d.singerNames.length;
    this.dislikeRules = d.rules.length;
  }

  private async refreshBackups(): Promise<void> {
    try {
      this.backups = await BackupManager.getInstance().listBackups();
    } catch (e) {
      this.backups = [];
    }
  }

  private clearDislike(): void {
    this.state.dislikeInfo = { names: [], musicNames: [], singerNames: [], rules: [] };
    dislikeEvent().emit('dislikeUpdated');
    this.refreshDislike();
    AppLog().log('已清空不喜欢列表');
  }

  private async doExport(): Promise<void> {
    this.backupBusy = true;
    this.backupMsg = '正在导出…';
    try {
      const r = await BackupManager.getInstance().exportBackup();
      const name: string = this.shortName(r.path);
      // 必须说清落盘位置：以前只写沙箱，用户卸载重装后备份随之被删，
      // 「导入最近备份」就变成「没有可用的备份文件」。
      this.backupMsg = r.isPublic
        ? '已导出到手机「下载/com.slowtime.hmplayer/备份」：' + name + '（卸载应用不会删除）'
        : '已导出到应用内目录：' + name + '（卸载应用会一并删除，建议改存到公共目录）';
      await this.refreshBackups();
    } catch (e) {
      this.backupMsg = '导出失败：' + ((e as Error).message ?? '未知错误');
    }
    this.backupBusy = false;
  }

  /** 从系统文件选择器挑一份备份 json 导入（重装后恢复的主要入口） */
  private async doImportFromFile(): Promise<void> {
    this.backupBusy = true;
    this.backupMsg = '正在读取备份…';
    try {
      const r = await BackupManager.getInstance().importFromPicker();
      if (r === null) {
        this.backupMsg = '已取消选择';
      } else {
        this.backupMsg = '已恢复 设置 ' + r.settings.toString() + ' 项 · 列表 ' + r.lists.toString() + ' 个';
        await this.refreshBackups();
      }
    } catch (e) {
      const msg: string = (e as Error).message ?? '未知错误';
      this.backupMsg = '导入失败：' + msg;
      userNotice().error('备份导入失败：' + msg);
    }
    this.backupBusy = false;
  }

  private async doImport(path: string): Promise<void> {
    this.backupBusy = true;
    this.backupMsg = '正在导入…';
    try {
      const r = await BackupManager.getInstance().importBackup(path);
      this.backupMsg = '已恢复 设置 ' + r.settings.toString() + ' 项 · 列表 ' + r.lists.toString() + ' 个';
    } catch (e) {
      const msg: string = (e as Error).message ?? '未知错误';
      this.backupMsg = '导入失败：' + msg;
      userNotice().error('备份导入失败：' + msg);
    }
    this.backupBusy = false;
  }

  build() {
    Column() {
      if (this.show('about')) {
        this.aboutBlock()
      }
      if (this.show('dislike')) {
        this.dislikeBlock()
      }
      if (this.show('backup')) {
        this.backupBlock()
      }
      if (this.show('log')) {
        this.logBlock()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  aboutBlock() {
    // 分组标题本身就是「关于·慢时光音乐（鸿蒙原生版）」，这里不再重复应用名与副标题
    Column() {
      Text(this.tx('about_desc'))
        .fontSize(11).fontColor(buildPalette(this.theme).subText)
    }
    .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  logBlock() {
    Column() {
      Row() {
        Button(this.showLog ? this.tx('log_hide') : this.tx('log_view'))
          .fontSize(13).backgroundColor(this.theme.primary).fontColor('#FFFFFF').stateEffect(false)
          .onClick((): void => { this.showLog = !this.showLog; })
        Button(this.tx('log_clear'))
          .fontSize(13).backgroundColor(buildPalette(this.theme).pillBg).fontColor(buildPalette(this.theme).subText).stateEffect(false)
          .margin({ left: 10 })
          .onClick((): void => { AppLog().clear(); })
      }
      .width('100%')
      if (this.showLog) {
        Scroll() {
          Column() {
            ForEach(this.logLines, (line: string): void => {
              Text(line)
                .fontSize(10).fontColor(buildPalette(this.theme).subText)
                .width('100%').textAlign(TextAlign.Start)
            }, (line: string, idx: number): string => idx.toString() + '|' + line)
          }
          .width('100%')
        }
        .height(160).width('100%').margin({ top: 8 })
        .backgroundColor(buildPalette(this.theme).divider).borderRadius(8)
      }
    }
    .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  dislikeBlock() {
    Column() {
      Text(this.tx('field_name') + ' ' + this.dislikeMusic.toString() + ' · ' + this.tx('field_singer') + ' ' + this.dislikeSinger.toString()
        + ' · ' + this.tx('playlist_detail') + ' ' + this.dislikeNames.toString() + ' · ' + this.tx('rule') + ' ' + this.dislikeRules.toString())
        .fontSize(12).fontColor(this.theme.font).width('100%')
      Button(this.tx('dislike_clear'))
        .fontSize(13).backgroundColor(buildPalette(this.theme).pillBg).fontColor(buildPalette(this.theme).subText).stateEffect(false)
        .margin({ top: 10 })
        .onClick((): void => { this.clearDislike(); })
    }
    .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  backupBlock() {
    Column() {
      Text(this.tx('backup_desc'))
        .fontSize(11).fontColor(buildPalette(this.theme).subText).width('100%').margin({ bottom: 10 })
      Row() {
        Button(this.tx('backup_export'))
          .fontSize(13).backgroundColor(this.theme.primary).fontColor('#FFFFFF').stateEffect(false)
          .layoutWeight(1)
          .onClick((): void => { this.doExport(); })
        Button(this.backupBusy ? this.tx('processing') : this.tx('backup_import_recent'))
          .fontSize(13).backgroundColor(buildPalette(this.theme).pillBg).fontColor(buildPalette(this.theme).subText).stateEffect(false)
          .layoutWeight(1).margin({ left: 10 })
          .onClick((): void => {
            if (this.backupBusy) {
              return;
            }
            if (this.backups.length > 0) {
              this.doImport(this.backups[0]);
            } else {
              // 一个备份都找不到（典型情况：卸载重装后沙箱已清空）：
              // 直接让用户从「文件」里挑备份，而不是只说一句"没有可用的备份文件"
              this.backupMsg = this.tx('backup_none');
              this.doImportFromFile();
            }
          })
      }
      .width('100%')
      Text(this.tx('backup_pick_file'))
        .fontSize(12).fontColor(this.theme.primary)
        .margin({ top: 10 })
        .onClick((): void => {
          if (!this.backupBusy) {
            this.doImportFromFile();
          }
        })
      if (this.backupMsg.length > 0) {
        Text(this.backupMsg)
          .fontSize(11).fontColor('#B4694A').width('100%').margin({ top: 8 })
      }
      if (this.backups.length > 0) {
        Text(this.tx('backup_existing'))
          .fontSize(11).fontColor(buildPalette(this.theme).subText).width('100%').margin({ top: 10, bottom: 4 })
        ForEach(this.backups, (p: string): void => {
          Row() {
            Text(this.shortName(p))
              .fontSize(11).fontColor(buildPalette(this.theme).subText).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.tx('import'))
              .fontSize(12).fontColor(this.theme.primary)
              .onClick((): void => { this.doImport(p); })
          }
          .width('100%').margin({ top: 2, bottom: 2 })
        }, (p: string): string => p)
      }
    }
    .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  private shortName(p: string): string {
    const i = p.lastIndexOf('/');
    return i >= 0 ? p.substring(i + 1) : p;
  }
}
