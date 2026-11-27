/**
 * 下载管理页 —— M2-E③ UI。
 * 展示下载任务（下载中/已完成/失败），支持暂停、继续、重试、取消、移除、清空已完成。
 * 任务由 PlayDetail / PlaylistDetail / 我的列表 的「下载」动作注入。
 *
 * v1.0.1.x 新增：
 * - 已完成歌曲右侧用播放栏同款的透明主题色播放图标（不再用绿色方块文字块）。
 * - 文件直接落手机「下载」公共目录时，隐藏已经没必要的「导出」按钮并更新目录说明。
 * - 按歌单的多选交互：长按进入、点选切换、全选、更多批量菜单、取消；
 *   另有「全部 / 进行中 / 已完成 / 失败」筛选，方便批量管理。
 */
import { DownloadListItem, MusicInfo, MusicInfoMetaLocal } from '../model/MusicTypes';
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { DownloadManager, formatBytes } from '../core/DownloadManager';
import { PlayController } from '../player/PlayController';
import { I18n } from '../core/I18n';
import { stateEvent, StateEvents, EmptyCallback } from '../store/EventBus';
import { AppState } from '../store/AppState';
import { userNotice } from '../core/UserNotice';
import { exportDownloadedFiles, ExportFileItem } from '../core/DownloadExporter';
import { usePublicStorage, publicStorageFailed } from '../core/DownloadStorage';
import { LONG_PRESS_DURATION_MS } from '../config/GestureConfig';
import { computePopupPos, setPopupAnchor, setPopupContainer, PopupPoint, popupWidthForTexts, popupMaxHeightVp, popupMaxWidthVp } from '../core/Popup';

/** 状态筛选：全部 / 进行中 / 已完成 / 失败 */
const DL_FILTERS: string[] = ['all', 'active', 'done', 'error'];

@Component
export struct DownloadPage {
  @State tasks: DownloadListItem[] = [];
  @State private langTick: number = 0;
  @State private selectMode: boolean = false;
  @State private selected: string[] = [];
  /** 三点浮窗：'' = 关闭；'__batch__' = 多选批量菜单；否则为单曲任务 id */
  @State private menuTaskId: string = '';
  /** 浮窗相对容器的落点，由根 Stack 的 onAreaChange 实时校准（按歌单三点浮窗） */
  @State private popupPos: PopupPoint = { x: 0, y: 0 };
  /** 删除文件是破坏性操作：点一次进确认态，再点一次才真正删 */
  @State private deleteArmed: boolean = false;
  @State private filter: string = 'all';
  /** 长按已触发：吃掉系统随后派发的 click，避免刚选中又被点掉 */
  private longPressed: boolean = false;
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 当前是否为激活标签：激活时把「清空已完成」注册到全局头部 ≡ 左侧 */
  @Prop @Watch('onActiveChanged') active: boolean = false;

  private manager: DownloadManager = DownloadManager.getInstance();
  private controller: PlayController = PlayController.getInstance();
  private refreshCb: () => void = (): void => { this.tasks = this.manager.getSnapshot(); };
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => { this.langTick = this.langTick + 1; };

