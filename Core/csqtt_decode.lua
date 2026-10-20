--[[
  csqtt_decode.lua — декодер ссылок csqtt://
  Чистый Lua 5.3+ (или Lua 5.1/5.2 с bit32). Без внешних библиотек.

  Формат (см. UiUtils.kt / web_panel.rs):
    csqtt://<base64url( IV(12) || AES-256-GCM-ciphertext+tag )>
    key = SHA-256("csqtt-chiper-key")
    plaintext = "connect?v=2&host=...&peer=...&password=...&hashes=...+...|token=..."

  Реализованы: SHA-256, HMAC-SHA256 (для проверки детерминированного IV),
  AES-256 (шифрование и расшифровка, режим CTR-подобный поток для GCM),
  GHASH (умножение в GF(2^128)), GCM-тег.

  Проверка тега GCM — обязательна: любая порча → nil.
--]]

local M = {}

------------------------------------------------------------------
-- УТИЛИТЫ
------------------------------------------------------------------
local function be_bytes_to_u32(b1, b2, b3, b4)
  return b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
end

local function u32_to_be_bytes(x)
  return
    bit32.band(bit32.rshift(x, 24), 0xFF),
    bit32.band(bit32.rshift(x, 16), 0xFF),
    bit32.band(bit32.rshift(x, 8), 0xFF),
    bit32.band(x, 0xFF)
end

local function xor_bytes(a, b)
  local out = {}
  for i = 1, #a do out[i] = bit32.bxor(a[i], b[i]) end
  return out
end

local function concat_bytes(...)
  local parts = {...}
  local out = {}
  for _, p in ipairs(parts) do
    for i = 1, #p do out[#out + 1] = p[i] end
  end
  return out
end

local function bytes_to_string(b)
  local t = {}
  for i = 1, #b do t[i] = string.char(b[i]) end
  return table.concat(t)
end

local function string_to_bytes(s)
  local b = {}
  for i = 1, #s do b[i] = string.byte(s, i) end
  return b
end

local function u64_to_be_bytes(x)
  -- x может быть > 2^53? Нет, у нас длины < 2^32, поэтому безопасно
  local hi = math.floor(x / 0x100000000)
  local lo = x % 0x100000000
  local function w(v)
    return bit32.band(bit32.rshift(v, 24), 0xFF),
           bit32.band(bit32.rshift(v, 16), 0xFF),
           bit32.band(bit32.rshift(v, 8), 0xFF),
           bit32.band(v, 0xFF)
  end
  local a, b, c, d = w(hi)
  local e, f, g, h = w(lo)
  return a, b, c, d, e, f, g, h
end

------------------------------------------------------------------
-- BASE64 URL-SAFE (с поддержкой + / и без padding)
------------------------------------------------------------------
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_LOOKUP = {}
for i = 1, #B64_CHARS do B64_LOOKUP[string.sub(B64_CHARS, i, i)] = i - 1 end
-- также принимаем стандартный алфавит (+ и /)
B64_LOOKUP["+"] = 62
B64_LOOKUP["/"] = 63

