/**
 * 酷狗（kg）元数据 —— 独立实现 各平台音源模块。
 * 搜索/联想/热搜/榜单/歌词(lrc 分支)均为无签名接口；歌词用 base64 标准 LRC，
 * 无需独立实现 KRC 的 zlib+XOR 逐字解码（后置）。
 */
import {
  HttpClient, HttpResult, Json, decodeName, formatPlayTime,
  encodeQuery, secureUrl,
} from '../net/HttpClient';
import {
  MusicInfo, ListInfoItem, BoardItem, LyricInfo, MusicInfoMetaOnline, TagInfoItem,
} from '../../model/MusicTypes';
import { OnlineSource } from '../../config/AppConstants';
import { decodeKrc, decodeBase64Lrc } from '../crypto/LyricDecoders';
import {
  SourceApi, SearchResult, SonglistResult, MusicListResult, TagResult,
  emptySearchResult, emptySonglistResult, emptyMusicListResult, emptyTagResult, makeMusicInfo,
} from './ApiTypes';

const KG_LYRIC_HEADERS: Record<string, string> = {
  'KG-RC': '1',
  'KG-THash': 'expand_search_manager.cpp:852736169:451',
  'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
  'Referer': 'https://www.kugou.com/',
};

/** 酷狗官方歌单页 UA（该页 https 证书不受信，走 http 明文，见 HttpClient.secureUrl） */
const KG_WWW2_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (Linux; Android 10; HLK-AL00) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/104.0.5112.102 Mobile Safari/537.36',
  'Referer': 'http://www.kugou.com/',
};

const KG_HOT_HEADERS: Record<string, string> = {
  'dfid': '1ssiv93oVqMp27cirf2CvoF1',
  'mid': '156798703528610303473757548878786007104',
  'clienttime': '1584257267',
  'x-router': 'msearch.kugou.com',
  'user-agent': 'Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi',
  'kg-rc': '1',
};

/** "03:55" / "1:03:55" → 毫秒（KRC 检索需要 timelength） */
function intervalToMs(interval: string | null): number {
  if (interval === null || interval.length === 0) {
    return 0;
  }
  const parts: string[] = interval.split(':');
  let total: number = 0;
  for (const p of parts) {
    const n: number = parseInt(p, 10);
    total = total * 60 + (isNaN(n) ? 0 : n);
  }
  return total * 1000;
}

/**
 * 酷狗各音质专属 hash（按该服务协议 _types）。
 * 搜索结果字段：FileHash/HQFileHash/SQFileHash/ResFileHash
 * 榜单结果字段：hash/320hash/sqhash
 */
function qualityHashesFrom(item: Object): Map<string, string> {
  const m: Map<string, string> = new Map();
  const pairs: string[][] = [
    ['128k', Json.str(item, 'FileHash', '')],
    ['320k', Json.str(item, 'HQFileHash', '')],
    ['flac', Json.str(item, 'SQFileHash', '')],
    ['flac24bit', Json.str(item, 'ResFileHash', '')],
  ];
  if (pairs[0][1].length === 0) { pairs[0][1] = Json.str(item, 'hash', ''); }
  if (pairs[1][1].length === 0) { pairs[1][1] = Json.str(item, '320hash', ''); }
  if (pairs[2][1].length === 0) { pairs[2][1] = Json.str(item, 'sqhash', ''); }
  for (const p of pairs) {
    if (p[1].length > 0) { m.set(p[0], p[1]); }
  }
  return m;
}

function qualitysFromSizes(item: Object): string[] {
  const out: string[] = ['128k'];
  if (Json.num(item, 'HQFileSize', 0) > 0) { out.push('320k'); }
  if (Json.num(item, 'SQFileSize', 0) > 0) { out.push('flac'); }
  if (Json.num(item, 'ResFileSize', 0) > 0) { out.push('flac24bit'); }
  return out;
}

function singersFrom(item: Object): string {
  const arr: Object[] = Json.arr(item, 'Singers');
  const names: string[] = [];
  for (const s of arr) {
    const n: string = Json.str(s, 'name', '');
    if (n.length > 0) {
      names.push(n);
    }
  }
  if (names.length > 0) {
    return names.join('、');
  }
  return decodeName(Json.str(item, 'SingerName', ''));
}

