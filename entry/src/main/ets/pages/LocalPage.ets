/**
 * 本地音乐页 —— M2-E④ UI + 分类模块。
 *
 * 扫描应用沙箱 downloads 目录（主要是本应用的下载文件），按「歌曲 / 文件夹 / 歌手」
 * 三个分类展示；分类标签栏与「我的列表」共用同一套交互（前 4 常驻、长按进管理态、
 * 多选拖动调序、抽屉导航条 + 系统返回手势）。
 *
 * 歌曲行交互与「我的列表 / 歌单详情」完全一致：
 * 双击播放、长按进入多选、多选时单击切换选中、右侧 ⋮ 打开同一套浮窗菜单。
 *
 * 「移除」只把歌曲从本地音乐列表隐藏（路径记进 local_hidden.json），
 * 不删除手机里的音乐文件；隐藏的歌曲可在本页「恢复隐藏」一次性找回。
 *
 * 导入：全应用统一走 core/LocalImport 的文件选择器流程，导入后重新扫描分组。
 */
import { MusicInfo, MusicInfoMetaLocal } from '../model/MusicTypes';
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { LocalMusicScanner, LocalMusicEdit } from '../core/LocalMusicScanner';
import { importLocalMusicFiles } from '../core/LocalImport';
import { LocalCategoryItem, DEFAULT_LOCAL_CATEGORIES, LocalCategoryOrder } from '../core/LocalCategoryOrder';
import { CategoryTabBar, CategoryDrawer } from '../components/CategoryTabBar';
import { MusicListItem } from '../components/MusicListItem';
import { SongMenuPanel } from '../components/SongMenuPanel';
import { PlayController } from '../player/PlayController';
import { I18n } from '../core/I18n';
import { stateEvent, StateEvents, EmptyCallback } from '../store/EventBus';
import { AppState, HeaderAction } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { userNotice } from '../core/UserNotice';

interface LocalGroup {
  key: string;
  name: string;
  songs: MusicInfo[];
}

@Component
export struct LocalPage {
  @State songs: MusicInfo[] = [];
  @State loading: boolean = false;
  @State showEdit: boolean = false;
  @State editInfo: MusicInfo | null = null;
  @State editName: string = '';
  @State editSinger: string = '';
  @State editAlbum: string = '';
  @State editPic: string = '';
  @State private langTick: number = 0;
  /** 分类标签（顺序可调整并持久化） */
  @State private categories: LocalCategoryItem[] = DEFAULT_LOCAL_CATEGORIES.slice();
  @State private activeCategory: string = 'songs';
  @State private groups: LocalGroup[] = [];
  /** 非空时表示正在查看某个文件夹 / 歌手的歌曲 */
  @State private groupKey: string = '';
  @State private showCategoryDrawer: boolean = false;
  @State private categoryInitialSelectId: string = '';
  /** 多选态（长按歌曲行进入）：与「我的列表 / 歌单详情」同一套交互 */
  @State private editMode: boolean = false;
  @State private selected: string[] = [];
  /** 批量菜单（多选后点「更多」打开） */
  @State private batchMenu: boolean = false;
  /** 当前打开的单曲菜单下标，-1 = 关闭 */
  @State private menuIndex: number = -1;
  /** 真正在播放的歌曲 id：跟着切歌事件走，用于行高亮 */
  @State private currentId: string = '';
  /** 已隐藏（从列表移除但文件仍在）的歌曲数量 */
  @State private hiddenCount: number = 0;
  /** 本次扫描跳过的 0 字节空文件数量（下载没写完留下的，播放不了，所以列表里不显示） */
  @State private emptyCount: number = 0;
  /** 空文件清理的二次确认 */
  @State private pendingCleanEmpty: boolean = false;
  /**
   * 每次重扫 +1。
   * ForEach 的 key 相同就不会重建子组件（@Builder 参数按值传递不会刷新），
   * 文件夹行只显示「名字 + 歌曲数」，文件挪到别的文件夹后数量变了但 key 没变，
   * 列表就会一直显示旧数量 —— 把重扫序号拼进 key，保证每次刷新都重算分组行。
   */
  @State private scanVersion: number = 0;
  /** 列表显示设置（与歌单详情 / 我的列表共用同一批开关） */
  @State private showAlbumName: boolean = false;
  @State private showInterval: boolean = true;
  /** 待二次确认移除的歌曲 */
  @State private pendingRemove: MusicInfo[] = [];
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 当前是否为激活标签：激活时注册头部「导入 / 刷新」，并重扫一次（标签解析有缓存，开销很小） */
  @Prop @Watch('onActiveChanged') active: boolean = false;

