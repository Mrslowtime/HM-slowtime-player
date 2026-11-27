/**
 * 在线歌单 / 排行榜 / 搜索 —— M2-D 已接入真实音源数据。
 * 数据来自 core/api/MusicApi（kw/kg/tx/mg 静态 HTTP 独立实现），
 * 点击歌曲走 PlayController.playMusicList（播放列表 + 队列/循环/锁屏队列）。
 * 未实现的源（wy 加密栈、tx/mg 搜索签名）会给出明确提示而非空白。
 */
import { router } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { MusicInfo, ListInfoItem, BoardItem, TagInfoItem, SortInfo } from '../../model/MusicTypes';
import { ThemeInfo, buildPalette } from '../../theme/Themes';
import { sourceDisplay, OnlineSource, LIST_LOAD_LIMIT, ListIds } from '../../config/AppConstants';
import { MusicApi } from '../../core/api/MusicApi';
import { MultiSearchResult, MultiSonglistResult } from '../../core/api/MusicApi';
import { SearchResult, SonglistResult, TagResult } from '../../core/api/ApiTypes';
import { MusicSource } from '../../core/MusicSource';
import { PlayController } from '../../player/PlayController';
import { MusicListItem } from '../../components/MusicListItem';
import { SourceDropdown } from '../../components/SourceDropdown';
import { TagDrawer } from '../../components/TagDrawer';
import { SongMenuPanel } from '../../components/SongMenuPanel';
import { I18n } from '../../core/I18n';
import { stateEvent, StateEvents, EmptyCallback } from '../../store/EventBus';
import { SettingStore } from '../../store/SettingStore';
import { AppState, HeaderAction } from '../../store/AppState';
import { userNotice } from '../../core/UserNotice';
import { PlaylistCountCache } from '../../core/PlaylistCountCache';
import { CoverCache } from '../../core/ImageCache';
import { SimpleDataSource } from '../../core/SimpleDataSource';
import { CoverImage } from '../../components/CoverImage';
import { columnCount } from '../../config/ScreenMetrics';

const DEFAULT_THEME: ThemeInfo = {
  id: 'green', name: '绿意盎然', isDark: false,
  primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
};

/**
 * 歌单网格每次上屏的卡片数（3 列 × 5 行）。
 * 咪咕歌单广场一个网络页返回 125 个歌单、封面单张 500KB+，整页上屏会同时发上百个图片请求，
 * 表现就是「打开咪咕歌单像卡死」。分批上屏后首屏只有 12 张图，滑动时再逐步补。
 */
const CARD_BATCH: number = 15;

/**
 * 搜索页的「全部」伪音源：一次把五家（酷我/酷狗/QQ/网易/咪咕）都搜一遍再交错合并。
 * 不是真音源，只是 UI 上的一个选项值；发请求时走 MusicApi.searchAll（串行，不并发）。
 */
const ALL_SOURCE: string = 'all';

/** 通用空状态提示 */
@Builder
function EmptyHint(msg: string, theme: ThemeInfo) {
  Column() {
    Image($r('app.media.ic_music')).width(44).height(44).fillColor(buildPalette(theme).divider)
    Text(msg).fontSize(13).fontColor(buildPalette(theme).subText).margin({ top: 10 })
  }
  .width('100%')
  .layoutWeight(1)
  .justifyContent(FlexAlign.Center)
}

// ============================================================ 在线歌单
@Component
export struct SonglistView {
  @State private source: OnlineSource = 'kw';
  @State private sortId: string = 'hot';
  @State private tagId: string = '';
  @State private tags: TagInfoItem[] = [{ id: '', name: '推荐' }];
  /**
   * 已上屏的卡片。普通成员（不是 @State）：
   * 每次翻页都整体赋值 @State 会让整页 build 重跑，滑到几百张时每翻一页都顿一下。
   * 现在只有「首次有数据 / 清空」才动 hasCards，其余全靠 LazyForEach 数据源增量通知。
   */
  private cardsAll: ListInfoItem[] = [];
  @State private hasCards: boolean = false;
  @State private loading: boolean = false;
  /** 已加载到第几页（首页为 1），滚动到底时 +1 继续取 */
  @State private page: number = 1;
  /** 正在加载下一页（底部显示「加载中」） */
  @State private loadingMore: boolean = false;
  /** 后面还有没有更多；某页返回的新增条目为 0 即为到底 */
  @State private hasMore: boolean = true;
  @State private errorMsg: string = '';
  @State private langTick: number = 0;
  /** 右上角平台下拉面板是否展开 */
  @State private showSourceMenu: boolean = false;
  /** 左侧歌单分类抽屉是否展开 */
  @State private showTagDrawer: boolean = false;
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  /** 当前是否为激活标签：歌单页无头部操作，激活时清空全局头部操作区 */
  @Prop @Watch('onActiveChanged') active: boolean = false;

  private api: MusicApi = MusicApi.getInstance();
  /** 列表请求序号：切平台/分类/排序后，旧请求的返回结果一律丢弃，避免串页 */
  private reqSeq: number = 0;
  /**
   * 已取回但还没显示的歌单（网络页余量）。
   * 咪咕一次给 125 个歌单、封面单张 500KB+，若整页塞进网格会同时发起上百个图片请求，
   * 界面直接卡住。这里改成「网络页整页取回 → 每次只上屏 12 个」，
   * 滑到底再从余量里放下一批，余量放完才发下一个网络请求。
   */
  private buffer: ListInfoItem[] = [];
  /** buffer 属于第几个网络页 */
  private netPage: number = 1;
  /** 网络侧是否还有下一页 */
  private netMore: boolean = true;
  /** 懒加载数据源：每项是「一行 3 张卡片」，只构建可视区附近的行 */
  private rowsSource: SimpleDataSource<ListInfoItem[]> = new SimpleDataSource<ListInfoItem[]>();
  /** 列表视口高度（vp），用于判断首屏是否还没填满（不进 @State：只是判据，不该触发重绘） */
  private viewportH: number = 0;
  /** 列表视口宽度（vp），用于按实际列宽估算行高 */
  private viewportW: number = 0;
  /** 当前每行卡片数：手机 3 列，平板按视口宽度扩到 4~5 列（@State 才会触发行重建） */
  @State private gridCols: number = 3;
  /** 视口填充检查是否已排队（避免重复 setTimeout） */
  private fillScheduled: boolean = false;
  /** 视口填充延迟重试次数（首屏请求未回时轮询，超过上限放弃，避免死循环） */
  private fillRetry: number = 0;
  /** 歌曲来源显示方式（简称/全名），切换设置后即时刷新平台名 */
  @State private sourceNameType: string = 'alias';
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => { this.langTick = this.langTick + 1; };
  /** 来源名展示设置变更后刷新平台名 */
  private onConfigUpdated: EmptyCallback = (): void => {
    this.sourceNameType = SettingStore.getInstance().getString('common.sourceNameType', 'alias');
  };