function songFromSearch(item: Object): MusicInfo | null {
  const hash: string = Json.str(item, 'FileHash', '');
  const name: string = decodeName(Json.str(item, 'OriSongName', Json.str(item, 'SongName', '')));
  if (hash.length === 0 || name.length === 0) {
    return null;
  }
  const songId: string = Json.str(item, 'Audioid', hash);
  const dur: number = Json.num(item, 'Duration', 0);
  // 封面：搜索项用 Image / AlbumImage（含 {size} 占位符），与歌单详情同样替换为 240
  const coverRaw: string = Json.str(item, 'Image', Json.str(item, 'AlbumImage', ''));
  const cover: string = coverRaw.length > 0 ? coverRaw.replace('{size}', '240') : '';
  return makeMusicInfo('kg', songId,
    name + decodeName(Json.str(item, 'Suffix', '')),
    singersFrom(item),
    dur > 0 ? formatPlayTime(dur) : null,
    decodeName(Json.str(item, 'AlbumName', '')), cover.length > 0 ? cover : null,
    qualitysFromSizes(item),
    { hash, qualityHashes: qualityHashesFrom(item), albumId: Json.str(item, 'AlbumID', '') });
}

export class KgApi implements SourceApi {
  readonly source: OnlineSource = 'kg';

  /** 酷狗明确返回 429/403 后暂时不再抓大页面兜底，避免被限流时继续加码 */
  private detailCooldownUntil: number = 0;

  async search(keyword: string, page: number, limit: number): Promise<SearchResult> {
    const url: string = 'https://songsearch.kugou.com/song_search_v2?keyword=' + encodeQuery(keyword) +
      '&page=' + page.toString() + '&pagesize=' + limit.toString() +
      '&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1';
    const r: HttpResult = await HttpClient.get(url, KG_LYRIC_HEADERS, 1);
    if (!r.ok || r.json === null) {
      return emptySearchResult('kg', page, limit, '酷狗搜索失败：' + r.error);
    }
    const data: Object | null = Json.obj(r.json, 'data');
    const items: Object[] = Json.arr(data, 'lists');
    const list: MusicInfo[] = [];
    for (const it of items) {
      const m: MusicInfo | null = songFromSearch(it);
      if (m !== null) {
        list.push(m);
      }
    }
    return {
      list, total: Json.num(data, 'total', list.length), page, limit, source: 'kg', error: '',
    };
  }

  async tipSearch(keyword: string): Promise<string[]> {
    const url: string = 'https://searchtip.kugou.com/getSearchTip?MusicTipCount=10&keyword=' +
      encodeQuery(keyword);
    const j: Object | null = await HttpClient.getJson(url, {
      'referer': 'https://www.kugou.com/',
    });
    const body: Object[] = Json.arr(j, 'body');
    const out: string[] = [];
    if (body.length > 0) {
      const records: Object[] = Json.arr(body[0], 'RecordDatas');
      for (const r of records) {
        const h: string = decodeName(Json.str(r, 'HintInfo', ''));
        if (h.length > 0) {
          out.push(h);
        }
      }
    }
    return out;
  }

  async hotSearch(): Promise<string[]> {
    const url: string = 'https://gateway.kugou.com/api/v3/search/hot_tab' +
      '?signature=ee44edb9d7155821412d220bcaf509dd&appid=1005&clientver=10026&plat=0';
    const j: Object | null = await HttpClient.getJson(url, KG_HOT_HEADERS);
    const data: Object | null = Json.obj(j, 'data');
    const groups: Object[] = Json.arr(data, 'list');
    const out: string[] = [];
    for (const g of groups) {
      const kws: Object[] = Json.arr(g, 'keywords');
      for (const k of kws) {
        const w: string = decodeName(Json.str(k, 'keyword', ''));
        if (w.length > 0) {
          out.push(w);
        }
      }
    }
    return out;
  }

