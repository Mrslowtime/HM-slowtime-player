/**
 * 歌曲三点菜单 —— 本协议的歌曲操作菜单。
 *
 * 13 项：播放 / 稍后播放 / 下载 / 添加到… / 移动到… / 调整位置 /
 *        歌曲换源 / 分享歌曲 / 歌曲详情页 / 清理缓存 / 不喜欢 / 移除 / 编辑歌曲信息
 *
 * localMode（本地音乐页）：隐藏「移动到…/调整位置/歌曲换源/清理缓存」，
 * 「播放」走 onPlayLocal 回调，「移除」改为「从本地音乐移除（不删文件）」并交给父级确认，
 * 额外提供「编辑歌曲信息」。
 *
 * 自包含：直接调用 ListManager / PlayController / DownloadManager 等单例，
 * 父级只需要传当前歌曲、列表 id 与下标，操作完回调 onChanged 刷新列表。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { MusicInfo, MusicInfoMetaOnline, MusicInfoMetaLocal, UserListInfo } from '../model/MusicTypes';
import { ThemeInfo, ThemePalette, buildPalette } from '../theme/Themes';
import { ListIds, OnlineSource, SOURCE_ALIAS, SOURCE_NAMES, Quality, isDownloadEnabled } from '../config/AppConstants';
import { ListManager } from '../core/ListManager';
import { PlayController } from '../player/PlayController';
import { DownloadManager } from '../core/DownloadManager';
import { availableDownloadQualities } from '../core/DownloadQualities';
import { DownloadQualityPicker } from './DownloadQualityPicker';
import { MusicSource } from '../core/MusicSource';
import { MusicUrlResolver } from '../core/net/MusicUrlResolver';
import { MusicApi } from '../core/api/MusicApi';
import { SearchResult } from '../core/api/ApiTypes';
import { AppState } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { dislikeEvent, stateEvent, StateEvents } from '../store/EventBus';
import { userNotice } from '../core/UserNotice';
import { computePopupPos, setPopupContainer, PopupPoint, popupMaxHeightVp, popupMaxWidthVp, popupWidthForTexts, estimateTextWidth } from '../core/Popup';
import { exportDownloadedFiles, ExportFileItem } from '../core/DownloadExporter';
import { isPublicStored } from '../core/DownloadStorage';
import { I18n } from '../core/I18n';

interface MenuItem {
  id: number;
  label: string;
}

/** 可作为添加/移动目标的列表 */
interface ListOption {
  id: string;
  name: string;
}

/** 歌曲详情行 */
interface DetailRow {
  k: string;
  v: string;
}

const MENU_ITEMS: MenuItem[] = [
  { id: 1, label: '播放' },
  { id: 2, label: '稍后播放' },
  { id: 3, label: '下载' },
  { id: 4, label: '添加到…' },
  { id: 5, label: '移动到…' },
  { id: 6, label: '调整位置' },
  { id: 7, label: '歌曲换源' },
  { id: 8, label: '分享歌曲' },
  { id: 9, label: '歌曲详情页' },
  { id: 10, label: '清理缓存' },
  { id: 11, label: '不喜欢' },
  { id: 12, label: '移除' },
  { id: 13, label: '编辑歌曲信息' },
  { id: 14, label: '导出到...' },
];

/** 二级面板：无 / 添加到 / 移动到 / 新增列表 / 调整位置 / 歌曲详情 */
type SubMode = 'none' | 'add' | 'move' | 'newList' | 'position' | 'detail';

/** 浮窗最小宽度：再短的文案也不低于这个值，避免「移到…」这类短菜单窄得放不下标题行与返回 */
const POPUP_MIN_WIDTH: number = 176;

