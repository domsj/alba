/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#include "proxy_client.h"
#include "rora_proxy_client.h"

#include "transport_helper.h"

#include "alba_logger.h"

#include <iostream>

#include <boost/lexical_cast.hpp>
#include <errno.h>

namespace alba {
namespace proxy_client {

std::unique_ptr<GenericProxy_client>
_make_proxy_client(const std::string &ip, const std::string &port,
                   const std::chrono::steady_clock::duration &timeout,
                   const transport::Kind &transport) {
  return std::make_unique<GenericProxy_client>(
      timeout, alba::transport::make_transport(transport, ip, port, timeout));
}

std::unique_ptr<Proxy_client>
make_proxy_client(const std::string &ip, const std::string &port,
                  const std::chrono::steady_clock::duration &timeout,
                  const transport::Kind &transport,
                  const boost::optional<RoraConfig> &rora_config) {

  std::unique_ptr<GenericProxy_client> inner_client =
      _make_proxy_client(ip, port, timeout, transport);

  if (boost::none == rora_config) {
    // work around g++ 4.[8|9] bug:
    return std::unique_ptr<Proxy_client>(inner_client.release());
  } else {
    ALBA_LOG(INFO, "make_proxy_client( rora_config=" << *rora_config << " )");
    return std::unique_ptr<Proxy_client>(
        new RoraProxy_client(std::move(inner_client), *rora_config));
  }
}

void Proxy_client::apply_sequence(const std::string &namespace_,
                                  const write_barrier write_barrier,
                                  const sequences::Sequence &seq) {
  this->apply_sequence(namespace_, write_barrier, seq._asserts, seq._updates);
}

std::ostream &operator<<(std::ostream &os, const RoraConfig &cfg) {
  os << "RoraConfig{"
     << " manifest_cache_size= " << cfg.manifest_cache_size
     << ", asd_connection_pool_size= " << cfg.asd_connection_pool_size << " }";
  return os;
}
}
}