  async songListTags(): Promise<TagResult> {
    // 酷狗分类：getSpecial?is_smarty=1 一次返回 data.tagids（组名 → { data: [{id,name}] }）。
    // 旧代码硬编码 c=1..8，但那不是真实分类 id，点任何一个标签都只能拿到空列表
    // （实测 {"special_db":[]}），所以这里改为读真实分类表。
    const url: string = 'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1&cdn=cdn';
    const r: HttpResult = await HttpClient.get(url, { 'Referer': 'https://www.kugou.com/' }, 0, true);
    const tags: TagInfoItem[] = [{ id: '', name: '推荐' }];
    const tagids: Object | null = Json.obj(Json.obj(r.json, 'data'), 'tagids');
    if (tagids !== null) {
      const rec: Record<string, Object> = tagids as Record<string, Object>;
      for (const group of Object.keys(rec)) {
        const items: Object[] = Json.arr(rec[group], 'data');
        for (const it of items) {
          const id: string = Json.str(it, 'id', '');
          const name: string = decodeName(Json.str(it, 'name', ''));
          if (id.length === 0 || name.length === 0) {
            continue;
          }
          tags.push({ id, name });
        }
      }
    }
    return {
      tags,
      sorts: [
        { tid: 'hot', id: 'hot' },
        { tid: 'new', id: 'new' },
      ],
      source: 'kg',
      error: '',
    };
  }

  async songList(tagId: string, sortId: string, page: number, limit: number): Promise<SonglistResult> {
    // www2.kugou.kugou.com 的 https 证书不受系统信任（真机报 Invalid SSL peer certificate），
    // 该 host 已在 HttpClient.secureUrl 加入明文白名单；这里显式 http + allowHttp 双保险。
    // t 是排序（5 推荐 / 6 最热 / 7 最新），c 是真实分类 id（空为全部），p 是页码。
    const order: string = sortId === 'new' ? '7' : '6';
    const url: string = 'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn' +
      '&t=' + order + '&c=' + encodeQuery(tagId) + '&p=' + page.toString();
    const r: HttpResult = await HttpClient.get(url, {
      'Referer': 'https://www.kugou.com/',
    }, 0, true);
    if (!r.ok || r.json === null) {
      return emptySonglistResult('kg', page, limit, '酷狗歌单加载失败：' + (r.error.length > 0 ? r.error : '响应格式异常'));
    }
    const items: Object[] = Json.arr(r.json, 'special_db');
    const list: ListInfoItem[] = [];
    for (const it of items) {
      const id: string = Json.str(it, 'specialid', Json.str(it, 'id', ''));
      const name: string = decodeName(Json.str(it, 'specialname', Json.str(it, 'name', '')));
      if (id.length === 0 || name.length === 0) {
        continue;
      }
      list.push({
        id, name,
        play_count: Json.str(it, 'play_count', '0'),
        author: decodeName(Json.str(it, 'nickname', '')),
        time: Json.str(it, 'publish_time', ''),
        img: Json.str(it, 'img', ''),
        desc: decodeName(Json.str(it, 'intro', '')),
        source: 'kg',
        total: Json.num(it, 'song_count', 0),
      });
    }
    return { list, total: Json.num(r.json, 'total', list.length), page, limit, source: 'kg', error: '' };
  }

