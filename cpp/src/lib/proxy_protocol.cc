/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#include "proxy_protocol.h"
#include <fstream>
#include <string.h>

#define _LIST_NAMESPACES 1
#define _NAMESPACE_EXISTS 2
#define _CREATE_NAMESPACE 3
#define _DELETE_NAMESPACE 4
#define _LIST_OBJECTS 5
#define _DELETE_OBJECT 8
#define _GET_OBJECT_INFO 9
#define _READ_OBJECT_FS 10
#define _WRITE_OBJECT_FS 11
//#define _READ_OBJECTS_SLICES 12 // deprecated.
#define _READ_OBJECTS_SLICES 13
#define _INVALIDATE_CACHE 14
#define _DROP_CACHE 16
#define _GET_PROXY_VERSION 17

#define _PING 20
#define _WRITE_OBJECT_FS2 21
#define _OSD_INFO 22
#define _READ_OBJECTS_SLICES2 23
#define _APPLY_SEQUENCE 24
#define _OSD_INFO2 28
#define _HAS_LOCAL_FRAGMENT_CACHE 31
#define _UPDATE_SESSION 32
#define _GET_FRAGMENT_ENCRYPTION_KEY 33

namespace alba {
namespace proxy_protocol {

using llio::to;
using llio::from;

void write_tag(message_builder &mb, uint32_t tag) { to<uint32_t>(mb, tag); }

void read_status(message &m, Status &status) {
  uint32_t rc;
  from(m, rc);

  status.set_rc(rc);
  if (rc != 0) {
    string what;
    from(m, what);
    status._what = what;
  }
}

void write_range_params(message_builder &mb, const string &first,
                        const bool finc, const optional<string> &last,
                        const bool linc, const int max, const bool reverse) {
  to(mb, first);
  to(mb, finc);

  boost::optional<std::pair<string, bool>> lasto;
  if (boost::none == last) {
    lasto = boost::none;
  } else {
    lasto = std::pair<string, bool>(*last, linc);
  }
  to(mb, lasto);

  to<uint32_t>(mb, max);
  to(mb, reverse);
}

void write_list_namespaces_request(message_builder &mb, const string &first,
                                   const bool finc,
                                   const optional<string> &last,
                                   const bool linc, const int max,
                                   const bool reverse) {
  write_tag(mb, _LIST_NAMESPACES);
  write_range_params(mb, first, finc, last, linc, max, reverse);
}
void read_list_namespaces_response(message &m, Status &status,
                                   std::vector<string> &namespaces,
                                   bool &has_more) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, namespaces);
    from(m, has_more);
  }
}

void write_namespace_exists_request(message_builder &mb, const string &name) {
  write_tag(mb, _NAMESPACE_EXISTS);
  to(mb, name);
}
void read_namespace_exists_response(message &m, Status &status, bool &exists) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, exists);
  }
}

void write_create_namespace_request(message_builder &mb, const string &name,
                                    const optional<string> &preset_name) {
  write_tag(mb, _CREATE_NAMESPACE);
  to(mb, name);
  to(mb, preset_name);
}
void read_create_namespace_response(message &m, Status &status) {
  read_status(m, status);
}

void write_delete_namespace_request(message_builder &mb, const string &name) {
  write_tag(mb, _DELETE_NAMESPACE);
  to(mb, name);
}
void read_delete_namespace_response(message &m, Status &status) {
  read_status(m, status);
}

void write_list_objects_request(message_builder &mb, const string &namespace_,
                                const string &first, const bool finc,
                                const optional<string> &last, const bool linc,
                                const int max, const bool reverse) {
  write_tag(mb, _LIST_OBJECTS);
  to(mb, namespace_);
  write_range_params(mb, first, finc, last, linc, max, reverse);
}

void read_list_objects_response(message &m, Status &status,
                                std::vector<string> &objects, bool &has_more) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, objects);
    from(m, has_more);
  }
}

void write_read_object_fs_request(message_builder &mb, const string &namespace_,
                                  const string &object_name,
                                  const string &dest_file,
                                  const bool consistent_read,
                                  const bool should_cache) {
  write_tag(mb, _READ_OBJECT_FS);
  to(mb, namespace_);
  to(mb, object_name);
  to(mb, dest_file);
  to(mb, consistent_read);
  to(mb, should_cache);
}

void read_read_object_fs_response(message &m, Status &status) {
  read_status(m, status);
}

void _write_write_object_fs_request(message_builder &mb, uint32_t tag,
                                    const string &namespace_,
                                    const string &object_name,
                                    const string &input_file,
                                    const bool allow_overwrite,
                                    const Checksum *checksum) {
  write_tag(mb, tag);
  to(mb, namespace_);
  to(mb, object_name);
  to(mb, input_file);
  to(mb, allow_overwrite);
  if (nullptr == checksum) {
    to<boost::optional<const Checksum *>>(mb, boost::none);
  } else {
    to(mb, boost::optional<const Checksum *>(checksum));
  }
}

