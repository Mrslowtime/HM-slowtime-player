/**
 * 通用「分类标签栏 + 全部分类抽屉」。
 *
 * 与「我的列表」保持同一套交互：
 *  - 前 4 个分类常驻胶囊标签栏，超过 4 个时末尾显示同尺寸「⋯」打开抽屉；
 *  - 点按切换分类；长按任意标签直接打开抽屉并进入管理态、高亮该分类；
 *  - 管理态：点选追加多选，长按任意高亮项上下拖动，选中组保持相对位置整体移动；
 *    每行另有 ↑/↓ 作为不依赖手势的兜底；三点菜单可「置顶」；
 *  - 退出：导航条「‹ 返回」、点遮罩、系统返回手势（先退管理态再关抽屉）。
 *
 * 拆成两个组件：CategoryTabBar 只负责标签行（可放进任何 Column），
 * CategoryDrawer 是全屏遮罩层，必须挂在页面最外层 Stack，避免被父容器裁切。
 */
import { ThemeInfo, buildPalette, ThemePalette } from '../theme/Themes';
import { LocalCategoryItem } from '../core/LocalCategoryOrder';
import { AppState } from '../store/AppState';
import { stateEvent, StateEvents } from '../store/EventBus';
import { LONG_PRESS_DURATION_MS } from '../config/GestureConfig';
import { setPopupAnchor, computePopupPos, setPopupContainer, PopupPoint, popupWidthForTexts } from '../core/Popup';

const DEFAULT_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};

interface CategoryMenuOption {
  id: number;
  label: string;
}

const CATEGORY_MENU_ITEMS: CategoryMenuOption[] = [
  { id: 1, label: '置顶' },
];
/** 标签栏最多常驻 4 个，其余收进抽屉 */
const VISIBLE_COUNT: number = 4;
/** 与「我的列表」标签胶囊完全一致的尺寸 */
const CHIP_MIN_WIDTH: number = 76;
const CHIP_HEIGHT: number = 28;
/** 抽屉单行高度，拖动时按位移换算跨过了几行 */
const ROW_H: number = 46;

@Component
export struct CategoryTabBar {
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  @Prop categories: LocalCategoryItem[] = [];
  @Prop activeId: string = 'songs';
  onSelect: (id: string) => void = () => {};
  /** 请求打开抽屉；参数是被长按的分类 id（普通点击 ⋯ 时传 ''） */
  onOpenDrawer: (id: string) => void = () => {};

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  private isMoreActive(): boolean {
    for (let i = VISIBLE_COUNT; i < this.categories.length; i++) {
      if (this.categories[i].id === this.activeId) {
        return true;
      }
    }
    return false;
  }

  /**
   * 胶囊是否选中。必须在 Builder 的属性表达式里读取 activeId：
   * @Builder 的参数按值传递，由调用方算好 boolean 传进来时状态变化不会刷新，
   * 会出现「点了第二个标签高亮还停在第一个」的问题。
   */
  private chipOn(id: string, more: boolean): boolean {
    return more ? this.isMoreActive() : this.activeId === id;
  }

