/**
 * 列表三点菜单 —— 按「歌曲行 ⋮ 菜单」的浮窗交互（SongMenuPanel 同一套视觉）。
 *
 * 白底圆角卡片 + 半透明遮罩 + 顶部标题（列表名 · N 首）+ 纵向选项列表。
 * 选项用 MENU_ITEMS 数组驱动，后续要加项只需往数组里加一条并在 onAction 里分派。
 *
 * 当前 5 项（前 4 项顺序按需求固定）：添加本地歌曲 / 重新命名 / 删除 / 置顶 / 导入文件夹。
 * 删除不在这里直接执行：交给父级弹二次确认（固定列表则直接提示不可删）。
 * 「导入文件夹」复用「本地」页的导入流程（系统文件选择器 → 复制进沙箱 → 重新扫描）。
 */
import { MusicInfo, UserListInfo } from '../model/MusicTypes';
import { ThemeInfo, ThemePalette, buildPalette } from '../theme/Themes';
import { ListManager } from '../core/ListManager';
import { ListIds } from '../config/AppConstants';
import { LocalMusicScanner } from '../core/LocalMusicScanner';
import { importLocalMusicFiles } from '../core/LocalImport';
import { SettingStore } from '../store/SettingStore';
import { userNotice } from '../core/UserNotice';
import { computePopupPos, setPopupContainer, PopupPoint, popupMaxHeightVp, popupMaxWidthVp, popupWidthForTexts } from '../core/Popup';

interface MenuItem {
  id: number;
  label: string;
}

/** 菜单项：新增选项在这里加一行，并到 onAction 里补一个分支 */
const MENU_ITEMS: MenuItem[] = [
  { id: 1, label: '添加本地歌曲' },
  { id: 2, label: '重新命名' },
  { id: 3, label: '删除' },
  { id: 4, label: '置顶' },
  { id: 5, label: '导入文件夹' },
];

type SubMode = 'none' | 'local' | 'rename';

const DEFAULT_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};

@Component
export struct ListActionMenu {
  @Prop list: UserListInfo = {
    id: '', name: '', locationUpdateTime: 0,
  };
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  @Prop songCount: number = 0;
  onClose: () => void = () => {};
  /** 请求删除（父级负责二次确认） */
  onDelete: (id: string) => void = () => {};
  /** 列表/歌曲数据变化后通知父级刷新 */
  onChanged: () => void = () => {};

  @State private sub: SubMode = 'none';
  @State private localSongs: MusicInfo[] = [];
  @State private loadingLocal: boolean = false;
  @State private renameText: string = '';
  /** 浮窗相对容器的落点，由根 Stack 的 onAreaChange 实时校准（消除头部/嵌套偏移） */
  @State private popupPos: PopupPoint = { x: 0, y: 0 };

  private listManager: ListManager = ListManager.getInstance();
  private settings: SettingStore = SettingStore.getInstance();

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  private title(): string {
    return this.list.name + ' · ' + this.songCount.toString() + ' 首';
  }

  /**
   * 当前列表可用的菜单项。
   * 「播放历史」是系统自动维护的只读列表（名字、顺序、内容都不归用户改）：
   * 只留「置顶」这一项，避免出现「重命名/删除/添加本地歌曲」这类会被忽略的操作。
   */
  private menuItems(): MenuItem[] {
    if (this.list.id === ListIds.HISTORY) {
      return MENU_ITEMS.filter((it: MenuItem): boolean => it.id === 4);
    }
    return MENU_ITEMS;
  }

  /** 卡片高度跟随内容，项数多时由 constraintSize 夹紧 */
  private panelHeight(): number {
    if (this.sub === 'rename') {
      return 168;
    }
    if (this.sub === 'local') {
      return 40 + 44 * Math.min(this.localSongs.length, 7) + 44;
    }
    return 36 + 42 * this.menuItems().length + 8;
  }

  /** 浮窗实际高度（vp）：内容自适应，上限为「状态栏 ~ 底部播控栏」之间的可用高度 */
  private popupHeight(): number {
    const h: number = this.panelHeight();
    const maxH: number = popupMaxHeightVp();
    return h < maxH ? h : maxH;
  }

