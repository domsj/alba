/*
  Copyright (C) 2016 iNuron NV

  This file is part of Open vStorage Open Source Edition (OSE), as available
  from


  http://www.openvstorage.org and
  http://www.openvstorage.com.

  This file is free software; you can redistribute it and/or modify it
  under the terms of the GNU Affero General Public License v3 (GNU AGPLv3)
  as published by the Free Software Foundation, in version 3 as it comes
  in the <LICENSE.txt> file of the Open vStorage OSE distribution.

  Open vStorage is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY of any kind.
*/
#include "osd_access.h"
#include "alba_logger.h"

#include "stuff.h"
#include <assert.h>

namespace alba {
namespace proxy_client {

OsdAccess &OsdAccess::getInstance(int connection_pool_size) {
  static OsdAccess instance(connection_pool_size);
  return instance;
}

bool OsdAccess::osd_is_unknown(osd_t osd) {
  std::lock_guard<std::mutex> lock(_osd_maps_mutex);
  auto &pair = _osd_maps[_osd_maps.size() - 1];
  auto &map = pair.second;
  bool result = (map.find(osd) == map.end());
  return result;
}

std::shared_ptr<info_caps> OsdAccess::_find_osd(osd_t osd) {
  std::lock_guard<std::mutex> lock(_osd_maps_mutex);
  auto &pair = _osd_maps[_osd_maps.size() - 1];
  auto &map = pair.second;
  const auto &ic = map.find(osd);
  if (ic == map.end()) {
    return nullptr;
  } else {
    return ic->second;
  }
}

std::shared_ptr<gobjfs::xio::client_ctx> OsdAccess::_find_ctx(osd_t osd) {
  std::lock_guard<std::mutex> lock(_osd_ctxs_mutex);

  auto &map = _osd_ctx;
  auto it = map.find(osd);
  if (it == map.end()) {
    return nullptr;
  } else {
    return it->second;
  }
}

void OsdAccess::_set_ctx(osd_t osd,
                         std::shared_ptr<gobjfs::xio::client_ctx> ctx) {
  std::lock_guard<std::mutex> lock(_osd_ctxs_mutex);
  _osd_ctx[osd] = std::move(ctx);
}

void OsdAccess::_remove_ctx(osd_t osd) {
  std::lock_guard<std::mutex> lock(_osd_ctxs_mutex);
  _osd_ctx.erase(osd);
}

bool OsdAccess::update(Proxy_client &client) {
  bool result = true;
  if (!_filling.load()) {
    ALBA_LOG(INFO, "OsdAccess::update:: filling up");
    std::lock_guard<std::mutex> f_lock(_filling_mutex);
    if (!_filling.load()) {
      _filling.store(true);
      try {
        std::lock_guard<std::mutex> lock(_osd_maps_mutex);
        osd_maps_t infos;
        client.osd_info2(infos);
        _alba_levels.clear();
        _osd_maps.clear();
        for (auto &p : infos) {
          _alba_levels.push_back(std::string(p.first));
          _osd_maps.push_back(std::move(p));
        }
      } catch (std::exception &e) {
        ALBA_LOG(INFO,
                 "OSDAccess::update: exception while filling up: " << e.what());
        result = false;
      }
      _filling.store(false);
      _filling_cond.notify_all();
    }
  } else {
    std::unique_lock<std::mutex> lock(_filling_mutex);
    _filling_cond.wait(lock, [this] { return (this->_filling.load()); });
  }
  return result;
}

std::vector<alba_id_t> OsdAccess::get_alba_levels(Proxy_client &client) {
  if (_alba_levels.size() == 0) {
    if (!this->update(client)) {
      throw osd_access_exception(
          -1, "initial update of osd infos in osd_access failed");
    }
  }
  return _alba_levels;
}

int OsdAccess::read_osds_slices(
    std::map<osd_t, std::vector<asd_slice>> &per_osd) {

  int rc = 0;
  for (auto &item : per_osd) {
    osd_t osd = item.first;
    auto &osd_slices = item.second;
    // TODO this could be done in parallel
    rc = _read_osd_slices_asd_direct_path(osd, osd_slices);
    if (rc) {
      break;
    }
  }
  return rc;
}

int OsdAccess::_read_osd_slices_asd_direct_path(
    osd_t osd, std::vector<asd_slice> &slices) {
  auto maybe_ic = _find_osd(osd);
  if (nullptr == maybe_ic) {
    ALBA_LOG(WARNING, "have context, but no info?");
    return -1;
  }
  auto p = asd_connection_pools.get_connection_pool(maybe_ic->first,
                                                    _connection_pool_size);
  if (nullptr == p) {
    return -1;
  }
  auto connection = p->get_connection();

  if (connection) {
    try {
      // TODO 1 batch call...
      for (auto &slice_ : slices) {
        alba::asd_protocol::slice slice__;
        slice__.offset = slice_.offset;
        slice__.length = slice_.len;
        slice__.target = slice_.target;
        std::vector<alba::asd_protocol::slice> slices_{slice__};
        connection->partial_get(slice_.key, slices_);
      }
      p->release_connection(std::move(connection));
      return 0;
    } catch (std::exception &e) {
      p->report_failure();
      ALBA_LOG(INFO, "exception in _read_osd_slices_asd_direct_path for osd "
                         << osd << " " << e.what());
      return -1;
    }
  } else {
    // asd was disqualified
    return -2;
  }
}

using namespace gobjfs::xio;
int OsdAccess::_read_osd_slices_xio(osd_t osd, std::vector<asd_slice> &slices) {

  ALBA_LOG(DEBUG, "OsdAccess::_read_osd_slices(" << osd << ")");

  auto ctx = _find_ctx(osd);

  if (ctx == nullptr) {
    std::shared_ptr<gobjfs::xio::client_ctx_attr> ctx_attr = ctx_attr_new();

    auto maybe_ic = _find_osd(osd);
    if (nullptr == maybe_ic) {
      ALBA_LOG(WARNING, "have context, but no info?");
      return -1;
    }
    const info_caps &ic = *maybe_ic;
    const auto &osd_info = ic.first;
    const auto &osd_caps = ic.second;
    std::string transport_name;
    if (boost::none == osd_caps.rora_transport) {
      if (osd_info.use_rdma) {
        transport_name = "rdma";
      } else {
        transport_name = "tcp";
      }
    } else {
      transport_name = *osd_caps.rora_transport;
    }
    if (boost::none == osd_caps.rora_port) {
      ALBA_LOG(DEBUG, "osd " << osd << " has no rora port. returning -1");
      return -1;
    }

    int backdoor_port = *osd_caps.rora_port;

    std::string ip;
    if (osd_caps.rora_ips != boost::none) {
      // TODO randomize the ip used here
      ip = (*osd_caps.rora_ips)[0];
    } else {
      ip = osd_info.ips[0];
    }

    ALBA_LOG(DEBUG, "OsdAccess::_read_osd_slices osd_id="
                        << osd << ", backdoor_port=" << backdoor_port
                        << ", ip=" << ip << ", transport=" << transport_name);

    int err =
        ctx_attr_set_transport(ctx_attr, transport_name, ip, backdoor_port);
    if (err != 0) {
      throw osd_access_exception(err, "ctx_attr_set_transport");
    }

    ctx = ctx_new(ctx_attr);
    err = ctx_init(ctx);
    if (err != 0) {
      throw osd_access_exception(err, "ctx_init");
    }
    _set_ctx(osd, ctx);
  }
  size_t n_slices = slices.size();
  std::vector<giocb *> iocb_vec(n_slices);
  std::vector<giocb> giocb_vec(n_slices);
  std::vector<std::string> key_vec(n_slices);

  for (uint i = 0; i < n_slices; i++) {
    asd_slice &slice = slices[i];
    giocb &iocb = giocb_vec[i];
    iocb.aio_offset = slice.offset;
    iocb.aio_nbytes = slice.len;
    iocb.aio_buf = slice.target;
    iocb_vec[i] = &iocb;
    key_vec[i] = slice.key;
  }

  int ret = aio_readv(ctx, key_vec, iocb_vec);
  if (ret == 0) {
    ret = aio_suspendv(ctx, iocb_vec, nullptr /* timeout */);
  }
  for (auto &elem : iocb_vec) {
    auto retcode = aio_return(ctx, elem);
    if (ret != 0) {
      ALBA_LOG(ERROR, "aio_return retcode:" << retcode << ", osd_id=" << osd
                                            << ", ret=" << ret);
    }
    aio_finish(ctx, elem);
  }
  // ALBA_LOG(DEBUG, "osd_access: ret=" << ret);
  if (ret != 0 && ctx_is_disconnected(ctx)) {
    ALBA_LOG(INFO, "removing bad ctx");
    _remove_ctx(osd);
  }
  return ret;
}

std::ostream &operator<<(std::ostream &os, const asd_slice &s) {
  os << "asd_slice{ _"
     << ", " << s.offset << ", " << s.len << ", _"
     << "}";
  return os;
}
}
}
