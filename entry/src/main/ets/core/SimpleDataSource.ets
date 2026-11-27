/**
 * 极简懒加载数据源（配合 LazyForEach）。
 *
 * 歌单广场原来是 Scroll + Column + ForEach：所有已上屏卡片全部构建并常驻，
 * 滑到几十张后每次状态变化都重建整棵行数组，越滑越卡。
 * 换成 List + LazyForEach 后只创建可视区 + cachedCount 范围内的 ListItem。
 */
export class SimpleDataSource<T> implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: T[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  /** 整体替换（切平台 / 切分类 / 首次加载） */
  setAll(next: T[]): void {
    this.items = next;
    this.notifyReload();
  }

  /** 追加一批（上屏新一屏卡片）。onDataAdd 必须逐项通知，否则 LazyForEach 只认新增 1 项 */
  append(next: T[]): void {
    if (next.length === 0) {
      return;
    }
    const start: number = this.items.length;
    for (let i: number = 0; i < next.length; i++) {
      this.items.push(next[i]);
      for (const l of this.listeners) {
        l.onDataAdd(start + i);
      }
    }
  }

  /** 原地更新某一项（只通知这一项，用于「尾行还没填满 3 张」的补齐） */
  setAt(index: number, value: T): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    this.items[index] = value;
    for (const l of this.listeners) {
      l.onDataChange(index);
    }
  }

  private notifyReload(): void {
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}