  async aboutToAppear(): Promise<void> {
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    this.sourceNameType = SettingStore.getInstance().getString('common.sourceNameType', 'alias');
    stateEvent().on(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    // 标签和列表互不依赖（默认分类 id 为空即可取推荐歌单），并行发请求，
    // 不要再 await 标签回来才去拉列表——那样首屏白等一个 RTT。
    this.loadTags();
    this.loadList();
    this.syncHeader();
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    stateEvent().off(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
  }

  /** 歌单页没有需要放到全局头部的操作 */
  private syncHeader(): void {
    if (!this.active) {
      return;
    }
    AppState.getInstance().setHeaderActions([]);
  }

  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  /** 分类标签（失败保留当前标签，不阻塞列表） */
  private async loadTags(): Promise<void> {
    const t: TagResult = await this.api.songListTags(this.source);
    if (t.tags.length > 0) {
      this.tags = t.tags;
    }
  }

  private async loadList(): Promise<void> {
    this.reqSeq++;
    const seq: number = this.reqSeq;
    this.loading = true;
    this.loadingMore = false;
    this.page = 1;
    this.netPage = 1;
    this.netMore = true;
    this.buffer = [];
    this.errorMsg = '';
    const r: SonglistResult = await this.api.songList(this.source, this.tagId, this.sortId, 1, LIST_LOAD_LIMIT);
    if (seq !== this.reqSeq) {
      return;
    }
    // 只先上屏一小批，剩下的进 buffer 等滚动加载（见 buffer 注释）
    const shown: ListInfoItem[] = r.list.length > CARD_BATCH ? r.list.slice(0, CARD_BATCH) : r.list;
    this.buffer = r.list.length > CARD_BATCH ? r.list.slice(CARD_BATCH) : [];
    this.setCards(shown);
    this.netMore = r.list.length > 0;
    this.hasMore = this.buffer.length > 0 || this.netMore;
    this.errorMsg = r.list.length === 0 && r.error.length > 0 ? r.error : '';
    this.loading = false;
    this.prefetchNext();
    // 首屏只有 CARD_BATCH 张时可能填不满（此时列表不可滚动、onReachEnd 不触发）→ 主动补齐
    this.fillViewport();
  }

  /**
   * 滚动到底继续加载：先从本页余量放一批（零网络开销），余量空了才翻下一页。
   * 各平台分页参数不同（酷我 pn/rn、酷狗 p、QQ From/page、咪咕 pageNo、网易 offset），
   * 但都在 source api 里统一成 page/limit。到底判定用「本页新增条目为 0」：
   * 部分平台 total 不可靠（咪咕按栏目聚合、酷狗不返回总数），只有真翻不动了才停。
   */
  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    if (this.buffer.length > 0) {
      const take: ListInfoItem[] = this.buffer.length > CARD_BATCH
        ? this.buffer.slice(0, CARD_BATCH) : this.buffer;
      this.buffer = this.buffer.length > CARD_BATCH ? this.buffer.slice(CARD_BATCH) : [];
      this.appendCards(take);
      this.hasMore = this.buffer.length > 0 || this.netMore;
      this.prefetchNext();
      this.fillViewport();
      return;
    }
    if (!this.netMore) {
      this.hasMore = false;
      return;
    }
    const seq: number = this.reqSeq;
    const next: number = this.netPage + 1;
    this.loadingMore = true;
    const r: SonglistResult = await this.api.songList(this.source, this.tagId, this.sortId, next, LIST_LOAD_LIMIT);
    if (seq !== this.reqSeq) {
      return;
    }
    const seen: Set<string> = new Set<string>();
    for (const c of this.cardsAll) {
      seen.add(c.id);
    }
    const fresh: ListInfoItem[] = [];
    for (const c of r.list) {
      if (!seen.has(c.id)) {
        seen.add(c.id);
        fresh.push(c);
      }
    }
    if (fresh.length > 0) {
      this.netPage = next;
    }
    const take: ListInfoItem[] = fresh.length > CARD_BATCH ? fresh.slice(0, CARD_BATCH) : fresh;
    this.buffer = fresh.length > CARD_BATCH ? fresh.slice(CARD_BATCH) : [];
    if (take.length > 0) {
      this.appendCards(take);
    }
    this.netMore = fresh.length > 0;
    this.hasMore = this.buffer.length > 0 || this.netMore;
    this.loadingMore = false;
    this.prefetchNext();
    // 新一页仍填不满一屏时继续补（onReachEnd 在不可滚动时永远不会触发）
    this.fillViewport();
  }

  /**
   * 预取下一批封面。
   * 用户下拉速度往往快过图片加载，等卡片上屏才去取图就是「滚下去一片空白」；
   * 这里在本批上屏时就把缓冲区里下一批的封面先下好（走 CoverCache 的并发队列），
   * 真正滑到那一屏时直接命中本地缓存，不再等网络。
   */
  private prefetchNext(): void {
    const n: number = this.buffer.length > CARD_BATCH ? CARD_BATCH : this.buffer.length;
    if (n === 0) {
      return;
    }
    const urls: string[] = [];
    for (let i = 0; i < n; i++) {
      // 与卡片显示用同一个高清地址，否则预取到的图和上屏请求的图不是同一份
      urls.push(this.buffer[i].img);
    }
    CoverCache.getInstance().prefetch(urls);
  }

  /** 整体重置网格（首次加载 / 切平台分类排序）：只有这里全量 reload */
  private setCards(next: ListInfoItem[]): void {
    this.cardsAll = next;
    this.rowsSource.setAll(this.cardRows());
    const has: boolean = next.length > 0;
    if (has !== this.hasCards) {
      this.hasCards = has;
    }
  }

  /**
   * 增量追加卡片：以「行」为单位上屏，只通知新增的行。
   * 原来每批都 setAll() 全量 reload，LazyForEach 会把已上屏的行全部销毁重建，
   * 越往后滑每翻一页越卡；现在旧行原地不动。
   */
  private appendCards(add: ListInfoItem[]): void {
    if (add.length === 0) {
      return;
    }
    const startLen: number = this.cardsAll.length;
    if (startLen === 0) {
      this.setCards(add.slice());
      return;
    }
    const merged: ListInfoItem[] = this.cardsAll.slice();
    for (const c of add) {
      merged.push(c);
    }
    this.cardsAll = merged;
    // 已经完整成行的行数
    const cols: number = this.gridCols;
    const doneRows: number = Math.floor(startLen / cols);
    let base: number = doneRows;
    if (startLen % cols !== 0) {
      // 尾行没满 cols 张：先原地补这一行，后面的整行再追加
      this.rowsSource.setAt(doneRows, merged.slice(doneRows * cols, doneRows * cols + cols));
      base = doneRows + 1;
    }
    const rest: ListInfoItem[][] = [];
    for (let i: number = base * cols; i < merged.length; i += cols) {
      rest.push(merged.slice(i, i + cols));
    }
    this.rowsSource.append(rest);
    if (!this.hasCards) {
      this.hasCards = true;
    }
  }

  /**
   * 视口填充：内容还不够一屏时主动续加载。
   * 只靠 onReachEnd 的话，一页 15 张填不满屏幕就再也滑不动（没有内容可滑 → 不触发到底）。
   * 这里按估算行高判断，必要时排队再加载一批，直到填满或确实没有更多。
   * 注意：首屏请求还在路上时不能直接 return，否则这一次检查就永久丢了（等请求回来没人再检查），
   * 所以改为延迟重试。
   */
  private fillViewport(): void {
    if (this.fillScheduled) {
      return;
    }
    if (this.viewportH <= 0) {
      return;
    }
    if (this.loading || this.loadingMore) {
      if (this.fillRetry < 30) {
        this.fillRetry++;
        this.scheduleFill(300);
      }
      return;
    }
    this.fillRetry = 0;
    if (!this.hasMore) {
      return;
    }
    const rowH: number = this.rowHeightEstimate();
    if (this.rowsSource.totalCount() * rowH >= this.viewportH + rowH) {
      return;
    }
    this.scheduleFill(50);
  }

  private scheduleFill(delayMs: number): void {
    this.fillScheduled = true;
    setTimeout((): void => {
      this.fillScheduled = false;
      this.loadMore();
      this.fillViewport();
    }, delayMs);
  }

  /** 单行高度估算：列宽（封面正方形）+ 两行标题 + 间距 */
  private rowHeightEstimate(): number {
    const w: number = this.viewportW > 0 ? this.viewportW : 360;
    const cell: number = (w - 24) / this.gridCols;
    return cell + 48;
  }

  /** 按当前列数切行，供封面网格渲染（手机 3 列，平板更宽） */
  private cardRows(): ListInfoItem[][] {
    const rows: ListInfoItem[][] = [];
    const cols: number = this.gridCols;
    for (let i: number = 0; i < this.cardsAll.length; i += cols) {
      rows.push(this.cardsAll.slice(i, i + cols));
    }
    return rows;
  }

  private openDetail(item: ListInfoItem): void {
    router.pushUrl({
      url: 'pages/PlaylistDetail',
      params: {
        source: this.source,
        id: item.id,
        title: item.name,
        type: 'playlist',
        author: item.author,
        playCount: item.play_count,
        // 卡片上的封面直接带给详情页，进页面立刻有图（咪咕详情接口不返回歌单封面）
        img: item.img,
      },
    });
  }

  private async changeSource(s: OnlineSource): Promise<void> {
    this.source = s;
    this.tagId = '';
    this.tags = [{ id: '', name: this.tx('recommend') }];
    this.loadTags();
    this.loadList();
  }

  /**
   * 卡片上的歌曲数：优先用接口给的 total；咪咕广场接口不带数量，
   * 就用「点进过该歌单后回填」的缓存（见 PlaylistCountCache），都没有则不显示。
   */
  private countText(c: ListInfoItem): string {
    const n: number = c.total > 0 ? c.total : PlaylistCountCache.get(this.source, c.id);
    return n > 0 ? n.toString() + ' 首' : '';
  }

  /** 工具行「默认」位置显示当前分类名；未选分类时显示「默认」 */
  private currentTagName(): string {
    if (this.tagId === '') {
      return '默认';
    }
    for (const t of this.tags) {
      if (t.id === this.tagId) {
        return t.name;
      }
    }
    return '默认';
  }

  /** 切模块：激活时清空头部操作，切走时关掉平台下拉与分类抽屉（浮窗不该留在别的页面上） */
  private onActiveChanged(): void {
    if (this.active) {
      this.syncHeader();
      return;
    }
    this.showSourceMenu = false;
    this.showTagDrawer = false;
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        // 工具行（设计稿）：左侧「最新 / 最热」排序，右侧「默认 / 打开 / 当前平台名」。
        // 歌单分类标签收进左侧抽屉，平台不再横排，只显示当前项并以下拉切换。
        Row() {
          Text(this.tx('sort_new'))
            .fontSize(13)
            .fontColor(this.sortId === 'new' ? this.theme.primary : buildPalette(this.theme).subText)
            .margin({ right: 18 })
            .onClick((): void => { this.sortId = 'new'; this.loadList(); })
          Text(this.tx('sort_hot'))
            .fontSize(13)
            .fontColor(this.sortId === 'hot' ? this.theme.primary : buildPalette(this.theme).subText)
            .margin({ right: 18 })
            .onClick((): void => { this.sortId = 'hot'; this.loadList(); })
          Blank()
          Text(this.currentTagName())
            .fontSize(13).fontColor(buildPalette(this.theme).subText)
            .margin({ right: 14 })
            .onClick((): void => { this.showTagDrawer = true; })
          Text(sourceDisplay(this.source, this.sourceNameType))
            .fontSize(13).fontColor(this.theme.primary)
            .onClick((): void => { this.showSourceMenu = true; })
        }
        .width('100%').height(42).padding({ left: 16, right: 16 })

        if (this.loading) {
          Row() {
            LoadingProgress().width(20).height(20).color(this.theme.primary)
            Text('  ' + this.tx('loading')).fontSize(12).fontColor(buildPalette(this.theme).subText)
          }.width('100%').padding(12).justifyContent(FlexAlign.Center)
        }

        if (this.hasCards) {
          // 方形封面网格（手机 3 列，平板 4~5 列）
          // 用 List + LazyForEach 只构建可视区附近的卡片行 —— 原来 Scroll + Column 会把
          // 已上屏的每一行都常驻，滑到几十张后每次状态变化整树重建，越滑越卡。
          List() {
            LazyForEach(this.rowsSource, (row: ListInfoItem[], ri: number): void => {
              ListItem() {
                Row() {
                  ForEach(row, (c: ListInfoItem): void => {
                    Column() {
                      // 走 CoverCache：本地命中直接出图，未命中先占位再自动补图
                      CoverImage({ url: c.img, theme: this.theme, radius: 4, placeholderSize: 40 })
                        .width('100%').aspectRatio(1)
                      Text(c.name)
                        .fontSize(12).fontColor(this.theme.font)
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%').margin({ top: 6 })
                      if (this.countText(c).length > 0) {
                        Text(this.countText(c))
                          .fontSize(10).fontColor(buildPalette(this.theme).subText)
                          .maxLines(1).width('100%').margin({ top: 1 })
                      }
                    }
                    .layoutWeight(1)
                    .padding({ left: 4, right: 4 })
                    .margin({ bottom: 14 })
                    .onClick((): void => { this.openDetail(c); })
                  }, (c: ListInfoItem): string => c.id)
                }
                .width('100%')
                .padding({ left: 12, right: 12 })
                .alignItems(VerticalAlign.Top)
              }
            }, (row: ListInfoItem[]): string => row.map((c: ListInfoItem): string => c.id).join('_'))
          }
          .layoutWeight(1).width('100%').scrollBar(BarState.Off)
          .cachedCount(2)
          .onReachEnd((): void => { this.loadMore(); })
          .onAreaChange((_o: Area, a: Area): void => {
            // 首屏内容不足一屏时 onReachEnd 永远不会触发 → 主动续加载，解决「滑不下去」
            this.viewportH = Number(a.height);
            this.viewportW = Number(a.width);
            // 平板 / 分屏导致列数变化时，把已加载的卡片按新列数重新切行
            const c: number = columnCount(this.viewportW > 0 ? this.viewportW : 360, 170, 3, 5);
            if (c !== this.gridCols) {
              this.gridCols = c;
              this.rowsSource.setAll(this.cardRows());
            }
            this.fillViewport();
          })

          // 翻页状态放在 List 外面：它绑的是 @State，留在 LazyForEach 里会让整行跟着重建
          if (this.loadingMore || !this.hasMore) {
            Row() {
              if (this.loadingMore) {
                LoadingProgress().width(16).height(16).color(this.theme.primary)
                Text('  ' + this.tx('loading')).fontSize(12)
                  .fontColor(buildPalette(this.theme).subText)
              } else {
                Text('- 没有更多歌单了 -').fontSize(12)
                  .fontColor(buildPalette(this.theme).subText)
              }
            }
            .width('100%').height(34)
            .justifyContent(FlexAlign.Center)
          }
        } else if (!this.loading) {
          EmptyHint(this.errorMsg.length > 0 ? this.errorMsg : this.tx('empty_songlist'), this.theme)
        }
      }
      .width('100%').height('100%')

      // 左侧歌单分类抽屉：点「默认 / 打开」滑出，胶囊按分组铺排
      if (this.showTagDrawer) {
        Row() {
          Column() {
            TagDrawer({
              theme: this.theme,
              tags: this.tags,
              currentId: this.tagId,
              onPick: (id: string): void => { this.tagId = id; this.loadList(); },
              onClose: (): void => { this.showTagDrawer = false; },
            })
          }
          .width('78%').height('100%')
          Column()
            .width('22%').height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => { this.showTagDrawer = false; })
        }
        .width('100%').height('100%')
      }