  private scanner: LocalMusicScanner = LocalMusicScanner.getInstance();
  private controller: PlayController = PlayController.getInstance();
  private state: AppState = AppState.getInstance();
  /** 是否已经完成首屏扫描：没有它，@Watch 首帧会和 aboutToAppear 撞成两次扫描 */
  private appeared: boolean = false;
  private scanning: boolean = false;

  /** 切歌后刷新高亮（AppState.playMusicInfo 是普通字段，不订阅事件不会重渲染） */
  private onPlayMusicChanged = (): void => {
    const cur = this.state.playMusicInfo;
    this.currentId = cur === null ? '' : cur.musicInfo.id;
  };
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => { this.langTick = this.langTick + 1; };

  /** 切到本地页：注册头部操作 + 重扫一次，让新增文件/修正后的标签立刻生效 */
  private onActiveChanged(): void {
    this.syncHeader();
    if (this.active) {
      if (this.appeared) {
        this.doScan();
      }
      return;
    }
    // 切走时把本页所有浮窗/确认框关掉：否则浮窗会留在别的模块上
    this.closeOverlays();
  }

  /** 关掉本页全部浮层（切模块时调用，规格与返回手势一致） */
  private closeOverlays(): void {
    this.menuIndex = -1;
    this.batchMenu = false;
    this.pendingRemove = [];
    this.pendingCleanEmpty = false;
    this.showEdit = false;
    this.editInfo = null;
    this.showCategoryDrawer = false;
  }
  /** 系统返回手势：抽屉（自己订阅）→ 分组详情 → 多选 → 浮窗 → 元数据编辑面板 */
  private onUiBack = (): void => {
    if (!this.active) {
      return;
    }
    if (this.showCategoryDrawer) {
      return;
    }
    if (this.pendingCleanEmpty) {
      this.pendingCleanEmpty = false;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.pendingRemove.length > 0) {
      this.pendingRemove = [];
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.batchMenu) {
      this.batchMenu = false;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.menuIndex >= 0) {
      this.menuIndex = -1;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.groupKey.length > 0) {
      this.groupKey = '';
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.showEdit) {
      this.showEdit = false;
      this.editInfo = null;
      AppState.getInstance().uiBackConsumed = true;
      return;
    }
    if (this.editMode) {
      this.exitEdit();
      AppState.getInstance().uiBackConsumed = true;
    }
  };