@Component
export struct SongMenuPanel {
  @Prop music: MusicInfo | null = null;
  /** 批量操作目标：非空时进入「多选批量」模式，菜单项作用于全部选中歌曲 */
  @Prop musics: MusicInfo[] = [];
  @Prop listId: string = '';
  @Prop index: number = 0;
  /** 是否显示「移除」项；搜索页 / 歌单详情等无法从本页列表真正移除的页面应传 false */
  @Prop allowRemove: boolean = true;
  /**
   * 列表顺序固定（「播放历史」）：隐藏「调整位置」。
   * 历史列表按播放时间倒序，手动挪动会把这个语义破坏掉。
   */
  @Prop fixedOrder: boolean = false;
  /**
   * 本地音乐页模式：列表不属于任何「我的列表」，所以
   *  - 隐藏「移动到…/调整位置/歌曲换源/清理缓存」（本地文件不需要换源、也没有列表顺序）；
   *  - 「播放」走 onPlayLocal 回调（本地页没有可用的 listId）；
   *  - 「移除」语义改为「从本地音乐移除（不删文件）」，交给父级二次确认；
   *  - 额外提供「编辑歌曲信息」。
   */
  @Prop localMode: boolean = false;
  /** 本地页播放第 index 首 */
  onPlayLocal: (index: number) => void = () => {};
  /** 本地页请求移除（父级负责二次确认后隐藏，不删除文件） */
  onRemoveLocal: (musics: MusicInfo[]) => void = () => {};
  /** 本地页请求编辑歌曲信息 */
  onEditLocal: (music: MusicInfo) => void = () => {};
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  onClose: () => void = () => {};
  onChanged: () => void = () => {};

  @State private sub: SubMode = 'none';
  @State private posText: string = '';
  /** 「新增列表」输入的名字，以及是从「添加到」还是「移动到」进来的（决定建好后怎么放歌） */
  @State private newListName: string = '';
  @State private newListFrom: string = 'add';
  @State private busy: boolean = false;
  /**
   * 容器坐标校准计数器：根 Stack 的 onAreaChange 收到真实容器坐标后自增，触发一次重算。
   * 真正的位置不再缓存，而是每次 build 按当前面板宽高现算（见 posPoint）。
   */
  @State private posTick: number = 0;
  /** 下载音质选择弹窗：目标歌曲 + 候选音质；数组为空表示不弹 */
  @State private downloadTargets: MusicInfo[] = [];
  @State private downloadQualities: Quality[] = [];

  private state: AppState = AppState.getInstance();
  private listManager: ListManager = ListManager.getInstance();
  private controller: PlayController = PlayController.getInstance();
  private settings: SettingStore = SettingStore.getInstance();

  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  /** 可作为「添加/移动」目标的列表（排除歌单分类与当前列表） */
  private targetLists(): ListOption[] {
    const out: ListOption[] = [];
    for (const u of this.state.userLists) {
      if (u.id === ListIds.PLAYLIST) {
        continue;
      }
      if (u.id === ListIds.TEMP && this.listId === ListIds.TEMP) {
        continue;
      }
      out.push({ id: u.id, name: u.name });
    }
    return out;
  }

  /** 批量模式：多选后点「更多」打开，菜单项作用于所有选中歌曲 */
  private isBatch(): boolean {
    return this.musics.length > 0;
  }

  /** 本次操作的目标歌曲：批量取选中集合，否则取单曲 */
  private targets(): MusicInfo[] {
    if (this.musics.length > 0) {
      return this.musics;
    }
    return this.music === null ? [] : [this.music];
  }

  private fullTitle(): string {
    if (this.isBatch()) {
      return '已选 ' + this.musics.length.toString() + ' 首';
    }
    const m = this.music;
    if (m === null) {
      return '';
    }
    return m.singer.length > 0 ? m.name + ' - ' + m.singer : m.name;
  }

  private actionName(id: number): string {
    for (const it of MENU_ITEMS) {
      if (it.id === id) {
        return it.label;
      }
    }
    return '';
  }

