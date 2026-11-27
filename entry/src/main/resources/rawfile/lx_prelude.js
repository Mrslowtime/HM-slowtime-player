/**
 * lx-music 自定义音源协议 · 鸿蒙 WebView 沙箱注入层（prelude）
 *
 * 这一层原样复刻 lx-music-desktop / lx-music-mobile 注入给音源脚本的 globalThis.lx：
 *   - 全局脚本（无 require / module / exports），靠 lx.EVENT_NAMES + lx.on / lx.send 收发消息
 *   - 唯一网络出口是 lx.request(url, options, callback)，由 ArkTS 宿主代发 HTTP
 *   - on(EVENT_NAMES.request) 注册的处理器返回 Promise，resolve 值即播放直链
 *   - send(EVENT_NAMES.inited, {sources}) 上报支持的音源与音质
 *   - send(EVENT_NAMES.updateAlert, {log, updateUrl}) 请求宿主显示更新提示
 *
 * 宿主（ArkTS）通过 javaScriptProxy 注入 __lxHost.post(action, jsonString)，
 * 并通过 runJavaScript('__lxDispatch(action, jsonString)') 把响应送回本层。
 * 消息表见 docs/自定义音源编写指南.md。
 *
 * 本文件同时可被 Node.js 直接加载做协议回归测试（node tools/test_lx_prelude.js）。
 */