      // 右上角平台下拉：点当前平台名展开，可切换平台 / 长按调整顺序
      if (this.showSourceMenu) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#01000000')
          .onClick((): void => { this.showSourceMenu = false; })
        Column() {
          SourceDropdown({
            theme: this.theme,
            selected: this.source,
            sourceNameType: this.sourceNameType,
            onSelect: (s: OnlineSource): void => { this.changeSource(s); },
            onClose: (): void => { this.showSourceMenu = false; },
          })
        }
        .margin({ top: 6, right: 12 })
      }
    }
    .width('100%').height('100%').backgroundColor(this.theme.mainBackground)
  }
}

// ============================================================ 排行榜
@Component
export struct LeaderboardView {
  @State @Watch('syncHeader') private source: OnlineSource = 'kg';
  /** 右上角平台下拉面板是否展开 */
  @State private showSourceMenu: boolean = false;
  @State private boards: BoardItem[] = [];
  @State private loading: boolean = false;
  @State private errorMsg: string = '';
  @State private langTick: number = 0;
  /** 歌曲来源显示方式（简称/全名），切换设置后即时刷新头部平台名 */
  @State private sourceNameType: string = 'alias';
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  /** 当前是否为激活标签：激活时把「当前来源」注册到全局头部 ≡ 左侧 */
  @Prop @Watch('onActiveChanged') active: boolean = false;

