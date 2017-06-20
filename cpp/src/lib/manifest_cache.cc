/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#include "manifest_cache.h"

namespace alba {
namespace proxy_client {

using std::string;

ManifestCache &ManifestCache::getInstance() {
  static ManifestCache instance;
  return instance;
}

void ManifestCache::set_capacity(size_t capacity) {
  std::lock_guard<std::mutex> lock(_level1_mutex);
  _manifest_cache_capacity = capacity;
}

string make_key(const string alba_id, const string object_name) {
  return alba_id + object_name;
}

void ManifestCache::add(string namespace_, string alba_id,
                        manifest_cache_entry mfp) {
  ALBA_LOG(DEBUG, "ManifestCache::add namespace=" << namespace_
                                                  << ", alba_id=" << alba_id
                                                  << ", mfp=" << *mfp);

  std::shared_ptr<manifest_cache> mcp = nullptr;
  std::shared_ptr<std::mutex> mp = nullptr;
  {
    std::lock_guard<std::mutex> lock(_level1_mutex);
    auto it1 = _level1.find(namespace_);

    if (it1 == _level1.end()) {
      ALBA_LOG(INFO, "ManifestCache::add namespace:'"
                         << namespace_ << "' : new manifest cache");
      std::shared_ptr<manifest_cache> mc(
          new manifest_cache(_manifest_cache_capacity));
      std::shared_ptr<std::mutex> mm(new std::mutex);
      auto p = std::make_pair(mc, mm);
      _level1[namespace_] = std::move(p);
      it1 = _level1.find(namespace_);
    } else {
      ALBA_LOG(DEBUG, "ManifestCache::add namespace:'"
                          << namespace_ << "' : existing manifest cache");
    }
    const auto &v = it1->second;
    mcp = v.first;
    mp = v.second;
  }

  manifest_cache &manifest_cache = *mcp;
  manifest_cache.insert(make_key(alba_id, mfp->name), std::move(mfp));
}

manifest_cache_entry ManifestCache::find(const string &namespace_,
                                         const string &alba_id,
                                         const string &object_name) {
  std::pair<std::shared_ptr<manifest_cache>, std::shared_ptr<std::mutex>> vp;
  {
    std::lock_guard<std::mutex> g(_level1_mutex);
    auto it = _level1.find(namespace_);
    if (it == _level1.end()) {
      return nullptr;
    } else {
      vp = it->second;
    }
  }
  auto &map = *vp.first;
  auto &mm = *vp.second;
  {
    std::lock_guard<std::mutex> g(mm);
    const auto &maybe_elem = map.find(make_key(alba_id, object_name));
    if (boost::none == maybe_elem) {
      return nullptr;
    } else {
      return *maybe_elem;
    }
  }
}

void ManifestCache::invalidate_namespace(const string &namespace_) {
  ALBA_LOG(DEBUG, "ManifestCache::invalidate_namespace(" << namespace_ << ")");
  std::lock_guard<std::mutex> g(_level1_mutex);
  auto it = _level1.find(namespace_);
  if (it != _level1.end()) {
    _level1.erase(it);
  }
}
}
}
