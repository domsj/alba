/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/


#include "llio.h"
#include "proxy_protocol.h"
#include "snappy.h"
#include "stuff.h"
#include <boost/optional/optional_io.hpp>

namespace alba {
namespace llio {

using namespace proxy_protocol;
template <> void from(message &m, EncodingScheme &es) {
  uint8_t version;
  from(m, version);
  if (version != 1) {
    throw deserialisation_exception("unexpected EncodingScheme version");
  }

  from(m, es.k);
  from(m, es.m);
  from(m, es.w);
}

template <> void from(message &m, std::unique_ptr<Compression> &p) {
  uint8_t type;
  from(m, type);
  Compression *r;
  switch (type) {
  case 1: {
    r = new NoCompression();
  }; break;
  case 2: {
    r = new SnappyCompression();
  }; break;
  case 3: {
    r = new BZip2Compression();
  }; break;
  case 4: {
    r = new TestCompression();
  }; break;
  default: {
    ALBA_LOG(WARNING, "unknown compression type " << (int)type);
    throw deserialisation_exception("unknown compression type");
  };
  }
  p.reset(r);
}

void _from_version1(message &m, Manifest &mf, bool &ok_to_continue) {
  ALBA_LOG(DEBUG, "_from_version1");
  std::string compressed;
  from(m, compressed);

  std::string real;
  snappy::Uncompress(compressed.data(), compressed.size(), &real);
  auto buffer = message_buffer::from_string(real);
  ok_to_continue = true;
  message m2(buffer);
  from(m2, mf.name);
  from(m2, mf.object_id);

  std::vector<uint32_t> chunk_sizes;
  from(m2, mf.chunk_sizes);

  uint8_t version2;
  from(m2, version2);
  if (version2 != 1) {
    throw deserialisation_exception("unexpected version2");
  }

  from(m2, mf.encoding_scheme);

  from(m2, mf.compression);

  from(m2, mf.encrypt_info);
  from(m2, mf.checksum);
  from(m2, mf.size);

  layout<fragment_location_t> fragment_locations;
  uint8_t layout_tag;
  from(m2, layout_tag);
  if (layout_tag != 1) {
    throw deserialisation_exception("unexpected layout tag");
  }
  from(m2, fragment_locations);

  layout<std::shared_ptr<alba::Checksum>> fragment_checksums;
  uint8_t layout_tag2;
  from(m2, layout_tag2);
  if (layout_tag2 != 1) {
    throw deserialisation_exception("unexpected layout tag 2");
  }

  // from(m2, mf.fragment_checksums); // TODO: how to this via the layout based
  // template ?
  // iso this:

  uint32_t n_chunks;
  from(m2, n_chunks);
  fragment_checksums.resize(n_chunks);
  for (int32_t c = n_chunks - 1; c >= 0; --c) {
    uint32_t n_fragments;
    from(m2, n_fragments);
    std::vector<std::shared_ptr<alba::Checksum>> chunk(n_fragments);
    for (int32_t f = n_fragments - 1; f >= 0; --f) {
      alba::Checksum *p;
      from(m2, p);
      std::shared_ptr<alba::Checksum> sp(p);
      chunk[f] = sp;
    };
    fragment_checksums[c] = std::move(chunk);
  }

  layout<uint32_t> fragment_packed_sizes;
  uint8_t layout_tag3;
  from(m2, layout_tag3);
  if (layout_tag3 != 1) {
    throw deserialisation_exception("unexpected layout tag 3");
  }

  from(m2, fragment_packed_sizes);

  // build mf.fragments
  for (uint32_t c = 0; c < n_chunks; c++) {
    uint32_t n_fragments = fragment_locations[c].size();
    std::vector<std::shared_ptr<Fragment>> chunk;
    for (uint32_t f = 0; f < n_fragments; f++) {
      std::shared_ptr<Fragment> fragment_ptr(new Fragment());
      fragment_ptr->loc = fragment_locations[c][f];
      fragment_ptr->crc = fragment_checksums[c][f];
      fragment_ptr->len = fragment_packed_sizes[c][f];
      chunk.push_back(fragment_ptr);
    }
    mf.fragments.push_back(std::move(chunk));
  }

  from(m2, mf.version_id);
  from(m2, mf.max_disks_per_node);
  from(m2, mf.timestamp);
}

void _small_string_from(message &m, std::string &s) {
  varint_t v;
  from(m, v);
  int size = v.j;
  s.resize(size);
  s.replace(0, size, m.current(size), size);
  m.skip(size);
}

template <> void from(message &m, Fragment &f) {
  varint_t fragment_s_size;
  from(m, fragment_s_size);
  auto m2 = m.get_nested_message(fragment_s_size.j);
  m.skip(fragment_s_size.j);

  uint8_t version;
  from(m2, version);
  if (version != 1) {
    throw deserialisation_exception("unexpected Fragment version");
  }
  from(m2, f.loc);

  Checksum *p;
  from(m2, p);
  std::shared_ptr<Checksum> sp(p);
  f.crc = sp;

  from(m2, f.len);
  int size_left = m.get_pos() - m2.get_pos();

  if (size_left > 0) {
    bool has_ctr;
    from(m2, has_ctr);
    if (has_ctr) {
      string ctr;
      _small_string_from(m2, ctr);
      f.ctr = ctr;
    }
  }
  // TODO: need m2.is_done()
  size_left = m.get_pos() - m2.get_pos();
  if (size_left > 0) {
    bool has_fnr;
    from(m2, has_fnr);
    if (has_fnr) {
      string fnr;
      _small_string_from(m2, fnr);
      f.fnr = fnr;
    }
  }
  size_left = m.get_pos() - m2.get_pos();
}

void _from_version2(message &m, Manifest &mf, bool &ok_to_continue) {
  ALBA_LOG(DEBUG, "_from_version2");
  uint32_t compressed_size;
  from(m, compressed_size);
  auto m_compressed = m.get_nested_message(compressed_size);
  m.skip(compressed_size);

  std::string real;
  snappy::Uncompress(m_compressed.current(compressed_size), compressed_size,
                     &real);

  auto buffer = message_buffer::from_string(real); // TODO:copies
  ok_to_continue = true;
  message m2(buffer);
  from(m2, mf.name);
  from(m2, mf.object_id);
  from(m2, mf.chunk_sizes);

  uint8_t version2;
  from(m2, version2);
  if (version2 != 1) {
    throw deserialisation_exception("unexpected version2");
  }

  from(m2, mf.encoding_scheme);
  from(m2, mf.compression);
  from(m2, mf.encrypt_info);
  from(m2, mf.checksum);
  from(m2, mf.size);
  uint8_t layout_tag;
  from(m2, layout_tag);
  if (layout_tag != 1) {
    throw deserialisation_exception("unexpected layout tag");
  }
  // TODO: from(m2, mf.fragments) // how to coerce templating system ?

  uint32_t n_chunks;
  from(m2, n_chunks);
  mf.fragments.resize(n_chunks);

  for (int32_t c = n_chunks - 1; c >= 0; --c) {
    uint32_t n_fragments;
    from(m2, n_fragments);
    std::vector<std::shared_ptr<Fragment>> chunk(n_fragments);
    for (int32_t f = n_fragments - 1; f >= 0; --f) {
      std::shared_ptr<Fragment> fragment_ptr(new Fragment());
      from(m2, *fragment_ptr);
      chunk[f] = std::move(fragment_ptr);
    };
    mf.fragments[c] = std::move(chunk);
  }
}

template <> void from2(message &m, Manifest &mf, bool &ok_to_continue) {
  ok_to_continue = false;
  uint8_t version;
  from(m, version);
  switch (version) {
  case 1: {
    _from_version1(m, mf, ok_to_continue);
  }; break;
  case 2: {
    _from_version2(m, mf, ok_to_continue);
  }; break;
  default:
    throw deserialisation_exception("unexpecteded Manifest version");
  }
}

template <> void from(message &m, Manifest &mf) {
  bool dont_care = false;
  from2(m, mf, dont_care);
}

template <>
void from2(message &m, ManifestWithNamespaceId &mfid, bool &ok_to_continue) {
  try {
    from2(m, (Manifest &)mfid, ok_to_continue);
    from(m, mfid.namespace_id);
  } catch (deserialisation_exception &e) {
    if (ok_to_continue) {
      from(m, mfid.namespace_id);
    };
    throw;
  }
}

template <> void from(message &m, ManifestWithNamespaceId &mfid) {
  bool dont_care = false;
  from2(m, mfid, dont_care);
}
}

namespace proxy_protocol {

std::ostream &operator<<(std::ostream &os, const EncodingScheme &scheme) {
  os << "EncodingScheme{k=" << scheme.k << ", m=" << scheme.m
     << ", w=" << (int)scheme.w << "}";

  return os;
}

std::ostream &operator<<(std::ostream &os, const compressor_t &compressor) {
  switch (compressor) {
  case compressor_t::NO_COMPRESSION:
    os << "NO_COMPRESSION";
    break;
  case compressor_t::SNAPPY:
    os << "SNAPPY";
    break;
  case compressor_t::BZIP2:
    os << "BZIP2";
    break;
  case compressor_t::TEST:
    os << "TEST";
    break;
  };
  return os;
}

std::ostream &operator<<(std::ostream &os, const Compression &c) {
  c.print(os);
  return os;
}

std::ostream &operator<<(std::ostream &os, const fragment_location_t &f) {
  os << "(" << f.first // boost knows how
     << ", " << f.second << ")";
  return os;
}

void dump_string(std::ostream &os, const std::string &s) {
  const char *bytes = s.data();
  const int size = s.size();
  stuff::dump_buffer(os, bytes, size);
}

void dump_string_option(std::ostream &os, const boost::optional<string> &so) {
  if (boost::none == so) {
    os << "None";
  } else {
    os << "(Some ";
    dump_string(os, *so);
    os << ")";
  }
}
std::ostream &operator<<(std::ostream &os, const Fragment &f) {
  os << "{";
  os << "loc = " << f.loc << ", crc = " << *f.crc << ", len = " << f.len
     << ", ctr = ";
  dump_string_option(os, f.ctr);
  os << " , fnr = ";
  ;
  dump_string_option(os, f.fnr);
  os << " }" << std::endl;
  return os;
}

std::ostream &operator<<(std::ostream &os, const Manifest &mf) {
  using alba::stuff::operator<<;
  os << "{"
     << "name = `";
  dump_string(os, mf.name);
  os << "`, " << std::endl;
  os << "  object_id = `";
  dump_string(os, mf.object_id);
  os << "`, " << std::endl

     << "  encoding_scheme = " << mf.encoding_scheme << "," << std::endl
     << "  compression = " << *mf.compression << "," << std::endl
     << "  encryptinfo = " << *mf.encrypt_info << "," // dangerous
     << "  chunk_sizes = " << mf.chunk_sizes << "," << std::endl
     << "  size = " << mf.size << std::endl
     << std::endl
     << "  checksum= " << *mf.checksum << "," << std::endl
     << "  fragments= " << mf.fragments << "," << std::endl
     << "  version_id = " << mf.version_id << "," << std::endl
     << "  timestamp = " << mf.timestamp // TODO: decent formatting?
     << "}";
  return os;
}

std::ostream &operator<<(std::ostream &os,
                         const ManifestWithNamespaceId &mfid) {
  os << "{" << (Manifest &)mfid << ", namespace_id = " << mfid.namespace_id
     << "} ";
  return os;
}
}
}