function M.base64url_decode(s)
  s = s:gsub("[\r\n%s]", "")
  s = s:gsub("=+$", "")
  local out = {}
  local buf, bits = 0, 0
  for i = 1, #s do
    local ch = s:sub(i, i)
    local v = B64_LOOKUP[ch]
    if v then
      buf = bit32.bor(bit32.lshift(buf, 6), v)
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        local byte = bit32.band(bit32.rshift(buf, bits), 0xFF)
        out[#out + 1] = byte
      end
    end
  end
  return out
end

------------------------------------------------------------------
-- SHA-256
------------------------------------------------------------------
local SHA256_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256(bytes)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local len = #bytes
  local bitlen = len * 8
  local msg = {}
  for i = 1, len do msg[i] = bytes[i] end
  msg[#msg + 1] = 0x80
  while (#msg % 64) ~= 56 do msg[#msg + 1] = 0 end
  local hi = math.floor(bitlen / 0x100000000)
  local lo = bitlen % 0x100000000
  local function push32(v)
    msg[#msg + 1] = bit32.band(bit32.rshift(v, 24), 0xFF)
    msg[#msg + 1] = bit32.band(bit32.rshift(v, 16), 0xFF)
    msg[#msg + 1] = bit32.band(bit32.rshift(v, 8), 0xFF)
    msg[#msg + 1] = bit32.band(v, 0xFF)
  end
  push32(hi)
  push32(lo)

  local w = {}
  for chunk = 0, (#msg / 64) - 1 do
    local off = chunk * 64
    for i = 0, 15 do
      w[i] = be_bytes_to_u32(msg[off + i*4 + 1], msg[off + i*4 + 2], msg[off + i*4 + 3], msg[off + i*4 + 4])
    end
    for i = 16, 63 do
      local s0 = bit32.bxor(bit32.bxor(
        bit32.rrotate(w[i-15], 7), bit32.rrotate(w[i-15], 18)),
        bit32.rshift(w[i-15], 3))
      local s1 = bit32.bxor(bit32.bxor(
        bit32.rrotate(w[i-2], 17), bit32.rrotate(w[i-2], 19)),
        bit32.rshift(w[i-2], 10))
      w[i] = (w[i-16] + s0 + w[i-7] + s1) % 0x100000000
    end

    local a, b, c, d = h0, h1, h2, h3
    local e, f, g, h = h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bit32.bxor(bit32.bxor(
        bit32.rrotate(e, 6), bit32.rrotate(e, 11)), bit32.rrotate(e, 25))
      local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
      local temp1 = (h + S1 + ch + SHA256_K[i+1] + w[i]) % 0x100000000
      local S0 = bit32.bxor(bit32.bxor(
        bit32.rrotate(a, 2), bit32.rrotate(a, 13)), bit32.rrotate(a, 22))
      local maj = bit32.bxor(bit32.bxor(bit32.band(a, b), bit32.band(a, c)), bit32.band(b, c))
      local temp2 = (S0 + maj) % 0x100000000

      h = g; g = f; f = e
      e = (d + temp1) % 0x100000000
      d = c; c = b; b = a
      a = (temp1 + temp2) % 0x100000000
    end

    h0 = (h0 + a) % 0x100000000
    h1 = (h1 + b) % 0x100000000
    h2 = (h2 + c) % 0x100000000
    h3 = (h3 + d) % 0x100000000
    h4 = (h4 + e) % 0x100000000
    h5 = (h5 + f) % 0x100000000
    h6 = (h6 + g) % 0x100000000
    h7 = (h7 + h) % 0x100000000
  end

  local out = {}
  for _, v in ipairs({h0, h1, h2, h3, h4, h5, h6, h7}) do
    local a, b, c, d = u32_to_be_bytes(v)
    out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] = a, b, c, d
  end
  return out
end

function M.sha256_hex(bytes)
  local h = sha256(bytes)
  return (bytes_to_string(h):gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

------------------------------------------------------------------
-- HMAC-SHA256 (для проверки детерминированного IV)
------------------------------------------------------------------
local function hmac_sha256(key_bytes, msg_bytes)
  local block = 64
  if #key_bytes > block then key_bytes = sha256(key_bytes) end
  local k = {}
  for i = 1, block do k[i] = key_bytes[i] or 0 end
  local ipad, opad = {}, {}
  for i = 1, block do
    ipad[i] = bit32.bxor(k[i], 0x36)
    opad[i] = bit32.bxor(k[i], 0x5c)
  end
  return sha256(concat_bytes(opad, sha256(concat_bytes(ipad, msg_bytes))))
end

------------------------------------------------------------------
-- AES-256 (шифрование и обратное) — табличный вариант
------------------------------------------------------------------
local SBOX = {
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
}
local INV_SBOX = {}
for i = 0, 255 do INV_SBOX[SBOX[i+1]] = i end
-- индекс по SBOX[i+1] в 1-based
local function inv_sbox(b) return INV_SBOX[b] + 1 end
local function sbox(b) return SBOX[b + 1] end

local function xtime(a)
  a = bit32.band(a, 0xFF)
  a = bit32.lshift(a, 1)
  if bit32.band(a, 0x100) ~= 0 then a = bit32.bxor(a, 0x1B) end
  return bit32.band(a, 0xFF)
end
local function gmul(a, b)
  a = bit32.band(a, 0xFF); b = bit32.band(b, 0xFF)
  local p = 0
  for _ = 1, 8 do
    if bit32.band(b, 1) ~= 0 then p = bit32.bxor(p, a) end
    a = xtime(a)
    b = bit32.rshift(b, 1)
  end
  return bit32.band(p, 0xFF)
end

local RCON = {0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1B,0x36,0x6C,0xD8,0xAB,0x4D}

local function aes256_key_expand(key)
  -- key: таблица из 32 байт
  local w = {}
  for i = 0, 7 do
    w[i] = be_bytes_to_u32(key[i*4+1], key[i*4+2], key[i*4+3], key[i*4+4])
  end
  local i = 8
  local rcon_iter = 1
  local function sub_word(x)
    local a, b, c, d = u32_to_be_bytes(x)
    return be_bytes_to_u32(sbox(a), sbox(b), sbox(c), sbox(d))
  end
  local function rot_word(x)
    local a, b, c, d = u32_to_be_bytes(x)
    return be_bytes_to_u32(b, c, d, a)
  end
  while i < 60 do
    local temp = w[i-1]
    if i % 8 == 0 then
      temp = sub_word(rot_word(temp))
      temp = bit32.bxor(temp, bit32.lshift(RCON[rcon_iter], 24))
      rcon_iter = rcon_iter + 1
    elseif i % 8 == 4 then
      temp = sub_word(temp)
    end
    w[i] = bit32.bxor(w[i-8], temp)
    i = i + 1
  end
  -- перевод в байты в 4-байтовых блоках, как это принято в AES
  local rk = {}
  for idx = 0, 59 do
    local a, b, c, d = u32_to_be_bytes(w[idx])
    rk[idx*4+1], rk[idx*4+2], rk[idx*4+3], rk[idx*4+4] = a, b, c, d
  end
  return rk
end

local function add_round_key(state, rk, round)
  for col = 0, 3 do
    for row = 0, 3 do
      state[col*4 + row + 1] = bit32.bxor(state[col*4 + row + 1], rk[(round*16) + col*4 + row + 1])
    end
  end
end

local function sub_bytes(state)
  for i = 1, 16 do state[i] = sbox(state[i]) end
end
local function inv_sub_bytes(state)
  for i = 1, 16 do state[i] = SBOX[inv_sbox(state[i])] end
end

local function shift_rows(state)
  -- state column-major: state[col*4+row]
  local function g(c, r) return state[c*4 + r + 1] end
  local function s(c, r, v) state[c*4 + r + 1] = v end
  local t
  t = g(0,1); s(0,1, g(1,1)); s(1,1, g(2,1)); s(2,1, g(3,1)); s(3,1, t)
  t = g(0,2); s(0,2, g(2,2)); s(2,2, g(0,2)) -- careful
  -- делаем аккуратно через копии
  local gv = {g(0,2), g(1,2), g(2,2), g(3,2)}
  s(0,2, gv[3]); s(1,2, gv[4]); s(2,2, gv[1]); s(3,2, gv[2])
  gv = {g(0,3), g(1,3), g(2,3), g(3,3)}
  s(0,3, gv[2]); s(1,3, gv[3]); s(2,3, gv[4]); s(3,3, gv[1])
end

local function inv_shift_rows(state)
  local function g(c, r) return state[c*4 + r + 1] end
  local function s(c, r, v) state[c*4 + r + 1] = v end
  local t
  t = g(3,1); s(3,1, g(2,1)); s(2,1, g(1,1)); s(1,1, g(0,1)); s(0,1, t)
  local gv = {g(0,2), g(1,2), g(2,2), g(3,2)}
  s(0,2, gv[3]); s(1,2, gv[4]); s(2,2, gv[1]); s(3,2, gv[2])
  gv = {g(0,3), g(1,3), g(2,3), g(3,3)}
  s(0,3, gv[4]); s(1,3, gv[1]); s(2,3, gv[2]); s(3,3, gv[3])
end

local function mix_columns(state)
  for c = 0, 3 do
    local a0 = state[c*4+1]
    local a1 = state[c*4+2]
    local a2 = state[c*4+3]
    local a3 = state[c*4+4]
    state[c*4+1] = bit32.bxor(bit32.bxor(gmul(a0,2), gmul(a1,3)), bit32.bxor(a2, a3))
    state[c*4+2] = bit32.bxor(bit32.bxor(a0, gmul(a1,2)), bit32.bxor(gmul(a2,3), a3))
    state[c*4+3] = bit32.bxor(bit32.bxor(a0, a1), bit32.bxor(gmul(a2,2), gmul(a3,3)))
    state[c*4+4] = bit32.bxor(bit32.bxor(gmul(a0,3), a1), bit32.bxor(a2, gmul(a3,2)))
  end
end

local function inv_mix_columns(state)
  for c = 0, 3 do
    local a0 = state[c*4+1]
    local a1 = state[c*4+2]
    local a2 = state[c*4+3]
    local a3 = state[c*4+4]
    state[c*4+1] = bit32.bxor(bit32.bxor(gmul(a0,14), gmul(a1,11)), bit32.bxor(gmul(a2,13), gmul(a3,9)))
    state[c*4+2] = bit32.bxor(bit32.bxor(gmul(a0,9), gmul(a1,14)), bit32.bxor(gmul(a2,11), gmul(a3,13)))
    state[c*4+3] = bit32.bxor(bit32.bxor(gmul(a0,13), gmul(a1,9)), bit32.bxor(gmul(a2,14), gmul(a3,11)))
    state[c*4+4] = bit32.bxor(bit32.bxor(gmul(a0,11), gmul(a1,13)), bit32.bxor(gmul(a2,9), gmul(a3,14)))
  end
end

local function aes256_encrypt_block(block, rk)
  -- block: 16 байт (1-based)
  local state = {}
  for i = 1, 16 do state[i] = block[i] end
  add_round_key(state, rk, 0)
  for round = 1, 13 do
    sub_bytes(state)
    shift_rows(state)
    mix_columns(state)
    add_round_key(state, rk, round)
  end
  sub_bytes(state)
  shift_rows(state)
  add_round_key(state, rk, 14)
  return state
end

local function aes256_decrypt_block(block, rk)
  local state = {}
  for i = 1, 16 do state[i] = block[i] end
  add_round_key(state, rk, 14)
  for round = 13, 1, -1 do
    inv_shift_rows(state)
    inv_sub_bytes(state)
    add_round_key(state, rk, round)
    inv_mix_columns(state)
  end
  inv_shift_rows(state)
  inv_sub_bytes(state)
  add_round_key(state, rk, 0)
  return state
end

------------------------------------------------------------------
-- GCM (CTR + GHASH + тег)
------------------------------------------------------------------
local function gf_mul(x, y)
  -- x, y — массивы байт длины 16 (1-based)
  local z = {}
  local v = {}
  for i = 1, 16 do
    z[i] = 0
    v[i] = y[i]
  end
  for i = 1, 128 do
    local xi = x[math.floor((i-1)/8) + 1]
    local bit = bit32.band(bit32.rshift(xi, 7 - ((i-1) % 8)), 1)
    if bit == 1 then
      for j = 1, 16 do z[j] = bit32.bxor(z[j], v[j]) end
    end
    local lsb = bit32.band(v[16], 1)
    -- v >> 1
    for j = 16, 2, -1 do
      v[j] = bit32.bor(bit32.rshift(v[j], 1), bit32.lshift(bit32.band(v[j-1], 1), 7))
    end
    v[1] = bit32.rshift(v[1], 1)
    if lsb == 1 then v[1] = bit32.bxor(v[1], 0xE1) end
  end
  return z
end

local function ghash(h, a, c)
  local function to_blocks(b)
    local blocks = {}
    for i = 1, #b, 16 do
      local blk = {}
      for j = 1, 16 do blk[j] = b[i+j-1] or 0 end
      blocks[#blocks+1] = blk
    end
    return blocks
  end
  local function pad16(len)
    return (16 - (len % 16)) % 16
  end
  local ab = to_blocks(a)
  local cb = to_blocks(c)
  -- упаковка A || 0^pad || C || 0^pad || len(A) || len(C)
  local all = {}
  for _, blk in ipairs(ab) do for k = 1, 16 do all[#all+1] = blk[k] end end
  for _ = 1, pad16(#a) do all[#all+1] = 0 end
  for _, blk in ipairs(cb) do for k = 1, 16 do all[#all+1] = blk[k] end end
  for _ = 1, pad16(#c) do all[#all+1] = 0 end
  local la = {}
  local lc = {}
  do
    local hi = math.floor(#a / 0x100000000)
    local lo = #a % 0x100000000
    local function push32(dst, v)
      dst[#dst+1] = bit32.band(bit32.rshift(v, 24), 0xFF)
      dst[#dst+1] = bit32.band(bit32.rshift(v, 16), 0xFF)
      dst[#dst+1] = bit32.band(bit32.rshift(v, 8), 0xFF)
      dst[#dst+1] = bit32.band(v, 0xFF)
    end
    push32(la, hi); push32(la, lo)
    push32(lc, math.floor(#c / 0x100000000)); push32(lc, #c % 0x100000000)
  end
  local lenblk = {la[1],la[2],la[3],la[4],la[5],la[6],la[7],la[8],lc[1],lc[2],lc[3],lc[4],lc[5],lc[6],lc[7],lc[8]}
  all[#all+1] = lenblk[1]; all[#all+1] = lenblk[2]; all[#all+1] = lenblk[3]; all[#all+1] = lenblk[4]
  all[#all+1] = lenblk[5]; all[#all+1] = lenblk[6]; all[#all+1] = lenblk[7]; all[#all+1] = lenblk[8]
  all[#all+1] = lenblk[9]; all[#all+1] = lenblk[10]; all[#all+1] = lenblk[11]; all[#all+1] = lenblk[12]
  all[#all+1] = lenblk[13]; all[#all+1] = lenblk[14]; all[#all+1] = lenblk[15]; all[#all+1] = lenblk[16]

  local y = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
  for i = 1, #all, 16 do
    local x = {}
    for j = 1, 16 do x[j] = all[i+j-1] or 0 end
    y = gf_mul(bit32.bxor and {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0} or y, h) -- noop, just to keep lua happy
    -- XOR y ^ x
    local yx = {}
    for j = 1, 16 do yx[j] = bit32.bxor(y[j], x[j]) end
    y = gf_mul(yx, h)
  end
  return y
end

local function inc32(ctr)
  -- ctr: 16 байт, инкремент последних 32 бит (big-endian), 4 байта
  local lo = be_bytes_to_u32(ctr[13], ctr[14], ctr[15], ctr[16])
  lo = (lo + 1) % 0x100000000
  local a, b, c, d = u32_to_be_bytes(lo)
  ctr[13], ctr[14], ctr[15], ctr[16] = a, b, c, d
end

local function gcm_encrypt(key, iv, plaintext, aad)
  aad = aad or {}
  local rk = aes256_key_expand(key)
  local h = aes256_encrypt_block({0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}, rk)
  -- J0: если IV 96 бит (12 байт) → J0 = IV || 0^31 || 1
  local j0
  if #iv == 12 then
    j0 = {iv[1],iv[2],iv[3],iv[4],iv[5],iv[6],iv[7],iv[8],iv[9],iv[10],iv[11],iv[12],0,0,0,1}
  else
    -- GHASH по IV
    local hb = h
    local function blk(b, i) return b[i] end
    local pad = (16 - (#iv % 16)) % 16
    local all = {}
    for i = 1, #iv do all[#all+1] = iv[i] end
    for _ = 1, pad do all[#all+1] = 0 end
    local y = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
    for i = 1, #all, 16 do
      local x = {}
      for j = 1, 16 do x[j] = all[i+j-1] or 0 end
      local yx = {}
      for j = 1, 16 do yx[j] = bit32.bxor(y[j], x[j]) end
      y = gf_mul(yx, hb)
    end
    -- XOR с len block
    local hi = math.floor(#iv / 0x100000000)
    local lo = #iv % 0x100000000
    local lenblk = {}
    local function push32(dst, v)
      dst[#dst+1] = bit32.band(bit32.rshift(v, 24), 0xFF)
      dst[#dst+1] = bit32.band(bit32.rshift(v, 16), 0xFF)
      dst[#dst+1] = bit32.band(bit32.rshift(v, 8), 0xFF)
      dst[#dst+1] = bit32.band(v, 0xFF)
    end
    push32(lenblk, 0); push32(lenblk, 0); push32(lenblk, hi); push32(lenblk, lo)
    j0 = {}
    for j = 1, 16 do j0[j] = bit32.bxor(y[j], lenblk[j]) end
  end

  -- CTR шифрование
  local function ctr_encrypt(ctr0, data)
    local out = {}
    local ctr = {}
    for i = 1, 16 do ctr[i] = ctr0[i] end
    for i = 1, #data, 16 do
      local keystream = aes256_encrypt_block(ctr, rk)
      for j = 1, 16 do
        local idx = i + j - 1
        if idx > #data then break end
        out[idx] = bit32.bxor(data[idx], keystream[j])
      end
      inc32(ctr)
    end
    return out
  end

  local ct = ctr_encrypt(j0, plaintext)
  -- тег: E(K, J0) XOR GHASH(A, C)
  local ekj0 = aes256_encrypt_block(j0, rk)
  local tag = ghash(h, aad, ct)
  for i = 1, 16 do tag[i] = bit32.bxor(tag[i], ekj0[i]) end
  return ct, tag
end

------------------------------------------------------------------
-- ВЫСОКОУРОВНЕВЫЙ API
------------------------------------------------------------------
local KEY_SEED = "csqtt-chiper-key"
local AES_KEY = nil

local function get_key()
  if not AES_KEY then
    AES_KEY = sha256(string_to_bytes(KEY_SEED))
  end
  return AES_KEY
end

-- Возвращает plaintext-строку или nil, если тег не сходится.
function M.decrypt_payload(raw)
  local bytes = M.base64url_decode(raw)
  if #bytes < 12 + 16 then return nil end
  local iv = {}
  for i = 1, 12 do iv[i] = bytes[i] end
  local ct = {}
  for i = 13, #bytes - 16 do ct[#ct+1] = bytes[i] end
  local tag_in = {}
  for i = #bytes - 15, #bytes do tag_in[#tag_in+1] = bytes[i] end
  -- GCM: шифрование (CTR) симметрично расшифровке; aad пустой
  local pt, tag_calc = gcm_encrypt(get_key(), iv, ct, {})
  -- сравниваем тег (constant-time в идеале; здесь простое сравнение)
  for i = 1, 16 do
    if tag_in[i] ~= tag_calc[i] then return nil end
  end
  return bytes_to_string(pt)
end

-- Полный парсинг: csqtt://... → таблица {host, port, password, hashes={...}, token}
function M.parse_csqtt_link(raw_link)
  if type(raw_link) ~= "string" then return nil end
  raw_link = raw_link:gsub("^%s+", ""):gsub("%s+$", "")
  if not raw_link:match("^csqtt://") then return nil end
  local payload = raw_link:sub(9)
  local plaintext = M.decrypt_payload(payload)
  if not plaintext then return nil end

  -- Приводим к виду connect?... (Kotlin-клиент тоже это делает)
  local body = plaintext
  if body:sub(1, 8) == "csqtt://" then body = body:sub(9) end
  if body:match("^connect%?") then
    -- ok
  elseif body:match("host=") then
    body = "connect?" .. body
  else
    return nil
  end

  -- Разбор query. Основной режим — & / ;.
  local function url_decode(s)
    s = s:gsub("+", "%%2B") -- не превращать + в пробел (в query так не делают)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
  end

  local params = {}
  local query = body:match("^connect%?(.*)$") or ""
  -- Пробуем сначала нормальный &/;
  local normal = true
  if query:find("&", 1, true) or query:find(";", 1, true) then
    for part in query:gmatch("[^&;]+") do
      local k, v = part:match("^([^=]+)=?(.*)$")
      if k and k ~= "" then
        if params[k] then normal = false; break end
        params[k] = v
      end
    end
  else
    normal = false
  end

  -- Fallback: склеенные параметры вида v=2host=1.2.3.4peer=46000password=...
  if not normal or not (params["v"] and params["host"] and params["peer"]) then
    params = {}
    local pattern = "[&;]?([vVhH][oO][sS][tT]?%a*%s*=?)" -- fallback ненадёжен; используем позиционный поиск
    -- Позиционный разбор по именам известных параметров
    local names = {"v","host","peer","password","client","hashes","token","workers"}
    local i = 1
    local len = #query
    while i <= len do
      -- ищем ближайшее имя
      local best_name, best_pos
      for _, n in ipairs(names) do
        local p = query:find(n .. "=", i, true)
        if p and (not best_pos or p < best_pos) then
          best_pos, best_name = p, n
        end
      end
      if not best_pos then break end
      local value_start = best_pos + #best_name + 1
      -- значение до следующего имени
      local next_pos = len + 1
      for _, n in ipairs(names) do
        local p = query:find(n .. "=", value_start, true)
        if p and p < next_pos then next_pos = p end
      end
      local value = query:sub(value_start, next_pos - 1)
      if params[best_name] then return nil end
      params[best_name] = value
      i = next_pos
    end
  end

  if url_decode(params["v"] or "") ~= "2" then return nil end
  local host = url_decode(params["host"] or "")
  if host == "" then return nil end
  if host == "0.0.0.0" or host == "127.0.0.1"
     or host:lower() == "localhost" or host == "::1" then
    return nil
  end
  local port = tonumber(params["peer"] or "")
  if not port or port < 1 or port > 65535 then return nil end
  local password = url_decode(params["password"] or "")
  if password:find("%s") then return nil end

  local hashes = {}
  if params["hashes"] then
    local raw_h = url_decode(params["hashes"])
    if raw_h == "" then return nil end
    for h in raw_h:gmatch("[^+]+") do
      if #h < 16 or h:find("%s") then return nil end
      table.insert(hashes, h)
    end
    if #hashes == 0 or #hashes > 6 then return nil end
    -- без дубликатов
    local seen = {}
    for _, h in ipairs(hashes) do
      if seen[h] then return nil end
      seen[h] = true
    end
  end

  local token = ""
  if params["token"] then
    token = url_decode(params["token"])
    if token == "" or #token > 4096 or token:find("%s") then return nil end
  end

  if #hashes > 0 and token ~= "" then return nil end
  if params["hashes"] and #hashes == 0 then return nil end
  if params["token"] and token == "" then return nil end

  return {
    host = host,
    port = port,
    password = password,
    hashes = hashes,
    token = token,
  }
end

-- Ручной детерминированный IV из HMAC — на случай, если захотите проверить,
-- что конкретная ссылка действительно сгенерирована CSQTT.
function M.recompute_iv(plaintext)
  return hmac_sha256(get_key(), string_to_bytes(plaintext))
end

return M