  private api: MusicApi = MusicApi.getInstance();
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => { this.langTick = this.langTick + 1; };
  /** 来源名展示设置变更后刷新平台名与头部 */
  private onConfigUpdated: EmptyCallback = (): void => {
    this.sourceNameType = SettingStore.getInstance().getString('common.sourceNameType', 'alias');
    this.syncHeader();
  };

  aboutToAppear(): void {
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    this.sourceNameType = SettingStore.getInstance().getString('common.sourceNameType', 'alias');
    stateEvent().on(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    this.refreshBoards();
    this.syncHeader();
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    stateEvent().off(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
  }

  /** 排行榜：把当前来源（如「酷我音乐」）放到全局头部 ≡ 左侧，字号保持 12 */
  private syncHeader(): void {
    if (!this.active) {
      return;
    }
    const acts: HeaderAction[] = [{
      key: 'source',
      text: sourceDisplay(this.source, this.sourceNameType),
      fontSize: 12,
      textColor: this.theme.primary,
      // 点右上角当前平台名 → 弹出平台下拉（纯选择，无编辑态）
      onClick: (): void => { this.showSourceMenu = true; },
    }];
    AppState.getInstance().setHeaderActions(acts);
  }

  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  private refreshBoards(): void {
    this.boards = this.api.leaderboardCategories(this.source);
    this.errorMsg = '';
  }

  private openBoard(b: BoardItem): void {
    router.pushUrl({
      url: 'pages/PlaylistDetail',
      params: {
        source: this.source,
        id: b.bangid,
        title: b.name,
        type: 'leaderboard',
        img: b.img ?? '',
      },
    });
  }

  /** 切模块：激活时注册头部「当前来源」，切走时关掉平台下拉 */
  private onActiveChanged(): void {
    if (this.active) {
      this.syncHeader();
      return;
    }
    this.showSourceMenu = false;
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        // 设计稿：平台不再横排，右上角头部只显示当前平台名，点击弹出下拉
        if (this.loading) {
          Row() {
            LoadingProgress().width(20).height(20).color(this.theme.primary)
            Text('  ' + this.tx('loading')).fontSize(12).fontColor(buildPalette(this.theme).subText)
          }.width('100%').padding(12).justifyContent(FlexAlign.Center)
        }
        if (this.errorMsg.length > 0) {
          Text(this.errorMsg).fontSize(12).fontColor('#B4694A')
            .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }

        List() {
          ForEach(this.boards, (b: BoardItem, idx: number): void => {
            ListItem() {
              Row() {
                // 榜单封面（静态内置 URL，走 CoverImage 磁盘缓存，不额外打接口）
                CoverImage({ url: b.img ?? '', theme: this.theme, radius: 5, placeholderSize: 42 })
                  .width(42).height(42)
                Text((idx + 1).toString()).fontSize(13).fontColor(buildPalette(this.theme).subText)
                  .width(26).textAlign(TextAlign.Center).margin({ left: 10 })
                Text(b.name).fontSize(14).fontColor(this.theme.font).layoutWeight(1).margin({ left: 4 })
                Image($r('app.media.ic_chevron_right')).width(16).height(16).fillColor(buildPalette(this.theme).subText)
              }
              .width('100%').height(60).padding({ left: 16, right: 16 })
              .onClick((): void => { this.openBoard(b); })
            }
          }, (b: BoardItem): string => b.id)
        }
        .layoutWeight(1).width('100%')
      }
      .width('100%').height('100%')

      if (this.showSourceMenu) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('#01000000')
          .onClick((): void => { this.showSourceMenu = false; })
        Column() {
          SourceDropdown({
            theme: this.theme,
            selected: this.source,
            sourceNameType: this.sourceNameType,
            onSelect: (s: OnlineSource): void => {
              this.source = s;
              this.refreshBoards();
              // 立即把新平台名注册到全局头部（@Watch 是异步时机，这里显式再刷一次保证「实时」）
              this.syncHeader();
            },
            onClose: (): void => { this.showSourceMenu = false; },
          })
        }
        .margin({ top: 6, right: 12 })
      }
    }
    .width('100%').height('100%').backgroundColor(this.theme.mainBackground)
  }
}

