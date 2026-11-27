import { PlaySource } from './PlaySource';

/**
 * 曲目数据模型（M1 演示用）。
 * 继承 PlaySource，因此可直接传给 PlayerManager.load()，
 * 与 M2 的 MusicInfo 播放链路共用底层实现。
 */
export interface Track extends PlaySource {
  id: string;
  title: string;
  artist: string;
  album: string;
  /** 在线地址；为空串表示使用内置 rawfile */
  url: string;
  /** 内置 rawfile 文件名；为空串表示在线播放 */
  rawFile: string;
  /** 已知时长（毫秒），0 表示由播放器解析 */
  durationMs: number;
}

// 已移除 M1 遗留的 3 首内置验证曲目（DEMO_TRACKS）：
// 软件不再内置任何可播放的歌曲，也不内置任何兜底音频（demo.wav 已删除）；
// 取不到音源时只提示用户并停播。