  /** 实际展示的菜单项：本地音乐不显示「下载」(id=3)；allowRemove=false 时不显示「移除」(id=12) */
  private visibleItems(): MenuItem[] {
    let items: MenuItem[] = MENU_ITEMS;
    // 下载功能总开关关闭时隐藏「下载」(id=3)：源码逻辑保留，改 download.enable 即可恢复
    if (!isDownloadEnabled()) {
      items = items.filter((it: MenuItem): boolean => it.id !== 3);
    }
    // 批量模式：只保留能对多首同时生效的项（播放/调位置/换源/分享/详情/编辑信息都是单曲语义）
    if (this.isBatch()) {
      items = items.filter((it: MenuItem): boolean =>
        it.id !== 1 && it.id !== 6 && it.id !== 7 && it.id !== 8 && it.id !== 9 && it.id !== 13);
    }
    if (this.music !== null && this.music.source === 'local') {
      items = items.filter((it: MenuItem): boolean => it.id !== 3);
    }
    if (this.localMode) {
      // 本地文件本身就是音源：没有「源列表」可移动、没有列表顺序、换源与直链缓存都无意义
      items = items.filter((it: MenuItem): boolean =>
        it.id !== 5 && it.id !== 6 && it.id !== 7 && it.id !== 10);
    } else {
      items = items.filter((it: MenuItem): boolean => it.id !== 13);
    }
    if (!this.allowRemove) {
      items = items.filter((it: MenuItem): boolean => it.id !== 12);
    }
    if (this.fixedOrder) {
      // 顺序由播放时间决定，不给手动调位置
      items = items.filter((it: MenuItem): boolean => it.id !== 6);
    }
    // 「导出到...」只对「还在应用沙箱里」的本地文件有意义：已经在手机公共目录（文件 App
    // 里能直接看到、能自己拷走）的歌不需要再导出一份，菜单里就不显示。
    // 批量看选中集合里有没有仍需要导出的歌。
    let hasExportable: boolean = false;
    for (const it of this.targets()) {
      if (it.source !== 'local') {
        continue;
      }
      const lm = it.meta as MusicInfoMetaLocal;
      const p: string = lm !== null && lm !== undefined ? lm.filePath : '';
      if (p.length > 0 && !isPublicStored(p)) {
        hasExportable = true;
        break;
      }
    }
    if (!hasExportable) {
      items = items.filter((it: MenuItem): boolean => it.id !== 14);
    }
    return items;
  }

  /** 本地歌曲导出到用户指定文件夹：与下载页「导出到...」共用同一实现 */
  private async exportLocal(ts: MusicInfo[]): Promise<void> {
    const files: ExportFileItem[] = [];
    for (const m of ts) {
      if (m.source !== 'local') {
        continue;
      }
      const lm = m.meta as MusicInfoMetaLocal;
      if (lm === null || lm === undefined || lm.filePath.length === 0) {
        continue;
      }
      // 已经在公共目录里的歌不再复制一份（用户自己就能在文件 App 里拷走）
      if (isPublicStored(lm.filePath)) {
        continue;
      }
      const dot: number = lm.filePath.lastIndexOf('.');
      const ext: string = dot > 0 ? lm.filePath.substring(dot + 1).toLowerCase() : (lm.ext.length > 0 ? lm.ext : 'mp3');
      files.push({ srcPath: lm.filePath, displayName: m.name + ' - ' + m.singer, ext: ext });
    }
    if (files.length === 0) {
      userNotice().warn('没有可导出的本地歌曲');
      this.onClose();
      return;
    }
    const ok: boolean = await exportDownloadedFiles(files);
    if (ok) {
      userNotice().info(I18n().t('export_to_done'));
    }
    this.onClose();
  }

  /** 菜单文案：本地模式下「移除」要说清楚只移出列表、不删文件 */
  private itemLabel(it: MenuItem): string {
    if (it.id === 12 && this.localMode) {
      return '从本地音乐移除';
    }
    if (it.id === 14) {
      return I18n().t('export_to');
    }
    return it.label;
  }

  /** 点下载：先算可用音质，多于一种弹窗让用户挑，只有一种直接下载（与歌单页一致） */
  private openDownload(ts: MusicInfo[]): void {
    const online: MusicInfo[] = ts.filter((it: MusicInfo): boolean => it.source !== 'local');
    if (online.length === 0) {
      userNotice().info('选中歌曲都在本地');
      this.onClose();
      return;
    }
    const qs: Quality[] = availableDownloadQualities(online[0]);
    if (qs.length <= 1) {
      this.doDownload(online, qs.length > 0 ? qs[0] : '128k');
      return;
    }
    this.downloadTargets = online;
    this.downloadQualities = qs;
  }

