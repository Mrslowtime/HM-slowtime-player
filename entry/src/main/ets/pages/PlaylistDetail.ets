/**
 * 歌单详情页（在线歌单 / 排行榜共用）—— M2-E⑤。
 * 接收 router 参数：source / id / title / type('playlist'|'leaderboard') / author / playCount。
 * 自行拉取详情（kg 全量 303 首端点已打通，含 10 首兜底），
 * 展示大封面 + 歌单名 + 作者/播放量 + 收藏 + 播放全部 + 歌曲列表。
 */
import { router } from '@kit.ArkUI';
import { MusicInfo, MusicInfoMetaOnline, FavoritePlaylistInfo } from '../model/MusicTypes';
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { OnlineSource, ListIds, Quality, isDownloadEnabled } from '../config/AppConstants';
import { MusicApi } from '../core/api/MusicApi';
import { MusicListResult } from '../core/api/ApiTypes';
import { PlayController } from '../player/PlayController';
import { DownloadManager } from '../core/DownloadManager';
import { SourceConfig } from '../core/net/SourceConfig';
import { AppState } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { MusicListItem } from '../components/MusicListItem';
import { SongMenuPanel } from '../components/SongMenuPanel';
import { DownloadQualityPicker } from '../components/DownloadQualityPicker';
import { PlayerBar } from '../components/PlayerBar';
import { PlayDetail } from './PlayDetail';
import { I18n } from '../core/I18n';
import { stateEvent, StateEvents, EmptyCallback } from '../store/EventBus';
import { ControllerSnapshot } from '../player/PlayController';
import { PlaylistStore } from '../store/PlaylistStore';
import { userNotice } from '../core/UserNotice';
import { PlaylistCountCache } from '../core/PlaylistCountCache';
import { CoverImage } from '../components/CoverImage';
import { hdCoverUrl } from '../common/CoverUrl';
import { LocateButton } from '../components/LocateButton';
import { VinylDisc } from '../components/VinylDisc';
import { FavSongIndex, favKeyOf } from '../core/FavSongIndex';

/** 空快照（列表页底部播放条初始态） */
const EMPTY_SNAPSHOT: ControllerSnapshot = {
  musicInfo: null, isPlay: false, nowPlayTime: 0, maxPlayTime: 0,
  playMode: 'listLoop', statusText: '', lyricLines: [], activeLyricIndex: -1,
  lyricWords: [], activeWordIndex: -1,
  listName: '我的歌单', listCount: 0, isFavorite: false, mediaMatching: false,
};

