/**
 * 播放队列面板 —— 阶段三第 ② 步
 * 按播放页布局 的队列抽屉 + playLater 面板。
 * 两个分区：
 *   当前列表 —— 点击切歌、⋯ 菜单（下一首播放 / 从队列移除）、编辑模式拖拽排序
 *   稍后播放 —— 点击插队播放、移除、清空（按 tempPlayList 语义）
 */
import { MusicInfo, TempPlayListItem } from '../../model/MusicTypes';
import { AppState } from '../../store/AppState';
import { PlayController } from '../../player/PlayController';
import { PlayQueue } from '../../core/PlayQueue';
import { ListManager } from '../../core/ListManager';
import { ThemeInfo, ThemePalette, buildPalette } from '../../theme/Themes';
import { ListIds, isDownloadEnabled, Quality } from '../../config/AppConstants';
import { availableDownloadQualities } from '../../core/DownloadQualities';
import { DownloadManager } from '../../core/DownloadManager';
import { SongMenuPanel } from '../../components/SongMenuPanel';
import {
  EmptyCallback, stateEvent, listEvent, StateEvents, ListEvents,
} from '../../store/EventBus';
import { userNotice } from '../../core/UserNotice';
import { AppLog } from '../../core/AppLog';
import { setPopupAnchor } from '../../core/Popup';

/** 操作菜单动作编号（@Builder 传函数参数在部分版本不触发，改用编号分发） */
const MENU_INSERT_NEXT: number = 1;
const MENU_REMOVE: number = 2;
const MENU_PLAY_TEMP: number = 3;
const MENU_REMOVE_TEMP: number = 4;

@Component
export struct QueuePanel {
  @Link show: boolean;
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 列表名（由播放页快照传入，只用于副标题展示） */
  @Prop listName: string = '我的歌单';
  /** 外部每次 +1 即强制刷新（打开面板、切歌时由父组件触发） */
  @Prop @Watch('onTick') tick: number = 0;
  /** 横屏播放页：队列改为悬浮在歌词区的浮窗；竖屏保持底部抽屉 */
  @Prop landscape: boolean = false;

  /** 0 = 当前列表，1 = 稍后播放 */
  @State private tab: number = 0;
  @State private songs: MusicInfo[] = [];
  @State private curIndex: number = -1;
  @State private curListId: string | null = null;
  @State private curMusicId: string = '';
  @State private tempItems: TempPlayListItem[] = [];
  @State private editMode: boolean = false;
  @State private dragIndex: number = -1;
  /** 操作菜单：当前列表索引，-1 关闭 */
  @State private menuIndex: number = -1;
  /** 操作菜单：稍后播放索引，-1 关闭 */
  @State private menuTempIndex: number = -1;

  private state: AppState = AppState.getInstance();
  private controller: PlayController = PlayController.getInstance();
  private queue: PlayQueue = PlayQueue.getInstance();
  private listManager: ListManager = ListManager.getInstance();
  private onStateChange: EmptyCallback = (): void => {
    this.refresh();
  };

