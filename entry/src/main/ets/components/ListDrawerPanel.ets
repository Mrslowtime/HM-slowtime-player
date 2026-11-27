import { ThemeInfo, buildPalette, ThemePalette } from '../theme/Themes';
import { UserListInfo } from '../model/MusicTypes';
import { AppState } from '../store/AppState';
import { stateEvent, StateEvents } from '../store/EventBus';
import { ListManager } from '../core/ListManager';
import { userNotice } from '../core/UserNotice';
import { ListActionMenu } from './ListActionMenu';
import { LONG_PRESS_DURATION_MS } from '../config/GestureConfig';
import { setPopupAnchor } from '../core/Popup';

const DEFAULT_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};
/** 抽屉单行高度，拖动时按位移换算跨过了几行 */
const ROW_H: number = 46;

/**
 * 「我的列表」抽屉：全部列表的有序清单。
 *
 * 普通态：点按切换列表；长按任意项进入管理态并高亮。
 * 管理态：点选其它项追加多选；长按任意高亮项上下拖动，选中组保持相对顺序整体移动；
 *         每项另有 ↑/↓ 作为不依赖手势的兜底；底部可全选 / 删除 / 完成。
 * 退出：顶部导航条「‹ 返回」、点遮罩、系统返回手势（UI_BACK，先退管理态再关抽屉）。
 *
 * 手势说明：管理态用 priorityGesture + 禁用 Scroll 滚动，避免上次「横向 Scroll 吃掉
 * LongPress+Pan 手势组」导致长按无反应的问题；不使用抖动动画。
 */
@Component
export struct ListDrawerPanel {
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  @Prop @Watch('onListsChanged') lists: UserListInfo[] = [];
  @Prop activeId: string = '';
  /** 由主行 chip 长按打开时，直接进入管理态并高亮该列表 */
  @Prop initialSelectId: string = '';
  onSelect: (id: string) => void = () => {};
  onReorder: (ids: string[]) => void = () => {};
  onDelete: (ids: string[]) => void = () => {};
  onChanged: () => void = () => {};
  onClose: () => void = () => {};

  @State private order: UserListInfo[] = [];
  @State private selectMode: boolean = false;
  @State private sel: string[] = [];
  @State private dragging: boolean = false;
  /** 当前打开三点菜单的列表 id，'' = 未打开 */
  @State private menuId: string = '';

  /** PanGesture 最近一次累计位移，长按触发时作为本次拖动的基准 */
  private lastPanY: number = 0;
  private panBaseY: number = 0;
  private appliedSteps: number = 0;
  private dragAnchor: string = '';

  private onUiBack = (): void => {
    // 分层消费：先关三点菜单 → 再退管理态 → 最后关抽屉
    if (this.menuId.length > 0) {
      this.menuId = '';
    } else if (this.selectMode) {
      this.exitSelect();
    } else {
      this.onClose();
    }
    AppState.getInstance().uiBackConsumed = true;
  };