  aboutToAppear(): void {
    this.manager.init();
    this.manager.subscribe(this.refreshCb);
    this.tasks = this.manager.getSnapshot();
    stateEvent().on(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    this.syncHeader();
  }

  /**
   * 系统返回手势（与其它 Swiper 子模块同一范式）：先关三点浮窗 → 退出多选，
   * 谁消费了就置 uiBackConsumed，Index.onBackPress 据此不再继续退页面。
   */
  private onUiBack = (): void => {
    if (!this.active) {
      return;
    }
    if (this.menuTaskId.length > 0) {
      this.closeMenu();
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.selectMode) {
      this.exitSelect();
      AppState.getInstance().uiBackConsumed = true;
    }
  };

  /** 切模块：激活时注册头部操作，切走时自动关掉三点浮窗并退出多选 */
  private onActiveChanged(): void {
    if (this.active) {
      this.syncHeader();
      return;
    }
    this.closeMenu();
    this.selectMode = false;
    this.selected = [];
  }

  /** 下载页：把「清空已完成」放到全局头部 ≡ 左侧，字号保持 12 */
  private syncHeader(): void {
    if (!this.active) {
      return;
    }
    AppState.getInstance().setHeaderActions([{
      key: 'clear_done',
      text: this.tx('clear_done'),
      fontSize: 12,
      textColor: '#FFFFFF',
      bg: '#C9BBA0',
      onClick: (): void => { this.manager.clearCompleted(); },
    }]);
  }

  /** 取翻译：读取 langTick 是为触发语言切换时的依赖收集与重新渲染 */
  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  aboutToDisappear(): void {
    this.manager.unsubscribe(this.refreshCb);
    stateEvent().off(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
  }

  /** 目录说明随「下载保存位置」设置变化 */
  private dirHint(): string {
    if (!usePublicStorage() || publicStorageFailed()) {
      return this.tx('dl_dir_hint');
    }
    return this.tx('dl_dir_hint_public');
  }

  private filterLabel(f: string): string {
    if (f === 'active') {
      return this.tx('dl_filter_active');
    }
    if (f === 'done') {
      return this.tx('dl_filter_done');
    }
    if (f === 'error') {
      return this.tx('dl_filter_error');
    }
    return this.tx('dl_filter_all');
  }

  /** 当前筛选下可见的任务（全选、批量操作都以它为范围） */
  private visibleTasks(): DownloadListItem[] {
    if (this.filter === 'all') {
      return this.tasks;
    }
    return this.tasks.filter((t: DownloadListItem): boolean => {
      if (this.filter === 'active') {
        return t.status === 'downloading' || t.status === 'paused' || t.status === 'waiting';
      }
      if (this.filter === 'done') {
        return t.status === 'completed';
      }
      return t.status === 'error' || t.status === 'canceled';
    });
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  private toggleSelect(id: string): void {
    if (this.isSelected(id)) {
      this.selected = this.selected.filter((x: string): boolean => x !== id);
    } else {
      this.selected = this.selected.concat([id]);
    }
  }

  /** 全选 / 全不选（只作用于当前筛选可见的任务，与歌单一致是「一键全选」） */
  private toggleSelectAll(): void {
    const ids: string[] = this.visibleTasks().map((t: DownloadListItem): string => t.id);
    const allPicked: boolean = ids.length > 0 && ids.every((id: string): boolean => this.isSelected(id));
    if (allPicked) {
      this.selected = this.selected.filter((id: string): boolean => ids.indexOf(id) < 0);
    } else {
      const merged: string[] = this.selected.slice();
      for (const id of ids) {
        if (merged.indexOf(id) < 0) {
          merged.push(id);
        }
      }
      this.selected = merged;
    }
  }

  private enterSelect(id: string): void {
    this.longPressed = true;
    this.selectMode = true;
    if (!this.isSelected(id)) {
      this.selected = this.selected.concat([id]);
    }
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selected = [];
    this.menuTaskId = '';
    this.deleteArmed = false;
  }

  private openItemMenu(t: DownloadListItem): void {
    this.deleteArmed = false;
    this.menuTaskId = t.id;
    this.popupPos = computePopupPos(this.menuWidth(), this.menuHeight());
  }

  private openBatchMenu(): void {
    if (this.selected.length === 0) {
      userNotice().info(this.tx('dl_no_selection'));
      return;
    }
    this.deleteArmed = false;
    this.menuTaskId = '__batch__';
    this.popupPos = computePopupPos(this.menuWidth(), this.menuHeight());
  }

  private closeMenu(): void {
    this.menuTaskId = '';
    this.deleteArmed = false;
  }

  /** 当前三点浮窗的菜单项数（单曲按状态给不同项，批量固定 5 项） */
  private menuItems(): string[] {
    if (this.menuTaskId === '__batch__') {
      return ['delete', 'remove', 'cancel_task', 'play', 'export_to', 'cancel_text'];
    }
    const t: DownloadListItem | undefined = this.findTask(this.menuTaskId);
    if (t === undefined) {
      return ['cancel_text'];
    }
    if (t.status === 'completed') {
      return ['play', 'export_to', 'delete', 'remove', 'cancel_text'];
    }
    if (t.status === 'downloading') {
      return ['pause', 'cancel_task', 'remove', 'cancel_text'];
    }
    if (t.status === 'paused' || t.status === 'waiting') {
      return ['resume', 'cancel_task', 'remove', 'cancel_text'];
    }
    return ['retry', 'cancel_task', 'remove', 'cancel_text'];
  }

  private menuHeight(): number {
    return 36 + 42 * this.menuItems().length + 8;
  }

  private menuWidth(): number {
    const labels: string[] = this.menuItems().map((k: string): string => this.menuLabel(k));
    const w: number = popupWidthForTexts(labels, 14, 16);
    const capped: number = w > popupMaxWidthVp() ? popupMaxWidthVp() : w;
    return capped < 176 ? 176 : capped;
  }

  private findTask(id: string): DownloadListItem | undefined {
    for (const t of this.tasks) {
      if (t.id === id) {
        return t;
      }
    }
    return undefined;
  }

  private menuLabel(key: string): string {
    if (key === 'play') {
      return this.tx('play');
    }
    if (key === 'export_to') {
      return this.tx('export_to');
    }
    if (key === 'delete') {
      return this.deleteArmed ? this.tx('dl_delete_confirm') : this.tx('dl_delete_file');
    }
    if (key === 'remove') {
      return this.tx('remove_record');
    }
    if (key === 'pause') {
      return this.tx('pause');
    }
    if (key === 'resume') {
      return this.tx('resume');
    }
    if (key === 'retry') {
      return this.tx('retry');
    }
    if (key === 'cancel_task') {
      return this.tx('cancel');
    }
    if (key === 'cancel_text') {
      return this.tx('cancel');
    }
    return '';
  }

  private menuColor(key: string): string {
    if (key === 'delete') {
      return this.deleteArmed ? '#C0504D' : this.theme.font;
    }
    if (key === 'cancel_text') {
      return buildPalette(this.theme).subText;
    }
    return this.theme.font;
  }

  /** 批量操作收尾：提示一次、退出多选 */
  private finishBatch(): void {
    userNotice().info(this.tx('dl_batch_done'));
    this.exitSelect();
  }

  private toLocalInfo(t: DownloadListItem): MusicInfo | null {
    if (t.filePath === undefined || t.filePath.length === 0) {
      return null;
    }
    const localMeta: MusicInfoMetaLocal = {
      songId: t.musicInfo.id,
      albumName: '',
      picUrl: null,
      filePath: t.filePath,
      ext: t.ext,
    };
    return {
      id: 'dl_' + t.musicInfo.id + '_' + t.quality,
      name: t.musicInfo.name,
      singer: t.musicInfo.singer,
      source: 'local',
      interval: t.musicInfo.interval,
      meta: localMeta,
    };
  }

  private playSelected(): void {
    const list: MusicInfo[] = [];
    for (const t of this.tasks) {
      if (!this.isSelected(t.id) || t.status !== 'completed') {
        continue;
      }
      const m: MusicInfo | null = this.toLocalInfo(t);
      if (m !== null) {
        list.push(m);
      }
    }
    if (list.length > 0) {
      this.controller.playMusicList(list, 0);
    }
    this.closeMenu();
  }

  /** 把已下载任务整理成一次 save 面板可批量导出的文件清单 */
  private exportItems(tasks: DownloadListItem[]): ExportFileItem[] {
    const items: ExportFileItem[] = [];
    for (const t of tasks) {
      if (t.status !== 'completed' || t.filePath.length === 0) {
        continue;
      }
      // 已在公共目录的文件也允许再归类到用户指定的其它子文件夹（save 面板由用户定目标）
      items.push({
        srcPath: t.filePath,
        displayName: t.musicInfo.name + ' - ' + t.musicInfo.singer,
        ext: t.ext,
      });
    }
    return items;
  }

  private async exportTo(tasks: DownloadListItem[]): Promise<void> {
    const items: ExportFileItem[] = this.exportItems(tasks);
    if (items.length === 0) {
      userNotice().warn(this.tx('export_fail'));
      return;
    }
    const ok: boolean = await exportDownloadedFiles(items);
    if (ok) {
      userNotice().info(this.tx('export_to_done'));
    }
    this.closeMenu();
  }

  /** 三点浮窗某个菜单项被点击 */
  private onMenuAction(key: string): void {
    if (key === 'cancel_text') {
      this.closeMenu();
      return;
    }
    if (this.menuTaskId === '__batch__') {
      this.onBatchAction(key);
      return;
    }
    const t: DownloadListItem | undefined = this.findTask(this.menuTaskId);
    if (t === undefined) {
      this.closeMenu();
      return;
    }
    if (key === 'play') {
      this.playLocal(t);
      this.closeMenu();
    } else if (key === 'export_to') {
      void this.exportTo([t]);
    } else if (key === 'delete') {
      if (!this.deleteArmed) {
        this.deleteArmed = true;
        return;
      }
      this.manager.batchRemove([t.id], true);
      this.closeMenu();
    } else if (key === 'remove') {
      this.manager.remove(t.id);
      this.closeMenu();
    } else if (key === 'pause') {
      this.manager.pause(t.id);
      this.closeMenu();
    } else if (key === 'resume') {
      this.manager.resume(t.id);
      this.closeMenu();
    } else if (key === 'retry') {
      this.manager.retry(t.id);
      this.closeMenu();
    } else if (key === 'cancel_task') {
      this.manager.cancel(t.id);
      this.closeMenu();
    }
  }

  private onBatchAction(key: string): void {
    if (key === 'delete') {
      if (!this.deleteArmed) {
        this.deleteArmed = true;
        return;
      }
      this.manager.batchRemove(this.selected.slice(), true);
      this.finishBatch();
    } else if (key === 'remove') {
      this.manager.batchRemove(this.selected.slice(), false);
      this.finishBatch();
    } else if (key === 'cancel_task') {
      this.manager.batchCancel(this.selected.slice());
      this.finishBatch();
    } else if (key === 'play') {
      this.playSelected();
    } else if (key === 'export_to') {
      const tasks: DownloadListItem[] = [];
      for (const t of this.tasks) {
        if (this.isSelected(t.id)) {
          tasks.push(t);
        }
      }
      void this.exportTo(tasks);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text(this.dirHint())
          .fontSize(11).fontColor(buildPalette(this.theme).subText)
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })

        // 状态筛选 + 多选入口（与歌单的编辑/多选同一层级）
        Row() {
          ForEach(DL_FILTERS, (f: string): void => {
            Text(this.filterLabel(f))
              .fontSize(11)
              .fontColor(this.filter === f ? '#FFFFFF' : buildPalette(this.theme).pillText)
              .backgroundColor(this.filter === f ? this.theme.primary : buildPalette(this.theme).pillBg)
              .borderRadius(12)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .margin({ right: 6 })
              .onClick((): void => { this.filter = f; })
          }, (f: string): string => f)
          Blank()
          Text(this.selectMode ? this.tx('cancel') : this.tx('dl_multi'))
            .fontSize(12).fontColor(this.theme.primary)
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .onClick((): void => {
              if (this.selectMode) {
                this.exitSelect();
              } else {
                this.selectMode = true;
              }
            })
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 6 })

        // 多选工具条：已选数量 / 全选 / 更多 / 取消（按歌单详情）
        if (this.selectMode) {
          Row() {
            Text(this.tx('dl_selected') + ' ' + this.selected.length.toString())
              .fontSize(12).fontColor(this.theme.primary)
            Blank()
            Text(this.tx('dl_select_all'))
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick((): void => { this.toggleSelectAll(); })
            Image($r('app.media.ic_more'))
              .width(18).height(18)
              .fillColor(this.selected.length > 0 ? this.theme.primary : buildPalette(this.theme).subText)
              .margin({ left: 6 })
              .onClick((e: ClickEvent): void => {
                setPopupAnchor(e.windowX, e.windowY);
                this.openBatchMenu();
              })
            Text(this.tx('cancel'))
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .padding({ left: 8, right: 0, top: 4, bottom: 4 })
              .margin({ left: 4 })
              .onClick((): void => { this.exitSelect(); })
          }
          .width('100%').padding({ left: 16, right: 16, top: 2, bottom: 6 })
        }

        if (this.visibleTasks().length === 0) {
          Column() {
            Text(this.tx('dl_empty'))
              .fontSize(14).fontColor(buildPalette(this.theme).subText)
              .margin({ top: 40 })
            Text(this.tx('dl_empty_hint'))
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .margin({ top: 8 })
          }
          .width('100%')
        } else {
          List() {
            ForEach(this.visibleTasks(), (t: DownloadListItem): void => {
              ListItem() {
                this.taskCard(t)
              }
            }, (t: DownloadListItem): string =>
              // @Builder 按值传参：key 必须拼上会变的字段与选中态，否则状态/勾选都不刷新
              t.id + '|' + t.status + '|' + t.statusText + '|' +
              t.downloaded.toString() + '|' + t.total.toString() + '|' + t.speed + '|' +
              (this.isSelected(t.id) ? '1' : '0'))
          }
          .layoutWeight(1).width('100%')
          .divider({ strokeWidth: 0.5, color: buildPalette(this.theme).pillBg })
        }
      }
      .width('100%').height('100%').backgroundColor(this.theme.mainBackground)

      // 三点操作浮窗（单曲 / 批量共用）——交互与歌单三点菜单完全一致：
      // 半透明遮罩点击关闭、贴右就近弹出、内容自适应宽高、删除文件需二次确认。
      if (this.menuTaskId.length > 0) {
        Column() {
          Column()
            .width('100%').height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => { this.closeMenu(); })

          Column() {
            Text(this.menuTaskId === '__batch__'
              ? this.tx('dl_selected') + ' ' + this.selected.length.toString()
              : (this.findTask(this.menuTaskId)?.musicInfo.name ?? ''))
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 6 })
            ForEach(this.menuItems(), (key: string): void => {
              Row() {
                Text(this.menuLabel(key))
                  .fontSize(14).fontColor(this.menuColor(key))
              }
              .width('100%').height(42)
              .padding({ left: 16, right: 16 })
              .onClick((): void => { this.onMenuAction(key); })
            }, (key: string): string => key + (key === 'delete' && this.deleteArmed ? '_armed' : ''))
          }
          .width(this.menuWidth())
          .height(this.menuHeight())
          .constraintSize({ maxHeight: popupMaxHeightVp() })
          .backgroundColor(buildPalette(this.theme).card)
          .borderRadius(12)
          .border({ width: 1, color: buildPalette(this.theme).divider })
          .position({ x: this.popupPos.x, y: this.popupPos.y })
          .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 })
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      // 记录浮窗容器（根 Stack）在窗口中的真实位置，供 computePopupPos 换算成容器相对坐标
      setPopupContainer(Number(area.globalPosition.x), Number(area.globalPosition.y));
      if (this.menuTaskId.length > 0) {
        this.popupPos = computePopupPos(this.menuWidth(), this.menuHeight());
      }
    })
  }

  @Builder
  taskCard(t: DownloadListItem) {
    Column() {
      Row() {
        if (this.selectMode) {
          // 与歌单多选同款：应用内 ic_check / ic_checkbox_empty，fillColor 自动跟随主题
          Image(this.isSelected(t.id) ? $r('app.media.ic_check') : $r('app.media.ic_checkbox_empty'))
            .width(20).height(20)
            .fillColor(this.isSelected(t.id) ? this.theme.primary : buildPalette(this.theme).subText)
            .margin({ right: 12 })
        }
        Column() {
          Text(t.musicInfo.name)
            .fontSize(15).fontColor(this.theme.font)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(t.musicInfo.singer + ' · ' + t.quality.toUpperCase())
            .fontSize(12).fontColor(buildPalette(this.theme).subText)
            .margin({ top: 3 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        if (t.status === 'completed' && !this.selectMode) {
          // 播放栏同款：透明底 + 主题色三角图标，不再是绿色方块里的白三角
          Button() {
            Image($r('app.media.ic_play'))
              .width(28).height(28).fillColor(this.theme.primary)
          }
          .type(ButtonType.Normal).width(40).height(40)
          .backgroundColor(Color.Transparent).stateEffect(false)
          .onClick((): void => { this.playLocal(t); })
        }
        // 行尾三点：打开本曲操作浮窗（与歌单歌曲行 ⋮ 同一交互）
        if (!this.selectMode) {
          Image($r('app.media.ic_more'))
            .width(20).height(20).fillColor(buildPalette(this.theme).subText)
            .margin({ left: 4 })
            .onClick((e: ClickEvent): void => {
              setPopupAnchor(e.windowX, e.windowY);
              this.openItemMenu(t);
            })
        }
      }
      .width('100%')

      if (t.status === 'downloading' || t.status === 'paused' || t.status === 'waiting') {
        Row() {
          Progress({ value: Math.round(t.progress * 100), total: 100, type: ProgressType.Linear })
            .width('100%').height(6)
            .color(this.theme.primary)
        }
        .width('100%').margin({ top: 6 })
        Row() {
          Text(this.statusLine(t))
            .fontSize(11).fontColor(buildPalette(this.theme).subText)
          Blank()
          if (t.speed.length > 0) {
            Text(t.speed).fontSize(11).fontColor(buildPalette(this.theme).subText)
          }
        }
        .width('100%').margin({ top: 3 })
      } else if (t.status === 'completed') {
        Text(this.tx('done') + ' · ' + formatBytes(t.total))
          .fontSize(11).fontColor('#7CAF8C')
          .margin({ top: 4 })
      } else if (t.status === 'error') {
        Text(t.statusText)
          .fontSize(11).fontColor('#C0504D')
          .margin({ top: 4 })
      }

      // 操作已收进行尾 ⋮ 浮窗：播放/暂停/继续/重试/取消/导出到.../删除/移除记录
      // 多选态整行点击即切换选中（与歌单详情一致），此时不显示 ⋮
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .onClick((): void => {
      if (this.longPressed) {
        this.longPressed = false;
        return;
      }
      if (this.selectMode) {
        this.toggleSelect(t.id);
      }
    })
    .gesture(LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS })
      .onAction((): void => { this.enterSelect(t.id); }))
  }

  /** 状态行文案：排队/取链中显示阶段提示，不暴露误导性的 0B/0B；真正开始传输后才显示字节 */
  private statusLine(t: DownloadListItem): string {
    const label: string = t.status === 'waiting' ? this.tx('queuing') : t.statusText;
    if (t.downloaded <= 0 && t.total <= 0) {
      if (t.status === 'waiting') {
        return label + ' · 等待前面的下载完成';
      }
      // 取链进度文案本身已经写明「正在…获取下载链接」，不要重复拼后缀
      if (label.indexOf('获取下载链接') >= 0 || label.indexOf('链接') >= 0) {
        return label;
      }
      return label + ' · 正在获取下载链接…';
    }
    return label + '  ' + formatBytes(t.downloaded) + ' / ' + formatBytes(t.total);
  }

  private playLocal(t: DownloadListItem): void {
    const local: MusicInfo | null = this.toLocalInfo(t);
    if (local !== null) {
      this.controller.playMusicList([local], 0);
    }
  }
}
