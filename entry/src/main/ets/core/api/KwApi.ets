/**
 * 酷我（kw）元数据 —— 独立实现 各平台音源模块。
 * 全部为公开 GET JSON 接口，无签名；歌词改用源码注释里的纯 JSON 备用接口
 * （m.kuwo.cn/newh5/.../songinfoandlrc），避免独立实现 zlib inflate + XOR 解码。
 * 榜单详情在协议使用 wbd AES 加密接口，本轮后置（明确返回提示）。
 */
import { HttpClient, HttpResult, Json, decodeName, formatSinger, formatPlayTime, encodeQuery } from '../net/HttpClient';
import {
  MusicInfo, ListInfoItem, BoardItem, LyricInfo, MusicInfoMetaOnline, TagInfoItem,
} from '../../model/MusicTypes';
import { OnlineSource } from '../../config/AppConstants';
import { buildWbdParam, decodeWbdResponse, KW_BOARDS, KW_BOARD_IMGS } from '../crypto/KwWbdCrypto';
import {
  SourceApi, SearchResult, SonglistResult, MusicListResult, TagResult,
  emptySearchResult, emptySonglistResult, emptyMusicListResult, emptyTagResult, makeMusicInfo,
} from './ApiTypes';

const KW_DEFAULT_HEADERS: Record<string, string> = {
  'Referer': 'https://www.kuwo.cn/',
};

/** 从 N_MINFO 解析支持的音质（bitrate 4000/2000/320/128） */
function parseQualitys(nMinfo: string): string[] {
  const out: string[] = [];
  const lower: string = nMinfo.toLowerCase();
  // 协议按 order 反序输出，这里按从高到低
  if (lower.includes('bitrate:4000')) { out.push('flac24bit'); }
  if (lower.includes('bitrate:2000')) { out.push('flac'); }
  if (lower.includes('bitrate:320')) { out.push('320k'); }
  out.push('128k');
  return out;
}

function songFromAbs(item: Object): MusicInfo | null {
  const rid: string = Json.str(item, 'MUSICRID', '');
  const songId: string = rid.startsWith('MUSIC_') ? rid.substring(6) : rid;
  const name: string = decodeName(Json.str(item, 'SONGNAME', ''));
  if (songId.length === 0 || name.length === 0) {
    return null;
  }
  const singer: string = formatSinger(decodeName(Json.str(item, 'ARTIST', '')));
  const dur: number = Json.num(item, 'DURATION', 0);
  const qs: string[] = parseQualitys(Json.str(item, 'N_MINFO', ''));
  return makeMusicInfo('kw', songId, name, singer,
    dur > 0 ? formatPlayTime(dur) : null,
    decodeName(Json.str(item, 'ALBUM', '')), null, qs,
    { albumId: Json.str(item, 'ALBUMID', '') });
}

export class KwApi implements SourceApi {
  readonly source: OnlineSource = 'kw';

  async search(keyword: string, page: number, limit: number): Promise<SearchResult> {
    const url: string = 'https://search.kuwo.cn/r.s?client=kt&all=' + encodeQuery(keyword) +
      '&pn=' + (page - 1).toString() + '&rn=' + limit.toString() +
      '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1' +
      '&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    const r: HttpResult = await HttpClient.get(url, KW_DEFAULT_HEADERS, 2);
    if (!r.ok || r.json === null) {
      return emptySearchResult('kw', page, limit, '酷我搜索失败：' + r.error);
    }
    const items: Object[] = Json.arr(r.json, 'abslist');
    const list: MusicInfo[] = [];
    for (const it of items) {
      const m: MusicInfo | null = songFromAbs(it);
      if (m !== null) {
        list.push(m);
      }
    }
    const totalStr: string = Json.str(r.json, 'TOTAL', '0');
    const total: number = isNaN(Number(totalStr)) ? list.length : Number(totalStr);
    return { list, total, page, limit, source: 'kw', error: '' };
  }

  async tipSearch(keyword: string): Promise<string[]> {
    const url: string = 'https://tips.kuwo.cn/t.s?corp=kuwo&newver=3&p2p=1&notrace=0&c=mbox&w=' +
      encodeQuery(keyword) + '&encoding=utf8&rformat=json';
    const j: Object | null = await HttpClient.getJson(url, KW_DEFAULT_HEADERS);
    const items: Object[] = Json.arr(j, 'WORDITEMS');
    const out: string[] = [];
    for (const it of items) {
      const w: string = Json.str(it, 'RELWORD', '');
      if (w.length > 0) {
        out.push(decodeName(w));
      }
    }
    return out;
  }

  async hotSearch(): Promise<string[]> {
    const url: string = 'https://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo' +
      '&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0' +
      '&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1';
    const headers: Record<string, string> = {
      'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)',
    };
    const j: Object | null = await HttpClient.getJson(url, headers);
    const items: Object[] = Json.arr(j, 'tagvalue');
    const out: string[] = [];
    for (const it of items) {
      const k: string = Json.str(it, 'key', '');
      if (k.length > 0) {
        out.push(decodeName(k));
      }
    }
    return out;
  }