// ============================================================ 搜索
@Component
export struct SearchView {
  @State private keyword: string = '';
  /** 当前搜索音源：不再提供「全部」，默认取第一个可搜索音源 */
  @State private source: string = '';
  @State private results: MusicInfo[] = [];
  @State private tips: string[] = [];
  /** 联想词防抖：中文输入法逐字上屏时不逐字打接口（既降封禁风险，也少闪烁） */
  private tipTimer: number = -1;
  private tipSeq: number = 0;
  @State private hotWords: string[] = [];
  @State private history: string[] = [];
  @State private loading: boolean = false;
  @State private errorMsg: string = '';
  @State private page: number = 1;
  @State private langTick: number = 0;
  /** 还有下一页可加载；到底后按钮变「没有更多了」并禁用，避免反复空点 */
  @State private hasMore: boolean = false;
  /** 已执行过搜索（决定是否显示结果计数行，避免首屏出现「共 0 首」） */
  @State private searched: boolean = false;
  /**
   * 请求序号：点 ❌ 清空时 +1，让在途的搜索 / 歌单请求作废。
   * 没有它的话，清空后几百毫秒旧结果又会被写回来，看着像「清不掉」。
   */
  private searchSeq: number = 0;
  private playlistSeq: number = 0;
  /** 列表展示开关（来自设置 list.isShow*，设置变更后实时刷新） */
  @State private showSource: boolean = true;
  @State private showAlbumName: boolean = false;
  @State private showInterval: boolean = true;
  /** 点按播放：true=点击列表项即播放该曲；false=仅选中高亮不切换播放 */
  @State private clickPlay: boolean = true;
  @State private tapIndex: number = -1;
  /** 当前播放歌曲 id：订阅切歌事件，搜索结果高亮跟随实际播放曲目 */
  @State private currentId: string = '';
  /** 搜索页：热搜榜 / 搜索历史 是否展示 */
  @State private showHot: boolean = true;
  @State private showHistory: boolean = true;
  /** 来源名展示：alias=短名（酷我）/ real=全名（酷我音乐） */
  @State private sourceNameType: string = 'alias';
  /** 歌曲「⋯」菜单索引，-1 关闭 */
  @State private menuIndex: number = -1;
  /** 多选模式：长按结果进入，点击其他行切换选中 */
  @State private selectMode: boolean = false;
  @State private selected: string[] = [];
  /** 批量操作菜单：对选中的多首歌执行同一操作 */
  @State private batchMenu: boolean = false;
  /** 结果分栏：song=歌曲 / list=歌单（歌单懒加载，切过来才发请求） */
  @State private tab: string = 'song';
  @State private playlists: ListInfoItem[] = [];
  @State private listLoading: boolean = false;
  @State private listError: string = '';
  @State private listPage: number = 1;
  @State private listHasMore: boolean = false;
  /** 已取到的歌单结果对应的「源|关键词」：词或源变了才重新请求，反复切栏不重复打接口 */
  private playlistKey: string = '';
  @Prop theme: ThemeInfo = DEFAULT_THEME;
  /** 当前是否为激活标签：搜索页无头部操作，激活时清空全局头部操作区 */
  @Prop @Watch('onActiveChanged') active: boolean = false;

  private api: MusicApi = MusicApi.getInstance();
  private musicSource: MusicSource = MusicSource.getInstance();
  private settings: SettingStore = SettingStore.getInstance();
  private listListenerBound: boolean = false;
  /** 结果列表滚动器：换源/换关键词后回到顶部，否则停在上一次的滚动位置让人以为只有半屏结果 */
  private resultScroller: Scroller = new Scroller();
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案并刷新头部（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => {
    this.langTick = this.langTick + 1;
    this.syncHeader();
  };
  /** 切歌后刷新歌曲结果高亮 */
  private onPlayMusicChanged: EmptyCallback = (): void => {
    const now = AppState.getInstance().playMusicInfo;
    this.currentId = now === null ? '' : now.musicInfo.id;
    this.tapIndex = -1;
  };
  /** 列表展示设置变更后重读开关；热词为空时补一次拉取 */
  private onConfigUpdated: EmptyCallback = (): void => {
    this.reloadListDisplay();
    if (this.showHot && this.hotWords.length === 0) {
      this.api.hotSearch('kw').then((ws: string[]): void => {
        this.hotWords = ws;
      }).catch((): void => {
      });
    }
  };