  @Builder
  private Chip(label: string, id: string, more: boolean, onTap: () => void, onLong: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(this.chipOn(id, more) ? '#FFFFFF' : this.pal().pillText)
      .backgroundColor(this.chipOn(id, more) ? this.theme.primary : this.pal().pillBg)
      .borderRadius(14)
      .constraintSize({ minWidth: more ? 26 : CHIP_MIN_WIDTH })
      .height(CHIP_HEIGHT)
      .textAlign(TextAlign.Center)
      .padding({ left: more ? 8 : 12, right: more ? 8 : 12 })
      .margin({ right: 8 })
      .onClick((): void => { onTap(); })
      .gesture(LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS }).onAction((): void => {
        onLong();
      }))
  }

  build() {
    Scroll() {
      Row() {
        ForEach(this.categories.slice(0, VISIBLE_COUNT), (c: LocalCategoryItem): void => {
          this.Chip(c.name, c.id, false,
            (): void => { this.onSelect(c.id); },
            (): void => { this.onOpenDrawer(c.id); });
        }, (c: LocalCategoryItem): string => c.id)
        if (this.categories.length > VISIBLE_COUNT) {
          this.Chip('⋯', '', true,
            (): void => { this.onOpenDrawer(''); },
            (): void => { this.onOpenDrawer(''); });
        }
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(40)
    .padding({ left: 16 })
  }
}

@Component
export struct CategoryDrawer {
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  @Prop @Watch('onCategoriesChanged') categories: LocalCategoryItem[] = [];
  @Prop activeId: string = 'songs';
  /** 由标签长按打开时，直接进入管理态并高亮该分类 */
  @Prop initialSelectId: string = '';
  @Prop title: string = '全部分类';
  onSelect: (id: string) => void = () => {};
  onReorder: (ids: string[]) => void = () => {};
  onClose: () => void = () => {};

  @State private order: LocalCategoryItem[] = [];
  @State private selectMode: boolean = false;
  @State private sel: string[] = [];
  @State private dragging: boolean = false;
  @State private menuId: string = '';
  /** 菜单浮窗相对容器的落点，由 MenuPopup 根 Stack 的 onAreaChange 实时校准 */
  @State private menuPopupPos: PopupPoint = { x: 0, y: 0 };

  private lastPanY: number = 0;
  private panBaseY: number = 0;
  private appliedSteps: number = 0;

  private onUiBack = (): void => {
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
    this.order = this.categories.slice();
    if (this.initialSelectId.length > 0) {
      this.selectMode = true;
      this.sel = [this.initialSelectId];
    }
    stateEvent().on(StateEvents.UI_BACK, this.onUiBack);
    this.menuPopupPos = computePopupPos(this.menuWidth(), 36 + 42 + 8);
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.UI_BACK, this.onUiBack);
  }

  private onCategoriesChanged(): void {
    this.order = this.categories.slice();
  }

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  private isSel(id: string): boolean {
    return this.sel.indexOf(id) >= 0;
  }

  /** 默认无背景，只有被选中 / 被点开三点菜单时才加浅色底纹 */
  private rowBg(id: string): string {
    return (this.isSel(id) || this.menuId === id) ? this.pal().activeTint : '#00000000';
  }

  private indexOf(c: LocalCategoryItem): number {
    for (let i = 0; i < this.order.length; i++) {
      if (this.order[i].id === c.id) {
        return i;
      }
    }
    return -1;
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

  private onContentClick(id: string): void {
    if (this.selectMode) {
      this.toggleSel(id);
    } else {
      this.onSelect(id);
      this.onClose();
    }
  }

  private startDrag(id: string): void {
    if (!this.isSel(id)) {
      this.sel = [id];
    }
    this.selectMode = true;
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
    this.submitOrder();
  }

  private submitOrder(): void {
    this.onReorder(this.order.map((c: LocalCategoryItem): string => c.id));
  }

  /** 选中组整体平移 delta 行，组内相对顺序不变 */
  private moveSelectedBy(delta: number): void {
    if (delta === 0 || this.sel.length === 0) {
      return;
    }
    const set: Set<string> = new Set(this.sel);
    const chosen: LocalCategoryItem[] = this.order.filter((c: LocalCategoryItem): boolean => set.has(c.id));
    const rest: LocalCategoryItem[] = this.order.filter((c: LocalCategoryItem): boolean => !set.has(c.id));
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
    this.order = rest.slice(0, at).concat(chosen, rest.slice(at));
  }

  private step(delta: number): void {
    if (this.sel.length === 0) {
      return;
    }
    this.moveSelectedBy(delta);
    this.submitOrder();
  }

  private pinToTop(): void {
    const id: string = this.menuId;
    this.menuId = '';
    const picked: LocalCategoryItem[] = this.order.filter((c: LocalCategoryItem): boolean => c.id === id);
    if (picked.length === 0) {
      return;
    }
    this.order = picked.concat(this.order.filter((c: LocalCategoryItem): boolean => c.id !== id));
    this.submitOrder();
  }

  @Builder
  private RowContent(c: LocalCategoryItem) {
    Row() {
      if (this.selectMode) {
        Text(this.isSel(c.id) ? '●' : '○')
          .fontSize(13)
          .fontColor(this.isSel(c.id) ? this.theme.primary : this.pal().subText)
          .width(26).textAlign(TextAlign.Center)
          .onClick((): void => { this.onContentClick(c.id); })
      } else {
        Text((this.indexOf(c) + 1).toString())
          .fontSize(11).fontColor(this.pal().subText)
          .width(26).textAlign(TextAlign.Center)
          .onClick((): void => { this.onContentClick(c.id); })
      }
      Text(c.name)
        .fontSize(14)
        .fontColor(this.activeId === c.id ? this.theme.primary : this.theme.font)
        .fontWeight(this.activeId === c.id ? FontWeight.Bold : FontWeight.Normal)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .onClick((): void => { this.onContentClick(c.id); })
      if (this.selectMode) {
        Text('↑').fontSize(16).fontColor(this.theme.primary)
          .width(30).height(40).textAlign(TextAlign.Center)
          .onClick((): void => { this.step(-1); })
        Text('↓').fontSize(16).fontColor(this.theme.primary)
          .width(30).height(40).textAlign(TextAlign.Center)
          .onClick((): void => { this.step(1); })
      } else {
        Button() {
          Image($r('app.media.ic_more')).width(16).height(16).fillColor(this.pal().subText)
        }
        .type(ButtonType.Normal).width(30).height(40)
        .backgroundColor(Color.Transparent).stateEffect(false)
        .onClick((e: ClickEvent): void => {
          // 记录点击位置，让弹出菜单贴近本行 ⋮
          setPopupAnchor(e.windowX, e.windowY);
          this.menuId = c.id;
        })
      }
    }
    .width('100%')
  }

  @Builder
  private NormalRow(c: LocalCategoryItem) {
    Row() {
      this.RowContent(c);
    }
    .width('100%').height(ROW_H)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.rowBg(c.id))
    .borderRadius(8).margin({ bottom: 2 })
    .gesture(LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS }).onAction((): void => {
      this.lastPanY = 0;
      this.enterSelect(c.id);
    }))
  }

  @Builder
  private SelectRow(c: LocalCategoryItem) {
    Row() {
      this.RowContent(c);
    }
    .width('100%').height(ROW_H)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.rowBg(c.id))
    .border({ width: this.isSel(c.id) ? 1 : 0, color: this.theme.primary })
    .borderRadius(8).margin({ bottom: 2 })
    .opacity(this.dragging && this.isSel(c.id) ? 0.85 : 1)
    .priorityGesture(
      GestureGroup(GestureMode.Parallel,
        LongPressGesture({ repeat: false, duration: LONG_PRESS_DURATION_MS })
          .onAction((): void => { this.startDrag(c.id); })
          .onActionEnd((): void => { this.finishDrag(); }),
        PanGesture({ direction: PanDirection.Vertical, distance: 1 })
          .onActionUpdate((ev: GestureEvent): void => { this.onPanUpdate(ev); })
          .onActionEnd((): void => { this.finishDrag(); })
      )
    )
  }

  @Builder
  private ListRow(c: LocalCategoryItem) {
    if (this.selectMode) {
      this.SelectRow(c);
    } else {
      this.NormalRow(c);
    }
  }

  @Builder
  private MenuPopup() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.menuId = ''; })
      Column() {
        ForEach(CATEGORY_MENU_ITEMS, (it: CategoryMenuOption): void => {
          Row() {
            Text(it.label).fontSize(14).fontColor(this.theme.font)
          }
          .width('100%').height(42).padding({ left: 16, right: 16 })
          .onClick((): void => { this.pinToTop(); })
        }, (it: CategoryMenuOption): string => it.id.toString())
      }
      .width(this.menuWidth()).height(36 + 42 + 8)
      .backgroundColor(this.pal().card).borderRadius(12)
      .border({ width: 1, color: this.pal().divider })
      .position({ x: this.menuPopupPos.x, y: this.menuPopupPos.y })
      .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%').height('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      // 记录浮窗容器（根 Stack）在窗口中的真实位置，供 computePopupPos 换算成容器相对坐标
      setPopupContainer(Number(area.globalPosition.x), Number(area.globalPosition.y));
      this.menuPopupPos = computePopupPos(this.menuWidth(), 36 + 42 + 8);
    })
  }

  /** 菜单浮窗宽度：随文字内容变化 */
  private menuWidth(): number {
    return popupWidthForTexts(CATEGORY_MENU_ITEMS.map((it: CategoryMenuOption): string => it.label), 14, 16);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        Row() {
          Text('‹ 返回')
            .fontSize(13).fontColor(this.theme.primary).width(62)
            .onClick((): void => { this.onClose(); })
          Text(this.title)
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
          : '点按切换分类 · 长按进入管理 · 前 4 个显示在顶部标签栏')
          .fontSize(11).fontColor(this.pal().subText)
          .width('100%').padding({ top: 2, bottom: 8 })

        Scroll() {
          Column() {
            ForEach(this.order, (c: LocalCategoryItem): void => {
              this.ListRow(c);
            }, (c: LocalCategoryItem): string => c.id)
          }
          .width('100%')
        }
        .enableScrollInteraction(!this.selectMode)
        .constraintSize({ maxHeight: 360 })
        .width('100%').scrollBar(BarState.Off)

        if (this.selectMode) {
          Row() {
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

      if (this.menuId.length > 0) {
        this.MenuPopup();
      }
    }
    .width('100%').height('100%')
  }
}