@Entry
@Component
export struct PlaylistDetail {
  @State private songs: MusicInfo[] = [];
  @State private coverUrl: string = '';
  @State private title: string = '';
  @State private author: string = '';
  @State private playCount: string = '';
  @State private desc: string = '';
  @State private loading: boolean = false;
  /** 已加载到第几页（详情接口按页取，咪咕每页 50、酷狗每页 100） */
  @State private page: number = 1;
  /** 服务端给的总数；<=0 表示接口不分页（只能一次拿完） */
  @State private total: number = 0;
  @State private loadingMore: boolean = false;
  @State private hasMore: boolean = false;
  @State private errorMsg: string = '';
  @State private isFavorite: boolean = false;
  @State private theme: ThemeInfo = AppState.getInstance().theme;
  @State private langTick: number = 0;
  /** 播放快照（驱动底部迷你播放条实时刷新） */
  @State private snapshot: ControllerSnapshot = EMPTY_SNAPSHOT;
  /** 是否展开全屏播放详情浮层 */
  @State private showDetail: boolean = false;
  /** 列表展示开关（来自设置 list.isShow*，设置变更后实时刷新） */
  @State private showSource: boolean = true;
  @State private showAlbumName: boolean = false;
  @State private showInterval: boolean = true;
  /** 点按播放：true=点击列表项即播放该曲；false=仅选中高亮不切换播放 */
  @State private clickPlay: boolean = true;
  @State private tapIndex: number = -1;
  /** 当前播放歌曲 id：订阅切歌事件后列表高亮才会跟着音乐切换 */
  @State private currentId: string = '';
  /** 来源名展示：alias=短名（酷我）/ real=全名（酷我音乐） */
  @State private sourceNameType: string = 'alias';
  /** 歌曲「⋯」菜单索引，-1 关闭 */
  @State private menuIndex: number = -1;
  /** 单曲下载音质弹窗：-1 关闭；>=0 表示正在为第几首挑音质 */
  @State private downloadIndex: number = -1;
  @State private downloadQualities: Quality[] = [];
  /** 多选模式：长按歌曲行进入，点击其他行切换选中 */
  @State private selectMode: boolean = false;
  @State private selected: string[] = [];
  /** 批量操作菜单：对选中的多首歌执行同一操作 */
  @State private batchMenu: boolean = false;
  /** 主题变更回调：让本页 this.theme 跟随全局主题（独立页不随父刷新，需自订阅） */
  private onThemeUpdate = (): void => {
    this.theme = AppState.getInstance().resolveActiveTheme();
  };
  /** 切歌事件：只靠 tapIndex 高亮时，从播放页/队列切歌后列表不会跳转 */
  private onPlayMusicChanged = (): void => {
    const cur = AppState.getInstance().playMusicInfo;
    this.currentId = cur === null ? '' : cur.musicInfo.id;
    this.tapIndex = -1;
  };
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => {
    this.langTick = this.langTick + 1;
  };
  /** 列表展示设置变更（来源/专辑/间隔/点按播放/来源名）后刷新列表 */
  private onConfigUpdated: EmptyCallback = (): void => {
    this.reloadListDisplay();
  };

  private api: MusicApi = MusicApi.getInstance();
  private controller: PlayController = PlayController.getInstance();
  private source: string = 'kg';
  private listId: string = '';
  private type: string = 'playlist';
  private settings: SettingStore = SettingStore.getInstance();
  private listListenerBound: boolean = false;
  /** 歌曲列表滚动控制器：供浮动定位按钮跳转到正在播放的那一行 */
  private songScroller: Scroller = new Scroller();
  /** 进入本页前已存在的快照回调，离开时恢复，避免覆盖首页的订阅 */
  private prevOnSnapshot: ((s: ControllerSnapshot) => void) | null = null;