void write_write_object_fs_request(message_builder &mb,
                                   const string &namespace_,
                                   const string &object_name,
                                   const string &input_file,
                                   const bool allow_overwrite,
                                   const Checksum *checksum) {

  _write_write_object_fs_request(mb, _WRITE_OBJECT_FS, namespace_, object_name,
                                 input_file, allow_overwrite, checksum);
}

void write_write_object_fs2_request(message_builder &mb,
                                    const string &namespace_,
                                    const string &object_name,
                                    const string &input_file,
                                    const bool allow_overwrite,
                                    const Checksum *checksum) {

  _write_write_object_fs_request(mb, _WRITE_OBJECT_FS2, namespace_, object_name,
                                 input_file, allow_overwrite, checksum);
}

void read_write_object_fs_response(message &m, Status &status) {
  read_status(m, status);
}

void read_write_object_fs2_response(message &m, Status &status,
                                    ManifestWithNamespaceId &mf) {
  read_status(m, status);
  if (status.is_ok()) {

    from(m, mf);
  }
}

void write_delete_object_request(message_builder &mb, const string &namespace_,
                                 const string &object_name,
                                 const bool may_not_exist) {
  write_tag(mb, _DELETE_OBJECT);
  to(mb, namespace_);
  to(mb, object_name);
  to(mb, may_not_exist);
}

void read_delete_object_response(message &m, Status &status) {
  read_status(m, status);
}

void write_get_object_info_request(message_builder &mb,
                                   const string &namespace_,
                                   const string &object_name,
                                   const bool consistent_read,
                                   const bool should_cache) {
  write_tag(mb, _GET_OBJECT_INFO);
  to(mb, namespace_);
  to(mb, object_name);
  to(mb, consistent_read);
  to(mb, should_cache);
}

void read_get_object_info_response(message &m, Status &status, uint64_t &size,
                                   Checksum *&checksum) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, size);
    from(m, checksum);
  }
}

void _write_read_objects_slices_request(const int tag, message_builder &mb,
                                        const string &namespace_,
                                        const std::vector<ObjectSlices> &slices,
                                        const bool consistent_read) {
  write_tag(mb, tag);
  to(mb, namespace_);
  to(mb, slices);
  to(mb, consistent_read);
}

void write_read_objects_slices_request(message_builder &mb,
                                       const string &namespace_,
                                       const std::vector<ObjectSlices> &slices,
                                       const bool consistent_read) {

  _write_read_objects_slices_request(_READ_OBJECTS_SLICES, mb, namespace_,
                                     slices, consistent_read);
}

void write_read_objects_slices2_request(message_builder &mb,
                                        const string &namespace_,
                                        const std::vector<ObjectSlices> &slices,
                                        const bool consistent_read) {

  _write_read_objects_slices_request(_READ_OBJECTS_SLICES2, mb, namespace_,
                                     slices, consistent_read);
}

void read_read_objects_slices_response(
    message &m, Status &status,
    const std::vector<ObjectSlices> &objects_slices) {
  read_status(m, status);
  if (status.is_ok()) {
    uint32_t size;
    from<uint32_t>(m, size);

    for (auto &object_slices : objects_slices) {
      for (auto &slice : object_slices.slices) {
        memcpy(slice.buf, m.current(slice.size), slice.size);
        m.skip(slice.size);
      }
    }
  }
}

void _read_object_infos(message &m, std::vector<object_info> &object_infos) {
  // todo: automatically via templates
  uint32_t size;
  from(m, size);
  object_infos.reserve(size);
  using namespace std;
  for (int32_t i = size - 1; i >= 0; --i) {
    std::string name;
    from(m, name);
    std::string future;
    from(m, future);
    bool ok_to_continue = false;
    try {
      unique_ptr<ManifestWithNamespaceId> umf(new ManifestWithNamespaceId());
      from2(m, *umf, ok_to_continue);
      assert(name == umf->name);
      auto t = make_tuple(move(name), move(future), move(umf));
      object_infos.push_back(move(t));
    } catch (alba::llio::deserialisation_exception &e) {
      if (ok_to_continue) {
        ALBA_LOG(WARNING, "skipping name=" << name << " because of "
                                           << e.what());
      } else {
        throw;
      }
    }
  }
}

void read_read_objects_slices2_response(
    message &m, Status &status, const std::vector<ObjectSlices> &objects_slices,
    std::vector<object_info> &object_infos) {
  read_status(m, status);
  if (status.is_ok()) {
    uint32_t size;
    from<uint32_t>(m, size);

    for (auto &object_slices : objects_slices) {
      for (auto &slice : object_slices.slices) {
        memcpy(slice.buf, m.current(slice.size), slice.size);
        m.skip(slice.size);
      }
    }

    _read_object_infos(m, object_infos);
  }
}

void write_update_session_request(
    message_builder &mb,
    const std::vector<std::pair<std::string, boost::optional<std::string>>>
        &args) {
  write_tag(mb, _UPDATE_SESSION);
  to(mb, args);
}