  /**
   * 歌单详情 —— 按该服务协议。
   * 官方页 www2.kugou.kugou.com/yueku/v9/special/single/<id>-5-9999.html 内嵌
   * `global.data = [...]` 一次给出整张歌单（实测 303 首，字段含 songname/singername/
   * duration/hash/hash_320/hash_flac/audio_id/trans_param.union_cover），无需二次 gateway 补全。
   * 该主机 https 证书不受系统信任，故走 http 明文（HttpClient.secureUrl 已开白名单）。
   * 若明文端点不可用，退回 m.kugou.com 的 ?json=true 拿前 10 首。
   */
  /**
   * 酷狗歌单歌曲（JSON 接口 special/song）。
   * 旧实现抓 yueku 歌单 HTML：894KB / 1.3s+，还要正则切 global.data，是「打开酷狗歌单卡」的主因。
   * 该接口 137KB / 0.5s，字段与榜单一致，pagesize=100 分页且 total 可靠（303 首可分 4 页取全）。
   * mobilecdnbj 的 https 在部分网络下握手失败，这里明文 http + allowHttp（与 www2 同样处理）。
   */
  private async specialSongs(sid: string, page: number): Promise<MusicListResult | null> {
    const url: string = 'http://mobilecdnbj.kugou.com/api/v3/special/song?version=9108&plat=0' +
      '&pagesize=100&page=' + page.toString() + '&specialid=' + encodeQuery(sid) + '&with_res_tag=0';
    const r: HttpResult = await HttpClient.get(url, { 'Referer': 'https://www.kugou.com/' }, 0, true);
    if (!r.ok || r.json === null) {
      if (r.statusCode === 429 || r.statusCode === 403) {
        this.detailCooldownUntil = Date.now() + 30000;
      }
      return null;
    }
    const data: Object | null = Json.obj(r.json, 'data');
    const items: Object[] = Json.arr(data, 'info');
    if (items.length === 0) {
      return null;
    }
    const list: MusicInfo[] = [];
    for (const it of items) {
      const hash: string = Json.str(it, 'hash', '');
      const audioId: string = Json.str(it, 'audio_id', hash);
      if (hash.length === 0) {
        continue;
      }
      // 该接口只给 filename（"歌手 - 歌名"），没有拆好的 songname/singername
      const filename: string = decodeName(Json.str(it, 'filename', ''));
      const sep: number = filename.indexOf(' - ');
      const singer: string = sep > 0 ? filename.substring(0, sep) : '';
      const songName: string = sep > 0 ? filename.substring(sep + 3) : filename;
      if (songName.length === 0) {
        continue;
      }
      const h320: string = Json.str(it, '320hash', '');
      const hflac: string = Json.str(it, 'sqhash', '');
      const qs: string[] = ['128k'];
      const qm: Map<string, string> = new Map();
      qm.set('128k', hash);
      if (h320.length > 0) { qs.push('320k'); qm.set('320k', h320); }
      if (hflac.length > 0) { qs.push('flac'); qm.set('flac', hflac); }
      const dur: number = Json.num(it, 'duration', 0);
      const tp: Object | null = Json.obj(it, 'trans_param');
      let cover: string = Json.str(tp, 'union_cover', '').replace('{size}', '240');
      if (cover.startsWith('http://')) {
        cover = 'https://' + cover.substring(7);
      }
      list.push(makeMusicInfo('kg', audioId, songName, singer,
        dur > 0 ? formatPlayTime(dur) : null, decodeName(Json.str(it, 'album_name', '')),
        cover.length > 0 ? cover : null, qs,
        { hash, qualityHashes: qm, albumId: Json.str(it, 'album_id', '') }));
    }
    if (list.length === 0) {
      return null;
    }
    return {
      list, total: Json.num(data, 'total', list.length), page, source: 'kg',
      name: '', desc: '', img: '', error: '',
    };
  }