  /** 浮窗宽度（vp）：同时容纳「菜单项文字」与「顶部列表名标题行」，避免标题被省略成「xxx · ...」 */
  private popupWidth(): number {
    const labels: string[] = this.menuItems().map((it: MenuItem): string => it.label);
    let w: number = popupWidthForTexts(labels, 14, 16);
    if (this.sub === 'rename') {
      // 重命名子面板有输入框 + 两个并排按钮，按菜单文字算出来的宽度会把它裁掉
      w = Math.max(w, 240);
    } else if (this.sub === 'local') {
      // 本地歌曲列表：一行「歌名 - 歌手」+ 右侧勾选标记
      w = Math.max(w, 220);
    } else {
      const title: string = this.title();
      if (title.length > 0) {
        w = Math.max(w, Math.min(popupWidthForTexts([title], 12, 16) + 8, 260));
      }
    }
    if (w < 176) {
      w = 176;
    }
    const cap: number = popupMaxWidthVp();
    return w > cap ? cap : w;
  }

  aboutToAppear(): void {
    // 先用当前已知容器坐标算一版（onAreaChange 收到真实坐标后会再次校准）
    this.popupPos = computePopupPos(this.popupWidth(), this.popupHeight());
  }

  private onAction(id: number): void {
    if (id === 1) {
      this.sub = 'local';
      this.loadLocal();
      return;
    }
    if (id === 2) {
      this.renameText = this.list.name;
      this.sub = 'rename';
      return;
    }
    if (id === 3) {
      if (this.listManager.isFixedList(this.list.id)) {
        userNotice().info('固定列表不能删除');
        return;
      }
      this.onDelete(this.list.id);
      this.onClose();
      return;
    }
    if (id === 4) {
      this.listManager.moveListToPosition(this.list.id, 0);
      this.onChanged();
      userNotice().info('已置顶「' + this.list.name + '」');
      this.onClose();
    }
    if (id === 5) {
      // 与「本地」页完全同一条导入链路，导入完成后刷新可选的本地歌曲
      importLocalMusicFiles().then((n: number): void => {
        if (n > 0) {
          userNotice().info('已导入 ' + n.toString() + ' 首，可直接添加到本列表');
          this.sub = 'local';
          this.loadLocal();
          this.onChanged();
        }
      });
    }
  }

  private loadLocal(): void {
    this.loadingLocal = true;
    LocalMusicScanner.getInstance().scan().then((songs: MusicInfo[]): void => {
      this.localSongs = songs;
      this.loadingLocal = false;
    }).catch((): void => {
      this.localSongs = [];
      this.loadingLocal = false;
    });
  }

  private addTop(): boolean {
    return this.settings.getString('list.addMusicLocationType', 'top') !== 'bottom';
  }

  private addLocalOne(m: MusicInfo): void {
    const n: number = this.listManager.addListMusics(this.list.id, [m], this.addTop());
    this.onChanged();
    userNotice().info(n > 0 ? '已添加「' + m.name + '」' : '该歌曲已在列表中');
  }

  private addAllLocal(): void {
    if (this.localSongs.length === 0) {
      userNotice().info('没有本地歌曲，可先在「本地」页导入');
      return;
    }
    const n: number = this.listManager.addListMusics(this.list.id, this.localSongs, this.addTop());
    this.onChanged();
    userNotice().info('已添加 ' + n.toString() + ' 首本地歌曲');
    this.onClose();
  }

  private applyRename(): void {
    const name: string = this.renameText.trim();
    if (name.length === 0) {
      userNotice().info('名称不能为空');
      return;
    }
    this.listManager.renameUserList(this.list.id, name);
    this.onChanged();
    userNotice().info('已重命名为「' + name + '」');
    this.onClose();
  }

