/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#include "llio.h"

namespace alba {
namespace llio {

std::ostream &operator<<(std::ostream &os, const message &msg) {
  os << "message { size:" << msg._size << " data=";
  stuff::dump_buffer(os, msg._mb->data(msg._initial_offset), msg._size);
  os << " }";
  return os;
}

void check_stream(const std::istream &is) {
  if (!is.good()) {
    throw input_stream_exception("invalid inputstream");
  }
}

template <> void to(message_builder &mb, const bool &b) noexcept {
  char c = b ? '\01' : '\00';
  mb.add_raw(&c, 1);
}

template <> void from(message &m, uint8_t &i) {
  const char *ib = m.current(1);
  i = *((uint8_t *)ib);
  m.skip(1);
}

template <> void from(message &m, bool &b) {

  char c;
  const char *ib = m.current(1);
  c = *ib;
  switch (c) {
  case '\01': {
    b = true;
  }; break;
  case '\00': {
    b = false;
  }; break;
  default:
    throw deserialisation_exception(
        "got unexpected value while deserializing a boolean");
  }
  m.skip(1);
}

template <> void to(message_builder &mb, const uint32_t &i) noexcept {
  const char *ip = (const char *)(&i);
  mb.add_raw(ip, 4);
}

void to_be(message_builder &mb, const uint32_t &i) noexcept {
  uint32_t res =
      (i >> 24) | ((i << 8) & 0x00ff0000) | ((i >> 8) & 0x0000ff00) | (i << 24);
  to(mb, res);
}

template <> void from<uint32_t>(message &m, uint32_t &i) {

  const char *ib = m.current(4);
  i = *((uint32_t *)ib);
  m.skip(4);
}

template <> void from<int32_t>(message &m, int32_t &i) {
  const char *ib = m.current(4);
  i = *((int32_t *)ib);
  m.skip(4);
}

template <> void to(message_builder &mb, const uint64_t &i) noexcept {
  const char *ip = (const char *)(&i);
  mb.add_raw(ip, 8);
}

void to_be(message_builder &mb, const uint64_t &i) noexcept {
  uint64_t res =
      ((i & 0xff00000000000000) >> 56) | ((i & 0x00ff000000000000) >> 40) |
      ((i & 0x0000ff0000000000) >> 24) | ((i & 0x000000ff00000000) >> 8) |
      ((i & 0x00000000ff000000) << 8) | ((i & 0x0000000000ff0000) << 24) |
      ((i & 0x000000000000ff00) << 40) | ((i & 0x00000000000000ff) << 56);
  to(mb, res);
}

template <> void from(message &m, uint64_t &i) {
  const char *ib = m.current(8);
  i = *((uint64_t *)ib);
  m.skip(8);
}

void from_be(message &m, uint64_t &i) {
  from(m, i);
  i = ((i & 0xff00000000000000) >> 56) | ((i & 0x00ff000000000000) >> 40) |
      ((i & 0x0000ff0000000000) >> 24) | ((i & 0x000000ff00000000) >> 8) |
      ((i & 0x00000000ff000000) << 8) | ((i & 0x0000000000ff0000) << 24) |
      ((i & 0x000000000000ff00) << 40) | ((i & 0x00000000000000ff) << 56);
}

template <> void to(message_builder &mb, const std::string &s) noexcept {
  uint32_t size = s.size();
  to(mb, size);
  mb.add_raw(s.data(), size);
}

template <> void from(message &m, std::string &s) {
  uint32_t size;
  from<uint32_t>(m, size);
  const char *ib = m.current(size);
  s.replace(0, size, ib, size);
  s.resize(size);
  m.skip(size);
}

template <> void to(message_builder &mb, const double &d) noexcept {
  const char *dp = (const char *)(&d);
  mb.add_raw(dp, 8);
}

template <> void from(message &m, double &d) {
  const char *db = m.current(8);
  d = *((double *)db);
  m.skip(8);
}

template <> void to(message_builder &mb, const varint_t &v) noexcept {
  uint64_t j = v.j;
  uint8_t b;
  while (j >= 0x80) {
    b = (j & 0x7f) | 0x80;
    mb.add_raw((const char *)&b, 1);
    j >>= 7;
  }
  b = j & 0x7f;
  mb.add_raw((const char *)&b, 1);
}

template <> void from(message &m, varint_t &v) {
  uint8_t b0;
  uint64_t r = 0;
  int shift = 0;
  from(m, b0);
  while (b0 >= 0x80) {
    r = r + ((uint64_t)(b0 & 0x7f) << shift);
    from(m, b0);
    shift = shift + 7;
  }
  r = r + ((uint64_t)b0 << shift);
  v.j = r;
}
}
}