  /**
   * 按关键词搜歌单（酷狗 mobilecdn search/special，零签名）。
   * imgurl 里带 {size} 占位，替换成 400 拿可用封面（不替换会拿到 404 链接）。
   */
  async searchPlaylists(keyword: string, page: number, limit: number): Promise<SonglistResult> {
    const url: string = 'http://mobilecdn.kugou.com/api/v3/search/special?format=json&keyword=' +
      encodeQuery(keyword) + '&page=' + page.toString() + '&pagesize=' + limit.toString();
    const r: HttpResult = await HttpClient.get(url, {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 12)',
    }, 0, true);
    if (!r.ok || r.json === null) {
      return emptySonglistResult('kg', page, limit, '酷狗歌单搜索失败：' + (r.error.length > 0 ? r.error : '响应格式异常'));
    }
    const data: Object | null = Json.obj(r.json, 'data');
    const items: Object[] = Json.arr(data, 'info');
    const list: ListInfoItem[] = [];
    for (const it of items) {
      const id: string = Json.str(it, 'specialid', '');
      const name: string = decodeName(Json.str(it, 'specialname', ''));
      if (id.length === 0 || name.length === 0) {
        continue;
      }
      const img: string = Json.str(it, 'imgurl', '').replace('{size}', '400');
      list.push({
        id, name,
        play_count: Json.str(it, 'playcount', '0'),
        author: decodeName(Json.str(it, 'nickname', '')),
        time: Json.str(it, 'publishtime', ''),
        img,
        desc: decodeName(Json.str(it, 'intro', '')),
        source: 'kg',
        total: Json.num(it, 'songcount', 0),
      });
    }
    return { list, total: Json.num(data, 'total', list.length), page, limit, source: 'kg', error: '' };
  }

  async songListDetail(id: string, page: number): Promise<MusicListResult> {
    if (Date.now() < this.detailCooldownUntil) {
      return emptyMusicListResult('kg', page, '酷狗歌单暂时限流，稍后再试');
    }
    let sid: string = id;
    if (sid.startsWith('id_')) {
      sid = sid.substring(3);
    }
    // 先走轻量 JSON 接口；失败（老歌单 / 接口变更）再退回抓 HTML 全量页
    const fast: MusicListResult | null = await this.specialSongs(sid, page);
    if (fast !== null) {
      return fast;
    }
    const url: string = 'http://www2.kugou.kugou.com/yueku/v9/special/single/' +
      sid + '-5-9999.html';
    const html: string = await HttpClient.getText(url, KG_WWW2_HEADERS);
    const list: MusicInfo[] = [];
    let name: string = '';
    let img: string = '';
    if (html.length > 0) {
      // `var global = {... name / pic ...}` 元信息块位于 HTML 约第 10KB 处
      const gp: number = html.indexOf('var global = {');
      const gs: number = gp >= 0 ? gp : 0;
      const head: string = html.substring(gs, Math.min(gs + 2000, html.length));
      const nm: RegExpMatchArray | null = head.match(/name:\s*"([^"]*)"/);
      if (nm !== null && nm.length > 1) {
        name = decodeName(nm[1]);
      }
      const pm: RegExpMatchArray | null = head.match(/pic:\s*"([^"]*)"/);
      if (pm !== null && pm.length > 1) {
        img = secureUrl(pm[1].replace('{size}', '240'));
      }
      const dm: RegExpMatchArray | null = html.match(/global\.data\s*=\s*(\[.+\]);/);
      if (dm !== null && dm.length > 1) {
        const arr: Object[] = Json.asArr(Json.parse(dm[1]));
        for (const it of arr) {
          const hash: string = Json.str(it, 'hash', '');
          if (hash.length === 0) {
            continue;
          }
          const h320: string = Json.str(it, 'hash_320', '');
          const hflac: string = Json.str(it, 'hash_flac', '');
          const qs: string[] = ['128k'];
          const qm: Map<string, string> = new Map();
          qm.set('128k', hash);
          if (h320.length > 0) { qs.push('320k'); qm.set('320k', h320); }
          if (hflac.length > 0) { qs.push('flac'); qm.set('flac', hflac); }
          const durMs: number = Json.num(it, 'duration', 0);
          const audioId: string = Json.str(it, 'audio_id', hash);
          const tp: Object | null = Json.obj(it, 'trans_param');
          let cover: string = Json.str(tp, 'union_cover', '').replace('{size}', '240');
          if (cover.startsWith('http://')) {
            cover = 'https://' + cover.substring(7);
          }
          list.push(makeMusicInfo('kg', audioId,
            decodeName(Json.str(it, 'songname', '')),
            decodeName(Json.str(it, 'singername', '')),
            durMs > 0 ? formatPlayTime(Math.floor(durMs / 1000)) : null,
            decodeName(Json.str(it, 'album_name', '')),
            cover.length > 0 ? cover : null, qs,
            { hash, qualityHashes: qm, albumId: Json.str(it, 'album_id', '') }));
        }
      }
    }
    if (list.length === 0) {
      return await this.songListDetailFallback(sid, page);
    }
    return { list, total: list.length, page, source: 'kg', name, desc: '', img, error: '' };
  }

  /** 备用端点：m.kugou.com 的 JSON 视图（固定返回前 10 首，字段为 filename 合并形式） */
  private async songListDetailFallback(id: string, page: number): Promise<MusicListResult> {
    const r: HttpResult = await HttpClient.get(
      'https://m.kugou.com/plist/list/' + id + '/?json=true', KG_WWW2_HEADERS, 1);
    if (!r.ok || r.json === null) {
      return emptyMusicListResult('kg', page, '酷狗歌单详情加载失败：全量端点与备用端点均不可用');
    }
    const outer: Object | null = Json.obj(r.json, 'list');
    const inner: Object | null = Json.obj(outer, 'list');
    const items: Object[] = Json.arr(inner, 'info');
    const list: MusicInfo[] = [];
    for (const it of items) {
      const hash: string = Json.str(it, 'hash', '');
      if (hash.length === 0) {
        continue;
      }
      const filename: string = decodeName(Json.str(it, 'filename', ''));
      const sep: number = filename.indexOf(' - ');
      const singer: string = sep > 0 ? filename.substring(0, sep) : '';
      const song: string = sep > 0 ? filename.substring(sep + 3) : filename;
      const h320: string = Json.str(it, '320hash', '');
      const hflac: string = Json.str(it, 'sqhash', '');
      const qs: string[] = ['128k'];
      const qm: Map<string, string> = new Map();
      qm.set('128k', hash);
      if (h320.length > 0) { qs.push('320k'); qm.set('320k', h320); }
      if (hflac.length > 0) { qs.push('flac'); qm.set('flac', hflac); }
      const dur: number = Json.num(it, 'duration', 0);
      const tp: Object | null = Json.obj(it, 'trans_param');
      let cover: string = Json.str(tp, 'union_cover', '').replace('{size}', '240');
      if (cover.startsWith('http://')) {
        cover = 'https://' + cover.substring(7);
      }
      list.push(makeMusicInfo('kg', Json.str(it, 'audio_id', hash), song, singer,
        dur > 0 ? formatPlayTime(dur) : null, '', cover.length > 0 ? cover : null, qs,
        { hash, qualityHashes: qm, albumId: Json.str(it, 'album_id', '') }));
    }
    return {
      list, total: Json.num(inner, 'total', list.length), page, source: 'kg',
      name: '', desc: '', img: '',
      error: list.length > 0 ? '' : '酷狗歌单详情无数据',
    };
  }

  leaderboardCategories(): BoardItem[] {
    // id/名称/封面均参考酷狗官方 rank/list 接口（实测）。
    // 旧表里 24971 写成「欧美金曲榜」、4681 写成「DJ热歌榜」是错的：
    // 官方 24971=DJ热歌榜、33166=欧美金曲榜，4681 根本不存在 → 榜单名与内容对不上。
    // 封面 URL 静态内置，不额外打接口；{size} 用 240，走 CoverImage 缓存。
    return [
      { id: 'kg_8888', name: 'TOP500', bangid: '8888',
        img: 'https://imge.kugou.com/mcommon/240/20241219/20241219164209670219.png' },
      { id: 'kg_6666', name: '飙升榜', bangid: '6666',
        img: 'https://imge.kugou.com/mcommon/240/20241219/20241219193628550054.png' },
      { id: 'kg_31308', name: '内地榜', bangid: '31308',
        img: 'https://imge.kugou.com/mcommon/240/20241211/20241211192146592398.png' },
      { id: 'kg_74534', name: '新歌榜', bangid: '74534',
        img: 'https://imge.kugou.com/mcommon/240/20241219/20241219200509300768.png' },
      { id: 'kg_24971', name: 'DJ热歌榜', bangid: '24971',
        img: 'https://imge.kugou.com/mcommon/240/20241219/20241219194419154116.png' },
      { id: 'kg_33166', name: '欧美金曲榜', bangid: '33166',
        img: 'https://imge.kugou.com/mcommon/240/20241211/20241211190352819248.jpg' },
      { id: 'kg_33165', name: '粤语金曲榜', bangid: '33165',
        img: 'https://imge.kugou.com/mcommon/240/20241219/20241219200119140556.png' },
      { id: 'kg_31310', name: '欧美榜', bangid: '31310',
        img: 'https://imge.kugou.com/mcommon/240/20241211/20241211192454699571.jpg' },
    ];
  }

  async leaderboardDetail(bangid: string, page: number): Promise<MusicListResult> {
    // mobilecdnbj.kugou.com 的 https 握手会失败（歌单详情 songListDetail 早已改 http），
    // 排行榜这里之前漏改，一直取不到数据。改回 http 并放行，请求次数不变。
    const url: string = 'http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=1' +
      '&plat=0&pagesize=100&area_code=1&page=' + page.toString() +
      '&rankid=' + encodeQuery(bangid) + '&with_res_tag=0&show_portrait_mv=1';
    const r: HttpResult = await HttpClient.get(url, { 'Referer': 'https://www.kugou.com/' }, 0, true);
    const j: Object | null = r.ok ? r.json : null;
    const data: Object | null = Json.obj(j, 'data');
    const items: Object[] = Json.arr(data, 'info');
    const list: MusicInfo[] = [];
    for (const it of items) {
      const hash: string = Json.str(it, 'hash', '');
      const name: string = decodeName(Json.str(it, 'songname', ''));
      if (hash.length === 0 || name.length === 0) {
        continue;
      }
      const authors: Object[] = Json.arr(it, 'authors');
      const names: string[] = [];
      for (const a of authors) {
        const n: string = Json.str(a, 'author_name', '');
        if (n.length > 0) { names.push(n); }
      }
      const dur: number = Json.num(it, 'duration', 0);
      const qs: string[] = ['128k'];
      if (Json.str(it, '320hash', '').length > 0) { qs.push('320k'); }
      if (Json.str(it, 'sqhash', '').length > 0) { qs.push('flac'); }
      list.push(makeMusicInfo('kg', Json.str(it, 'audio_id', hash), name,
        names.length > 0 ? names.join('、') : decodeName(Json.str(it, 'remark', '')),
        dur > 0 ? formatPlayTime(dur) : null,
        decodeName(Json.str(it, 'album_name', '')), null, qs,
        { hash, qualityHashes: qualityHashesFrom(it), albumId: Json.str(it, 'album_id', '') }));
    }
    return {
      list, total: Json.num(data, 'total', list.length), page, source: 'kg',
      name: '', desc: '', img: '', error: '',
    };
  }

  async getLyric(info: MusicInfo): Promise<LyricInfo | null> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    const hash: string = meta.hash ?? meta.songId;
    const timeMs: number = intervalToMs(info.interval);
    const url: string = 'https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=' +
      encodeQuery(info.name) + '&hash=' + encodeQuery(hash) + '&timelength=' +
      timeMs.toString() + '&lrctxt=1';
    const j: Object | null = await HttpClient.getJson(url, KG_LYRIC_HEADERS);
    const candidates: Object[] = Json.arr(j, 'candidates');
    if (candidates.length === 0) {
      return null;
    }
    const c: Object = candidates[0];
    const id: string = Json.str(c, 'id', '');
    const key: string = Json.str(c, 'accesskey', '');
    if (id.length === 0 || key.length === 0) {
      return null;
    }
    // 按该服务协议：krctype==1 且 contenttype!=1 时是 KRC 逐字歌词
    const isKrc: boolean = Json.num(c, 'krctype', 0) === 1 && Json.num(c, 'contenttype', 0) !== 1;
    const fmt: string = isKrc ? 'krc' : 'lrc';
    const dl: string = 'https://lyrics.kugou.com/download?ver=1&client=pc&id=' + encodeQuery(id) +
      '&accesskey=' + encodeQuery(key) + '&fmt=' + fmt + '&charset=utf8';
    const body: Object | null = await HttpClient.getJson(dl, KG_LYRIC_HEADERS);
    const content: string = Json.str(body, 'content', '');
    if (content.length === 0) {
      return null;
    }
    if (isKrc) {
      const krc: LyricInfo | null = await decodeKrc(content);
      if (krc !== null && krc.lyric.length > 0) {
        return krc;
      }
      // KRC 解码失败时回退请求 LRC
      const lrcUrl: string = dl.replace('fmt=krc', 'fmt=lrc');
      const lrcBody: Object | null = await HttpClient.getJson(lrcUrl, KG_LYRIC_HEADERS);
      return decodeBase64Lrc(Json.str(lrcBody, 'content', ''));
    }
    return decodeBase64Lrc(content);
  }

  async getPic(info: MusicInfo): Promise<string> {
    // 接口占位实现：恒定返回空串。
    // 协议用 POST get_res_privilege 换取封面，此处后置未实现；UI 会用占位图兜底。
    void info;
    return '';
  }
}