  /** 取翻译：读取 langTick 是为触发语言切换时的依赖收集与重新渲染 */
  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  aboutToAppear(): void {
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    stateEvent().on(StateEvents.THEME_UPDATED, this.onThemeUpdate);
    stateEvent().on(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
    const cur = AppState.getInstance().playMusicInfo;
    this.currentId = cur === null ? '' : cur.musicInfo.id;
    this.reloadListDisplay();
    if (!this.listListenerBound) {
      this.listListenerBound = true;
      stateEvent().on(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    }
    const p = router.getParams() as Record<string, Object> | undefined;
    if (p !== undefined) {
      this.source = (p['source'] as string) ?? 'kg';
      this.listId = (p['id'] as string) ?? '';
      this.type = (p['type'] as string) ?? 'playlist';
      this.title = (p['title'] as string) ?? '';
      this.author = (p['author'] as string) ?? '';
      this.playCount = (p['playCount'] as string) ?? '';
      // 列表页卡片上的封面直接带过来：进页面先显示，详情接口拿到更清晰的再覆盖
      const cover: string = (p['img'] as string) ?? '';
      if (cover.length > 0) {
        this.coverUrl = cover;
      }
    }
    this.isFavorite = this.readFavorite();
    // 订阅播放快照：先保存首页回调，本页卸载时恢复，避免首页迷你条失活
    this.snapshot = this.controller.getSnapshot();
    this.prevOnSnapshot = this.controller.onSnapshot;
    this.controller.onSnapshot = (s: ControllerSnapshot): void => {
      this.snapshot = s;
      if (this.prevOnSnapshot !== null) {
        this.prevOnSnapshot(s);
      }
    };
    this.loadDetail();
  }

  /**
   * 心型收藏按钮旁的旋转唱片是否显示：
   * 当前播放的歌曲属于本歌单，且播放器处于播放态（暂停时不转、不显示）。
   */
  private discVisible(): boolean {
    const cur = this.snapshot.musicInfo;
    // 暂停时仍然显示（只是停止转动），只有队列换成别的歌单/别的入口才消失
    if (cur === null || !this.isFavorite) {
      return false;
    }
    // 只认「队列来源歌单」：同一首歌可能同时存在于多个歌单，
    // 按歌曲 id 命中会让别的歌单也跟着亮；这里与「我的歌单」卡片用同一份 key，
    // 保证两处显示完全同步（从播放列表/播放历史点歌时 key 也会被反查出来）。
    const key: string = AppState.getInstance().playListKey;
    return key.length > 0 && key === ('fav:' + this.source + ':' + this.listId);
  }

  aboutToDisappear(): void {
    // 恢复首页的快照订阅，避免返回后首页迷你播放条卡住
    this.controller.onSnapshot = this.prevOnSnapshot;
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    stateEvent().off(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    stateEvent().off(StateEvents.THEME_UPDATED, this.onThemeUpdate);
    stateEvent().off(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
  }

  /** 系统返回手势：先关下载音质弹窗 → 三点菜单 → 批量菜单 → 退出多选 → 关播放详情浮层，否则交给路由回退 */
  onBackPress(): boolean {
    if (this.downloadIndex >= 0) {
      this.downloadIndex = -1;
      return true;
    }
    if (this.menuIndex >= 0) {
      this.menuIndex = -1;
      return true;
    }
    if (this.batchMenu) {
      this.batchMenu = false;
      return true;
    }
    if (this.selectMode) {
      this.exitSelect();
      return true;
    }
    if (this.showDetail) {
      this.showDetail = false;
      return true;
    }
    return false;
  }

  /** 从设置读取列表展示开关（来源/专辑/间隔）与点按播放 */
  private reloadListDisplay(): void {
    this.showSource = this.settings.getBoolean('list.isShowSource', true);
    this.showAlbumName = this.settings.getBoolean('list.isShowAlbumName', false);
    this.showInterval = this.settings.getBoolean('list.isShowInterval', true);
    this.clickPlay = this.settings.getBoolean('list.isClickPlayList', true);
    this.sourceNameType = this.settings.getString('common.sourceNameType', 'alias');
  }

  private loadDetail(): void {
    this.loadPage(1, true);
  }

  /**
   * 按页取详情。酷我/酷狗/咪咕的歌单可能上百首，接口都是分页的
   * （咪咕 pageNo/pageSize=50、酷狗 special/song pagesize=100、酷我 pn/rn），
   * 首屏先拿第一页立刻出内容，滚到底再取下一页，不必等整个歌单拉完。
   */
  private async loadPage(page: number, reset: boolean): Promise<void> {
    if (reset) {
      this.loading = true;
      this.errorMsg = '';
    } else {
      this.loadingMore = true;
    }
    let r: MusicListResult;
    if (this.type === 'leaderboard') {
      r = await this.api.leaderboardDetail(this.source as OnlineSource, this.listId, page);
    } else {
      r = await this.api.songListDetail(this.source as OnlineSource, this.listId, page);
    }
    if (r.name.length > 0) {
      this.title = r.name;
    }
    if (r.img.length > 0) {
      this.coverUrl = r.img;
    }
    if (r.desc.length > 0) {
      this.desc = r.desc;
    }
    this.total = r.total > 0 ? r.total : this.total;
    // 回填歌曲数缓存：咪咕广场接口不给数量，点进来一次之后卡片上就能显示「N 首」
    PlaylistCountCache.put(this.source, this.listId, r.total);
    if (reset) {
      this.songs = r.list;
      this.page = 1;
      this.errorMsg = r.list.length === 0 && r.error.length > 0 ? r.error : '';
      this.loading = false;
      this.syncFavIndex();
      // 点开歌单后把歌曲同步进播放列表，切到「播放列表」就能看到这个歌单；
      // 只在当前没有播放时预填，避免 clearList 重置正在播的队列索引。
      if (r.list.length > 0 && AppState.getInstance().playMusicInfo === null) {
        this.controller.syncTempList(r.list);
      }
    } else {
      const seen: Set<string> = new Set<string>();
      for (const m of this.songs) {
        seen.add(m.id);
      }
      const merged: MusicInfo[] = this.songs.slice();
      let added: number = 0;
      for (const m of r.list) {
        if (!seen.has(m.id)) {
          seen.add(m.id);
          merged.push(m);
        }
      }
      added = merged.length - this.songs.length;
      if (added > 0) {
        this.songs = merged;
        this.page = page;
        this.syncFavIndex();
      }
      this.loadingMore = false;
      this.hasMore = added > 0 && (this.total <= 0 || this.songs.length < this.total);
      return;
    }
    // 首页：还有没有下一页（total 不可靠时退回「本页是否满页」判断）
    this.hasMore = r.list.length > 0 && (this.total <= 0 ? r.list.length >= 50 : this.songs.length < this.total);
  }

  /** 滚动到底继续取下一页 */
  private loadMore(): void {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    this.loadPage(this.page + 1, false);
  }

  /** 歌单歌曲数文案（接口返回 total 后才有） */
  private songCountText(): string {
    if (this.total > 0) {
      return '共 ' + this.total.toString() + ' 首';
    }
    if (this.songs.length > 0 && !this.hasMore) {
      return '共 ' + this.songs.length.toString() + ' 首';
    }
    return '';
  }

  /** 浮动定位按钮是否显示：有歌单歌曲且有正在播放的歌 */
  private canLocate(): boolean {
    return this.songs.length > 0 && this.currentId.length > 0;
  }

  /** 滚动到正在播放的歌曲那一行（居中显示）；列表刚进入时布局未完成，留几次重试 */
  private locatePlaying(): void {
    const cur = AppState.getInstance().playMusicInfo;
    if (cur === null) {
      userNotice().info('还没有正在播放的歌曲');
      return;
    }
    this.scrollToSong(cur.musicInfo.id, 2);
  }

  private scrollToSong(id: string, retry: number): void {
    let idx: number = -1;
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      if (retry > 0) {
        setTimeout((): void => { this.scrollToSong(id, retry - 1); }, 120);
        return;
      }
      userNotice().info('正在播放的歌曲不在当前歌单');
      return;
    }
    try {
      this.songScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
    } catch (e) {
      // 列表尚未挂载：再点一次即可
    }
  }

  /** 收藏态直接从 PlaylistStore 读（独立 preferences，重启不丢） */
  private readFavorite(): boolean {
    return PlaylistStore.getInstance().isFavorite(this.source, this.listId);
  }

  /** 队列来源 key：只有收藏歌单才带（「我的歌单」靠它点亮旋转黑胶） */
  private playListKey(): string {
    return this.readFavorite() ? ('fav:' + this.source + ':' + this.listId) : '';
  }

  /** 收藏歌单：写入完整元数据，否则「我的歌单」无法渲染卡片 */
  private async toggleFavorite(): Promise<void> {
    const info: FavoritePlaylistInfo = {
      source: this.source,
      sourceListId: this.listId,
      name: this.title,
      author: this.author,
      // 仅收藏到「我的歌单」时固化高清封面地址：歌单广场等其它入口仍用原始图。
      // hdCoverUrl 只对源站确认支持的平台升 800px，其它域名原样返回，不会裂图。
      img: hdCoverUrl(this.coverUrl),
      playCount: this.playCount,
      total: this.total > 0 ? this.total : this.songs.length,
      type: this.type,
      updateTime: Date.now(),
    };
    this.isFavorite = await PlaylistStore.getInstance().toggle(info);
    const key: string = favKeyOf(this.source, this.listId);
    if (this.isFavorite) {
      this.syncFavIndex();
    } else {
      FavSongIndex.getInstance().dropPlaylist(key);
    }
  }

  /**
   * 已收藏的歌单：把当前歌曲清单写进「歌曲 → 收藏歌单」索引。
   * 之后从「播放列表 / 播放历史 / 我的收藏」点这首歌时，能反查出它属于这个歌单，
   * 「我的歌单」卡片与详情页的黑胶才会同步亮起（零额外网络请求）。
   */
  private syncFavIndex(): void {
    if (!this.isFavorite || this.songs.length === 0) {
      return;
    }
    FavSongIndex.getInstance().indexPlaylist(favKeyOf(this.source, this.listId), this.songs);
  }

  private playAll(): void {
    if (this.songs.length > 0) {
      this.controller.playMusicList(this.songs, 0, this.readFavorite(), this.playListKey());
    }
  }

  /**
   * 该歌曲实际可下载的音质 = 歌曲自带 qualitys ∩ 已启用且支持该源的音源服务，
   * 按高→低排序（与弹窗展示顺序一致）。交集为空时退回歌曲自身声明，最后兜底 128k，
   * 避免把服务根本不支持的音质列给用户（选了也会被 MusicUrlResolver 静默降级）。
   */
  private availableQualities(m: MusicInfo): Quality[] {
    const meta: MusicInfoMetaOnline = m.meta as MusicInfoMetaOnline;
    const songQs: Quality[] = [];
    if (meta.qualitys !== undefined && meta.qualitys !== null) {
      for (const q of meta.qualitys) {
        songQs.push(q.type);
      }
    }
    const supported: Set<string> = new Set<string>();
    for (const e of SourceConfig.getInstance().getEndpoints()) {
      if (!e.enabled || e.apiUrl.length === 0 || !e.sources.includes(m.source)) {
        continue;
      }
      for (const q of e.qualitys) {
        supported.add(q);
      }
    }
    const order: Quality[] = ['flac24bit', 'flac', 'wav', 'ape', '320k', '192k', '128k'];
    const out: Quality[] = [];
    for (const q of order) {
      if (songQs.includes(q) && (supported.size === 0 || supported.has(q))) {
        out.push(q);
      }
    }
    if (out.length === 0) {
      for (const q of songQs) {
        if (out.indexOf(q) < 0 && (supported.size === 0 || supported.has(q))) {
          out.push(q);
        }
      }
    }
    if (out.length === 0) {
      out.push('128k');
    }
    return out;
  }

  /** 点单曲下载：只有一种可下载音质就直接下载，多种才弹窗让用户挑 */
  private openDownload(index: number): void {
    if (index < 0 || index >= this.songs.length) {
      return;
    }
    const m: MusicInfo = this.songs[index];
    if (m.source === 'local') {
      userNotice().info('本地歌曲无需下载');
      return;
    }
    const qs: Quality[] = this.availableQualities(m);
    this.menuIndex = -1;
    this.batchMenu = false;
    if (qs.length <= 1) {
      this.downloadIndex = -1;
      this.doDownload(index, qs[0]);
      return;
    }
    this.downloadQualities = qs;
    this.downloadIndex = index;
  }

  private doDownload(index: number, quality: Quality): void {
    if (index < 0 || index >= this.songs.length) {
      return;
    }
    const m: MusicInfo = this.songs[index];
    DownloadManager.getInstance().enqueue(m, quality);
    userNotice().info('已加入下载队列：' + m.name);
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  private selectedSongs(): MusicInfo[] {
    return this.songs.filter((m: MusicInfo): boolean => this.isSelected(m.id));
  }

  private toggleSelect(id: string): void {
    if (this.isSelected(id)) {
      this.selected = this.selected.filter((x: string): boolean => x !== id);
    } else {
      this.selected = this.selected.concat([id]);
    }
  }

  private toggleSelectAll(): void {
    if (this.selected.length === this.songs.length) {
      this.selected = [];
    } else {
      this.selected = this.songs.map((m: MusicInfo): string => m.id);
    }
  }

  /** 长按进入多选：先取 id 再改状态，避免列表刷新后下标错位 */
  private enterSelect(index: number): void {
    if (index < 0 || index >= this.songs.length) {
      return;
    }
    const id: string = this.songs[index].id;
    this.selectMode = true;
    if (!this.isSelected(id)) {
      this.selected = this.selected.concat([id]);
    }
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selected = [];
    this.batchMenu = false;
  }

  private openBatchMenu(): void {
    if (this.selected.length === 0) {
      userNotice().info('先长按或点击选中歌曲');
      return;
    }
    this.batchMenu = true;
  }

  build() {
    Stack() {
      Column() {
      // 顶部栏：返回 + 标题
      Row() {
        Row() {
          Image($r('app.media.ic_back')).width(18).height(18).fillColor(this.theme.primary)
          Text(this.tx('back'))
            .fontSize(15)
            .fontColor(this.theme.primary)
        }
        .width(64)
        .onClick((): void => { router.back(); })
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.font)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        Text('')
          .width(64)
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })

      // 头部信息：封面 + 名称 + 作者/播放量/简介（先用列表页传进来的封面/标题立即显示，不等详情接口）
      Row() {
        CoverImage({
          url: this.coverUrl, theme: this.theme, radius: 10,
          placeholder: $r('app.media.ic_music'), placeholderSize: 40,
        })
          .width(110).height(110)
        Column() {
          Text(this.title)
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.author.length > 0) {
            Text('by ' + this.author)
              .fontSize(12).fontColor(buildPalette(this.theme).subText).margin({ top: 6 }).width('100%')
          }
          if (this.songCountText().length > 0) {
            Text(this.songCountText())
              .fontSize(12).fontColor(buildPalette(this.theme).subText).margin({ top: 4 }).width('100%')
          }
          if (this.playCount.length > 0 && this.playCount !== '0') {
            Text(this.playCount + ' ' + this.tx('play_count_unit'))
              .fontSize(12).fontColor(buildPalette(this.theme).subText).margin({ top: 4 }).width('100%')
          }
          if (this.desc.length > 0) {
            Text(this.desc)
              .fontSize(11).fontColor(buildPalette(this.theme).subText).margin({ top: 6 }).width('100%')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 14 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })

      // 操作栏：收藏 / 播放全部（轻绿文字按钮，无背景无边框）
      // 「下载全部」已按用户要求取消，下载改为每首歌右侧的单曲按钮
      Row() {
        Button() {
          Row() {
            // 本歌单有歌在播：心型左侧转一张黑胶（带唱臂，和「我的歌单」卡片同款）
            if (this.discVisible()) {
              VinylDisc({ diameter: 22, playing: this.snapshot.isPlay })
                .margin({ right: 5 })
            }
            Image(this.isFavorite ? $r('app.media.ic_heart_fill') : $r('app.media.ic_heart'))
              .width(16).height(16).fillColor(this.theme.primary).margin({ right: 4 })
            Text(this.isFavorite ? this.tx('collected') : this.tx('collect')).fontSize(14)
              .fontColor(this.theme.primary)
          }
        }
        .type(ButtonType.Normal).height(40).backgroundColor(Color.Transparent).padding({ left: 4, right: 4 }).stateEffect(false)
        .onClick((): void => { this.toggleFavorite(); })

        Button() {
          Row() {
            Text(this.tx('play_all')).fontSize(14).fontColor(this.theme.primary)
          }
        }
        .type(ButtonType.Normal).height(40).backgroundColor(Color.Transparent).padding({ left: 4, right: 4 }).stateEffect(false)
        .onClick((): void => { this.playAll(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })
      .justifyContent(FlexAlign.SpaceAround)

      // 多选工具条：已选数量 / 全选 / 更多（批量菜单）/ 取消
      if (this.selectMode) {
        Row() {
          Text('已选 ' + this.selected.length.toString() + ' 首')
            .fontSize(12).fontColor(this.theme.primary)
          Blank()
          Text('全选')
            .fontSize(12).fontColor(buildPalette(this.theme).subText)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick((): void => { this.toggleSelectAll(); })
          Text('更多')
            .fontSize(12)
            .fontColor(this.selected.length > 0 ? this.theme.primary : buildPalette(this.theme).subText)
            .border({
              width: 1,
              color: this.selected.length > 0 ? this.theme.primary : buildPalette(this.theme).pillBg,
            })
            .borderRadius(12)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ left: 6 })
            .onClick((): void => { this.openBatchMenu(); })
          Text('取消')
            .fontSize(12).fontColor(buildPalette(this.theme).subText)
            .padding({ left: 8, right: 0, top: 4, bottom: 4 })
            .margin({ left: 4 })
            .onClick((): void => { this.exitSelect(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 2, bottom: 6 })
      }

      if (this.loading) {
        Row() {
          LoadingProgress().width(22).height(22).color(this.theme.primary)
          Text('  ' + this.tx('loading')).fontSize(13).fontColor(buildPalette(this.theme).subText)
        }
        .width('100%')
        .padding(20)
        .justifyContent(FlexAlign.Center)
      } else if (this.songs.length === 0 && this.errorMsg.length > 0) {
        Column() {
          Image($r('app.media.ic_music')).width(44).height(44).fillColor(buildPalette(this.theme).divider).margin({ top: 40 })
          Text(this.errorMsg)
            .fontSize(13).fontColor('#B4694A').margin({ top: 10 })
            .width('80%').textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 歌曲列表
        List({ scroller: this.songScroller }) {
          ForEach(this.songs, (m: MusicInfo, idx: number): void => {
            ListItem() {
              MusicListItem({
                music: m,
                index: idx,
                isActive: (this.currentId.length > 0 && this.currentId === m.id) || this.tapIndex === idx,
                theme: this.theme,
                showSource: this.showSource,
                showAlbumName: this.showAlbumName,
                showInterval: this.showInterval,
                sourceNameType: this.sourceNameType,
                selecting: this.selectMode,
                checked: this.isSelected(m.id),
                onItemClick: (i: number): void => {
                  // 单击：多选时切换选中；普通状态下不播放（播放改为双击），也不弹任何提示
                  if (this.selectMode) {
                    this.toggleSelect(this.songs[i].id);
                  }
                },
                onItemDoubleClick: (i: number): void => {
                  if (this.selectMode) {
                    // 双击的第一下已经切换过选中，这里不再重复切换
                    return;
                  }
                  if (this.clickPlay) {
                    this.tapIndex = -1;
                    this.controller.playMusicList(this.songs, i, this.readFavorite(), this.playListKey());
                  } else {
                    this.tapIndex = i;
                  }
                },
                onItemLongPress: (i: number): void => { this.enterSelect(i); },
                showDownload: true,
                onDownloadClick: (i: number): void => { this.openDownload(i); },
                onMoreClick: (i: number): void => {
                  // 多选时 ⋮ 作用于全部选中歌曲：该行未选中先补选
                  if (this.selectMode) {
                    if (i >= 0 && i < this.songs.length && !this.isSelected(this.songs[i].id)) {
                      this.selected = this.selected.concat([this.songs[i].id]);
                    }
                    this.openBatchMenu();
                    return;
                  }
                  this.menuIndex = i;
                },
              })
            }
          }, (m: MusicInfo): string => m.id + '_' + this.sourceNameType)
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: buildPalette(this.theme).divider })
        .onReachEnd((): void => { this.loadMore(); })

        // 列表底部：翻页转圈 / 到底提示（歌单上百首时靠这个继续加载）
        Row() {
          if (this.loadingMore) {
            LoadingProgress().width(16).height(16).color(this.theme.primary)
            Text('  ' + this.tx('loading')).fontSize(12)
              .fontColor(buildPalette(this.theme).subText)
          } else if (!this.hasMore && this.songs.length > 0) {
            Text('- ' + this.songs.length.toString() + ' 首 -').fontSize(12)
              .fontColor(buildPalette(this.theme).subText)
          }
        }
        .width('100%').height(36)
        .justifyContent(FlexAlign.Center)
      }

      // 底部迷你播放条（始终显示，与首页一致）
      PlayerBar({
        snapshot: this.snapshot,
        theme: this.theme,
        onBarClick: (): void => { this.showDetail = true; },
        onTogglePlay: (): void => { this.controller.togglePlay(); },
        onPrev: (): void => { this.controller.playPrev(); },
        onNext: (): void => { this.controller.playNext(false); },
      })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.theme.mainBackground)

      // 浮动「定位到正在播放的歌曲」按钮：抬到迷你播放条（62vp）上方，
      // 外层 Column 用 hitTestBehavior(None)，空白区域不拦截列表滑动与点按。
      if (this.canLocate()) {
        Column() {
          LocateButton({
            theme: this.theme,
            onLocate: (): void => { this.locatePlaying(); },
          })
        }
        .width('100%')
        .height('100%')
        .padding({ right: 16, bottom: 76 })
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .hitTestBehavior(HitTestMode.None)
      }

      // 三点菜单必须挂在页面最外层 Stack 下，不能放进上面的 Column：
      // 一旦成为 Column 的普通子项，它会和顶部栏 / 列表 / 播放条一起排版，
      // 遮罩只能盖住列表区，卡片 78% 高度也按剩余空间算，长菜单底部会被屏幕裁掉。
      if (this.menuIndex >= 0 && this.menuIndex < this.songs.length) {
        SongMenuPanel({
          music: this.songs[this.menuIndex],
          listId: ListIds.TEMP,
          index: this.menuIndex,
          allowRemove: false,
          theme: this.theme,
          onClose: (): void => { this.menuIndex = -1; },
        })
      }

      // 批量菜单：一次对选中的多首歌执行同一操作（歌单详情不能真正移除，故不给「移除」）
      if (this.batchMenu) {
        SongMenuPanel({
          musics: this.selectedSongs(),
          listId: ListIds.TEMP,
          index: 0,
          allowRemove: false,
          theme: this.theme,
          onClose: (): void => { this.batchMenu = false; },
        })
      }

      // 单曲下载音质弹窗（挂最外层 Stack，遮罩覆盖整页含底部播放条）
      // 下载功能总开关关闭时不渲染（源码保留，改 download.enable 即可恢复）
      if (isDownloadEnabled() && this.downloadIndex >= 0 && this.downloadIndex < this.songs.length) {
        DownloadQualityPicker({
          qualities: this.downloadQualities,
          theme: this.theme,
          onPick: (q: Quality): void => {
            const i: number = this.downloadIndex;
            this.downloadIndex = -1;
            this.doDownload(i, q);
          },
          onClose: (): void => { this.downloadIndex = -1; },
        })
      }

      // 全屏播放详情浮层
      if (this.showDetail) {
        PlayDetail({
          showDetail: this.showDetail,
          snapshot: this.snapshot,
          theme: this.theme,
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