  async aboutToAppear(): Promise<void> {
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    stateEvent().on(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().on(StateEvents.LOCAL_FILES_CHANGED, this.onLocalFilesChanged);
    stateEvent().on(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
    // 列表显示开关（专辑名 / 时长）：以前本地页写死，设置里改了不生效
    stateEvent().on(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    this.onPlayMusicChanged();
    this.reloadListDisplay();
    LocalCategoryOrder.getInstance().ensure().then((): void => {
      this.categories = LocalCategoryOrder.getInstance().applyOrder(DEFAULT_LOCAL_CATEGORIES);
    });
    await this.doScan();
    this.appeared = true;
    this.syncHeader();
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().off(StateEvents.LOCAL_FILES_CHANGED, this.onLocalFilesChanged);
    stateEvent().off(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
    stateEvent().off(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
  }

  /** 导出 / 下载落地等本地文件变动：只在本页激活时静默重扫，避免无谓的重复扫描 */
  private onLocalFilesChanged = (): void => {
    if (this.active && this.appeared) {
      this.doScan();
    }
  };

  private onConfigUpdated = (): void => {
    this.reloadListDisplay();
  };

  /** 读取「显示专辑名 / 显示时长」两个列表设置（本地歌没有来源，故不读 isShowSource） */
  private reloadListDisplay(): void {
    const s = SettingStore.getInstance();
    this.showAlbumName = s.getBoolean('list.isShowAlbumName', false);
    this.showInterval = s.getBoolean('list.isShowInterval', true);
  }

  /** 本地页：把「导入 / 刷新」放到全局头部 ≡ 左侧，字号保持 12 */
  private syncHeader(): void {
    if (!this.active) {
      return;
    }
    const acts: HeaderAction[] = [];
    acts.push({
      key: 'import',
      text: '导入',
      fontSize: 12,
      textColor: this.theme.primary,
      onClick: (): void => { this.importMusic(); },
    });
    acts.push({
      key: 'refresh',
      text: this.tx('refresh'),
      fontSize: 12,
      // 与「导入」保持一致：只染文字色，不加主色底（此前加了 bg 会整块高亮，用户要求不高亮）
      textColor: this.theme.primary,
      onClick: (): void => { this.doScan(); },
    });
    AppState.getInstance().setHeaderActions(acts);
  }

  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  private async doScan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.loading = true;
    try {
      this.songs = await this.scanner.scan();
      this.hiddenCount = this.scanner.hiddenCount();
      this.emptyCount = this.scanner.emptyFilePaths().length;
      this.rebuildGroups();
      this.scanVersion = this.scanVersion + 1;
      // 已不存在的选中项剔除，避免计数虚高
      if (this.selected.length > 0) {
        const ids = new Set<string>(this.songs.map((m: MusicInfo): string => m.id));
        this.selected = this.selected.filter((id: string): boolean => ids.has(id));
        if (this.selected.length === 0) {
          this.editMode = false;
        }
      }
      if (this.menuIndex >= this.songs.length) {
        this.menuIndex = -1;
      }
    } finally {
      this.loading = false;
      this.scanning = false;
    }
  }


  /** 按当前分类把歌曲聚合成组：文件夹取 filePath 的父目录名，歌手取 singer */
  private rebuildGroups(): void {
    const out: LocalGroup[] = [];
    for (const m of this.songs) {
      let key: string;
      if (this.activeCategory === 'artists') {
        key = m.singer.length > 0 ? m.singer : '未知歌手';
      } else {
        const meta = m.meta as MusicInfoMetaLocal;
        const path: string = meta.filePath ?? '';
        const idx: number = path.lastIndexOf('/');
        const dir: string = idx > 0 ? path.substring(0, idx) : path;
        const name: string = dir.substring(dir.lastIndexOf('/') + 1);
        key = name.length > 0 ? name : '本地音乐';
      }
      let found: LocalGroup | null = null;
      for (const g of out) {
        if (g.key === key) {
          found = g;
          break;
        }
      }
      if (found === null) {
        const item: LocalGroup = { key: key, name: key, songs: [m] };
        out.push(item);
      } else {
        found.songs.push(m);
      }
    }
    out.sort((a: LocalGroup, b: LocalGroup): number => a.name.localeCompare(b.name));
    this.groups = out;
    // 正在查看的文件夹 / 歌手在重扫后可能已经不存在（文件被挪走 / 改名）：
    // 自动退回分组列表，别停在空壳详情页
    if (this.groupKey.length > 0) {
      let hit: boolean = false;
      for (const g of out) {
        if (g.key === this.groupKey) {
          hit = true;
          break;
        }
      }
      if (!hit) {
        this.groupKey = '';
        this.editMode = false;
        this.selected = [];
      }
    }
  }

  private currentGroupSongs(): MusicInfo[] {
    for (const g of this.groups) {
      if (g.key === this.groupKey) {
        return g.songs;
      }
    }
    return [];
  }

  /** 当前屏幕上正在展示的歌曲数组（菜单下标 / 多选都基于它） */
  private currentList(): MusicInfo[] {
    if (this.groupKey.length > 0) {
      return this.currentGroupSongs();
    }
    return this.songs;
  }

  private switchCategory(id: string): void {
    this.activeCategory = id;
    this.groupKey = '';
    this.editMode = false;
    this.selected = [];
    this.menuIndex = -1;
    this.rebuildGroups();
  }

  private applyCategoryOrder(ids: string[]): void {
    const next: LocalCategoryItem[] = [];
    for (const id of ids) {
      for (const c of this.categories) {
        if (c.id === id) {
          next.push(c);
          break;
        }
      }
    }
    for (const c of this.categories) {
      if (ids.indexOf(c.id) < 0) {
        next.push(c);
      }
    }
    this.categories = next;
    LocalCategoryOrder.getInstance().save(ids);
  }

  /** 导入（含「导入文件夹」入口）：统一走本地页的选择器 + 复制沙箱流程 */
  private async importMusic(): Promise<void> {
    const n: number = await importLocalMusicFiles();
    if (n < 0) {
      // 用户取消选择
      return;
    }
    await this.doScan();
    if (n > 0) {
      userNotice().info('已导入 ' + n.toString() + ' 首本地音乐');
    } else {
      userNotice().warn('没有导入成功，请确认选的是音频文件');
    }
  }

  // ─────────────────────────── 播放 / 多选 / 移除 ───────────────────────────

  /** 播放当前列表第 idx 首（本地歌曲直接走文件路径，不需要取链） */
  private playAt(idx: number): void {
    const list: MusicInfo[] = this.currentList();
    if (idx < 0 || idx >= list.length) {
      return;
    }
    this.controller.playMusicList(list, idx);
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  private selectedSongs(): MusicInfo[] {
    return this.currentList().filter((m: MusicInfo): boolean => this.isSelected(m.id));
  }

  private toggleSelect(id: string): void {
    if (this.isSelected(id)) {
      this.selected = this.selected.filter((x: string): boolean => x !== id);
    } else {
      this.selected = this.selected.concat([id]);
    }
  }

  private toggleSelectAll(): void {
    const list: MusicInfo[] = this.currentList();
    if (this.selected.length === list.length) {
      this.selected = [];
    } else {
      this.selected = list.map((m: MusicInfo): string => m.id);
    }
  }

  /** 长按：先取 id 再切模式，避免刷新后下标错位 */
  private enterSelect(index: number): void {
    const list: MusicInfo[] = this.currentList();
    if (index < 0 || index >= list.length) {
      return;
    }
    const id: string = list[index].id;
    if (!this.editMode) {
      this.editMode = true;
    }
    if (!this.isSelected(id)) {
      this.selected = this.selected.concat([id]);
    }
  }

  private exitEdit(): void {
    this.editMode = false;
    this.selected = [];
  }

  private openBatchMenu(): void {
    if (this.selected.length === 0) {
      userNotice().info('先长按或点击选中歌曲');
      return;
    }
    this.batchMenu = true;
  }

  /**
   * 请求移除：只做二次确认，不删文件。
   * 单曲菜单与批量移除都走这里。
   */
  private requestRemove(infos: MusicInfo[]): void {
    const list: MusicInfo[] = [];
    for (const m of infos) {
      if (m.source === 'local') {
        list.push(m);
      }
    }
    if (list.length === 0) {
      return;
    }
    this.pendingRemove = list;
  }

  /** 确认移除：把路径写进隐藏清单并重新扫描（文件不动） */
  private confirmRemove(): void {
    const list: MusicInfo[] = this.pendingRemove;
    this.pendingRemove = [];
    if (list.length === 0) {
      return;
    }
    const n: number = this.scanner.hide(list);
    this.menuIndex = -1;
    this.editMode = false;
    this.selected = [];
    this.doScan();
    if (n > 0) {
      userNotice().info('已从本地音乐移除 ' + n.toString() + ' 首（文件仍保留）');
    } else {
      userNotice().info('这些歌已经在隐藏列表里了');
    }
  }

  /** 恢复全部隐藏（文件一直都在，只是之前没显示） */
  private restoreHidden(): void {
    const n: number = this.scanner.restoreHidden();
    if (n <= 0) {
      return;
    }
    this.doScan();
    userNotice().info('已恢复 ' + n.toString() + ' 首');
  }

  /** 清理 0 字节空文件（只删空文件，有内容的音频一律不动） */
  private cleanEmptyFiles(): void {
    const n: number = this.scanner.clearEmptyFiles();
    this.pendingCleanEmpty = false;
    this.doScan();
    if (n > 0) {
      userNotice().info('已清理 ' + n.toString() + ' 个空文件');
    } else {
      userNotice().info('没有需要清理的空文件');
    }
  }

  build() {
    Stack() {
      Column() {
        // 顶部：普通态显示统计行（含「选择」与「恢复隐藏」），多选态换成工具条
        if (this.editMode) {
          Row() {
            Text(this.tx('sel_prefix') + ' ' + this.selected.length.toString() + ' ' + this.tx('unit_song'))
              .fontSize(12).fontColor(this.theme.primary)
            Blank()
            Text(this.tx('select_all'))
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .onClick((): void => { this.toggleSelectAll(); })
            Text('更多')
              .fontSize(12)
              .fontColor(this.selected.length > 0 ? this.theme.primary : buildPalette(this.theme).subText)
              .border({ width: 1, color: this.selected.length > 0 ? this.theme.primary : buildPalette(this.theme).pillBg })
              .borderRadius(12)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .margin({ left: 6 })
              .onClick((): void => { this.openBatchMenu(); })
            Text('移除')
              .fontSize(12).fontColor('#FFFFFF')
              .backgroundColor(this.selected.length > 0 ? '#C0553F' : buildPalette(this.theme).pillBg)
              .borderRadius(12)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .margin({ left: 8 })
              .onClick((): void => { this.requestRemove(this.selectedSongs()); })
            Text('取消')
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .padding({ left: 8, right: 0, top: 4, bottom: 4 })
              .margin({ left: 4 })
              .onClick((): void => { this.exitEdit(); })
          }
          .width('100%').padding({ left: 16, right: 16, top: 2, bottom: 6 })
        } else {
          Row() {
            Text(this.songs.length.toString() + ' ' + this.tx('unit_song') + ' · ' + this.tx('local_source_hint'))
              .fontSize(11).fontColor(buildPalette(this.theme).subText)
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.hiddenCount > 0) {
              Text('恢复隐藏 ' + this.hiddenCount.toString())
                .fontSize(11).fontColor(this.theme.primary)
                .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                .onClick((): void => { this.restoreHidden(); })
            }
            if (this.songs.length > 0 && (this.groupKey.length > 0 || this.activeCategory === 'songs')) {
              Text('选择')
                .fontSize(11).fontColor(this.theme.primary)
                .padding({ left: 6, right: 0, top: 4, bottom: 4 })
                .onClick((): void => { this.editMode = true; })
            }
          }
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
          // 下载中断留下的 0 字节文件：不显示在列表里（播放会报格式不支持），
          // 但必须让用户知道「有歌没被识别」的原因，并给一键清理。
          if (this.emptyCount > 0) {
            Row() {
              Text('有 ' + this.emptyCount.toString() + ' 个空文件（下载未完成，播放不了）')
                .fontSize(11).fontColor(buildPalette(this.theme).subText)
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('清理')
                .fontSize(11).fontColor(this.theme.primary)
                .padding({ left: 8, right: 0, top: 4, bottom: 4 })
                .onClick((): void => { this.pendingCleanEmpty = true; })
            }
            .width('100%').padding({ left: 16, right: 16, bottom: 4 })
          }
        }

        // 分类模块：与「我的列表」同款胶囊标签栏（可长按进抽屉调序）
        CategoryTabBar({
          theme: this.theme,
          categories: this.categories,
          activeId: this.activeCategory,
          onSelect: (id: string): void => { this.switchCategory(id); },
          onOpenDrawer: (id: string): void => {
            this.categoryInitialSelectId = id;
            this.showCategoryDrawer = true;
          },
        })

        if (this.loading) {
          Text(this.tx('scanning')).fontSize(13).fontColor(buildPalette(this.theme).subText).margin({ top: 30 })
        } else if (this.songs.length === 0) {
          Column() {
            Text(this.tx('local_empty_title'))
              .fontSize(14).fontColor(buildPalette(this.theme).subText).margin({ top: 40 })
            Text(this.tx('local_empty'))
              .fontSize(12).fontColor(buildPalette(this.theme).subText).margin({ top: 8 }).textAlign(TextAlign.Center)
            Text('＋ 导入文件夹')
              .fontSize(13).fontColor('#FFFFFF')
              .backgroundColor(this.theme.primary).borderRadius(16)
              .padding({ left: 18, right: 18, top: 8, bottom: 8 })
              .margin({ top: 16 })
              .onClick((): void => { this.importMusic(); })
            if (this.hiddenCount > 0) {
              Text('已隐藏 ' + this.hiddenCount.toString() + ' 首，点此恢复')
                .fontSize(12).fontColor(this.theme.primary).margin({ top: 14 })
                .onClick((): void => { this.restoreHidden(); })
            }
          }
          .width('100%')
        } else if (this.groupKey.length > 0) {
          // 分组详情：该文件夹 / 歌手下的歌曲
          Row() {
            Text('‹ 返回')
              .fontSize(13).fontColor(this.theme.primary).width(64)
              .onClick((): void => {
                this.groupKey = '';
                this.exitEdit();
              })
            Text(this.groupKey)
              .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.currentGroupSongs().length.toString() + ' ' + this.tx('unit_song'))
              .fontSize(11).fontColor(buildPalette(this.theme).subText)
          }
          .width('100%').height(40).padding({ left: 12, right: 16 })
          this.songRows(this.currentGroupSongs())
        } else if (this.activeCategory === 'songs') {
          this.songRows(this.songs)
        } else {
          // 文件夹 / 歌手分类：顶部导入入口 + 分组列表
          if (this.activeCategory === 'folders') {
            Row() {
              Text('＋ 导入文件夹')
                .fontSize(12).fontColor('#FFFFFF')
                .backgroundColor(this.theme.primary).borderRadius(14)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .onClick((): void => { this.importMusic(); })
              Text('在系统文件选择器里进入文件夹，可多选音频批量导入')
                .fontSize(10).fontColor(buildPalette(this.theme).subText)
                .layoutWeight(1).margin({ left: 10 })
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 8 })
          }
          List() {
            ForEach(this.groups, (g: LocalGroup): void => {
              ListItem() {
                Row() {
                  Column() {
                    Text(g.name)
                      .fontSize(15).fontColor(this.theme.font)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(g.songs.length.toString() + ' ' + this.tx('unit_song'))
                      .fontSize(11).fontColor(buildPalette(this.theme).subText)
                      .margin({ top: 3 })
                  }
                  .layoutWeight(1).alignItems(HorizontalAlign.Start)
                  Text('›').fontSize(18).fontColor(buildPalette(this.theme).subText).width(24)
                }
                .width('100%').height(56).padding({ left: 16, right: 12 })
                .onClick((): void => { this.groupKey = g.key; })
              }
            }, (g: LocalGroup): string => g.key + '|' + g.songs.length.toString() + '|' + this.scanVersion.toString())
          }
          .layoutWeight(1).width('100%')
          .divider({ strokeWidth: 0.5, color: buildPalette(this.theme).pillBg })
        }
      }
      .width('100%').height('100%').backgroundColor(this.theme.mainBackground)

      // 全部分类抽屉：交互与「我的列表」一致（导航条 / 管理 / 多选拖动 / 系统返回）
      if (this.showCategoryDrawer) {
        CategoryDrawer({
          theme: this.theme,
          categories: this.categories,
          activeId: this.activeCategory,
          initialSelectId: this.categoryInitialSelectId,
          title: '全部分类',
          onSelect: (id: string): void => { this.switchCategory(id); },
          onReorder: (ids: string[]): void => { this.applyCategoryOrder(ids); },
          onClose: (): void => {
            this.showCategoryDrawer = false;
            this.categoryInitialSelectId = '';
          },
        })
      }

      if (this.showEdit && this.editInfo !== null) {
        this.editPanel()
      }

      // 三点菜单必须挂在最外层 Stack：放进 Column 会被当成普通子项参与排版，
      // 遮罩盖不满整页，卡片高度也按剩余空间算，长菜单底部会被裁掉
      if (this.menuIndex >= 0 && this.menuIndex < this.currentList().length) {
        SongMenuPanel({
          music: this.currentList()[this.menuIndex],
          listId: '',
          index: this.menuIndex,
          localMode: true,
          theme: this.theme,
          onPlayLocal: (i: number): void => { this.playAt(i); },
          onRemoveLocal: (ms: MusicInfo[]): void => { this.requestRemove(ms); },
          onEditLocal: (m: MusicInfo): void => { this.openEdit(m); },
          onClose: (): void => { this.menuIndex = -1; },
        })
      }

      // 批量菜单：对选中的多首歌执行同一操作（本地模式自动隐藏不适用的项）
      if (this.batchMenu) {
        SongMenuPanel({
          musics: this.selectedSongs(),
          listId: '',
          index: 0,
          localMode: true,
          theme: this.theme,
          onPlayLocal: (i: number): void => { this.playAt(i); },
          onRemoveLocal: (ms: MusicInfo[]): void => { this.requestRemove(ms); },
          onEditLocal: (m: MusicInfo): void => { this.openEdit(m); },
          onClose: (): void => {
            this.batchMenu = false;
            // 移除后选中项可能已不在列表
            const ids = new Set<string>(this.songs.map((m: MusicInfo): string => m.id));
            this.selected = this.selected.filter((id: string): boolean => ids.has(id));
            if (this.selected.length === 0) {
              this.editMode = false;
            }
          },
        })
      }

      // 空文件清理二次确认：这些文件是下载没写完的残骸，说明清楚再删
      if (this.pendingCleanEmpty) {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => { this.pendingCleanEmpty = false; })
          Column() {
            Text('清理空文件')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
            Text('有 ' + this.emptyCount.toString() +
              ' 个 0 字节文件，是之前下载没完成留下的，播放会报「格式不支持」，所以本地音乐不显示它们。' +
              '清理只删除这些空文件，任何有内容的歌曲都不会被删除。')
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .margin({ top: 10 }).lineHeight(18)
            Row() {
              Button('取消')
                .onClick((): void => { this.pendingCleanEmpty = false; })
                .backgroundColor(buildPalette(this.theme).pillBg).stateEffect(false)
                .fontColor(buildPalette(this.theme).pillText).fontSize(13).layoutWeight(1)
              Button('清理')
                .onClick((): void => { this.cleanEmptyFiles(); })
                .backgroundColor('#C0553F').stateEffect(false)
                .fontColor('#FFFFFF').fontSize(13).layoutWeight(1)
                .margin({ left: 10 })
            }
            .width('100%').margin({ top: 16 })
          }
          .width('84%').padding(18)
          .backgroundColor(buildPalette(this.theme).card).borderRadius(14)
          .border({ width: 1, color: buildPalette(this.theme).divider })
        }
        .width('100%').height('100%')
      }

      // 移除二次确认：明确说明不删文件
      if (this.pendingRemove.length > 0) {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => { this.pendingRemove = []; })
          Column() {
            Text('从本地音乐移除')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
            Text('将从本地音乐列表移除 ' + this.pendingRemove.length.toString() +
              ' 首歌曲，不会删除手机里的音乐文件。之后可在本页点「恢复隐藏」找回。')
              .fontSize(12).fontColor(buildPalette(this.theme).subText)
              .margin({ top: 10 }).lineHeight(18)
            Row() {
              Button('取消')
                .onClick((): void => { this.pendingRemove = []; })
                .backgroundColor(buildPalette(this.theme).pillBg).stateEffect(false)
                .fontColor(buildPalette(this.theme).pillText).fontSize(13).layoutWeight(1)
              Button('移除')
                .onClick((): void => { this.confirmRemove(); })
                .backgroundColor('#C0553F').stateEffect(false)
                .fontColor('#FFFFFF').fontSize(13).layoutWeight(1)
                .margin({ left: 10 })
            }
            .width('100%').margin({ top: 16 })
          }
          .width('84%').padding(18)
          .backgroundColor(buildPalette(this.theme).card).borderRadius(14)
          .border({ width: 1, color: buildPalette(this.theme).divider })
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }

  /** 通用歌曲行（歌曲分类 / 分组详情共用）：与歌单页同一套 MusicListItem 交互 */
  @Builder
  songRows(list: MusicInfo[]) {
    List() {
      ForEach(list, (m: MusicInfo, idx: number): void => {
        ListItem() {
          MusicListItem({
            music: m,
            index: idx,
            isActive: this.currentId.length > 0 && this.currentId === m.id,
            theme: this.theme,
            showCover: true,
            showSource: false,
            showAlbumName: this.showAlbumName,
            showInterval: this.showInterval,
            selecting: this.editMode,
            checked: this.isSelected(m.id),
            onItemClick: (i: number): void => {
              // 与歌单详情 / 我的列表一致：单击只做选中，播放改为双击
              if (this.editMode) {
                this.toggleSelect(this.currentList()[i].id);
              }
            },
            onItemDoubleClick: (i: number): void => {
              if (this.editMode) {
                // 双击的第一下已经切换过选中，这里不再重复切换
                return;
              }
              this.playAt(i);
            },
            onItemLongPress: (i: number): void => { this.enterSelect(i); },
            onMoreClick: (i: number): void => {
              // 多选态下 ⋮ 作用于选中集合：该行未选中先补选
              if (this.editMode) {
                const listNow: MusicInfo[] = this.currentList();
                if (i >= 0 && i < listNow.length && !this.isSelected(listNow[i].id)) {
                  this.selected = this.selected.concat([listNow[i].id]);
                }
                this.openBatchMenu();
                return;
              }
              this.menuIndex = i;
            },
          })
        }
      }, (m: MusicInfo): string => {
        // 名字 / 歌手 / 专辑 / 封面变了必须换 key，否则 ForEach 复用旧行、文本不刷新
        const lm = m.meta as MusicInfoMetaLocal;
        const pic: string = lm.picUrl !== undefined && lm.picUrl !== null ? lm.picUrl : '';
        return m.id + '|' + m.name + '|' + m.singer + '|' + lm.albumName + '|' + pic;
      })
    }
    .layoutWeight(1).width('100%')
    .divider({ strokeWidth: 0.5, color: buildPalette(this.theme).pillBg })
  }

  @Builder
  editPanel() {
    Column() {
      Text(this.tx('edit_meta'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
      this.editRow('localEditName', this.tx('field_name'), this.editName, (v: string): void => { this.editName = v; })
      this.editRow('localEditSinger', this.tx('field_singer'), this.editSinger, (v: string): void => { this.editSinger = v; })
      this.editRow('localEditAlbum', this.tx('field_album'), this.editAlbum, (v: string): void => { this.editAlbum = v; })
      this.editRow('localEditPic', this.tx('cover_url'), this.editPic, (v: string): void => { this.editPic = v; })
      Row() {
        Button(this.tx('delete_file'))
          .backgroundColor('#E7C4C0').fontColor('#8B3A33').stateEffect(false)
          .layoutWeight(1)
          .onClick((): void => {
            if (this.editInfo !== null) {
              const target: MusicInfo = this.editInfo;
              this.scanner.deleteFile(target);
              this.showEdit = false;
              this.editInfo = null;
              this.doScan();
              userNotice().info('已删除文件「' + target.name + '」');
            }
          })
        Button(this.tx('source_save'))
          .backgroundColor(this.theme.primary).fontColor('#FFFFFF').stateEffect(false)
          .layoutWeight(1)
          .onClick((): void => {
            if (this.editInfo !== null) {
              const edit: LocalMusicEdit = {
                name: this.editName,
                singer: this.editSinger,
                albumName: this.editAlbum,
                picUrl: this.editPic,
              };
              this.scanner.saveEdit(this.editInfo, edit).then((): void => {
                this.showEdit = false;
                this.editInfo = null;
                this.doScan();
              });
            }
          })
      }
      .width('100%').margin({ top: 14 })
    }
    .width('86%').padding(18)
    .backgroundColor(buildPalette(this.theme).card).borderRadius(14)
    .border({ width: 1, color: this.theme.primary })
    .position({ x: '7%', y: '22%' })
    .onAppear((): void => {
      // 打开编辑弹窗后自动聚焦「名称」输入框，光标落入并唤起键盘
      setTimeout((): void => { focusControl.requestFocus('localEditName'); }, 60);
    })
  }

  @Builder
  editRow(keyName: string, label: string, value: string, onChange: (v: string) => void) {
    Row() {
      Text(label).fontSize(12).fontColor(buildPalette(this.theme).subText).width(64)
      TextInput({ placeholder: label, text: value })
        .height(36).fontSize(13).backgroundColor(buildPalette(this.theme).pillBg).borderRadius(8)
        .layoutWeight(1)
        .id(keyName)
        .onChange((v: string): void => { onChange(v); })
    }
    .width('100%').margin({ top: 10 })
  }

  private openEdit(m: MusicInfo): void {
    this.editInfo = m;
    this.editName = m.name;
    this.editSinger = m.singer;
    this.editAlbum = (m.meta as MusicInfoMetaLocal).albumName;
    const pic = (m.meta as MusicInfoMetaLocal).picUrl;
    this.editPic = pic !== undefined && pic !== null ? pic : '';
    this.showEdit = true;
  }
}