void read_update_session_response(
    message &m, Status &status,
    std::vector<std::pair<std::string, std::string>> &processed_kvs) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, processed_kvs);
  }
}
void write_apply_sequence_request(
    message_builder &mb, const string &namespace_, const bool write_barrier,
    const std::vector<std::shared_ptr<alba::proxy_client::sequences::Assert>>
        &asserts,
    const std::vector<std::shared_ptr<alba::proxy_client::sequences::Update>>
        &updates) {
  write_tag(mb, _APPLY_SEQUENCE);
  to(mb, namespace_);
  to(mb, write_barrier);
  to(mb, asserts);
  to(mb, updates);
}

void read_apply_sequence_response(message &m, Status &status,
                                  std::vector<object_info> &object_infos) {
  read_status(m, status);

  if (status.is_ok()) {
    _read_object_infos(m, object_infos);
  }
}

void write_invalidate_cache_request(message_builder &mb,
                                    const string &namespace_) {
  write_tag(mb, _INVALIDATE_CACHE);
  to(mb, namespace_);
}

void read_invalidate_cache_response(message &m, Status &status) {
  read_status(m, status);
}

void write_drop_cache_request(message_builder &mb, const string &namespace_) {
  write_tag(mb, _DROP_CACHE);
  to(mb, namespace_);
}

void read_drop_cache_response(message &m, Status &status) {
  read_status(m, status);
}

void write_get_proxy_version_request(message_builder &mb) {
  write_tag(mb, _GET_PROXY_VERSION);
}

void read_get_proxy_version_response(message &m, Status &status, int32_t &major,
                                     int32_t &minor, int32_t &patch,
                                     std::string &hash) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, major);
    from(m, minor);
    from(m, patch);
    from(m, hash);
  }
}

void write_ping_request(message_builder &mb, const double delay) {
  write_tag(mb, _PING);
  to(mb, delay);
}

void read_ping_response(message &m, Status &status, double &timestamp) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, timestamp);
  }
}

void write_osd_info_request(message_builder &mb) { write_tag(mb, _OSD_INFO); }

void _read_osd_infos(message &m, osd_map_t &result) {
  uint32_t n;
  from(m, n);
  for (uint32_t i = 0; i < n; i++) {
    osd_t osd_id;
    from(m, osd_id);
    uint32_t info_s_size;
    from(m, info_s_size);
    auto m2 = m.get_nested_message(info_s_size);
    m.skip(info_s_size);
    OsdInfo info;
    from(m2, info);
    OsdCapabilities caps;
    from(m, caps);
    auto p = std::shared_ptr<info_caps>(
        new info_caps(std::move(info), std::move(caps)));

    result[osd_id] = std::move(p);
  }
}
void read_osd_info_response(message &m, Status &status, osd_map_t &result) {
  read_status(m, status);
  if (status.is_ok()) {
    _read_osd_infos(m, result);
  }
}

void write_osd_info2_request(message_builder &mb) {
  ALBA_LOG(DEBUG, "write_osd_info2");
  write_tag(mb, _OSD_INFO2);
}

void read_osd_info2_response(message &m, Status &status, osd_maps_t &result) {
  read_status(m, status);
  if (status.is_ok()) {
    uint32_t n;
    from(m, n);
    result.resize(n);
    ALBA_LOG(DEBUG, "n=" << n);
    for (int32_t i = n - 1; i >= 0; --i) {
      alba_id_t alba_id;
      from(m, alba_id);
      ALBA_LOG(DEBUG, "alba_id = " << alba_id);
      osd_map_t infos;
      _read_osd_infos(m, infos);
      auto entry = std::make_pair(std::move(alba_id), std::move(infos));
      result[i] = std::move(entry);
    }
  }
}

void write_has_local_fragment_cache_request(message_builder &mb) {
  write_tag(mb, _HAS_LOCAL_FRAGMENT_CACHE);
}

void read_has_local_fragment_cache_response(message &m, Status &status,
                                            bool &result) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, result);
  }
}

void write_get_fragment_encryption_key_request(message_builder &mb,
                                               const string &alba_id,
                                               const namespace_t namespace_id) {
  write_tag(mb, _GET_FRAGMENT_ENCRYPTION_KEY);
  to(mb, alba_id);
  to(mb, namespace_id.i);
}

void read_get_fragment_encryption_key_response(
    message &m, Status &status, boost::optional<string> &enc_key) {
  read_status(m, status);
  if (status.is_ok()) {
    from(m, enc_key);
  }
}

std::ostream &operator<<(std::ostream &os, const SliceDescriptor &s) {
  os << "{ offset = " << s.offset << " , size = " << s.size << " }";
  return os;
}
std::ostream &operator<<(std::ostream &os, const ObjectSlices &s) {
  os << "{ object_name = ";
  dump_string(os, s.object_name);
  os << "slices = [ ";
  for (auto &sd : s.slices) {
    os << sd << ";";
  }
  os << " ] }";
  return os;
}

} // namespace

namespace llio {
template <>
void to(message_builder &mb,
        const proxy_protocol::SliceDescriptor &desc) noexcept {
  to(mb, desc.offset);
  to(mb, desc.size);
}
template <>
void to(message_builder &mb,
        const proxy_protocol::ObjectSlices &slices) noexcept {
  to(mb, slices.object_name);
  to(mb, slices.slices);
}
}
}