  private doDownload(targets: MusicInfo[], quality: Quality): void {
    this.downloadTargets = [];
    this.downloadQualities = [];
    for (const it of targets) {
      DownloadManager.getInstance().enqueue(it, quality);
    }
    userNotice().info('已加入下载队列 ' + targets.length.toString() + ' 首');
    this.onClose();
  }

  private onAction(id: number): void {
    const ts: MusicInfo[] = this.targets();
    if (ts.length === 0) {
      return;
    }
    const m: MusicInfo = ts[0];
    const n: number = ts.length;
    switch (id) {
      case 1:
        if (this.localMode) {
          this.onPlayLocal(this.index);
        } else {
          this.controller.playList(this.listId, this.index);
        }
        this.onClose();
        break;
      case 2:
        this.listManager.addListMusics(ListIds.PLAY_LATER, ts, false);
        userNotice().info(n > 1 ? ('已添加 ' + n.toString() + ' 首到「稍后播放」') : '已添加到「稍后播放」');
        this.onClose();
        break;
      case 3:
        if (m.source === 'local' && n === 1) {
          userNotice().warn('本地文件已经在手机里了');
          this.onClose();
        } else {
          this.openDownload(ts);
        }
        break;
      case 4:
        this.sub = 'add';
        break;
      case 5:
        this.sub = 'move';
        break;
      case 6:
        this.posText = (this.index + 1).toString();
        this.sub = 'position';
        break;
      case 7:
        this.changeSource(m);
        break;
      case 8:
        this.share(m);
        break;
      case 9:
        this.sub = 'detail';
        break;
      case 10:
        for (const it of ts) {
          MusicSource.getInstance().invalidate(it.id);
          MusicUrlResolver.getInstance().invalidate(it.id);
        }
        userNotice().info(n > 1 ? ('已清理 ' + n.toString() + ' 首的缓存') : ('已清理「' + m.name + '」的缓存'));
        this.onClose();
        break;
      case 11:
        for (const it of ts) {
          this.dislike(it);
        }
        break;
      case 12:
        if (this.localMode) {
          // 本地页的「移除」= 从列表隐藏，文件保留；二次确认与落盘由父级处理
          this.onRemoveLocal(ts);
          this.onClose();
          break;
        }
        this.listManager.removeListMusics(this.listId, ts.map((it: MusicInfo): string => it.id));
        userNotice().info(n > 1 ? ('已移除 ' + n.toString() + ' 首') : '已从列表移除');
        this.onChanged();
        this.onClose();
        break;
      case 13:
        this.onEditLocal(m);
        this.onClose();
        break;
      case 14:
        void this.exportLocal(ts);
        break;
      default:
        break;
    }
  }

  /** 添加到指定列表（批量时整批添加） */
  private addTo(listId: string): void {
    const ts: MusicInfo[] = this.targets();
    if (ts.length === 0) {
      return;
    }
    const n: number = this.listManager.addListMusics(listId, ts, true);
    if (ts.length > 1) {
      userNotice().info(n > 0 ? ('已添加 ' + n.toString() + ' 首') : '这些歌已经在列表里了');
    } else {
      userNotice().info(n > 0 ? '已添加' : '这首歌已经在列表里了');
    }
    this.onClose();
  }

  /** 移动到指定列表（先加后删，避免中途失败丢歌） */
  private moveTo(listId: string): void {
    const ts: MusicInfo[] = this.targets();
    if (ts.length === 0) {
      return;
    }
    if (listId === this.listId) {
      userNotice().warn('目标列表就是当前列表');
      return;
    }
    this.listManager.addListMusics(listId, ts, true);
    this.listManager.removeListMusics(this.listId, ts.map((it: MusicInfo): string => it.id));
    userNotice().info(ts.length > 1 ? ('已移动 ' + ts.length.toString() + ' 首') : '已移动');
    this.onChanged();
    this.onClose();
  }