  aboutToAppear(): void {
    this.order = this.lists.slice();
    if (this.initialSelectId.length > 0) {
      this.selectMode = true;
      this.sel = [this.initialSelectId];
    }
    stateEvent().on(StateEvents.UI_BACK, this.onUiBack);
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.UI_BACK, this.onUiBack);
  }

  private onListsChanged(): void {
    this.order = this.lists.slice();
  }

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  /** 内容区点击：管理态切换多选；普通态切换到该列表 */
  private onContentClick(id: string, inSelectMode: boolean): void {
    if (inSelectMode) {
      this.toggleSel(id);
    } else {
      this.onSelect(id);
    }
  }

  private isSel(id: string): boolean {
    return this.sel.indexOf(id) >= 0;
  }

  private isActive(u: UserListInfo): boolean {
    return u.id === this.activeId;
  }

  private indexOf(u: UserListInfo): number {
    for (let i = 0; i < this.order.length; i++) {
      if (this.order[i].id === u.id) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 行背景：固定列表与自建列表默认都无背景（完全一致），
   * 只有「被点选」时才加浅色底纹——管理态选中，或点开该行的三点菜单。
   */
  private rowBg(u: UserListInfo): string {
    if (this.isSel(u.id) || this.menuId === u.id) {
      return this.pal().activeTint;
    }
    return '#00000000';
  }

  private rowIndexText(u: UserListInfo): string {
    const i: number = this.indexOf(u);
    return (i + 1).toString();
  }

  /** 三点菜单当前作用的列表（找不到时给空壳兜底，避免可空类型进 @Builder） */
  private menuListInfo(): UserListInfo {
    for (const u of this.order) {
      if (u.id === this.menuId) {
        return u;
      }
    }
    return { id: this.menuId, name: '', locationUpdateTime: 0 };
  }

  private menuSongCount(): number {
    return AppState.getInstance().getList(this.menuId).length;
  }

  private toggleSelectMode(): void {
    if (this.selectMode) {
      this.exitSelect();
    } else {
      this.selectMode = true;
      this.sel = [];
    }
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.sel = [];
    this.dragging = false;
    this.dragAnchor = '';
  }

  private enterSelect(id: string): void {
    this.selectMode = true;
    this.sel = [id];
  }

  private toggleSel(id: string): void {
    if (this.isSel(id)) {
      this.sel = this.sel.filter((x: string): boolean => x !== id);
      if (this.sel.length === 0) {
        this.exitSelect();
      }
    } else {
      this.sel = this.sel.concat([id]);
    }
  }

  private toggleAll(): void {
    if (this.sel.length === this.order.length) {
      this.sel = [];
    } else {
      this.sel = this.order.map((u: UserListInfo): string => u.id);
    }
  }

  private deleteIds(): string[] {
    return this.sel.filter((id: string): boolean => !ListManager.getInstance().isFixedList(id));
  }

  private requestDelete(): void {
    const ids: string[] = this.deleteIds();
    if (ids.length === 0) {
      userNotice().info('固定列表不能删除，请选择自建列表');
      return;
    }
    this.onDelete(ids);
  }

  /** 长按高亮项：开始一次拖动（PanGesture 与长按并行识别，这里记录位移基准） */
  private startDrag(id: string): void {
    if (!this.isSel(id)) {
      this.sel = [id];
    }
    this.selectMode = true;
    this.dragAnchor = id;
    this.panBaseY = this.lastPanY;
    this.appliedSteps = 0;
    this.dragging = true;
  }

  private onPanUpdate(ev: GestureEvent): void {
    this.lastPanY = ev.offsetY;
    if (!this.dragging) {
      return;
    }
    const steps: number = Math.round((ev.offsetY - this.panBaseY) / ROW_H);
    if (steps !== this.appliedSteps) {
      this.moveSelectedBy(steps - this.appliedSteps);
      this.appliedSteps = steps;
    }
  }

  private finishDrag(): void {
    if (!this.dragging) {
      return;
    }
    this.dragging = false;
    this.dragAnchor = '';
    this.submitOrder();
  }

  private submitOrder(): void {
    this.onReorder(this.order.map((u: UserListInfo): string => u.id));
  }

  /**
   * 选中组整体平移 delta 行：组内相对顺序保持不变，其余列表按原顺序填充空位。
   * 这是「多选后拖动，选中的所有列表都以相对位置调整」的核心。
   */
  private moveSelectedBy(delta: number): void {
    if (delta === 0 || this.sel.length === 0) {
      return;
    }
    const set: Set<string> = new Set(this.sel);
    const chosen: UserListInfo[] = this.order.filter((u: UserListInfo): boolean => set.has(u.id));
    const rest: UserListInfo[] = this.order.filter((u: UserListInfo): boolean => !set.has(u.id));
    let first: number = -1;
    for (let i = 0; i < this.order.length; i++) {
      if (set.has(this.order[i].id)) {
        first = i;
        break;
      }
    }
    if (first < 0) {
      return;
    }
    let at: number = first + delta;
    if (at < 0) {
      at = 0;
    }
    if (at > rest.length) {
      at = rest.length;
    }
    const next: UserListInfo[] = rest.slice(0, at).concat(chosen, rest.slice(at));
    this.order = next;
  }

  /** ↑/↓ 兜底：不依赖手势，选中组同样整体移动一格 */
  private step(delta: number): void {
    if (this.sel.length === 0) {
      return;
    }
    this.moveSelectedBy(delta);
    this.submitOrder();
  }

  @Builder
  private RowContent(u: UserListInfo, inSelectMode: boolean) {
    Row() {
      if (inSelectMode) {
        // 用圆点表示选中（不再出现「勾」），高亮由背景色与边框承担
        Text(this.isSel(u.id) ? '●' : '○')
          .fontSize(13)
          .fontColor(this.isSel(u.id) ? this.theme.primary : this.pal().subText)
          .width(26)
          .textAlign(TextAlign.Center)
          .onClick((): void => { this.onContentClick(u.id, inSelectMode); })
      } else {
        Text(this.rowIndexText(u))
          .fontSize(11)
          .fontColor(this.pal().subText)
          .width(26)
          .textAlign(TextAlign.Center)
          .onClick((): void => { this.onContentClick(u.id, inSelectMode); })
      }
      Text(u.name)
        .fontSize(14)
        .fontColor(this.isActive(u) ? this.theme.primary : this.theme.font)
        .fontWeight(this.isActive(u) ? FontWeight.Bold : FontWeight.Normal)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .onClick((): void => { this.onContentClick(u.id, inSelectMode); })
      if (inSelectMode) {
        Text('↑')
          .fontSize(16).fontColor(this.theme.primary)
          .width(30).height(40).textAlign(TextAlign.Center)
          .onClick((): void => { this.step(-1); })
        Text('↓')
          .fontSize(16).fontColor(this.theme.primary)
          .width(30).height(40).textAlign(TextAlign.Center)
          .onClick((): void => { this.step(1); })
      } else {
        // 3 个竖点：与歌曲行同款图标，点击弹出操作浮窗（不再有 ✕ 删除 / ✓ 当前标记）
        Button() {
          Image($r('app.media.ic_more')).width(16).height(16).fillColor(this.pal().subText)
        }
        .type(ButtonType.Normal)
        .width(30).height(40)
        .backgroundColor(Color.Transparent)
        .stateEffect(false)
        .onClick((e: ClickEvent): void => {
          // 记录点击位置，使弹出的操作浮窗贴近该行 ⋮
          setPopupAnchor(e.windowX, e.windowY);
          this.menuId = u.id;
        })
      }
    }
    .width('100%')
  }

  @Builder
  private NormalRow(u: UserListInfo) {
    Row() {
      this.RowContent(u, false);
    }
    .width('100%').height(ROW_H)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.rowBg(u))
    .borderRadius(8)
    .margin({ bottom: 2 })
    .gesture(LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS }).onAction((): void => {
      this.lastPanY = 0;
      this.enterSelect(u.id);
    }))
  }

  @Builder
  private SelectRow(u: UserListInfo) {
    Row() {
      this.RowContent(u, true);
    }
    .width('100%').height(ROW_H)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.rowBg(u))
    .border({ width: this.isSel(u.id) ? 1 : 0, color: this.theme.primary })
    .borderRadius(8)
    .margin({ bottom: 2 })
    .opacity(this.dragging && this.isSel(u.id) ? 0.85 : 1)
    .priorityGesture(
      GestureGroup(GestureMode.Parallel,
        LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS })
          .onAction((): void => { this.startDrag(u.id); })
          .onActionEnd((): void => { this.finishDrag(); }),
        PanGesture({ direction: PanDirection.Vertical, distance: 1 })
          .onActionUpdate((ev: GestureEvent): void => { this.onPanUpdate(ev); })
          .onActionEnd((): void => { this.finishDrag(); })
      )
    )
  }

  @Builder
  private ListRow(u: UserListInfo) {
    if (this.selectMode) {
      this.SelectRow(u);
    } else {
      this.NormalRow(u);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        // 顶部导航条：返回 / 标题 / 管理
        Row() {
          Text('‹ 返回')
            .fontSize(13).fontColor(this.theme.primary)
            .width(62)
            .onClick((): void => { this.onClose(); })
          Text('全部列表')
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
            .layoutWeight(1).textAlign(TextAlign.Center)
          Text(this.selectMode ? '完成' : '管理')
            .fontSize(13).fontColor(this.theme.primary)
            .width(62).textAlign(TextAlign.End)
            .onClick((): void => { this.toggleSelectMode(); })
        }
        .width('100%').height(40)

        Text(this.selectMode
          ? '已选 ' + this.sel.length.toString() + ' 个 · 长按高亮项上下拖动，或点 ↑↓ 微调'
          : '点按切换列表 · 长按进入管理 · 前 4 个显示在顶部标签栏')
          .fontSize(11).fontColor(this.pal().subText)
          .width('100%')
          .padding({ top: 2, bottom: 8 })

        Scroll() {
          Column() {
            ForEach(this.order, (u: UserListInfo): void => {
              this.ListRow(u);
            }, (u: UserListInfo): string => u.id)
          }
          .width('100%')
        }
        .enableScrollInteraction(!this.selectMode)
        .constraintSize({ maxHeight: 360 })
        .width('100%')
        .scrollBar(BarState.Off)

        if (this.selectMode) {
          Row() {
            Text('全选')
              .fontSize(12).fontColor(this.pal().subText)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .onClick((): void => { this.toggleAll(); })
            Text('删除')
              .fontSize(12).fontColor('#C0553F')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin({ left: 8 })
              .onClick((): void => { this.requestDelete(); })
            Blank()
            Text('取消选择')
              .fontSize(12).fontColor(this.theme.primary)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .onClick((): void => { this.exitSelect(); })
          }
          .width('100%').height(44)
        }
        Row().height(10)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8 })
      .backgroundColor(this.pal().card)
      .borderRadius(16)

      // 三点菜单浮窗挂在抽屉最外层：遮罩能盖满整屏，且层级高于抽屉内容
      if (this.menuId.length > 0) {
        ListActionMenu({
          list: this.menuListInfo(),
          theme: this.theme,
          songCount: this.menuSongCount(),
          onClose: (): void => { this.menuId = ''; },
          onDelete: (id: string): void => { this.onDelete([id]); },
          onChanged: (): void => { this.onChanged(); },
        })
      }
    }
    .width('100%').height('100%')
  }
}