  @Builder
  private menuList() {
    Column() {
      Text(this.title())
        .fontSize(12)
        .fontColor(this.pal().subText)
        // 宽度已按标题测量，仅极长列表名才折成两行，保证首行信息完整
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 6 })
      ForEach(this.menuItems(), (it: MenuItem): void => {
        Row() {
          Text(it.label)
            .fontSize(14)
            .fontColor(it.id === 3 ? '#C0553F' : this.theme.font)
        }
        .width('100%')
        .height(42)
        .padding({ left: 16, right: 16 })
        .onClick((): void => { this.onAction(it.id); })
      }, (it: MenuItem): string => it.id.toString())
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private localPanel() {
    Column() {
      Row() {
        Text('添加本地歌曲')
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .layoutWeight(1)
        Text('返回')
          .fontSize(12).fontColor(this.theme.primary)
          .onClick((): void => { this.sub = 'none'; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.loadingLocal) {
        Text('正在扫描本地音乐…')
          .fontSize(12).fontColor(this.pal().subText)
          .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
      } else if (this.localSongs.length === 0) {
        Text('沙箱里还没有本地歌曲，可先在「本地」页导入音频文件')
          .fontSize(12).fontColor(this.pal().subText)
          .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.localSongs, (m: MusicInfo): void => {
              Row() {
                Column() {
                  Text(m.name)
                    .fontSize(13).fontColor(this.theme.font)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(m.singer)
                    .fontSize(10).fontColor(this.pal().subText)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text('＋')
                  .fontSize(16).fontColor(this.theme.primary).width(28)
                  .textAlign(TextAlign.Center)
              }
              .width('100%').height(44)
              .padding({ left: 16, right: 16 })
              .onClick((): void => { this.addLocalOne(m); })
            }, (m: MusicInfo): string => m.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Row() {
          Text('全部添加')
            .fontSize(13).fontColor(this.theme.primary)
            .width('100%').height(40).textAlign(TextAlign.Center)
            .onClick((): void => { this.addAllLocal(); })
        }
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private renamePanel() {
    Column() {
      Row() {
        Text('重新命名')
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .layoutWeight(1)
        Text('返回')
          .fontSize(12).fontColor(this.theme.primary)
          .onClick((): void => { this.sub = 'none'; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      TextInput({ placeholder: '列表名称', text: this.renameText })
        .height(38).fontSize(13)
        .backgroundColor(this.pal().pillBg).borderRadius(8)
        .fontColor(this.theme.font)
        .placeholderColor(this.pal().subText)
        .margin({ left: 16, right: 16, top: 6 })
        .id('renameListInput')
        .enableKeyboardOnFocus(true)
        .onAppear((): void => {
          // 输入框挂载后自动聚焦，光标落入并唤起键盘
          setTimeout((): void => {
            focusControl.requestFocus('renameListInput');
          }, 60);
        })
        .onChange((v: string): void => { this.renameText = v; })

      Row() {
        Text('取消')
          .fontSize(13).fontColor(this.pal().subText)
          .layoutWeight(1).textAlign(TextAlign.Center)
          .onClick((): void => { this.sub = 'none'; })
        Text('确定')
          .fontSize(13).fontColor(this.theme.primary)
          .layoutWeight(1).textAlign(TextAlign.Center)
          .onClick((): void => { this.applyRename(); })
      }
      .width('100%').height(44).margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        if (this.sub === 'none') {
          this.menuList();
        } else if (this.sub === 'local') {
          this.localPanel();
        } else {
          this.renamePanel();
        }
      }
      .width(this.popupWidth())
      .height(this.panelHeight())
      .constraintSize({ maxHeight: popupMaxHeightVp() })
      .backgroundColor(this.pal().card)
      .borderRadius(12)
      .border({ width: 1, color: this.pal().divider })
      .position({ x: this.popupPos.x, y: this.popupPos.y })
      .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      // 记录浮窗容器（根 Stack）在窗口中的真实位置，供 computePopupPos 换算成容器相对坐标
      setPopupContainer(Number(area.globalPosition.x), Number(area.globalPosition.y));
      this.popupPos = computePopupPos(this.popupWidth(), this.popupHeight());
    })
  }
}
