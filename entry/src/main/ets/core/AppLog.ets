/**
 * 共享运行日志环形缓冲 —— 替代原先散落在 Index 抽屉里的局部 logs 数组。
 * 任何组件都能写入与读取，方便「设置 → 运行日志」集中查看。
 * 纯内存、上限固定，不落盘（避免无谓 IO；如需持久可后续扩展）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

const MAX_LINES: number = 300;

export type LogListener = (lines: string[]) => void;

class AppLogImpl {
  private buffer: string[] = [];
  private listeners: LogListener[] = [];

  log(msg: string): void {
    const line: string = '[' + this.stamp() + '] ' + msg;
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
    this.buffer.push(line);
    if (this.buffer.length > MAX_LINES) {
      this.buffer = this.buffer.slice(this.buffer.length - MAX_LINES);
    }
    const snap = this.buffer.slice();
    for (const l of this.listeners) {
      l(snap);
    }
  }

  /** 分类日志：info/warn/error 仅影响 hilog 级别，文本统一入缓冲 */
  info(msg: string): void { this.log(msg); }
  warn(msg: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
    this.pushRaw('[WARN ' + this.stamp() + '] ' + msg);
  }
  error(msg: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', msg);
    this.pushRaw('[ERR ' + this.stamp() + '] ' + msg);
  }

  private pushRaw(line: string): void {
    this.buffer.push(line);
    if (this.buffer.length > MAX_LINES) {
      this.buffer = this.buffer.slice(this.buffer.length - MAX_LINES);
    }
    const snap = this.buffer.slice();
    for (const l of this.listeners) {
      l(snap);
    }
  }

  getAll(): string[] {
    return this.buffer.slice();
  }

  clear(): void {
    this.buffer = [];
    const snap = this.buffer.slice();
    for (const l of this.listeners) {
      l(snap);
    }
  }

  subscribe(l: LogListener): void {
    this.listeners.push(l);
  }

  unsubscribe(l: LogListener): void {
    const i = this.listeners.indexOf(l);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  private stamp(): string {
    const d = new Date();
    const p = (n: number): string => (n < 10 ? '0' : '') + n.toString();
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
}

let sLog: AppLogImpl | null = null;

export function AppLog(): AppLogImpl {
  if (sLog === null) {
    sLog = new AppLogImpl();
  }
  return sLog;
}
