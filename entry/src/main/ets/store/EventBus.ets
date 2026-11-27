/**
 * 全局事件总线 —— 按协议 的四条总线：
 * app_event / state_event / list_event / dislike_event（本协议）
 * ArkTS 严格模式下用显式 Map<string, Array<callback>>，不用 any / 动态索引签名。
 */
import { MusicInfo, PlayMusicInfo, PlayInfoState, ProgressState, LyricInfo } from '../model/MusicTypes';

export type EmptyCallback = () => void;
export type MusicInfoCallback = (info: MusicInfo) => void;
export type PlayMusicInfoCallback = (info: PlayMusicInfo) => void;
export type StringCallback = (value: string) => void;
export type NumberCallback = (value: number) => void;

/** 事件名常量（按 appEvent / stateEvent 的事件 key） */
export class AppEvents {
  static readonly PLAY: string = 'play';
  static readonly PAUSE: string = 'pause';
  static readonly STOP: string = 'stop';
  static readonly ERROR: string = 'error';
  static readonly PLAYER_PLAYING: string = 'playerPlaying';
  static readonly PLAYER_PAUSE: string = 'playerPause';
  static readonly PLAYER_ENDED: string = 'playerEnded';
  static readonly PLAYER_ERROR: string = 'playerError';
  static readonly PLAYER_LOADSTART: string = 'playerLoadstart';
  static readonly PLAYER_EMPTIED: string = 'playerEmptied';
  static readonly PLAYER_WAITING: string = 'playerWaiting';
  static readonly MUSIC_TOGGLED: string = 'musicToggled';
  static readonly PIC_UPDATED: string = 'picUpdated';
  static readonly LYRIC_UPDATED: string = 'lyricUpdated';
  static readonly MY_LIST_MUSIC_UPDATE: string = 'myListMusicUpdate';
  static readonly SET_PROGRESS: string = 'setProgress';
}

export class StateEvents {
  static readonly CONFIG_UPDATED: string = 'configUpdated';
  static readonly PLAY_MUSIC_INFO_CHANGED: string = 'playMusicInfoChanged';
  static readonly PLAY_INFO_CHANGED: string = 'playInfoChanged';
  static readonly PLAY_STATE_CHANGED: string = 'playStateChanged';
  static readonly PLAY_PROGRESS_CHANGED: string = 'playProgressChanged';
  static readonly PLAY_PLAYED_LIST_CHANGED: string = 'playPlayedListChanged';
  static readonly PLAY_TEMP_PLAY_LIST_CHANGED: string = 'playTempPlayListChanged';
  static readonly MYLIST_UPDATED: string = 'mylistUpdated';
  static readonly THEME_UPDATED: string = 'themeUpdated';
  static readonly LANGUAGE_CHANGED: string = 'languageChanged';
  /** 全局头部右侧操作区更新（由各模块激活时注册，Index 头部 ≡ 左侧渲染） */
  static readonly HEADER_ACTION_UPDATED: string = 'headerActionUpdated';
  /** 系统返回手势：子组件先关自己的浮层/弹窗，并把 uiBackConsumed 置 true */
  static readonly UI_BACK: string = 'uiBack';
  /** 自定义音源：打开管理弹窗 / 音源列表或启用状态变化 / 脚本请求显示更新提示 */
  static readonly CUSTOM_SOURCE_MANAGE: string = 'customSourceManage';
  static readonly CUSTOM_SOURCE_CHANGED: string = 'customSourceChanged';
  static readonly CUSTOM_SOURCE_UPDATE: string = 'customSourceUpdate';
  /** 打开「音源服务」弹窗（自定义源管理按钮下方入口，2026-11-17 用户要求） */
  static readonly SOURCE_SERVICE_OPEN: string = 'sourceServiceOpen';
  /** 本地音乐文件有变动（导出到指定文件夹、下载落地等）：本地页收到后静默重扫 */
  static readonly LOCAL_FILES_CHANGED: string = 'localFilesChanged';
}

export class ListEvents {
  static readonly LIST_DATA_OVERWRITE: string = 'list_data_overwrite';
  static readonly LIST_CREATE: string = 'list_create';
  static readonly LIST_REMOVE: string = 'list_remove';
  static readonly LIST_UPDATE: string = 'list_update';
  static readonly LIST_MUSIC_ADD: string = 'list_music_add';
  static readonly LIST_MUSIC_REMOVE: string = 'list_music_remove';
  static readonly LIST_MUSIC_CLEAR: string = 'list_music_clear';
  static readonly LIST_MUSIC_UPDATE: string = 'list_music_update';
}

/** 简单事件中心：on / off / emit */
export class EventHub {
  private listeners: Map<string, EmptyCallback[]> = new Map();

  on(event: string, cb: EmptyCallback): void {
    const arr = this.listeners.get(event);
    if (arr === undefined) {
      this.listeners.set(event, [cb]);
    } else {
      arr.push(cb);
    }
  }

  off(event: string, cb: EmptyCallback): void {
    const arr = this.listeners.get(event);
    if (arr === undefined) {
      return;
    }
    const idx = arr.indexOf(cb);
    if (idx >= 0) {
      arr.splice(idx, 1);
    }
  }

  /**
   * 移除某事件下的全部监听。
   * 供组件卸载时兜底清理匿名/临时订阅：匿名函数引用无法用 off() 反查，
   * 这类订阅可在 aboutToDisappear 中调用本方法一次性清空。
   * 注意：仅应在「该事件的订阅完全由当前组件独占」时使用，避免误删其他模块监听。
   */
  offAll(event: string): void {
    this.listeners.delete(event);
  }

  emit(event: string): void {
    const arr = this.listeners.get(event);
    if (arr === undefined) {
      return;
    }
    for (const cb of arr.slice()) {
      cb();
    }
  }

  clear(): void {
    this.listeners.clear();
  }
}

let sAppEvent: EventHub | null = null;
let sStateEvent: EventHub | null = null;
let sListEvent: EventHub | null = null;
let sDislikeEvent: EventHub | null = null;

/** 对应 global.app_event */
export function appEvent(): EventHub {
  if (sAppEvent === null) {
    sAppEvent = new EventHub();
  }
  return sAppEvent;
}

/** 对应 global.state_event */
export function stateEvent(): EventHub {
  if (sStateEvent === null) {
    sStateEvent = new EventHub();
  }
  return sStateEvent;
}

/** 对应 global.list_event */
export function listEvent(): EventHub {
  if (sListEvent === null) {
    sListEvent = new EventHub();
  }
  return sListEvent;
}

/** 对应 global.dislike_event */
export function dislikeEvent(): EventHub {
  if (sDislikeEvent === null) {
    sDislikeEvent = new EventHub();
  }
  return sDislikeEvent;
}