  async songListTags(): Promise<TagResult> {
    const url: string = 'https://wapi.kuwo.cn/api/pc/classify/playlist/getTagList' +
      '?cmd=rcm_keyword_playlist&user=0&prod=kwplayer_pc_9.0.5.0&vipver=9.0.5.0' +
      '&source=kwplayer_pc_9.0.5.0&loginUid=0&loginSid=0&appUid=76039576';
    const j: Object | null = await HttpClient.getJson(url);
    const groups: Object[] = Json.arr(j, 'data');
    const tags: TagInfoItem[] = [{ id: '', name: '推荐' }];
    for (const g of groups) {
      // 「专区」组是独立的专题入口，getTagPlayList 用它们的 id 查不到歌单（实测 total=0），
      // 放进来只会让用户点到空白页，直接跳过。
      if (Json.str(g, 'name', '') === '专区') {
        continue;
      }
      const children: Object[] = Json.arr(g, 'data');
      for (const c of children) {
        const id: string = Json.str(c, 'id', '');
        const name: string = decodeName(Json.str(c, 'name', ''));
        if (id.length > 0 && name.length > 0) {
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
      source: 'kw',
      error: '',
    };
  }

  async songList(tagId: string, sortId: string, page: number, limit: number): Promise<SonglistResult> {
    const base: string = 'https://wapi.kuwo.cn/api/pc/classify/playlist/';
    let url: string;
    if (tagId.length === 0) {
      url = base + 'getRcmPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=' +
        page.toString() + '&rn=' + limit.toString() + '&order=' + (sortId === 'new' ? 'new' : 'hot');
    } else {
      url = base + 'getTagPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=' +
        page.toString() + '&rn=' + limit.toString() + '&id=' + encodeQuery(tagId);
    }
    const j: Object | null = await HttpClient.getJson(url);
    const data: Object | null = Json.obj(j, 'data');
    const items: Object[] = Json.arr(data, 'data');
    const list: ListInfoItem[] = [];
    for (const it of items) {
      const id: string = Json.str(it, 'id', '');
      const name: string = decodeName(Json.str(it, 'name', ''));
      if (id.length === 0 || name.length === 0) {
        continue;
      }
      list.push({
        id, name,
        play_count: Json.str(it, 'playnum', '0'),
        author: decodeName(Json.str(it, 'uname', '')),
        time: Json.str(it, 'time', ''),
        // 推荐/标签歌单列表接口封面字段是 img（旧版误读 pic，导致三列网格全是占位图）
        img: Json.str(it, 'img', Json.str(it, 'pic', '')),
        desc: decodeName(Json.str(it, 'info', '')),
        source: 'kw',
        total: Json.num(it, 'total', 0),
      });
    }
    return { list, total: Json.num(data, 'total', list.length), page, limit, source: 'kw', error: '' };
  }

  /**
   * 按关键词搜歌单（酷我 ft=playlist，search.kuwo.cn 公开 JSON，零签名）。
   * abslist 里的 playlistid 与歌单详情接口 getlistinfo 的 pid 一致。
   */
  async searchPlaylists(keyword: string, page: number, limit: number): Promise<SonglistResult> {
    const url: string = 'https://search.kuwo.cn/r.s?client=kt&all=' + encodeQuery(keyword) +
      '&pn=' + (page - 1).toString() + '&rn=' + limit.toString() +
      '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1' +
      '&ft=playlist&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    const r: HttpResult = await HttpClient.get(url, KW_DEFAULT_HEADERS, 2);
    if (!r.ok || r.json === null) {
      return emptySonglistResult('kw', page, limit, '酷我歌单搜索失败：' + r.error);
    }
    const items: Object[] = Json.arr(r.json, 'abslist');
    const list: ListInfoItem[] = [];
    for (const it of items) {
      const id: string = Json.str(it, 'playlistid', Json.str(it, 'DC_TARGETID', ''));
      const name: string = decodeName(Json.str(it, 'name', ''));
      if (id.length === 0 || name.length === 0) {
        continue;
      }
      list.push({
        id, name,
        play_count: Json.str(it, 'playcnt', '0'),
        author: decodeName(Json.str(it, 'nickname', '')),
        time: '',
        // pic 是 240px 小图，hts_pic 是 700px 大图；搜索列表按封面网格尺寸取大图更清晰
        img: Json.str(it, 'hts_pic', Json.str(it, 'pic', '')),
        desc: decodeName(Json.str(it, 'intro', '')),
        source: 'kw',
        total: Json.num(it, 'songnum', 0),
      });
    }
    return { list, total: Json.num(r.json, 'TOTAL', list.length), page, limit, source: 'kw', error: '' };
  }

  async songListDetail(id: string, page: number): Promise<MusicListResult> {
    const url: string = 'https://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=' + encodeQuery(id) +
      '&pn=' + (page - 1).toString() + '&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo' +
      '&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1';
    const j: Object | null = await HttpClient.getJson(url);
    const items: Object[] = Json.arr(j, 'musiclist');
    const list: MusicInfo[] = [];
    for (const it of items) {
      const songId: string = Json.str(it, 'id', '');
      const name: string = decodeName(Json.str(it, 'name', ''));
      if (songId.length === 0 || name.length === 0) {
        continue;
      }
      const dur: number = Json.num(it, 'duration', 0);
      list.push(makeMusicInfo('kw', songId, name,
        formatSinger(decodeName(Json.str(it, 'artist', ''))),
        dur > 0 ? formatPlayTime(dur) : null,
        decodeName(Json.str(it, 'album', '')), null,
        parseQualitys(Json.str(it, 'N_MINFO', '')),
        { albumId: Json.str(it, 'albumid', '') }));
    }
    return {
      list, total: Json.num(j, 'total', list.length), page, source: 'kw',
      name: decodeName(Json.str(j, 'title', '')),
      desc: decodeName(Json.str(j, 'info', '')),
      img: Json.str(j, 'pic', ''),
      error: '',
    };
  }

  leaderboardCategories(): BoardItem[] {
    const out: BoardItem[] = [];
    for (const b of KW_BOARDS) {
      out.push({ id: 'kw__' + b[0], name: b[1], bangid: b[0], img: KW_BOARD_IMGS[b[0]] ?? '' });
    }
    return out;
  }

  async leaderboardDetail(bangid: string, page: number): Promise<MusicListResult> {
    // 按该服务协议：wbd.kuwo.cn AES-128-ECB 加密请求 + 加密响应
    const body: string = '{"uid":"","devId":"","sFrom":"kuwo_sdk","user_type":"AP",' +
      '"carSource":"kwplayercar_ar_6.0.1.0_apk_keluze.apk","id":"' + bangid +
      '","pn":' + (page - 1).toString() + ',"rn":100}';
    let query: string = '';
    try {
      query = await buildWbdParam(body);
    } catch (e) {
      return emptyMusicListResult('kw', page, '酷我榜单加密失败');
    }
    const url: string = 'https://wbd.kuwo.cn/api/bd/bang/bang_info?' + query;
    const raw: string = await HttpClient.getText(url, KW_DEFAULT_HEADERS);
    const j: Object | null = await decodeWbdResponse(raw);
    if (j === null) {
      return emptyMusicListResult('kw', page, '酷我榜单响应解密失败');
    }
    const data: Object | null = Json.obj(j, 'data');
    const items: Object[] = Json.arr(data, 'musiclist');
    const list: MusicInfo[] = [];
    for (const it of items) {
      const songId: string = Json.str(it, 'id', '');
      const name: string = decodeName(Json.str(it, 'name', ''));
      if (songId.length === 0 || name.length === 0) {
        continue;
      }
      const dur: number = Json.num(it, 'duration', 0);
      const minfo: string = Json.str(it, 'nMinfo', '') + ';' + Json.str(it, 'minfo', '');
      list.push(makeMusicInfo('kw', songId, name,
        formatSinger(decodeName(Json.str(it, 'artist', ''))),
        dur > 0 ? formatPlayTime(dur) : null,
        decodeName(Json.str(it, 'album', '')),
        Json.str(it, 'pic', ''), parseQualitys(minfo),
        { albumId: Json.str(it, 'albumId', '') }));
    }
    return {
      list, total: Json.num(data, 'total', list.length), page, source: 'kw',
      name: decodeName(Json.str(data, 'name', '')),
      desc: '', img: Json.str(data, 'pic', ''), error: '',
    };
  }

  async getLyric(info: MusicInfo): Promise<LyricInfo | null> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    const url: string = 'https://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=' + encodeQuery(meta.songId);
    const j: Object | null = await HttpClient.getJson(url);
    const data: Object | null = Json.obj(j, 'data');
    const lines: Object[] = Json.arr(data, 'lrclist');
    if (lines.length === 0) {
      return null;
    }
    let lrc: string = '';
    for (const line of lines) {
      const t: number = Json.num(line, 'time', -1);
      const text: string = Json.str(line, 'lineLyric', '');
      if (t < 0 || text.length === 0) {
        continue;
      }
      const m: number = Math.floor(t / 60);
      const s: number = t - m * 60;
      const mm: string = (m < 10 ? '0' : '') + m.toString();
      const ss: string = s.toFixed(2);
      // 用格式化后的字符串判断补零：s=9.996 时 toFixed(2) 会得到 "10.00"，
      // 若仍按 s<10 补零会拼出 [mm:010.00]（进位边界多出一位）。
      const ssp: string = parseInt(ss) < 10 ? '0' + ss : ss;
      lrc += '[' + mm + ':' + ssp + ']' + text + '\n';
    }
    if (lrc.length === 0) {
      return null;
    }
    return { lyric: lrc, tlyric: null, rlyric: null, lxlyric: null };
  }

  async getPic(info: MusicInfo): Promise<string> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    const url: string = 'https://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic' +
      '&pictype=500&size=500&rid=' + encodeQuery(meta.songId);
    const text: string = (await HttpClient.getText(url)).trim();
    return text.startsWith('http') ? text : '';
  }
}
