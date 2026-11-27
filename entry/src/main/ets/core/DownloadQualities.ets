/**
 * 下载音质候选计算 —— 供歌单详情页 / 播放详情页 / 三点菜单共用。
 *
 * 规则（与歌单页原有实现一致）：取「歌曲自身支持的音质 ∩ 已启用音源服务支持的音质」，
 * 按高→低排序；交集为空时退回歌曲自身声明，最后兜底 128k，
 * 避免把服务根本不支持的音质列给用户（选了也会被 MusicUrlResolver 静默降级）。
 */
import { Quality } from '../config/AppConstants';
import { MusicInfo, MusicInfoMetaOnline } from '../model/MusicTypes';
import { SourceConfig } from './net/SourceConfig';

export function availableDownloadQualities(m: MusicInfo): Quality[] {
  const meta: MusicInfoMetaOnline = m.meta as MusicInfoMetaOnline;
  const songQs: Quality[] = [];
  if (meta !== null && meta !== undefined && meta.qualitys !== undefined && meta.qualitys !== null) {
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
