/**
 * 崩溃兜底 —— 让「闪退」留下可读的痕迹。
 *
 * 三件事：
 * 1. 注册 errorManager 观察者，捕获未处理异常 / 未处理的 Promise 拒绝；
 * 2. 把崩溃栈写入 AppLog（抽屉「运行日志」可见）并落盘到沙箱 crash.log，进程被杀也不丢；
 * 3. 用 last_run.marker 判断上次是否正常回收，下次启动时把结论说出来。
 *
 * 落盘内容只留在应用沙箱内，不上传、不涉及任何用户数据。
 */

import { common, errorManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLog } from './AppLog';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

const CRASH_FILE: string = '/crash.log';
const RUN_MARK: string = '/last_run.marker';
/** 崩溃日志超过这个体量就清空重写，避免无限增长 */
const MAX_CRASH_BYTES: number = 32768;
/** 启动时回放的崩溃条数上限 */
const REPLAY_LINES: number = 8;

/** errorManager.ErrorObserver 在 SDK 里是 class 声明，ArkTS 不允许 implements，用字面量实现 */
const JS_ERROR_OBSERVER: errorManager.ErrorObserver = {
  onUnhandledException: (errMsg: string): void => {
    CrashGuard.record('未捕获异常', errMsg);
  },
  onException: (errObject: Error): void => {
    CrashGuard.record('JS 异常', errObject.message);
  },
};

export class CrashGuard {
  private static dir: string = '';
  private static installed: boolean = false;

  /** 在 EntryAbility.onCreate 里调用一次 */
  static install(ctx: common.UIAbilityContext): void {
    if (CrashGuard.installed) {
      return;
    }
    CrashGuard.installed = true;
    CrashGuard.dir = ctx.filesDir;

    try {
      errorManager.on('error', JS_ERROR_OBSERVER);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'install error observer failed: %{public}s', (e as Error).message);
    }
    try {
      errorManager.on('unhandledRejection', (reason: Error, _promise: Promise<Object>): void => {
        const msg: string = (reason !== undefined && reason !== null && reason.message !== undefined)
          ? reason.message : '未知原因';
        CrashGuard.record('未处理的 Promise 拒绝', msg);
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'install rejection observer failed: %{public}s', (e as Error).message);
    }

    CrashGuard.reportLastRun();
    CrashGuard.replayHistory();
    CrashGuard.writeMarker('foreground');
  }

  /** 前台恢复：刷新标记，用于区分「后台被系统回收」和「前台闪退」 */
  static markForeground(): void {
    CrashGuard.writeMarker('foreground');
  }

  /** 退到后台：刷新标记 */
  static markBackground(): void {
    CrashGuard.writeMarker('background');
  }

  /** 正常销毁：抹掉标记，下次启动不会再报「上次异常退出」 */
  static markCleanExit(): void {
    if (CrashGuard.dir.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(CrashGuard.dir + RUN_MARK)) {
        fileIo.unlinkSync(CrashGuard.dir + RUN_MARK);
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'clear marker failed: %{public}s', (e as Error).message);
    }
  }

  /** 记录一条崩溃/异常：进内存缓冲 + 落盘 */
  static record(kind: string, detail: string): void {
    const line: string = '[' + CrashGuard.stamp() + '] ' + kind + '：' + detail;
    AppLog().error(line);
    CrashGuard.appendToFile(line);
  }

  // ------------------------------------------------------------------ 内部

  private static writeMarker(state: string): void {
    if (CrashGuard.dir.length === 0) {
      return;
    }
    const text: string = '{"state":"' + state + '","at":"' + CrashGuard.stamp() + '"}';
    const path: string = CrashGuard.dir + RUN_MARK;
    let f: fileIo.File | null = null;
    try {
      f = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'write marker failed: %{public}s', (e as Error).message);
    } finally {
      if (f !== null) {
        try {
          fileIo.closeSync(f);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /** 上次没留下「正常退出」的收尾，就把结论告诉用户 */
  private static reportLastRun(): void {
    const path: string = CrashGuard.dir + RUN_MARK;
    let existed: boolean = false;
    try {
      existed = fileIo.accessSync(path);
    } catch (e) {
      existed = false;
    }
    if (!existed) {
      return;
    }
    let content: string = '';
    try {
      content = fileIo.readTextSync(path);
    } catch (e) {
      content = '';
    }
    if (content.indexOf('"state":"background"') >= 0) {
      AppLog().warn('上次运行在后台结束（可能被系统回收），非前台闪退');
    } else {
      AppLog().error('上次运行未正常结束，疑似闪退；最后记录见下方（含时间戳）');
    }
  }

  /** 把落盘的崩溃记录回放进内存缓冲，用户不连电脑也能看到 */
  private static replayHistory(): void {
    const path: string = CrashGuard.dir + CRASH_FILE;
    let text: string = '';
    try {
      if (!fileIo.accessSync(path)) {
        return;
      }
      text = fileIo.readTextSync(path);
    } catch (e) {
      return;
    }
    if (text.length === 0) {
      return;
    }
    const all: string[] = text.split('\n').filter((s: string): boolean => s.length > 0);
    const start: number = all.length > REPLAY_LINES ? all.length - REPLAY_LINES : 0;
    AppLog().warn('—— 历史崩溃记录（最近 ' + (all.length - start).toString() + ' 条）——');
    for (let i = start; i < all.length; i++) {
      AppLog().error(all[i]);
    }
  }

  private static appendToFile(line: string): void {
    if (CrashGuard.dir.length === 0) {
      return;
    }
    const path: string = CrashGuard.dir + CRASH_FILE;
    let f: fileIo.File | null = null;
    try {
      if (fileIo.accessSync(path)) {
        const size: number = fileIo.statSync(path).size;
        if (size > MAX_CRASH_BYTES) {
          fileIo.unlinkSync(path);
        }
      }
      f = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(f.fd, line + '\n');
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'append crash log failed: %{public}s', (e as Error).message);
    } finally {
      if (f !== null) {
        try {
          fileIo.closeSync(f);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  private static stamp(): string {
    const d: Date = new Date();
    const p: (n: number) => string = (n: number): string => (n < 10 ? '0' : '') + n.toString();
    return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
      p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
}