  /** 调整到第 N 位（1 基） */
  private applyPosition(): void {
    const n: number = parseInt(this.posText);
    const total: number = this.state.getList(this.listId).length;
    if (isNaN(n) || n < 1 || n > total) {
      userNotice().warn('请输入 1 ~ ' + total.toString() + ' 之间的序号');
      return;
    }
    this.listManager.moveListMusic(this.listId, this.index, n - 1);
    userNotice().info('已调整到第 ' + n.toString() + ' 位');
    this.onChanged();
    this.onClose();
  }

  /** 歌曲换源：在其他音源搜同名歌，替换列表项并在播放中时续播 */
  private async changeSource(m: MusicInfo): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const keyword: string = m.singer.length > 0 ? m.name + ' ' + m.singer : m.name;
    const all: OnlineSource[] = ['kw', 'tx', 'wy', 'kg', 'mg'];
    let hit: MusicInfo | null = null;
    for (const s of all) {
      if (s === m.source) {
        continue;
      }
      try {
        const r: SearchResult = await MusicApi.getInstance().search(s, keyword, 1, 5);
        for (const c of r.list) {
          if (c.name === m.name) {
            hit = c;
            break;
          }
        }
      } catch (e) {
        continue;
      }
      if (hit !== null) {
        break;
      }
    }
    this.busy = false;
    if (hit === null) {
      userNotice().warn('没有找到其他音源的同名歌曲');
      return;
    }
    const ok: boolean = this.listManager.replaceMusic(this.listId, m.id, hit);
    if (!ok) {
      userNotice().warn('换源失败：列表里找不到这首歌');
      return;
    }
    const cur = this.state.playMusicInfo;
    if (cur !== null && cur.musicInfo.id === m.id) {
      await this.controller.playListById(this.listId, hit.id);
    }
    userNotice().info('已换到' + (SOURCE_ALIAS[hit.source] ?? hit.source));
    this.onChanged();
    this.onClose();
  }

  /**
   * 分享歌曲：复制「歌名 - 歌手（来源）」到剪贴板（当前 SDK 未导出 systemShare，
   * 系统分享面板留待后续 SDK 升级再接，先保证可用）。
   */
  private share(m: MusicInfo): void {
    const text: string = this.fullTitle() + '（来源：' +
      (SOURCE_NAMES[m.source] ?? m.source) + '）';
    this.copyToClipboard(text);
  }

  private copyToClipboard(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        userNotice().info('歌曲信息已复制到剪贴板');
      }).catch((): void => {
        userNotice().warn('复制失败');
      });
    } catch (e) {
      userNotice().warn('复制失败');
    }
    this.onClose();
  }

  /** 不喜欢：按歌名加入不喜欢列表，随机播放时会跳过 */
  private dislike(m: MusicInfo): void {
    const d = this.state.dislikeInfo;
    if (d.musicNames.indexOf(m.name) < 0) {
      const names: string[] = d.musicNames.slice();
      names.push(m.name);
      this.state.dislikeInfo = {
        names: d.names, musicNames: names, singerNames: d.singerNames, rules: d.rules,
      };
      dislikeEvent().emit('dislikeUpdated');
      stateEvent().emit(StateEvents.CONFIG_UPDATED);
    }
    userNotice().info('已加入不喜欢：' + m.name);
    this.onClose();
  }

  /**
   * 面板高度按内容自适应：选项少时卡片贴合内容，不留大片空白；
   * 超过 78% 屏高时才由 constraintSize 夹紧，内部 Scroll 接管滚动。
   * 数值 = 标题行 + 每项固定行高 × 项数 + 底部留白（单位 vp）。
   */
  private panelHeight(): number {
    if (this.sub === 'add' || this.sub === 'move') {
      // 多出顶部固定的「＋ 新增列表」一行
      return 40 + 44 + 44 * this.targetLists().length + 8;
    }
    if (this.sub === 'newList') {
      return 152;
    }
    if (this.sub === 'position') {
      return 172;
    }
    if (this.sub === 'detail') {
      return 40 + 30 * this.detailRows().length + 12;
    }
    return 36 + 42 * this.visibleItems().length + 8;
  }

  /** 浮窗实际高度（vp）：内容自适应，上限为「状态栏 ~ 底部播控栏」之间的可用高度，超出由内部 Scroll 滚动 */
  private popupHeight(): number {
    const h: number = this.panelHeight();
    const maxH: number = popupMaxHeightVp();
    return h < maxH ? h : maxH;
  }

  /**
   * 浮窗宽度（vp）：按「当前这一屏真正显示的文字」自适应。
   *
   * 原来只按主菜单项测量，进到「添加到…/移动到…」子面板后就露馅了：
   * 标题行（标题 + 返回）被挤成两行，列表名被截断；「新增列表」面板更惨，
   * 输入框与两个按钮在 88vp 里根本放不下。
   * 现在每个子面板都参与测量，并给一个下限（保证输入框/按钮排得开），
   * 上限仍是屏幕可用宽度。
   */
  private popupWidth(): number {
    // 用「实际展示」的文案测量：本地模式的「从本地音乐移除」比默认的「移除」更宽
    const labels: string[] = this.visibleItems().map((it: MenuItem): string => this.itemLabel(it));
    let w: number = popupWidthForTexts(labels, 14, 16);
    if (this.sub === 'none') {
      // 主菜单：顶部还有一行「歌名 · 歌手」，也参与测量（超过 260 就让它换行/省略，
      // 不能因为一个超长歌名把浮窗撑满整屏）
      const title: string = this.fullTitle();
      if (title.length > 0) {
        w = Math.max(w, Math.min(popupWidthForTexts([title], 12, 16) + 8, 260));
      }
    } else if (this.sub === 'add' || this.sub === 'move') {
      const title: string = this.sub === 'add' ? '添加到…' : '移动到…';
      // 标题（14sp 粗）+ 左右内边距 + 「返回」（12sp）
      const byHead: number = estimateTextWidth(title, 14) + 16 * 2 + 8 + estimateTextWidth('返回', 12);
      const names: string[] = ['＋ 新增列表'];
      for (const t of this.targetLists()) {
        names.push(t.name);
      }
      // 列表名可能很长：放宽到 280 封顶，再长就单行省略，不要撑满整屏
      const byNames: number = Math.min(popupWidthForTexts(names, 14, 16), 280);
      w = Math.max(w, byHead, byNames);
    } else if (this.sub === 'newList') {
      // 输入框 + 两个并排按钮，太窄会把内容裁掉
      w = Math.max(w, 240);
    } else if (this.sub === 'position') {
      w = Math.max(w, 208);
    }
    if (w < POPUP_MIN_WIDTH) {
      w = POPUP_MIN_WIDTH;
    }
    const cap: number = popupMaxWidthVp();
    return w > cap ? cap : w;
  }

  /**
   * 浮窗落点（容器相对坐标）：每次渲染都按「当前这一屏的实际宽高」重算。
   *
   * 之前把结果缓存在 @State 里，只在打开和容器 onAreaChange 时赋值，于是
   * 「添加到…」→「新增列表」这类**子面板切换导致浮窗变宽**的场景会失效：
   * x 仍按窄面板算，宽面板右边缘直接顶出屏幕，必须滑一下列表（触发 onAreaChange）
   * 才回到屏内。改成实时计算后，宽度/高度一变，位置同帧跟上。
   */
  private posPoint(): PopupPoint {
    return computePopupPos(this.popupWidth(), this.popupHeight());
  }

  private detailRows(): DetailRow[] {
    const m = this.music;
    if (m === null) {
      return [];
    }
    const rows: DetailRow[] = [];
    rows.push({ k: '歌曲名', v: m.name });
    rows.push({ k: '歌手', v: m.singer });
    rows.push({ k: '专辑', v: m.meta.albumName.length > 0 ? m.meta.albumName : '—' });
    rows.push({ k: '来源', v: SOURCE_NAMES[m.source] ?? m.source });
    rows.push({ k: '时长', v: m.interval ?? '—' });
    if (m.source === 'local') {
      const lm = m.meta as MusicInfoMetaLocal;
      rows.push({ k: '文件', v: lm.filePath });
    } else {
      const om = m.meta as MusicInfoMetaOnline;
      rows.push({ k: '歌曲 ID', v: om.songId });
    }
    rows.push({ k: '音质', v: this.settings.getString('player.playQuality', '128k') as string });
    return rows;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 遮罩：点击空白关闭
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        if (this.sub === 'none') {
          this.menuList()
        } else if (this.sub === 'add' || this.sub === 'move') {
          this.pickListPanel()
        } else if (this.sub === 'newList') {
          this.newListPanel()
        } else if (this.sub === 'position') {
          this.positionPanel()
        } else {
          this.detailPanel()
        }
      }
      .width(this.popupWidth())
      // 高度跟随内容：项数少时卡片贴合内容，避免大片空白；
      // 项数多时被「状态栏 ~ 播控栏」可用高度夹紧，内部 Scroll 才真正可滚（layoutWeight 需要确定的父高度）
      .height(this.panelHeight())
      .constraintSize({ maxHeight: popupMaxHeightVp() })
      .backgroundColor(this.pal().card)
      .borderRadius(12)
      .border({ width: 1, color: this.pal().divider })
      .position({ x: this.posPoint().x, y: this.posPoint().y })
      .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 })

      // 下载音质弹窗：盖在菜单之上，选好音质后统一入队
      if (isDownloadEnabled() && this.downloadTargets.length > 0 && this.downloadQualities.length > 0) {
        DownloadQualityPicker({
          qualities: this.downloadQualities,
          theme: this.theme,
          onPick: (q: Quality): void => {
            this.doDownload(this.downloadTargets, q);
          },
          onClose: (): void => {
            this.downloadTargets = [];
            this.downloadQualities = [];
          },
        })
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      // 记录浮窗容器（根 Stack）在窗口中的真实位置，供 computePopupPos 换算成容器相对坐标
      setPopupContainer(Number(area.globalPosition.x), Number(area.globalPosition.y));
      // 容器坐标变了要重算一次位置（自增计数器触发重新渲染，位置由 posPoint 现算）
      this.posTick = (this.posTick + 1) % 10000;
    })
  }

  @Builder
  menuList() {
    Column() {
      Text(this.fullTitle())
        .fontSize(12).fontColor(this.pal().subText)
        // 宽度已按标题测量；只有极长标题才换成两行，仍放不下才省略，保证首行信息完整
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 6 })
      Scroll() {
        Column() {
          ForEach(this.visibleItems(), (it: MenuItem): void => {
            Row() {
              Text(this.itemLabel(it)).fontSize(14).fontColor(this.theme.font)
            }
            .width('100%')
            .height(42)
            .padding({ left: 16, right: 16 })
            .onClick((): void => { this.onAction(it.id); })
          }, (it: MenuItem): string => it.id.toString())
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  pickListPanel() {
    Column() {
      Row() {
        Text(this.sub === 'add' ? '添加到…' : '移动到…')
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('返回').fontSize(12).fontColor(this.theme.primary)
          .onClick((): void => { this.sub = 'none'; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      // 固定在最上面：新建一个列表，建好直接把这首歌（或这批歌）放进去。
      // 新列表写进「我的列表」，那里会立刻出现（ListEvents.LIST_CREATE 广播）。
      Row() {
        Text('＋ 新增列表')
          .fontSize(14).fontColor(this.theme.primary)
          .layoutWeight(1)
      }
      .width('100%').height(44).padding({ left: 16, right: 16 })
      .onClick((): void => {
        this.newListFrom = this.sub === 'move' ? 'move' : 'add';
        this.newListName = '';
        this.sub = 'newList';
      })

      Scroll() {
        Column() {
          ForEach(this.targetLists(), (t: ListOption): void => {
            Row() {
              // 列表名可能很长：单行省略，宽度已按最长名字测量（封顶 280）
              Text(t.name).fontSize(14).fontColor(this.theme.font)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%').height(44).padding({ left: 16, right: 16 })
            .onClick((): void => {
              if (this.sub === 'add') {
                this.addTo(t.id);
              } else {
                this.moveTo(t.id);
              }
            })
          }, (t: ListOption): string => t.id)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  /** 新增列表：输入名字 → 建列表 → 直接把目标歌曲放进去 */
  @Builder
  newListPanel() {
    Column() {
      Row() {
        Text('新增列表').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('返回').fontSize(12).fontColor(this.theme.primary)
          .onClick((): void => { this.sub = this.newListFrom === 'move' ? 'move' : 'add'; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      TextInput({ placeholder: '列表名称', text: this.newListName })
        .height(38).fontSize(13).margin({ left: 16, right: 16, top: 4 })
        .backgroundColor(this.pal().pillBg).borderRadius(8)
        .onChange((v: string): void => { this.newListName = v; })
        .onSubmit((): void => { this.createListAndApply(); })

      Row() {
        Button('取消')
          .fontSize(13).fontColor(this.pal().subText)
          .backgroundColor(this.pal().pillBg).borderRadius(8)
          .layoutWeight(1).height(36)
          .onClick((): void => { this.sub = this.newListFrom === 'move' ? 'move' : 'add'; })
        Button('新建并放入')
          .fontSize(13).fontColor('#FFFFFF')
          .backgroundColor(this.theme.primary).borderRadius(8)
          .layoutWeight(1).height(36).margin({ left: 10 })
          .onClick((): void => { this.createListAndApply(); })
      }
      .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 12 })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 建列表并放入当前目标歌曲。
   * 名字留空时按「新建列表」创建（与设置页的「＋ 新建列表」行为一致）。
   * 只允许建用户列表：createUserList 会写进 state.userLists 并广播 LIST_CREATE，
   * 「我的列表」页订阅后立即出现，不需要额外同步。
   */
  private createListAndApply(): void {
    if (this.busy) {
      return;
    }
    const raw: string = this.newListName.trim();
    const name: string = raw.length > 0 ? raw : '新建列表';
    this.busy = true;
    const item: UserListInfo = this.listManager.createUserList(name);
    this.busy = false;
    if (this.newListFrom === 'move') {
      this.moveTo(item.id);
    } else {
      this.addTo(item.id);
    }
    this.onChanged();
  }

  @Builder
  positionPanel() {
    Column() {
      Row() {
        Text('调整位置').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .layoutWeight(1)
        Text('返回').fontSize(12).fontColor(this.theme.primary)
          .onClick((): void => { this.sub = 'none'; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Text('当前第 ' + (this.index + 1).toString() + ' 位，共 ' +
        this.state.getList(this.listId).length.toString() + ' 首')
        .fontSize(11).fontColor(this.pal().subText)
        .width('100%').padding({ left: 16, right: 16 })

      TextInput({ placeholder: '目标序号', text: this.posText })
        .height(38).fontSize(13).margin({ left: 16, right: 16, top: 10 })
        .backgroundColor(this.pal().pillBg).borderRadius(8)
        .type(InputType.Number)
        .onChange((v: string): void => { this.posText = v; })

      Row() {
        Text('取消').fontSize(13).fontColor(this.pal().subText)
          .layoutWeight(1).textAlign(TextAlign.Center)
          .onClick((): void => { this.sub = 'none'; })
        Text('确定').fontSize(13).fontColor(this.theme.primary)
          .layoutWeight(1).textAlign(TextAlign.Center)
          .onClick((): void => { this.applyPosition(); })
      }
      .width('100%').height(44).margin({ top: 6, bottom: 8 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  detailPanel() {
    Column() {
      Row() {
        Text('歌曲详情').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .layoutWeight(1)
        Text('返回').fontSize(12).fontColor(this.theme.primary)
          .onClick((): void => { this.sub = 'none'; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column() {
          ForEach(this.detailRows(), (r: DetailRow): void => {
            Row() {
              Text(r.k).fontSize(12).fontColor(this.pal().subText).width(64)
              Text(r.v).fontSize(12).fontColor(this.theme.font)
                .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
          }, (r: DetailRow): string => r.k)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      Row().height(8)
    }
    .width('100%')
    .height('100%')
  }
}
