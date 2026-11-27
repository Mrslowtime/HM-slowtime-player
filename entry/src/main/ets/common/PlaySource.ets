/**
 * 播放源 —— M1 验证链路与 M2 完整播放器共用的底层抽象。
 * 在线歌曲（MusicInfo）与内置演示音频（Track）都先转成这个结构再交给 AVPlayer。
 */
export interface PlaySource {
  /** 在线地址；空串表示使用内置 rawfile */
  url: string;
  /** 内置 rawfile 文件名；空串表示在线播放 */
  rawFile: string;
  /** 已知时长（毫秒），0 表示由播放器解析 */
  durationMs: number;
}

/** 把 M2 的 MusicInfo 解析结果转成播放源（M2-D 音源接入后由 MusicSource 提供 url） */
export function makeOnlineSource(url: string): PlaySource {
  return { url, rawFile: '', durationMs: 0 };
}

/**
 * 空播放源：取链失败且没有可用的跨源结果时返回。
 * 软件不再内置任何音频文件，因此这里不指向任何 rawfile；
 * 上层看到 url 与 rawFile 都为空就直接停播并提示用户，绝不偷偷放别的歌。
 */
export function makeEmptySource(): PlaySource {
  return { url: '', rawFile: '', durationMs: 0 };
}