(function (root) {
  'use strict';

  var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' };
  var eventNames = ['request', 'inited', 'updateAlert'];

  var events = { request: null };
  var isInited = false;
  var isShowedUpdateAlert = false;
  var httpCallbacks = {};
  var consoleSeq = 0;

  function post(action, data) {
    try {
      root.__lxHost.post(action, JSON.stringify(data === undefined ? {} : data));
    } catch (e) {
      // 宿主桥不可用时脚本仍能初始化，取链会由宿主超时兜底
    }
  }

  function logToHost(text) {
    try {
      root.__lxHost.log(String(text).substring(0, 500));
    } catch (e) { /* ignore */ }
  }

  // ---------------------------------------------------------------- utils
  function utf8Encode(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
        var c2 = s.charCodeAt(++i);
        var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      } else {
        out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
    }
    return out;
  }

  function utf8Decode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length;) {
      var b = bytes[i++];
      if (b < 0x80) { out += String.fromCharCode(b); continue; }
      var cp = 0, need = 0;
      if ((b & 0xe0) === 0xc0) { cp = b & 0x1f; need = 1; }
      else if ((b & 0xf0) === 0xe0) { cp = b & 0x0f; need = 2; }
      else if ((b & 0xf8) === 0xf0) { cp = b & 0x07; need = 3; }
      else { out += String.fromCharCode(b); continue; }
      for (var k = 0; k < need && i < bytes.length; k++) { cp = (cp << 6) | (bytes[i++] & 0x3f); }
      if (cp > 0xffff) {
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      } else {
        out += String.fromCharCode(cp);
      }
    }
    return out;
  }

  function toBytes(v) {
    if (v === null || v === undefined) { return new Uint8Array(0); }
    // NodeBuffer 实例（鸭子类型判断 _b，定义在后面但函数声明已提升）
    if (v._b instanceof Uint8Array) { return new Uint8Array(v._b); }
    if (v instanceof Uint8Array) { return new Uint8Array(v); }
    if (Array.isArray(v)) { return new Uint8Array(v); }
    if (typeof v === 'string') { return new Uint8Array(utf8Encode(v)); }
    if (v.buffer instanceof ArrayBuffer) { return new Uint8Array(v.buffer); }
    return new Uint8Array(0);
  }

  function b64Encode(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) { s += String.fromCharCode(bytes[i]); }
    return root.btoa(s);
  }

  function b64Decode(str) {
    var s = root.atob(String(str).replace(/\s/g, ''));
    var out = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) { out[i] = s.charCodeAt(i); }
    return out;
  }

  function hexOf(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) {
      var h = bytes[i].toString(16);
      s += h.length < 2 ? '0' + h : h;
    }
    return s;
  }

  function bufferFrom(input, enc) {
    if (typeof input === 'string') {
      var fmt = (enc || 'utf8').toLowerCase();
      if (fmt === 'base64') { return b64Decode(input); }
      if (fmt === 'hex') {
        var t = input.replace(/[^0-9a-fA-F]/g, '');
        if (t.length % 2 !== 0) { t = t.substring(0, t.length - 1); }
        var out = new Uint8Array(t.length / 2);
        for (var i = 0; i < out.length; i++) { out[i] = parseInt(t.substring(i * 2, i * 2 + 2), 16); }
        return out;
      }
      return new Uint8Array(utf8Encode(input));
    }
    return toBytes(input);
  }

  function bufToString(buf, format) {
    var b = toBytes(buf);
    var fmt = (format || 'utf8').toLowerCase();
    if (fmt === 'hex') { return hexOf(b); }
    if (fmt === 'base64') { return b64Encode(b); }
    if (fmt === 'binary' || fmt === 'latin1') {
      var s = '';
      for (var i = 0; i < b.length; i++) { s += String.fromCharCode(b[i]); }
      return s;
    }
    return utf8Decode(b);
  }

  // ---------------------------------------------------------------- MD5
  /** 计算任意字节数组的 MD5，返回 16 字节 Uint8Array（HMAC 等二进制场景用） */
  function md5Bytes(inputBytes) {
    var bytes = Array.prototype.slice.call(inputBytes);
    var bitLen = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) { bytes.push(0); }
    var lo = bitLen >>> 0;
    var hi = Math.floor(bitLen / 4294967296) >>> 0;
    bytes.push(lo & 255, (lo >>> 8) & 255, (lo >>> 16) & 255, (lo >>> 24) & 255);
    bytes.push(hi & 255, (hi >>> 8) & 255, (hi >>> 16) & 255, (hi >>> 24) & 255);
    var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    var K = new Array(64);
    for (var t = 0; t < 64; t++) { K[t] = Math.floor(Math.abs(Math.sin(t + 1)) * 4294967296) >>> 0; }
    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    function rotl(x, n) { return ((x << n) | (x >>> (32 - n))) >>> 0; }
    function wordLE(o) { return (bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16) | (bytes[o + 3] << 24)) >>> 0; }
    for (var off = 0; off < bytes.length; off += 64) {
      var M = new Array(16);
      for (var j = 0; j < 16; j++) { M[j] = wordLE(off + j * 4); }
      var A = a0, B = b0, C = c0, D = d0;
      for (var i = 0; i < 64; i++) {
        var F = 0, g = 0;
        if (i < 16) { F = (B & C) | (~B & D); g = i; }
        else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
        else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
        else { F = C ^ (B | ~D); g = (7 * i) % 16; }
        F = (F + A + K[i] + M[g]) >>> 0;
        A = D; D = C; C = B;
        B = (B + rotl(F, S[i])) >>> 0;
      }
      a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
    }
    var words = new Uint8Array(16);
    var ws = [a0, b0, c0, d0];
    for (var wi = 0; wi < 4; wi++) {
      for (var k2 = 0; k2 < 4; k2++) { words[wi * 4 + k2] = (ws[wi] >>> (k2 * 8)) & 255; }
    }
    return words;
  }
  function md5Hex(input) {
    return hexOf(md5Bytes(new Uint8Array(utf8Encode(String(input)))));
  }

  // ---------------------------------------------------------------- AES-128
  var SBOX = null;
  function buildSbox() {
    var p = 1, q = 1, box = new Uint8Array(256);
    function rotl8(v, n) { return ((v << n) | (v >>> (8 - n))) & 255; }
    do {
      p = (p ^ ((p << 1) & 255) ^ (p & 0x80 ? 0x1b : 0)) & 255;
      q ^= (q << 1) & 255; q ^= (q << 2) & 255; q ^= (q << 4) & 255; q &= 255;
      if (q & 0x80) { q ^= 0x09; }
      var x = (q ^ rotl8(q, 1) ^ rotl8(q, 2) ^ rotl8(q, 3) ^ rotl8(q, 4) ^ 0x63) & 255;
      box[p] = x;
    } while (p !== 1);
    box[0] = 0x63;
    return box;
  }
  function sbox() { if (SBOX === null) { SBOX = buildSbox(); } return SBOX; }

  function xtime(x) { return ((x << 1) ^ (x & 0x80 ? 0x1b : 0)) & 255; }

  function expandKey128(key) {
    var w = [];
    var rcon = 1;
    for (var i = 0; i < 4; i++) { w.push([key[i * 4], key[i * 4 + 1], key[i * 4 + 2], key[i * 4 + 3]]); }
    for (var j = 4; j < 44; j++) {
      var t = w[j - 1].slice();
      if (j % 4 === 0) {
        t = [t[1], t[2], t[3], t[0]];
        var s = sbox();
        t = [s[t[0]], s[t[1]], s[t[2]], s[t[3]]];
        t[0] ^= rcon;
        rcon = xtime(rcon);
      }
      w.push([w[j - 4][0] ^ t[0], w[j - 4][1] ^ t[1], w[j - 4][2] ^ t[2], w[j - 4][3] ^ t[3]]);
    }
    return w;
  }

  function aesEncryptBlock(block, w) {
    var s = sbox();
    var st = [];
    for (var c = 0; c < 4; c++) { st.push([block[c * 4], block[c * 4 + 1], block[c * 4 + 2], block[c * 4 + 3]]); }
    function addRoundKey(r) {
      for (var c2 = 0; c2 < 4; c2++) {
        for (var r2 = 0; r2 < 4; r2++) { st[c2][r2] ^= w[r * 4 + c2][r2]; }
      }
    }
    addRoundKey(0);
    for (var round = 1; round <= 10; round++) {
      for (var c3 = 0; c3 < 4; c3++) {
        for (var r3 = 0; r3 < 4; r3++) { st[c3][r3] = s[st[c3][r3]]; }
      }
      for (var r4 = 1; r4 < 4; r4++) {
        var tmp = [st[0][r4], st[1][r4], st[2][r4], st[3][r4]];
        for (var c4 = 0; c4 < 4; c4++) { st[c4][r4] = tmp[(c4 + r4) % 4]; }
      }
      if (round !== 10) {
        for (var c5 = 0; c5 < 4; c5++) {
          var a = st[c5][0], b = st[c5][1], d = st[c5][2], e = st[c5][3];
          var all = a ^ b ^ d ^ e;
          st[c5][0] = a ^ all ^ xtime(a ^ b);
          st[c5][1] = b ^ all ^ xtime(b ^ d);
          st[c5][2] = d ^ all ^ xtime(d ^ e);
          st[c5][3] = e ^ all ^ xtime(e ^ a);
        }
      }
      addRoundKey(round);
    }
    var out = new Uint8Array(16);
    for (var c6 = 0; c6 < 4; c6++) {
      for (var r5 = 0; r5 < 4; r5++) { out[c6 * 4 + r5] = st[c6][r5]; }
    }
    return out;
  }

  function aesEncrypt(data, mode, keyBytes, ivBytes) {
    var key = new Uint8Array(16);
    key.set(toBytes(keyBytes).subarray(0, 16));
    var w = expandKey128(key);
    var input = toBytes(data);
    var pad = 16 - (input.length % 16);
    var padded = new Uint8Array(input.length + pad);
    padded.set(input);
    for (var i = input.length; i < padded.length; i++) { padded[i] = pad; }
    var out = new Uint8Array(padded.length);
    var iv = new Uint8Array(16);
    var isCbc = String(mode || '').toLowerCase().indexOf('cbc') >= 0;
    if (isCbc) { iv.set(toBytes(ivBytes).subarray(0, 16)); }
    for (var off = 0; off < padded.length; off += 16) {
      var block = padded.subarray(off, off + 16);
      if (isCbc) {
        var mixed = new Uint8Array(16);
        for (var k = 0; k < 16; k++) { mixed[k] = block[k] ^ iv[k]; }
        block = mixed;
      }
      var enc = aesEncryptBlock(block, w);
      out.set(enc, off);
      if (isCbc) { iv = enc; }
    }
    return out;
  }

  // ---- AES 解密（AES-128 CBC/ECB，对称补齐 createDecipheriv）----
  var INV_SBOX = null;
  function invSbox() {
    if (INV_SBOX !== null) { return INV_SBOX; }
    var s = sbox(); var inv = new Uint8Array(256);
    for (var i = 0; i < 256; i++) { inv[s[i]] = i; }
    INV_SBOX = inv; return inv;
  }
  function gmul(a, b) {
    var p = 0;
    for (var i = 0; i < 8; i++) {
      if (b & 1) { p ^= a; }
      var hi = a & 0x80; a = (a << 1) & 255;
      if (hi) { a ^= 0x1b; }
      b >>= 1;
    }
    return p;
  }
  function aesDecryptBlock(block, w) {
    var inv = invSbox();
    var st = [];
    for (var c = 0; c < 4; c++) { st.push([block[c * 4], block[c * 4 + 1], block[c * 4 + 2], block[c * 4 + 3]]); }
    function addRoundKey(r) {
      for (var c2 = 0; c2 < 4; c2++) { for (var r2 = 0; r2 < 4; r2++) { st[c2][r2] ^= w[r * 4 + c2][r2]; } }
    }
    addRoundKey(10);
    for (var round = 9; round >= 1; round--) {
      for (var rs = 1; rs < 4; rs++) {
        var tmp = [st[0][rs], st[1][rs], st[2][rs], st[3][rs]];
        for (var cs = 0; cs < 4; cs++) { st[cs][rs] = tmp[(cs - rs + 4) % 4]; }
      }
      for (var ci = 0; ci < 4; ci++) { for (var ri = 0; ri < 4; ri++) { st[ci][ri] = inv[st[ci][ri]]; } }
      addRoundKey(round);
      for (var cm = 0; cm < 4; cm++) {
        var a0 = st[cm][0], a1 = st[cm][1], a2 = st[cm][2], a3 = st[cm][3];
        st[cm][0] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
        st[cm][1] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
        st[cm][2] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
        st[cm][3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
      }
    }
    for (var rf = 1; rf < 4; rf++) {
      var tmp2 = [st[0][rf], st[1][rf], st[2][rf], st[3][rf]];
      for (var cf = 0; cf < 4; cf++) { st[cf][rf] = tmp2[(cf - rf + 4) % 4]; }
    }
    for (var ci2 = 0; ci2 < 4; ci2++) { for (var ri2 = 0; ri2 < 4; ri2++) { st[ci2][ri2] = inv[st[ci2][ri2]]; } }
    addRoundKey(0);
    var out = new Uint8Array(16);
    for (var co = 0; co < 4; co++) { for (var ro = 0; ro < 4; ro++) { out[co * 4 + ro] = st[co][ro]; } }
    return out;
  }
  function aesDecrypt(data, mode, keyBytes, ivBytes) {
    var key = new Uint8Array(16);
    key.set(toBytes(keyBytes).subarray(0, 16));
    var w = expandKey128(key);
    var input = toBytes(data);
    var isCbc = String(mode || '').toLowerCase().indexOf('cbc') >= 0;
    var iv = new Uint8Array(16);
    if (isCbc) { iv.set(toBytes(ivBytes).subarray(0, 16)); }
    var out = new Uint8Array(input.length - (input.length % 16));
    for (var off = 0; off < out.length; off += 16) {
      var block = input.subarray(off, off + 16);
      var dec = aesDecryptBlock(block, w);
      if (isCbc) {
        for (var k = 0; k < 16; k++) { dec[k] ^= iv[k]; }
        iv.set(block);
      }
      out.set(dec, off);
    }
    // 去 PKCS#7 padding
    if (out.length > 0) {
      var pad = out[out.length - 1];
      if (pad > 0 && pad <= 16 && pad <= out.length) {
        var ok = true;
        for (var p = out.length - pad; p < out.length; p++) { if (out[p] !== pad) { ok = false; break; } }
        if (ok) { return out.subarray(0, out.length - pad); }
      }
    }
    return out;
  }
  /** Node crypto.createCipheriv / createDecipheriv 风格：update(data, inEnc, outEnc) + final(outEnc) */
  function makeStdCipher(alg, key, iv, decrypt) {
    var low = String(alg || '').toLowerCase();
    var mode = low.indexOf('cbc') >= 0 ? 'aes-128-cbc' : 'aes-128-ecb';
    var chunks = [];
    var api = {
      update: function (data, inEnc) {
        chunks.push(typeof data === 'string' ? bufferFrom(data, inEnc || 'utf8') : toBytes(data));
        return api;
      },
      final: function (outEnc) {
        var all = concatBytes(chunks);
        var bytes = decrypt ? aesDecrypt(all, mode, key, iv) : aesEncrypt(all, mode, key, iv);
        if (outEnc) {
          var e = String(outEnc).toLowerCase();
          return bufToString(bytes, e === 'base64' ? 'base64' : e === 'hex' ? 'hex' : 'utf8');
        }
        return bytes;
      },
    };
    return api;
  }

  // ---------------------------------------------------------------- RSA (NoPadding)
  function derLength(buf, pos) {
    var first = buf[pos++];
    if ((first & 0x80) === 0) { return { len: first, pos: pos }; }
    var n = first & 0x7f;
    var len = 0;
    for (var i = 0; i < n; i++) { len = (len << 8) | buf[pos++]; }
    return { len: len, pos: pos };
  }

  function derChildren(buf, start, end) {
    var out = [];
    var pos = start;
    while (pos + 1 < end) {
      var tag = buf[pos++];
      var l = derLength(buf, pos);
      pos = l.pos;
      out.push({ tag: tag, start: pos, end: Math.min(pos + l.len, end) });
      pos += l.len;
      if (l.len === 0) { break; }
    }
    return out;
  }

  function bytesToBigInt(bytes) {
    var n = 0n;
    for (var i = 0; i < bytes.length; i++) { n = (n << 8n) | BigInt(bytes[i]); }
    return n;
  }

  function bigIntToBytes(n, size) {
    var out = new Uint8Array(size);
    for (var i = size - 1; i >= 0; i--) { out[i] = Number(n & 255n); n >>= 8n; }
    return out;
  }

  function modPow(base, exp, mod) {
    var result = 1n;
    base %= mod;
    while (exp > 0n) {
      if (exp & 1n) { result = (result * base) % mod; }
      base = (base * base) % mod;
      exp >>= 1n;
    }
    return result;
  }

  /**
   * 解析 PEM（SubjectPublicKeyInfo 或 PKCS#1 RSAPublicKey）取出 n / e，
   * 左补 0 到 128 字节后做 RSA/ECB/NoPadding 模幂，等价于 desktop 的
   * crypto.publicEncrypt({padding: RSA_NO_PADDING}) 与 mobile 的 RSA/ECB/NoPadding。
   */
  function rsaEncrypt(data, pem) {
    var b64 = String(pem).replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
    var der = b64Decode(b64);
    var top = derChildren(der, 0, der.length);
    if (top.length === 0) { throw new Error('invalid rsa key'); }
    var seq = top[0];
    var children = derChildren(der, seq.start, seq.end);
    var pub = null;
    if (children.length === 2 && children[0].tag === 0x30 && children[1].tag === 0x03) {
      // SubjectPublicKeyInfo: BIT STRING 内嵌 RSAPublicKey SEQUENCE
      var bit = children[1];
      var inner = derChildren(der, bit.start + 1, bit.end);
      if (inner.length > 0) { pub = derChildren(der, inner[0].start, inner[0].end); }
    } else if (children.length === 2 && children[0].tag === 0x02) {
      pub = children;
    }
    if (pub === null || pub.length < 2) { throw new Error('unsupported rsa key format'); }
    var nBytes = der.subarray(pub[0].start, pub[0].end);
    var eBytes = der.subarray(pub[1].start, pub[1].end);
    var n = bytesToBigInt(nBytes);
    var e = bytesToBigInt(eBytes);
    var raw = toBytes(data);
    var padded = new Uint8Array(128);
    padded.set(raw.subarray(0, 128), 128 - Math.min(raw.length, 128));
    return bigIntToBytes(modPow(bytesToBigInt(padded), e, n), 128);
  }

  function randomBytes(size) {
    var out = new Uint8Array(Math.max(0, Math.min(size | 0, 65536)));
    for (var i = 0; i < out.length; i++) { out[i] = Math.floor(Math.random() * 256); }
    return out;
  }

  function zlib(method, data) {
    var Ctor = root[method === 'inflate' ? 'DecompressionStream' : 'CompressionStream'];
    if (typeof Ctor !== 'function') {
      return Promise.reject(new Error('zlib is not available in this runtime'));
    }
    var stream = new Ctor('deflate');
    var bytes = toBytes(data);
    var writer = stream.writable.getWriter();
    writer.write(bytes);
    writer.close();
    return new Response(stream.readable).arrayBuffer().then(function (buf) {
      return new Uint8Array(buf);
    });
  }

  var utils = {
    buffer: { from: bufferFrom, bufToString: bufToString },
    crypto: {
      md5: function (str) { return md5Hex(str); },
      randomBytes: randomBytes,
      aesEncrypt: aesEncrypt,
      rsaEncrypt: rsaEncrypt,
    },
    zlib: {
      inflate: function (data) { return zlib('inflate', data); },
      deflate: function (data) { return zlib('deflate', data); },
    },
  };

  // ==================================================================
  // Node / 洛雪扩展模块兼容层
  // 真实社区 userApi 脚本常写成 CommonJS：require('crypto') / require('buffer')
  // / require('@/utils/request')，并读全局 Buffer、process。这里把这些名字
  // 映射到上面已有的纯 JS 实现，让脚本能加载并注册 lx.request handler。
  // 网络出口仍然只有 lx.request（宿主代发），禁止的能力不给真身。
  // ==================================================================

  // ---- SHA-1 / SHA-256（纯 JS，返回 Uint8Array）----
  function rotr32(x, n) { return ((x >>> n) | (x << (32 - n))) >>> 0; }
  function rotl32(x, n) { return ((x << n) | (x >>> (32 - n))) >>> 0; }

  var SHA256_K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  function sha256Bytes(bytes) {
    var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var len = bytes.length;
    var padLen = (((len + 9) >> 6) + 1) * 64;
    var msg = new Uint8Array(padLen);
    msg.set(bytes);
    msg[len] = 0x80;
    var dv = new DataView(msg.buffer);
    var bitLen = len * 8;
    dv.setUint32(padLen - 8, Math.floor(bitLen / 4294967296));
    dv.setUint32(padLen - 4, bitLen >>> 0);
    for (var off = 0; off < padLen; off += 64) {
      var w = new Array(64);
      for (var i = 0; i < 16; i++) { w[i] = dv.getUint32(off + i * 4); }
      for (i = 16; i < 64; i++) {
        var x = w[i - 15], y = w[i - 2];
        var s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >>> 3);
        var s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (i = 0; i < 64; i++) {
        var S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        var ch = (e & f) ^ (~e & g);
        var t1 = (h + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
        var S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
      H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
    }
    var out = new Uint8Array(32);
    var odv = new DataView(out.buffer);
    for (i = 0; i < 8; i++) { odv.setUint32(i * 4, H[i]); }
    return out;
  }

  function sha1Bytes(bytes) {
    var H = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
    var len = bytes.length;
    var padLen = (((len + 9) >> 6) + 1) * 64;
    var msg = new Uint8Array(padLen);
    msg.set(bytes);
    msg[len] = 0x80;
    var dv = new DataView(msg.buffer);
    var bitLen = len * 8;
    dv.setUint32(padLen - 8, Math.floor(bitLen / 4294967296));
    dv.setUint32(padLen - 4, bitLen >>> 0);
    for (var off = 0; off < padLen; off += 64) {
      var w = new Array(80);
      for (var i = 0; i < 16; i++) { w[i] = dv.getUint32(off + i * 4); }
      for (i = 16; i < 80; i++) { w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1); }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4];
      for (i = 0; i < 80; i++) {
        var f, k;
        if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
        else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
        else { f = b ^ c ^ d; k = 0xca62c1d6; }
        var t = (rotl32(a, 5) + f + e + k + w[i]) >>> 0;
        e = d; d = c; c = rotl32(b, 30); b = a; a = t;
      }
      H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0; H[4] = (H[4] + e) >>> 0;
    }
    var out = new Uint8Array(20);
    var odv = new DataView(out.buffer);
    for (i = 0; i < 5; i++) { odv.setUint32(i * 4, H[i]); }
    return out;
  }

  function digestBytes(alg, bytes) {
    var a = String(alg || 'md5').toLowerCase().replace(/[^a-z0-9]/g, '');
    if (a.indexOf('sha256') >= 0) { return sha256Bytes(bytes); }
    if (a.indexOf('sha1') >= 0) { return sha1Bytes(bytes); }
    return md5Bytes(bytes);
  }

  // ---- crypto 模块（含 createHash / createHmac）----
  function makeHash(alg) {
    var parts = [];
    var api = {
      update: function (data, enc) {
        parts.push(typeof data === 'string' ? new Uint8Array(utf8Encode(data)) : toBytes(data));
        return api;
      },
      digest: function (enc) {
        var bytes = digestBytes(alg, concatBytes(parts));
        if (!enc) { return bytes; }
        return bufToString(bytes, String(enc).toLowerCase() === 'base64' ? 'base64' : 'hex');
      },
    };
    return api;
  }
  function makeHmac(alg, key) {
    var keyBytes = typeof key === 'string' ? new Uint8Array(utf8Encode(key)) : toBytes(key);
    var parts = [];
    var api = {
      update: function (data) { parts.push(typeof data === 'string' ? new Uint8Array(utf8Encode(data)) : toBytes(data)); return api; },
      digest: function (enc) {
        var block = 64;
        var k = keyBytes.length > block ? digestBytes(alg, keyBytes) : keyBytes;
        var ipad = new Uint8Array(block), opad = new Uint8Array(block);
        for (var i = 0; i < block; i++) {
          var kb = i < k.length ? k[i] : 0;
          ipad[i] = kb ^ 0x36; opad[i] = kb ^ 0x5c;
        }
        var inner = concatBytes([ipad, concatBytes(parts)]);
        var ih = digestBytes(alg, inner);
        var outer = concatBytes([opad, ih]);
        var bytes = digestBytes(alg, outer);
        if (!enc) { return bytes; }
        return bufToString(bytes, String(enc).toLowerCase() === 'base64' ? 'base64' : 'hex');
      },
    };
    return api;
  }
  var cryptoModule = {
    md5: function (str) { return md5Hex(String(str)); },
    sha1: function (str) { return bufToString(sha1Bytes(new Uint8Array(utf8Encode(String(str)))), 'hex'); },
    sha256: function (str) { return bufToString(sha256Bytes(new Uint8Array(utf8Encode(String(str)))), 'hex'); },
    createHash: makeHash,
    createHmac: makeHmac,
    createCipheriv: function (alg, key, iv) { return makeStdCipher(alg, key, iv, false); },
    createDecipheriv: function (alg, key, iv) { return makeStdCipher(alg, key, iv, true); },
    randomBytes: randomBytes,
    aesEncrypt: aesEncrypt,
    aesDecrypt: aesDecrypt,
    rsaEncrypt: rsaEncrypt,
  };

  function concatBytes(arr) {
    var total = 0, i;
    for (i = 0; i < arr.length; i++) { total += arr[i].length; }
    var out = new Uint8Array(total), off = 0;
    for (i = 0; i < arr.length; i++) { out.set(arr[i], off); off += arr[i].length; }
    return out;
  }

  // ---- Buffer 模块 ----
  function NodeBuffer(value, enc) {
    if (!(this instanceof NodeBuffer)) { return new NodeBuffer(value, enc); }
    var bytes = bufferFrom(value, enc);
    this._b = bytes;
    this.length = bytes.length;
    for (var i = 0; i < bytes.length; i++) { this[i] = bytes[i]; }
  }
  NodeBuffer.prototype.toString = function (enc) { return bufToString(this._b, enc); };
  NodeBuffer.prototype.toJSON = function () { return { type: 'Buffer', data: Array.prototype.slice.call(this._b) }; };
  NodeBuffer.prototype.slice = function (s, e) { return new NodeBuffer(this._b.subarray(s, e)); };
  NodeBuffer.prototype.subarray = NodeBuffer.prototype.slice;
  NodeBuffer.prototype.equals = function (o) {
    var b = toBytes(o); if (b.length !== this._b.length) { return false; }
    for (var i = 0; i < b.length; i++) { if (b[i] !== this._b[i]) { return false; } } return true;
  };
  NodeBuffer.from = function (v, enc) { return new NodeBuffer(v, enc); };
  NodeBuffer.alloc = function (n, v) {
    var b = new Uint8Array(n >>> 0);
    if (v !== undefined) { var fill = toBytes(v); for (var i = 0; i < b.length; i++) { b[i] = fill.length ? fill[i % fill.length] : 0; } }
    return new NodeBuffer(b);
  };
  NodeBuffer.allocUnsafe = NodeBuffer.alloc;
  NodeBuffer.concat = function (list, total) {
    var arr = []; for (var i = 0; i < list.length; i++) { arr.push(toBytes(list[i])); }
    return new NodeBuffer(concatBytes(arr));
  };
  NodeBuffer.isBuffer = function (o) { return o instanceof NodeBuffer; };
  NodeBuffer.byteLength = function (v, enc) { return bufferFrom(v, enc).length; };

  // ---- querystring / url / util / path ----
  var querystringModule = {
    parse: function (s) {
      var out = {};
      String(s || '').replace(/^\?/, '').split('&').forEach(function (kv) {
        if (!kv) { return; }
        var p = kv.indexOf('=');
        var k = p < 0 ? kv : kv.substring(0, p);
        var v = p < 0 ? '' : kv.substring(p + 1);
        try { out[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' ')); } catch (e) { /* ignore */ }
      });
      return out;
    },
    stringify: function (o) {
      var parts = [];
      for (var k in o) {
        if (Object.prototype.hasOwnProperty.call(o, k)) {
          parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(o[k] === undefined ? '' : o[k]));
        }
      }
      return parts.join('&');
    },
    escape: function (s) { return encodeURIComponent(String(s)); },
    unescape: function (s) { try { return decodeURIComponent(String(s)); } catch (e) { return String(s); } },
  };
  var urlModule = {
    URL: root.URL,
    URLSearchParams: root.URLSearchParams,
    parse: function (s) { return { href: String(s || ''), query: querystringModule.parse(String(s || '').split('?')[1] || '') }; },
  };
  var utilModule = {
    format: function () { return Array.prototype.slice.call(arguments).map(function (v) { return typeof v === 'string' ? v : JSON.stringify(v); }).join(' '); },
    inspect: function (v) { try { return JSON.stringify(v); } catch (e) { return String(v); } },
    promisify: function (fn) { return function () { var self = this, a = Array.prototype.slice.call(arguments); return new Promise(function (res, rej) { a.push(function (e, r) { if (e) { rej(e); } else { res(r); } }); fn.apply(self, a); }); }; },
    TextEncoder: root.TextEncoder,
    TextDecoder: root.TextDecoder,
  };
  var pathModule = {
    basename: function (p, ext) { var b = String(p || '').split('/').pop(); return ext && b.endsWith(ext) ? b.substring(0, b.length - ext.length) : b; },
    dirname: function (p) { var s = String(p || '').split('/'); s.pop(); return s.join('/') || '.'; },
    extname: function (p) { var b = String(p || '').split('/').pop(), i = b.lastIndexOf('.'); return i < 0 ? '' : b.substring(i); },
    join: function () { return Array.prototype.slice.call(arguments).join('/'); },
    resolve: function () { return '/' + Array.prototype.slice.call(arguments).join('/'); },
  };

  // ---- HTTP 模块：映射到 lx.request（唯一网络出口）----
  function adaptRequest(urlOrOpts, opts, cb) {
    var url, options, callback;
    if (typeof urlOrOpts === 'string') {
      url = urlOrOpts; options = opts && typeof opts === 'object' ? opts : {};
      callback = typeof opts === 'function' ? opts : (typeof cb === 'function' ? cb : null);
    } else {
      options = urlOrOpts && typeof urlOrOpts === 'object' ? urlOrOpts : {};
      url = options.url || options.uri || '';
      callback = typeof opts === 'function' ? opts : (typeof cb === 'function' ? cb : null);
    }
    return new Promise(function (resolve, reject) {
      try {
        lxRequestInternal(url, options, function (err, resp, body) {
          if (err) { if (callback) { try { callback(err); } catch (e) { /* ignore */ } } reject(err); return; }
          if (callback) { try { callback(null, resp, body); } catch (e) { /* ignore */ } }
          resolve(resp);
        });
      } catch (e) { reject(e); }
    });
  }
  // 引用 setup() 里赋值的 lx.request，此处以函数声明占位（调用时已就绪）
  function lxRequestInternal(url, options, callback) {
    return root.lx.request(url, options, callback);
  }
  adaptRequest.get = adaptRequest;
  adaptRequest.post = function (url, opts, cb) {
    var options = (opts && typeof opts === 'object') ? shallowCopy(opts) : {};
    options.method = 'POST'; options.body = (opts && opts.body !== undefined) ? opts.body : (options.body || '');
    return adaptRequest(url, options, cb);
  };
  adaptRequest.default = adaptRequest;
  adaptRequest.request = adaptRequest;
  function shallowCopy(o) { var r = {}; for (var k in o) { if (Object.prototype.hasOwnProperty.call(o, k)) { r[k] = o[k]; } } return r; }

  var cacheStore = {};
  var cacheModule = {
    get: function (k) { return cacheStore[k]; },
    set: function (k, v) { cacheStore[k] = v; },
    has: function (k) { return Object.prototype.hasOwnProperty.call(cacheStore, k); },
    delete: function (k) { delete cacheStore[k]; },
    clear: function () { cacheStore = {}; },
  };

  // 未知模块宽容兜底：返回一个可调用、可取属性的对象，避免脚本因缺模块直接崩。
  // 任何属性访问都得到同样宽容的对象；Promise 判定用的 then 故意返回 undefined。
  function tolerantModule() {
    var fn = function () { return tolerantModule(); };
    if (typeof root.Proxy === 'function') {
      return new root.Proxy(fn, {
        get: function (t, p) {
          if (p === 'then') { return undefined; }
          if (p === 'toJSON' || p === Symbol.toPrimitive) { return function () { return ''; }; }
          if (p === 'default') { return tolerantModule(); }
          return tolerantModule();
        },
        apply: function () { return tolerantModule(); },
        construct: function () { return {}; },
      });
    }
    return fn;
  }

  function nodeRequire(name) {
    var key = String(name || '').replace(/^node:/, '').trim();
    if (key === 'crypto' || key === 'crypto-browserify' || key === '@/utils/crypto') { return cryptoModule; }
    if (key === 'buffer' || key === 'buffer/' || key === 'safe-buffer') { return { Buffer: NodeBuffer, SlowBuffer: NodeBuffer }; }
    if (key === 'zlib' || key === 'node:zlib') { return utils.zlib; }
    if (key === 'querystring' || key === 'querystring-es3') { return querystringModule; }
    if (key === 'url' || key === 'whatwg-url') { return urlModule; }
    if (key === 'util' || key === 'util/') { return utilModule; }
    if (key === 'path' || key === 'path-browserify') { return pathModule; }
    if (key === 'http' || key === 'https' || key === 'request' || key === 'axios' ||
        key === '@/utils/request' || key === '@/utils/http' || key === '@/utils/fetch') { return adaptRequest; }
    if (key === '@/utils/cache' || key === 'cache' || key === 'memory-cache') { return cacheModule; }
    if (key === '@/utils/log' || key === 'log' || key === 'debug') { return console; }
    if (key === 'fs' || key === 'fs-extra' || key === 'os' || key === 'stream' || key === 'events') { return tolerantModule(); }
    return tolerantModule();
  }

  // ---------------------------------------------------------------- lx API
  function on(eventName, handler) {
    return new Promise(function (resolve, reject) {
      if (eventNames.indexOf(eventName) < 0 || eventName !== EVENT_NAMES.request) {
        reject(new Error('Event name is not supported: ' + eventName));
        return;
      }
      if (typeof handler !== 'function') {
        reject(new Error('handler must be a function'));
        return;
      }
      events.request = handler;
      resolve();
    });
  }

  function send(eventName, data) {
    return new Promise(function (resolve, reject) {
      if (eventName === EVENT_NAMES.inited) {
        if (isInited) { reject(new Error('Script is inited')); return; }
        isInited = true;
        post('inited', data || {});
        resolve();
        return;
      }
      if (eventName === EVENT_NAMES.updateAlert) {
        if (isShowedUpdateAlert) { reject(new Error('Update alert is showed')); return; }
        isShowedUpdateAlert = true;
        if (!data || typeof data !== 'object' || typeof data.log !== 'string') {
          reject(new Error('log is required.'));
          return;
        }
        var out = { log: data.log.substring(0, 1024) };
        if (typeof data.updateUrl === 'string' && /^https?:\/\//.test(data.updateUrl)) {
          out.updateUrl = data.updateUrl.substring(0, 1024);
        }
        post('updateAlert', out);
        resolve();
        return;
      }
      reject(new Error('Event name is not supported: ' + eventName));
    });
  }

  function request(url, options, callback) {
    var requestKey = 'req__' + Math.random().toString().substring(2) + '__' + (++consoleSeq).toString();
    httpCallbacks[requestKey] = callback;
    post('httpRequest', {
      requestKey: requestKey,
      url: url,
      options: options || { method: 'GET' },
    });
    return function () {
      delete httpCallbacks[requestKey];
      post('httpCancel', { requestKey: requestKey });
    };
  }

  function setup(info) {
    var lx = {
      version: '2.0.0',
      env: 'mobile',
      currentScriptInfo: info || {},
      EVENT_NAMES: EVENT_NAMES,
      on: on,
      send: send,
      request: request,
      utils: utils,
    };
    root.lx = lx;
    try { root.window.lx = lx; } catch (e) { /* no window */ }

    // Node / 洛雪 CommonJS 脚本依赖的全局：require + Buffer + process + global
    root.require = nodeRequire;
    try { root.window.require = nodeRequire; } catch (e) { /* no window */ }
    root.Buffer = NodeBuffer;
    try { root.window.Buffer = NodeBuffer; } catch (e) { /* no window */ }
    root.global = root;
    root.process = {
      env: { NODE_ENV: 'production' },
      platform: 'linux',
      arch: 'arm64',
      version: 'v18.0.0',
      versions: { node: '18.0.0', v8: '10.2.0' },
      argv: [],
      nextTick: function (fn) { var a = Array.prototype.slice.call(arguments, 1); Promise.resolve().then(function () { fn.apply(null, a); }); },
      cwd: function () { return '/'; },
      uptime: function () { return (Date.now() / 1000); },
      hrtime: function () { return [0, 0]; },
      stdout: { write: function () {} },
      stderr: { write: function () {} },
    };
    return true;
  }

  function dispatch(action, data) {
    var d = data || {};
    if (action === 'httpResponse') {
      var cb = httpCallbacks[d.requestKey];
      if (!cb) { return; }
      delete httpCallbacks[d.requestKey];
      var err = d.error ? new Error(d.error) : null;
      var resp = null;
      if (!err && d.response && typeof d.response.body === 'string') {
        var body = d.response.body;
        try { body = JSON.parse(body); } catch (e) { /* plain text */ }
        resp = {
          statusCode: d.response.statusCode,
          statusMessage: d.response.statusMessage || '',
          headers: d.response.headers || {},
          body: body,
        };
      }
      try {
        cb(err, resp, resp ? resp.body : null);
      } catch (e) {
        logToHost('lx.request callback error: ' + e.message);
      }
      return;
    }
    if (action === 'request') {
      var handler = events.request;
      if (typeof handler !== 'function') {
        post('response', { requestKey: d.requestKey, status: false, errorMessage: 'Request event is not defined' });
        return;
      }
      Promise.resolve().then(function () {
        return handler({ source: d.data.source, action: d.data.action, info: d.data.info });
      }).then(function (result) {
        var url = result;
        if (d.data.action === 'musicUrl' || d.data.action === 'pic') {
          if (typeof url !== 'string' || url.length > 2048 || !/^https?:/.test(url)) {
            throw new Error('failed: invalid url');
          }
        }
        var payload;
        if (d.data.action === 'musicUrl') {
          payload = { type: d.data.info.type, url: url };
        } else if (d.data.action === 'pic') {
          payload = url;
        } else {
          payload = result;
        }
        post('response', {
          requestKey: d.requestKey,
          status: true,
          result: { source: d.data.source, action: d.data.action, data: payload },
        });
      }).catch(function (err) {
        post('response', {
          requestKey: d.requestKey,
          status: false,
          errorMessage: (err && err.message) ? String(err.message) : String(err),
        });
      });
    }
  }

  /**
   * 切换音源脚本时重置协议状态。沙箱页面可能重载（此时本层也会重新执行），
   * 也可能因系统未触发页面事件而复用旧环境，两种情况下都要清掉上一个脚本的
   * inited / request 处理器 / 未完成的 HTTP 回调。
   */
  function reset() {
    events.request = null;
    isInited = false;
    isShowedUpdateAlert = false;
    httpCallbacks = {};
    cacheStore = {};
    return true;
  }

  root.__lxSetup = setup;
  root.__lxReset = reset;
  root.__lxDispatch = dispatch;
  /**
   * 健康探针：宿主每次取链前调一次，判断「沙箱环境 + 脚本状态」是否还活着。
   * 返回两位字符串：第 1 位 = 脚本已 inited，第 2 位 = 已注册 request 处理器。
   * '11' 才是可用的；页面被系统回收 / 重载后这里连函数都不存在，
   * 宿主据此自动重建沙箱（等价于用户手动重选音源），无需人工干预。
   */
  root.__lxHealth = function () {
    return (isInited ? '1' : '0') + (typeof events.request === 'function' ? '1' : '0');
  };
  root.__lxPrelude = { EVENT_NAMES: EVENT_NAMES, utils: utils };

  // ---------------------------------------------------------------- 隔离
  // 脚本唯一网络出口是 lx.request；禁用浏览器自带的网络与跨页面能力。
  function denyNetwork() { throw new Error('Network access is only allowed via globalThis.lx.request'); }
  try { root.fetch = denyNetwork; } catch (e) { /* ignore */ }
  try { root.XMLHttpRequest = denyNetwork; } catch (e) { /* ignore */ }
  try { root.WebSocket = denyNetwork; } catch (e) { /* ignore */ }
  try { root.EventSource = denyNetwork; } catch (e) { /* ignore */ }
  try { root.Worker = denyNetwork; } catch (e) { /* ignore */ }
  try { root.importScripts = denyNetwork; } catch (e) { /* ignore */ }
  try {
    if (root.navigator && typeof root.navigator.sendBeacon === 'function') {
      root.navigator.sendBeacon = denyNetwork;
    }
  } catch (e) { /* ignore */ }

  // console 转发（只把 warn/error 送给宿主日志，避免刷屏）
  var nativeWarn = root.console ? root.console.warn : null;
  var nativeError = root.console ? root.console.error : null;
  if (root.console) {
    root.console.warn = function () {
      logToHost('[script warn] ' + Array.prototype.slice.call(arguments).join(' '));
      if (nativeWarn) { try { nativeWarn.apply(root.console, arguments); } catch (e) { /* ignore */ } }
    };
    root.console.error = function () {
      logToHost('[script error] ' + Array.prototype.slice.call(arguments).join(' '));
      if (nativeError) { try { nativeError.apply(root.console, arguments); } catch (e) { /* ignore */ } }
    };
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
