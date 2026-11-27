/**
 * 用户可见提示的统一出口。
 *
 * 背景：core / player 层不持有 UI，过去的失败分支只写 hilog，用户看到的是「点了没反应」。
 * 这里把提示收敛成一个投递点：任何层调用 userNotice().warn/error，Index 订阅后用系统轻提示展示，
 * 同时写入 AppLog，保证「工具 → 运行日志」里能翻到，便于远程排查。
 */

import { AppLog } from './AppLog';

export enum NoticeLevel {
  Info = 0,
  Warn = 1,
  Error = 2,
}

export interface NoticeItem {
  text: string;
  level: NoticeLevel;
}

export type NoticeListener = (item: NoticeItem) => void;

/** 同一文案在该窗口内只提示一次，避免循环里的失败把屏幕刷满 */
const DEDUP_WINDOW_MS: number = 2000;

class UserNoticeImpl {
  private listeners: NoticeListener[] = [];
  private lastText: string = '';
  private lastAt: number = 0;

  info(text: string): void {
    this.push(text, NoticeLevel.Info);
  }

  warn(text: string): void {
    this.push(text, NoticeLevel.Warn);
  }

  error(text: string): void {
    this.push(text, NoticeLevel.Error);
  }

  private push(text: string, level: NoticeLevel): void {
    if (text.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (text === this.lastText && now - this.lastAt < DEDUP_WINDOW_MS) {
      return;
    }
    this.lastText = text;
    this.lastAt = now;
    if (level === NoticeLevel.Error) {
      AppLog().error('[提示] ' + text);
    } else if (level === NoticeLevel.Warn) {
      AppLog().warn('[提示] ' + text);
    } else {
      AppLog().info('[提示] ' + text);
    }
    const item: NoticeItem = { text: text, level: level };
    for (const l of this.listeners.slice()) {
      l(item);
    }
  }

  subscribe(l: NoticeListener): void {
    this.listeners.push(l);
  }

  unsubscribe(l: NoticeListener): void {
    const i: number = this.listeners.indexOf(l);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }
}

let sNotice: UserNoticeImpl | null = null;

export function userNotice(): UserNoticeImpl {
  if (sNotice === null) {
    sNotice = new UserNoticeImpl();
  }
  return sNotice;
}