  aboutToAppear(): void {
    this.refresh();
    stateEvent().on(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onStateChange);
    stateEvent().on(StateEvents.PLAY_INFO_CHANGED, this.onStateChange);
    stateEvent().on(StateEvents.PLAY_TEMP_PLAY_LIST_CHANGED, this.onStateChange);
    stateEvent().on(StateEvents.THEME_UPDATED, this.onStateChange);
    listEvent().on(ListEvents.LIST_MUSIC_ADD, this.onStateChange);
    listEvent().on(ListEvents.LIST_MUSIC_REMOVE, this.onStateChange);
    listEvent().on(ListEvents.LIST_MUSIC_UPDATE, this.onStateChange);
    listEvent().on(ListEvents.LIST_MUSIC_CLEAR, this.onStateChange);
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.PLAY_MUSIC_INFO_CHANGED, this.onStateChange);
    stateEvent().off(StateEvents.PLAY_INFO_CHANGED, this.onStateChange);
    stateEvent().off(StateEvents.PLAY_TEMP_PLAY_LIST_CHANGED, this.onStateChange);
    stateEvent().off(StateEvents.THEME_UPDATED, this.onStateChange);
    listEvent().off(ListEvents.LIST_MUSIC_ADD, this.onStateChange);
    listEvent().off(ListEvents.LIST_MUSIC_REMOVE, this.onStateChange);
    listEvent().off(ListEvents.LIST_MUSIC_UPDATE, this.onStateChange);
    listEvent().off(ListEvents.LIST_MUSIC_CLEAR, this.onStateChange);
  }

  onTick(): void {
    this.refresh();
  }

  build() {
    if (this.landscape) {
      // 横屏：浮窗悬浮在右半屏歌词区，歌曲两列，不再从底部升起占满下半屏
      Stack() {
        // 遮罩：点空白收起
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#55000000')
        .onClick((): void => {
          this.show = false;
        })

        // 浮窗主体
        Column() {
          this.PanelBody()
        }
        .width('52%')
        .height('84%')
        .position({ right: '2%', top: '8%' })
        .backgroundColor(this.theme.mainBackground)
        .borderRadius(16)
        .clip(true)
        .shadow({ radius: 18, color: '#33000000', offsetX: 0, offsetY: 4 })

        this.MenuLayer()
      }
      .width('100%')
      .height('100%')
    } else {
      // 竖屏：保持原底部抽屉
      Stack({ alignContent: Alignment.Bottom }) {
        // 遮罩：点空白收起
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => {
          this.show = false;
        })

        // 面板主体
        Column() {
          this.PanelBody()
        }
        .width('100%')
        .height('62%')
        .backgroundColor(this.theme.mainBackground)
        .borderRadius({ topLeft: 18, topRight: 18 })
        .shadow({ radius: 18, color: '#33000000', offsetX: 0, offsetY: -4 })

        this.MenuLayer()
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 浮窗与抽屉共用的面板内容 */
  @Builder
  PanelBody() {
    Row() {
    }
    .width(36)
    .height(4)
    .borderRadius(2)
    .backgroundColor(this.pal().divider)
    .margin({ top: 8 })

    Row() {
      Column() {
        Text('播放队列')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.font)
        Text(this.subTitle())
          .fontSize(11)
          .fontColor(this.pal().subText)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 横屏浮窗用两列网格，系统拖拽排序在 Grid 上不可用，故隐藏「排序」
      if (this.tab === 0 && !this.landscape) {
        Text(this.editMode ? '完成' : '排序')
          .fontSize(12)
          .fontColor(this.theme.primary)
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .onClick((): void => {
            this.editMode = !this.editMode;
          })
      } else if (this.tab === 1) {
        Text('清空')
          .fontSize(12)
          .fontColor(this.tempItems.length === 0 ? this.pal().subText : this.theme.primary)
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .onClick((): void => {
            this.clearTemp();
          })
      }
      Image($r('app.media.ic_close')).width(20).height(20).fillColor(this.pal().subText)
        .onClick((): void => {
          this.show = false;
        })
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 6 })

    // 分区切换
    Row() {
      this.TabChip(0)
      this.TabChip(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 4, bottom: 6 })

    if (this.tab === 0) {
      if (this.songs.length === 0) {
        this.EmptyHint('当前列表还是空的')
      } else if (this.landscape) {
        // 横屏浮窗：两列网格，一屏多看几首
        Grid() {
          ForEach(this.songs, (m: MusicInfo, i: number) => {
            GridItem() {
              this.SongRow(m, i)
            }
          }, (m: MusicInfo) => m.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(0)
        .rowsGap(0)
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      } else {
        List() {
          ForEach(this.songs, (m: MusicInfo, i: number) => {
            ListItem() {
              this.SongRow(m, i)
            }
          }, (m: MusicInfo) => m.id)
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: this.pal().divider })
        .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
          this.dragIndex = itemIndex;
          return this.DragPreview(itemIndex);
        })
        .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean): void => {
          if (!this.editMode || !isSuccess || insertIndex < 0) {
            return;
          }
          this.moveSong(itemIndex, insertIndex);
        })

        if (this.editMode) {
          Text('长按拖动可调整顺序，改动会同步到原列表')
            .fontSize(10)
            .fontColor(this.pal().subText)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 6, bottom: 8 })
        }
      }
    } else {
      if (this.tempItems.length === 0) {
        this.EmptyHint('暂无稍后播放的歌曲\n在歌曲「⋯」菜单里选「下一首播放」即可加入')
      } else if (this.landscape) {
        Grid() {
          // 稍后播放允许同一首歌重复插入，且不支持拖动排序，key 必须带索引保证唯一
          ForEach(this.tempItems, (it: TempPlayListItem, i: number) => {
            GridItem() {
              this.TempRow(it, i)
            }
          }, (it: TempPlayListItem, i: number): string => it.musicInfo.id + '_' + i.toString())
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(0)
        .rowsGap(0)
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      } else {
        List() {
          ForEach(this.tempItems, (it: TempPlayListItem, i: number) => {
            ListItem() {
              this.TempRow(it, i)
            }
          }, (it: TempPlayListItem, i: number): string => it.musicInfo.id + '_' + i.toString())
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: this.pal().divider })
      }
    }
  }

  /** 歌曲 ⋯ 操作菜单层（浮窗与抽屉共用） */
  @Builder
  MenuLayer() {
    if (this.menuIndex >= 0 && this.menuIndex < this.songs.length && this.curListId !== null) {
      SongMenuPanel({
        music: this.songs[this.menuIndex],
        listId: this.curListId as string,
        index: this.menuIndex,
        theme: this.theme,
        onClose: (): void => { this.menuIndex = -1; this.menuTempIndex = -1; },
        onChanged: (): void => { this.refresh(); },
      })
    } else if (this.menuTempIndex >= 0 && this.menuTempIndex < this.tempItems.length) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#55000000')
        .onClick((): void => {
          this.closeMenu();
        })

        Column() {
          Text(this.menuTitle())
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.font)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 14, bottom: 10, left: 16, right: 16 })

          this.MenuItem('立即播放', true, MENU_PLAY_TEMP)
          this.MenuItem('移出稍后播放', false, MENU_REMOVE_TEMP)

          Divider()
            .strokeWidth(0.5)
            .color(this.pal().divider)
          Text('取消')
            .fontSize(13)
            .fontColor(this.pal().subText)
            .width('100%')
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.closeMenu();
            })
        }
        .width('76%')
        .backgroundColor(this.pal().card)
        .borderRadius(14)
        .clip(true)
      }
      .width('100%')
      .height('100%')
    }
  }


  /**
   * 分区胶囊：计数在 builder 内直接读 @State。
   * （@Builder 按值传参不会跟随状态变化重渲染，计数会被冻结在首帧值）
   */
  @Builder
  TabChip(idx: number) {
    Text((idx === 0 ? '当前列表 ' : '稍后播放 ') + (idx === 0 ? this.songs.length : this.tempItems.length).toString())
      .fontSize(12)
      .fontColor(this.tab === idx ? '#FFFFFF' : this.pal().pillText)
      .backgroundColor(this.tab === idx ? this.theme.primary : this.pal().pillBg)
      .borderRadius(14)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .margin({ right: 8 })
      .onClick((): void => {
        this.tab = idx;
        this.editMode = false;
        this.closeMenu();
      })
  }

  @Builder
  SongRow(m: MusicInfo, i: number) {
    Row() {
      if (this.isCurrentIndex(i)) {
        Image($r('app.media.ic_play_outline')).width(14).height(14).fillColor(this.theme.primary)
      } else {
        Text((i + 1).toString())
          .fontSize(11)
          .fontColor(this.pal().subText)
          .width(32)
          .textAlign(TextAlign.Center)
      }
      Column() {
        Text(m.name)
          .fontSize(13.5)
          .fontColor(this.isCurrentIndex(i) ? this.theme.primary : this.theme.font)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(m.singer)
          .fontSize(11)
          .fontColor(this.pal().subText)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.editMode) {
        Row() {
          Image($r('app.media.ic_menu')).width(18).height(18).fillColor(this.pal().subText)
        }
        .width(34).height(44).justifyContent(FlexAlign.Center)
      } else {
        // 网络歌曲：三点菜单前加下载图标，听到喜欢的可直接下载
        if (isDownloadEnabled() && m.source !== 'local') {
          Row() {
            Image($r('app.media.ic_download')).width(18).height(18).fillColor(this.theme.primary)
          }
          .width(34).height(44).justifyContent(FlexAlign.Center)
          .onClick((): void => { this.downloadSong(m); })
        }
        Row() {
          Image($r('app.media.ic_more')).width(18).height(18).fillColor(this.pal().subText)
        }
        .width(34).height(44).justifyContent(FlexAlign.Center)
        .onClick((e: ClickEvent): void => {
          setPopupAnchor(e.windowX, e.windowY);
          this.openMenu(i);
        })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 6, right: 6 })
    .backgroundColor(this.isCurrentIndex(i) ? this.pal().activeTint : Color.Transparent)
    .onClick((): void => {
      if (this.editMode) {
        return;
      }
      this.playAt(i);
    })
  }

  @Builder
  TempRow(it: TempPlayListItem, i: number) {
    Row() {
      Text((i + 1).toString())
        .fontSize(11)
        .fontColor(this.pal().subText)
        .width(32)
        .textAlign(TextAlign.Center)
      Column() {
        Text(it.musicInfo.name)
          .fontSize(13.5)
          .fontColor(this.theme.font)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(it.musicInfo.singer)
          .fontSize(11)
          .fontColor(this.pal().subText)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row() {
        Image($r('app.media.ic_more')).width(18).height(18).fillColor(this.pal().subText)
      }
      .width(34).height(44).justifyContent(FlexAlign.Center)
      .onClick((e: ClickEvent): void => {
        setPopupAnchor(e.windowX, e.windowY);
        this.menuTempIndex = i;
        this.menuIndex = -1;
      })
    }
    .width('100%')
    .height(52)
    .padding({ left: 6, right: 6 })
    .onClick((): void => {
      this.playTempAt(i);
    })
  }

  @Builder
  MenuItem(label: string, highlight: boolean, action: number) {
    Text(label)
      .fontSize(13)
      .fontColor(highlight ? this.theme.primary : this.theme.font)
      .width('100%')
      .height(46)
      .textAlign(TextAlign.Center)
      .onClick((): void => {
        this.handleMenuAction(action);
      })
  }

  @Builder
  EmptyHint(text: string) {
    Column() {
      Text(text)
        .fontSize(12)
        .fontColor(this.pal().subText)
        .textAlign(TextAlign.Center)
        .lineHeight(20)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  DragPreview(index: number) {
    Row() {
      Text(index >= 0 && index < this.songs.length ? this.songs[index].name : '')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('72%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.theme.primary)
    .borderRadius(10)
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 6 })
  }

  // ------------------------------------------------------------------ 数据
  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  private refresh(): void {
    const cur = this.state.playMusicInfo;
    // 插队曲（稍后播放）的 listId 为 null，此时回落到真实的播放列表，
    // 否则面板会误显示成空列表。
    let listId: string | null = cur === null ? null : cur.listId;
    if (listId === null) {
      listId = this.state.playInfo.playerListId;
    }
    this.curListId = listId;
    this.curMusicId = cur === null ? '' : cur.musicInfo.id;
    // 取副本：Map 里的原数组引用不变时不会触发 UI 刷新
    this.songs = this.state.getList(listId).slice();
    this.curIndex = this.state.playInfo.playIndex;
    this.tempItems = this.state.tempPlayList.slice();
  }

  /** 当前播放的是「稍后播放」插队曲（不归属任何列表） */
  private isTempPlaying(): boolean {
    const cur = this.state.playMusicInfo;
    if (cur === null) {
      return false;
    }
    return cur.listId === null || cur.isTempPlay;
  }

  private isCurrentIndex(i: number): boolean {
    if (i !== this.curIndex || i < 0 || i >= this.songs.length) {
      return false;
    }
    return this.songs[i].id === this.curMusicId;
  }

  private subTitle(): string {
    if (this.tab === 1) {
      return this.tempItems.length === 0 ? '稍后播放 · 空' : '稍后播放 · ' + this.tempItems.length.toString() + ' 首';
    }
    if (this.songs.length === 0) {
      return this.listName + ' · 空';
    }
    const total = '共 ' + this.songs.length.toString() + ' 首';
    // 插队曲在播时它不在列表里，别硬报「第 N 首在播」以免误导
    if (this.isTempPlaying()) {
      return this.listName + ' · ' + total + ' · 正在播放插队曲';
    }
    const pos = this.curIndex >= 0 && this.curIndex < this.songs.length ? this.curIndex + 1 : 0;
    return this.listName + ' · ' + total + ' · 第 ' + pos.toString() + ' 首在播';
  }

  private menuTitle(): string {
    if (this.menuIndex >= 0 && this.menuIndex < this.songs.length) {
      return this.songs[this.menuIndex].name;
    }
    if (this.menuTempIndex >= 0 && this.menuTempIndex < this.tempItems.length) {
      return this.tempItems[this.menuTempIndex].musicInfo.name;
    }
    return '';
  }

  private closeMenu(): void {
    this.menuIndex = -1;
    this.menuTempIndex = -1;
  }

  private handleMenuAction(action: number): void {
    if (action === MENU_INSERT_NEXT) {
      this.insertAsNext(this.menuIndex);
    } else if (action === MENU_REMOVE) {
      this.removeAt(this.menuIndex);
    } else if (action === MENU_PLAY_TEMP) {
      this.playTempAt(this.menuTempIndex);
    } else if (action === MENU_REMOVE_TEMP) {
      this.removeTempAt(this.menuTempIndex);
    }
  }

  /**
   * 队列行下载：网络歌曲点下载图标，取可用音质里的首选并入下载队列。
   * 与歌单页/播放页下载逻辑一致（DownloadManager 内部对同曲同音质去重）。
   */
  private downloadSong(m: MusicInfo): void {
    const qs: Quality[] = availableDownloadQualities(m);
    const q: Quality = qs.length > 0 ? qs[0] : '128k';
    DownloadManager.getInstance().enqueue(m, q);
    userNotice().info('已加入下载队列：' + m.name);
  }

  private openMenu(i: number): void {
    if (this.curListId === null || i < 0 || i >= this.songs.length) {
      return;
    }
    this.menuIndex = i;
    this.menuTempIndex = -1;
  }

  // ------------------------------------------------------------------ 操作
  private playAt(i: number): void {
    if (this.curListId === null || i < 0 || i >= this.songs.length) {
      return;
    }
    this.controller.playList(this.curListId, i);
  }

  private insertAsNext(i: number): void {
    this.closeMenu();
    AppLog().info('[队列] 下一首播放 index=' + i.toString() + ' 列表=' + this.songs.length.toString());
    if (i < 0 || i >= this.songs.length) {
      return;
    }
    const m = this.songs[i];
    // 与当前曲同 id 时插队无意义
    if (m.id === this.curMusicId) {
      userNotice().warn('这首歌正在播放');
      return;
    }
    this.queue.addTempPlayList(m, true);
    AppLog().info('[队列] 已插入稍后播放，当前共 ' + this.state.tempPlayList.length.toString() + ' 首');
    userNotice().info('已插到下一首：' + m.name);
    this.refresh();
  }

  private removeAt(i: number): void {
    const listId = this.curListId;
    this.closeMenu();
    AppLog().info('[队列] 移除 index=' + i.toString() + ' 列表=' + this.songs.length.toString());
    if (listId === null || i < 0 || i >= this.songs.length) {
      return;
    }
    if (this.isCurrentIndex(i)) {
      userNotice().warn('不能移除正在播放的歌曲');
      return;
    }
    const target = this.songs[i];
    this.listManager.removeListMusics(listId, [target.id]);
    userNotice().info('已从队列移除：' + target.name);
    this.refresh();
  }

  private moveSong(from: number, to: number): void {
    const listId = this.curListId;
    if (listId === null || from === to || from < 0 || to < 0) {
      return;
    }
    this.listManager.moveListMusic(listId, from, to);
    this.refresh();
  }

  private playTempAt(i: number): void {
    this.closeMenu();
    const arr = this.state.tempPlayList.slice();
    if (i < 0 || i >= arr.length) {
      return;
    }
    // 把目标项顶到队首，再走标准「下一首」链路，语义与协议一致
    const item = arr.splice(i, 1)[0];
    arr.unshift(item);
    this.state.setTempPlayList(arr);
    this.controller.playNext(true);
    this.refresh();
  }

  private removeTempAt(i: number): void {
    this.closeMenu();
    if (i < 0 || i >= this.tempItems.length) {
      return;
    }
    const name = this.tempItems[i].musicInfo.name;
    this.queue.removeTempPlayList(i);
    userNotice().info('已移出稍后播放：' + name);
    this.refresh();
  }

  private clearTemp(): void {
    this.closeMenu();
    if (this.tempItems.length === 0) {
      userNotice().warn('稍后播放是空的');
      return;
    }
    this.queue.clearTempPlayList();
    userNotice().info('已清空稍后播放');
    this.refresh();
  }
}
