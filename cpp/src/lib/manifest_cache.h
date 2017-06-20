/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#pragma once
#include "lru_cache.h"
#include "manifest.h"
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
namespace alba {
namespace proxy_client {

using namespace proxy_protocol;
typedef std::shared_ptr<ManifestWithNamespaceId> manifest_cache_entry;
typedef ovs::SafeLRUCache<std::string, manifest_cache_entry> manifest_cache;
class ManifestCache {
public:
  static ManifestCache &getInstance();
  void set_capacity(size_t capacity);

  ManifestCache(ManifestCache const &) = delete;
  void operator=(ManifestCache const &) = delete;

  void add(std::string namespace_, std::string alba_id,
           manifest_cache_entry rora_map);

  manifest_cache_entry find(const std::string &namespace_,
                            const std::string &alba_id,
                            const std::string &object_name);

  void invalidate_namespace(const std::string &);

private:
  ManifestCache() {}
  size_t _manifest_cache_capacity = 10000;
  std::mutex _level1_mutex;
  std::map<std::string, std::pair<std::shared_ptr<manifest_cache>,
                                  std::shared_ptr<std::mutex>>>
      _level1;
};
}
}