  async aboutToAppear(): Promise<void> {
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    const cur = AppState.getInstance().playMusicInfo;
    this.currentId = cur === null ? '' : cur.musicInfo.id;
    stateEvent().on(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
    this.reloadListDisplay();
    // 默认搜索音源：取第一个支持搜索的音源（不再有「全部」聚合项）
    if (this.source.length === 0) {
      const ss: OnlineSource[] = this.api.searchableSources();
      this.source = ss.length > 0 ? ss[0] : 'kw';
    }
    if (!this.listListenerBound) {
      this.listListenerBound = true;
      stateEvent().on(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
    }
    this.history = await this.musicSource.loadSearchHistory();
    if (this.showHot) {
      this.hotWords = await this.api.hotSearch('kw');
    }
    stateEvent().on(StateEvents.UI_BACK, this.onUiBack);
    this.syncHeader();
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.UI_BACK, this.onUiBack);
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    stateEvent().off(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onPlayMusicChanged);
    stateEvent().off(StateEvents.CONFIG_UPDATED, this.onConfigUpdated);
  }

  /** 系统返回手势：先关批量菜单 / 单曲菜单 / 退出多选，再交给页面回退 */
  private onUiBack = (): void => {
    // 7 个模块常驻同一个 Swiper，非激活模块不能抢这次返回
    if (!this.active) {
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
    if (this.selectMode) {
      this.exitSelect();
      AppState.getInstance().uiBackConsumed = true;
    }
  };

  /**
   * 「歌曲 / 歌单」两个分栏放到全局头部的 ≡ 左侧（用户要求，不再占一行标签栏）。
   * 选中项用主题色，未选中用次要文字色；切换分栏后重新注册一次让颜色跟着变。
   */
  private syncHeader(): void {
    if (!this.active) {
      return;
    }
    const sub: string = buildPalette(this.theme).subText;
    const acts: HeaderAction[] = [];
    acts.push({
      key: 'search_tab_song',
      text: this.tx('search_tab_song'),
      fontSize: 12,
      textColor: this.tab === 'song' ? this.theme.primary : sub,
      onClick: (): void => { this.switchTab('song'); },
    });
    acts.push({
      key: 'search_tab_list',
      text: this.tx('search_tab_list'),
      fontSize: 12,
      textColor: this.tab === 'list' ? this.theme.primary : sub,
      onClick: (): void => { this.switchTab('list'); },
    });
    AppState.getInstance().setHeaderActions(acts);
  }

  /** 从设置读取列表展示开关（来源/专辑/间隔）、点按播放与搜索页热搜/历史开关 */
  private reloadListDisplay(): void {
    this.showSource = this.settings.getBoolean('list.isShowSource', true);
    this.showAlbumName = this.settings.getBoolean('list.isShowAlbumName', false);
    this.showInterval = this.settings.getBoolean('list.isShowInterval', true);
    this.clickPlay = this.settings.getBoolean('list.isClickPlayList', true);
    this.showHot = this.settings.getBoolean('search.isShowHotSearch', true);
    this.showHistory = this.settings.getBoolean('search.isShowHistorySearch', true);
    this.sourceNameType = this.settings.getString('common.sourceNameType', 'alias');
  }

  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  /** 切分栏：歌单懒加载——只有用户真的切过来才发请求，不给单曲搜索多加请求 */
  private switchTab(t: string): void {
    if (this.tab === t) {
      return;
    }
    this.tab = t;
    this.syncHeader();
    if (t === 'list') {
      void this.ensurePlaylists();
    }
  }

  private playlistQueryKey(): string {
    return this.source + '|' + this.keyword.trim();
  }

  private async ensurePlaylists(): Promise<void> {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      this.playlists = [];
      this.listError = '';
      this.playlistKey = '';
      return;
    }
    if (this.playlistKey === this.playlistQueryKey() && this.playlists.length > 0) {
      return;
    }
    await this.loadPlaylists(1);
  }

  /** 搜歌单：单源或「全部」（全部只问支持的三家：酷我 / 酷狗 / 网易） */
  private async loadPlaylists(page: number): Promise<void> {
    const kw: string = this.keyword.trim();
    if (kw.length === 0 || this.listLoading) {
      return;
    }
    this.listLoading = true;
    this.listError = '';
    const limit: number = LIST_LOAD_LIMIT;
    const seq: number = ++this.playlistSeq;
    if (this.source === ALL_SOURCE) {
      const r: MultiSonglistResult = await this.api.searchPlaylistsAll(kw, page, limit);
      if (seq !== this.playlistSeq) {
        return;
      }
      this.playlists = page === 1 ? r.list : this.playlists.concat(r.list);
      this.listHasMore = r.hasMore;
      if (r.list.length === 0) {
        this.listError = r.errors.length > 0 ? r.errors[0] : this.tx('search_list_none');
      }
    } else {
      const r: SonglistResult = await this.api.searchPlaylists(this.source as OnlineSource, kw, page, limit);
      if (seq !== this.playlistSeq) {
        return;
      }
      this.playlists = page === 1 ? r.list : this.playlists.concat(r.list);
      this.listHasMore = r.list.length >= limit;
      if (r.list.length === 0) {
        this.listError = r.error.length > 0 ? r.error : this.tx('search_list_none');
      }
    }
    this.listPage = page;
    this.playlistKey = this.playlistQueryKey();
    this.listLoading = false;
    this.hideKeyboard();
  }

  /** 点歌单卡片：进歌单详情（与在线歌单页同一条路由） */
  private openPlaylist(p: ListInfoItem): void {
    router.pushUrl({
      url: 'pages/PlaylistDetail',
      params: {
        source: p.source,
        id: p.id,
        title: p.name,
        type: 'playlist',
        author: p.author,
        playCount: p.play_count,
        img: p.img,
      },
    });
  }

  /** 换音源：歌曲栏直接重搜；歌单栏只重取歌单，不多打一次单曲搜索 */
  private pickSource(s: string): void {
    if (this.source === s) {
      return;
    }
    this.source = s;
    this.playlists = [];
    this.playlistKey = '';
    if (this.tab === 'list') {
      void this.loadPlaylists(1);
    } else {
      this.doSearch();
    }
  }

  private async doSearch(): Promise<void> {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.tips = [];
    const h: string[] = this.history.slice();
    const i: number = h.indexOf(kw);
    if (i >= 0) { h.splice(i, 1); }
    h.unshift(kw);
    this.history = h.slice(0, 20);
    this.musicSource.saveSearchHistory(this.history);
    this.loading = true;
    this.errorMsg = '';
    this.page = 1;
    this.searched = true;
    const seq: number = ++this.searchSeq;
    // 关键词变了：上次的歌单结果作废（切到歌单栏时再按需取）
    this.playlists = [];
    this.playlistKey = '';
    if (this.source === ALL_SOURCE) {
      // 「全部」：串行搜五家再交错合并。单家失败不影响其余结果，只有一家都没搜到才提示错误。
      const r: MultiSearchResult = await this.api.searchAll(kw, 1, LIST_LOAD_LIMIT);
      // 期间点了 ❌ 或换了关键词：这批结果已经过期，直接丢弃（loading 由清空逻辑复位）
      if (seq !== this.searchSeq) {
        return;
      }
      this.results = r.list;
      this.hasMore = r.hasMore;
      if (r.list.length === 0) {
        this.errorMsg = r.errors.length > 0 ? r.errors[0] : this.tx('not_found');
      }
    } else {
      const r: SearchResult = await this.api.search(this.source as OnlineSource, kw, 1, LIST_LOAD_LIMIT);
      if (seq !== this.searchSeq) {
        return;
      }
      this.results = r.list;
      this.hasMore = r.list.length >= LIST_LOAD_LIMIT;
      this.errorMsg = r.list.length === 0 ? (r.error.length > 0 ? r.error : this.tx('not_found')) : '';
    }
    this.loading = false;
    this.hideKeyboard();
    this.scrollResultsTop();
    if (this.tab === 'list') {
      void this.loadPlaylists(1);
    }
  }

  /** 收起软键盘：否则搜索完成后键盘仍挡着半屏结果，得手动点「完成」才能看全 */
  private hideKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
      // 低版本无该能力时忽略，不影响搜索
    }
    try {
      inputMethod.getController().stopInputSession().then((_ok: boolean): void => {
      }).catch((_e: Error): void => {
      });
    } catch (e) {
      // 输入法服务不可用时忽略
    }
  }

  /** 结果列表回到顶部：换源/换关键词后若沿用旧滚动位置，会让人误以为只搜到半屏 */
  private scrollResultsTop(): void {
    setTimeout((): void => {
      try {
        this.resultScroller.scrollToIndex(0);
      } catch (e) {
        // 结果为空时列表未创建，忽略
      }
    }, 80);
  }

  /** 打开歌曲「⋯」菜单：未播放时把搜索结果同步进播放列表，让菜单的播放/移除落到正确列表 */
  private openItemMenu(i: number): void {
    if (i < 0 || i >= this.results.length) {
      return;
    }
    if (AppState.getInstance().playMusicInfo === null && this.results.length > 0) {
      PlayController.getInstance().syncTempList(this.results);
    }
    this.menuIndex = i;
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  private selectedSongs(): MusicInfo[] {
    return this.results.filter((m: MusicInfo): boolean => this.isSelected(m.id));
  }

  private toggleSelect(id: string): void {
    if (this.isSelected(id)) {
      this.selected = this.selected.filter((x: string): boolean => x !== id);
    } else {
      this.selected = this.selected.concat([id]);
    }
  }

  private toggleSelectAll(): void {
    if (this.selected.length === this.results.length) {
      this.selected = [];
    } else {
      this.selected = this.results.map((m: MusicInfo): string => m.id);
    }
  }

  /** 长按进入多选：先取 id 再改状态，避免结果刷新后下标错位 */
  private enterSelect(i: number): void {
    if (i < 0 || i >= this.results.length) {
      return;
    }
    const id: string = this.results[i].id;
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
    if (AppState.getInstance().playMusicInfo === null && this.results.length > 0) {
      PlayController.getInstance().syncTempList(this.results);
    }
    this.batchMenu = true;
  }

  private async loadMore(): Promise<void> {
    const kw: string = this.keyword.trim();
    if (kw.length === 0 || this.loading || !this.hasMore) {
      return;
    }
    this.loading = true;
    const next: number = this.page + 1;
    const oldLen: number = this.results.length;
    const seq: number = ++this.searchSeq;
    if (this.source === ALL_SOURCE) {
      const r: MultiSearchResult = await this.api.searchAll(kw, next, LIST_LOAD_LIMIT);
      if (seq !== this.searchSeq) {
        return;
      }
      if (r.list.length > 0) {
        const merged: MusicInfo[] = this.results.slice();
        for (const m of r.list) { merged.push(m); }
        this.results = merged;
        this.page = next;
      }
      this.hasMore = r.hasMore;
    } else {
      const r: SearchResult = await this.api.search(this.source as OnlineSource, kw, next, LIST_LOAD_LIMIT);
      if (seq !== this.searchSeq) {
        return;
      }
      if (r.list.length > 0) {
        const merged: MusicInfo[] = this.results.slice();
        for (const m of r.list) { merged.push(m); }
        this.results = merged;
        this.page = next;
      }
      // 返回条数不足一页即判定到底，按钮变「没有更多了」并禁用
      this.hasMore = r.list.length >= LIST_LOAD_LIMIT;
    }
    this.loading = false;
    setTimeout((): void => {
      try {
        this.resultScroller.scrollToIndex(oldLen);
      } catch (e) {
        // 列表未就绪时忽略
      }
    }, 80);
  }

  private async loadTips(v: string): Promise<void> {
    const seq: number = ++this.tipSeq;
    if (v.trim().length < 2) {
      this.tips = [];
      return;
    }
    const words: string[] = await this.api.tipSearch('kw', v.trim());
    // 输入过程中可能已发起新请求，旧结果直接丢弃，避免覆盖新联想
    if (seq !== this.tipSeq) {
      return;
    }
    this.tips = words;
  }

  /**
   * 搜索框 ❌ 清除：不止清空输入框，而是回到「初始搜索页」。
   * 关键词、联想词、在途请求（用序号作废）、歌曲结果、歌单结果、分页状态、
   * 多选与菜单状态一起复位；热搜榜与搜索历史照常显示。
   */
  private clearKeyword(): void {
    this.keyword = '';
    if (this.tipTimer >= 0) {
      clearTimeout(this.tipTimer);
      this.tipTimer = -1;
    }
    this.tipSeq++;
    this.tips = [];
    // 作废在途请求：否则清空后旧结果会被晚到的响应写回来
    this.searchSeq++;
    this.playlistSeq++;
    this.results = [];
    this.playlists = [];
    this.searched = false;
    this.loading = false;
    this.listLoading = false;
    this.errorMsg = '';
    this.listError = '';
    this.page = 1;
    this.listPage = 1;
    this.hasMore = false;
    this.listHasMore = false;
    this.playlistKey = '';
    // 结果清空了，浮窗 / 多选也必须一起收掉，否则菜单挂在不存在的行上
    this.menuIndex = -1;
    this.batchMenu = false;
    this.selectMode = false;
    this.selected = [];
    this.tapIndex = -1;
    this.hideKeyboard();
    this.scrollResultsTop();
  }

  /** 歌单分栏：封面 + 歌单名 + 作者/歌曲数，点进歌单详情 */
  @Builder
  playlistResults() {
    if (this.listLoading && this.playlists.length === 0) {
      Row() {
        LoadingProgress().width(20).height(20).color(this.theme.primary)
        Text('  ' + this.tx('searching')).fontSize(12).fontColor(buildPalette(this.theme).subText)
      }.width('100%').padding(10).justifyContent(FlexAlign.Center)
    }
    if (this.playlists.length > 0) {
      Row() {
        Text(this.tx('search_total') + this.playlists.length.toString() + ' ' + this.tx('unit_playlist'))
          .fontSize(11).fontColor(buildPalette(this.theme).subText)
      }
      .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })

      List() {
        ForEach(this.playlists, (p: ListInfoItem): void => {
          ListItem() {
            Row() {
              CoverImage({ url: p.img, theme: this.theme, radius: 8, placeholderSize: 26 })
                .width(52).height(52)
              Column() {
                Text(p.name)
                  .fontSize(13).fontColor(this.theme.font)
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%').textAlign(TextAlign.Start)
                Row() {
                  Text(sourceDisplay(p.source, this.sourceNameType))
                    .fontSize(10).fontColor(this.theme.primary)
                    .backgroundColor(buildPalette(this.theme).pillBg).borderRadius(4)
                    .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  if (p.author.length > 0) {
                    Text(p.author).fontSize(10).fontColor(buildPalette(this.theme).subText)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1).margin({ left: 6 })
                  }
                  if (p.total > 0) {
                    Text(p.total.toString() + ' ' + this.tx('unit_song'))
                      .fontSize(10).fontColor(buildPalette(this.theme).subText).margin({ left: 6 })
                  }
                }
                .width('100%').margin({ top: 4 })
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 10 })
            }
            .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .onClick((): void => { this.openPlaylist(p); })
          }
        }, (p: ListInfoItem): string => p.source + '_' + p.id + '_' + p.name + '_' + this.sourceNameType)
        ListItem() {
          Text(this.listLoading ? this.tx('searching') : (this.listHasMore ? this.tx('load_more') : this.tx('no_more')))
            .fontSize(12)
            .fontColor(this.listHasMore ? this.theme.primary : buildPalette(this.theme).subText)
            .width('100%').height(40).textAlign(TextAlign.Center)
            .onClick((): void => {
              if (this.listHasMore && !this.listLoading) {
                void this.loadPlaylists(this.listPage + 1);
              }
            })
        }
      }
      .layoutWeight(1).width('100%')
    } else if (!this.listLoading) {
      Column() {
        if (this.listError.length > 0) {
          Text(this.listError).fontSize(12).fontColor('#B4694A')
            .width('100%').padding(12).textAlign(TextAlign.Center)
        } else if (this.keyword.trim().length === 0) {
          EmptyHint(this.tx('search_hint'), this.theme)
        } else {
          Text(this.tx('search_list_none')).fontSize(12)
            .fontColor(buildPalette(this.theme).subText)
            .width('100%').padding(12).textAlign(TextAlign.Center)
        }
      }
      .width('100%').layoutWeight(1)
    }
  }

  /** 切模块：激活时注册「歌曲 / 歌单」，切走时关掉菜单浮窗并退出多选 */
  private onActiveChanged(): void {
    if (this.active) {
      this.syncHeader();
      return;
    }
    this.menuIndex = -1;
    this.batchMenu = false;
    this.selectMode = false;
    this.selected = [];
  }

  build() {
    Stack() {
      Column() {
      Row() {
        Stack({ alignContent: Alignment.End }) {
          TextInput({ placeholder: this.tx('search_ph'), text: this.keyword })
            .width('100%').height(38).fontSize(13)
            .backgroundColor(buildPalette(this.theme).card).borderRadius(19)
            .fontColor(this.theme.font)
            .placeholderColor(buildPalette(this.theme).subText)
            .padding({ right: 42 })
            .onChange((v: string): void => {
              this.keyword = v;
              // 停下 350ms 才请求联想，快速输入/改词只发一次；清空时立即收起
              if (this.tipTimer >= 0) {
                clearTimeout(this.tipTimer);
                this.tipTimer = -1;
              }
              const word: string = v.trim();
              if (word.length < 2) {
                this.tipSeq++;
                this.tips = [];
                return;
              }
              this.tipTimer = setTimeout((): void => {
                this.tipTimer = -1;
                void this.loadTips(word);
              }, 350);
            })
            .onSubmit((): void => { this.doSearch(); })
          // 有内容才显示 ❌，点击清空关键词并复位联想（与「我的列表」一致）
          if (this.keyword.length > 0) {
            Image($r('app.media.ic_close_thin'))
              .width(16).height(16).fillColor(buildPalette(this.theme).subText)
              .margin({ right: 14 })
              .onClick((): void => { this.clearKeyword(); })
          }
        }
        .layoutWeight(1)
        .height(38)
        Button(this.tx('search_btn')).height(38).fontSize(13)
          .backgroundColor(this.theme.primary).fontColor('#FFFFFF').stateEffect(false)
          .margin({ left: 8 })
          .onClick((): void => { this.doSearch(); })
      }
      .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 6 })

      Scroll() {
        Row() {
          // 「全部」固定在最前：串行搜五家后交错合并，对应 MusicApi.searchAll
          Text(this.tx('all')).fontSize(12)
            .fontColor(this.source === ALL_SOURCE ? '#FFFFFF' : buildPalette(this.theme).pillText)
            .backgroundColor(this.source === ALL_SOURCE ? this.theme.primary : buildPalette(this.theme).pillBg)
            .borderRadius(12).padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .margin({ right: 6 })
            .onClick((): void => { this.pickSource(ALL_SOURCE); })
          ForEach(this.api.searchableSources(), (s: OnlineSource): void => {
            Text(sourceDisplay(s, this.sourceNameType)).fontSize(12)
              .fontColor(this.source === s ? '#FFFFFF' : buildPalette(this.theme).pillText)
              .backgroundColor(this.source === s ? this.theme.primary : buildPalette(this.theme).pillBg)
              .borderRadius(12).padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .margin({ right: 6 })
              .onClick((): void => { this.pickSource(s); })
          }, (s: OnlineSource): string => s + '_' + this.sourceNameType)
        }
      }
      .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .width('100%').height(34).padding({ left: 16 })

      if (this.tips.length > 0 && this.keyword.length > 0 && this.results.length === 0) {
        List() {
          ForEach(this.tips, (t: string): void => {
            ListItem() {
              Text(t).fontSize(13).fontColor(buildPalette(this.theme).pillText)
                .width('100%').height(36).padding({ left: 16 })
                .onClick((): void => { this.keyword = t; this.tips = []; this.doSearch(); })
            }
          }, (t: string): string => t)
        }
        .height(Math.min(this.tips.length * 36, 180)).width('100%')
      }

      if (this.tab === 'list') {
        this.playlistResults()
      } else {
      if (this.loading) {
        Row() {
          LoadingProgress().width(20).height(20).color(this.theme.primary)
          Text('  ' + this.tx('searching')).fontSize(12).fontColor(buildPalette(this.theme).subText)
        }.width('100%').padding(10).justifyContent(FlexAlign.Center)
      }

      if (this.results.length > 0) {
        Row() {
          Text(this.tx('search_total') + this.results.length.toString() + ' ' + this.tx('unit_song'))
            .fontSize(11).fontColor(buildPalette(this.theme).subText)
          Blank()
          if (this.selectMode) {
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
          } else {
            Row() {
              Image($r('app.media.ic_play')).width(14).height(14).fillColor(this.theme.primary).margin({ right: 4 })
              Text(this.tx('play_all')).fontSize(12).fontColor(this.theme.primary)
            }
              .onClick((): void => {
                this.tapIndex = -1;
                PlayController.getInstance().playMusicList(this.results, 0);
              })
          }
        }
        .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })

        if (this.selectMode) {
          Text('已选 ' + this.selected.length.toString() + ' 首')
            .fontSize(11).fontColor(this.theme.primary)
            .width('100%').padding({ left: 16, bottom: 2 })
        }

        List({ scroller: this.resultScroller }) {
          ForEach(this.results, (m: MusicInfo, idx: number): void => {
            ListItem() {
              MusicListItem({
                music: m, index: idx, isActive: (this.currentId.length > 0 && this.currentId === m.id) || this.tapIndex === idx, theme: this.theme,
                showSource: this.showSource,
                showAlbumName: this.showAlbumName,
                showInterval: this.showInterval,
                sourceNameType: this.sourceNameType,
                selecting: this.selectMode,
                checked: this.isSelected(m.id),
                onItemClick: (i: number): void => {
                  // 单击：多选时切换选中；普通状态下不播放（播放改为双击），也不弹任何提示
                  if (this.selectMode) {
                    this.toggleSelect(this.results[i].id);
                  }
                },
                onItemDoubleClick: (i: number): void => {
                  if (this.selectMode) {
                    // 双击的第一下已经切换过选中，这里不再重复切换
                    return;
                  }
                  if (this.clickPlay) {
                    this.tapIndex = -1;
                    PlayController.getInstance().playMusicList(this.results, i);
                  } else {
                    this.tapIndex = i;
                  }
                },
                onItemLongPress: (i: number): void => { this.enterSelect(i); },
                onMoreClick: (i: number): void => {
                  // 多选时 ⋮ 作用于全部选中歌曲：该行未选中先补选
                  if (this.selectMode) {
                    if (i >= 0 && i < this.results.length && !this.isSelected(this.results[i].id)) {
                      this.selected = this.selected.concat([this.results[i].id]);
                    }
                    this.openBatchMenu();
                    return;
                  }
                  this.openItemMenu(i);
                },
              })
            }
          }, (m: MusicInfo): string => m.id + '_' + this.sourceNameType)
          ListItem() {
            Text(this.loading ? this.tx('searching') : (this.hasMore ? this.tx('load_more') : this.tx('no_more')))
              .fontSize(12)
              .fontColor(this.hasMore ? this.theme.primary : buildPalette(this.theme).subText)
              .width('100%').height(40).textAlign(TextAlign.Center)
              .onClick((): void => { this.loadMore(); })
          }
        }
        .layoutWeight(1).width('100%')
      } else if (!this.loading) {
        Column() {
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(12).fontColor('#B4694A')
              .width('100%').padding(12).textAlign(TextAlign.Center)
          }
          if (this.searched && this.keyword.length > 0) {
            Text(this.tx('search_try_other')).fontSize(11)
              .fontColor(buildPalette(this.theme).subText)
              .width('100%').padding({ left: 16, right: 16, bottom: 8 }).textAlign(TextAlign.Center)
          }
          if (this.keyword.length === 0) {
            if (this.showHot && this.hotWords.length > 0) {
              Row() { Text(this.tx('hot_search')).fontSize(12).fontColor(buildPalette(this.theme).subText) }
                .width('100%').padding({ left: 16, top: 8 })
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.hotWords, (w: string): void => {
                  Text(w).fontSize(12).fontColor(buildPalette(this.theme).pillText)
                    .backgroundColor(buildPalette(this.theme).pillBg).borderRadius(12)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .margin({ right: 6, top: 6 })
                    .onClick((): void => { this.keyword = w; this.doSearch(); })
                }, (w: string): string => w)
              }.width('100%').padding({ left: 16, right: 16 })
            }
            if (this.showHistory && this.history.length > 0) {
              Row() {
                Text(this.tx('history_search')).fontSize(12).fontColor(buildPalette(this.theme).subText)
                Blank()
                Text(this.tx('clear')).fontSize(12).fontColor(this.theme.primary)
                  .onClick((): void => {
                    this.history = [];
                    this.musicSource.saveSearchHistory([]);
                  })
              }.width('100%').padding({ left: 16, right: 16, top: 14 })
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.history, (h: string): void => {
                  Text(h).fontSize(12).fontColor(buildPalette(this.theme).pillText)
                    .backgroundColor(buildPalette(this.theme).pillBg).borderRadius(12)
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .margin({ right: 6, top: 6 })
                    .onClick((): void => { this.keyword = h; this.doSearch(); })
                }, (h: string): string => h)
              }.width('100%').padding({ left: 16, right: 16 })
            }
            if ((!this.showHot || this.hotWords.length === 0) && (!this.showHistory || this.history.length === 0)) {
              EmptyHint(this.tx('search_hint'), this.theme)
            }
          }
        }
        .width('100%').layoutWeight(1)
      }
      }
    }
    .width('100%').height('100%').backgroundColor(this.theme.mainBackground)

    // 三点菜单挂在页面最外层 Stack：留在上面的 Column 里会被当成普通子项排版，
    // 遮罩盖不满整页、卡片 78% 高度按剩余空间算，长菜单底部会被屏幕裁掉
    if (this.menuIndex >= 0 && this.menuIndex < this.results.length) {
      SongMenuPanel({
        music: this.results[this.menuIndex],
        listId: ListIds.TEMP,
        index: this.menuIndex,
        allowRemove: false,
        theme: this.theme,
        onClose: (): void => { this.menuIndex = -1; },
      })
    }

    // 批量菜单：一次对选中的多首歌执行同一操作（搜索结果不能真正移除，故不给「移除」）
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
  }
  .width('100%').height('100%')
  }
}