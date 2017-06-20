/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/


#pragma once

#include "boolean_enum.h"
#include "checksum.h"
#include "llio.h"
#include <memory>

namespace alba {
namespace proxy_client {
namespace sequences {

class Assert {
public:
  virtual ~Assert(){};
  virtual void to(llio::message_builder &) const = 0;
};

class AssertObjectExists final : public Assert {
public:
  AssertObjectExists(const std::string &name) : _name(name){};

  void to(llio::message_builder &mb) const override {
    mb.add_type(1);
    llio::to(mb, _name);
  }

  std::string _name;
};

class AssertObjectDoesNotExist final : public Assert {
public:
  AssertObjectDoesNotExist(const std::string &name) : _name(name){};

  void to(llio::message_builder &mb) const override {
    mb.add_type(2);
    llio::to(mb, _name);
  }

  std::string _name;
};

class AssertObjectHasId final : public Assert {
public:
  AssertObjectHasId(const std::string &name, const std::string &object_id)
      : _name(name), _object_id(object_id){};

  void to(llio::message_builder &mb) const override {
    mb.add_type(3);
    llio::to(mb, _name);
    llio::to(mb, _object_id);
  }

  std::string _name;
  std::string _object_id;
};

class AssertObjectHasChecksum final : public Assert {
public:
  AssertObjectHasChecksum(const std::string &name,
                          std::unique_ptr<alba::Checksum> cs)
      : _name(name), _cs(std::move(cs)){};

  void to(llio::message_builder &mb) const override {
    mb.add_type(4);
    llio::to(mb, _name);
    _cs->to(mb);
  }

  std::string _name;
  std::unique_ptr<alba::Checksum> _cs;
};

class Update {
public:
  virtual ~Update(){};
  virtual void to(llio::message_builder &) const = 0;
};

class UpdateUploadObjectFromFile final : public Update {
public:
  UpdateUploadObjectFromFile(const std::string &name,
                             const std::string &file_name,
                             const alba::Checksum *cs_o)
      : _name(name), _file_name(file_name), _cs_o(cs_o){};

  void to(llio::message_builder &mb) const override {
    mb.add_type(1);
    llio::to(mb, _name);
    llio::to(mb, _file_name);
    if (_cs_o == nullptr) {
      llio::to<boost::optional<const Checksum *>>(mb, boost::none);
    } else {
      llio::to(mb, boost::optional<const Checksum *>(_cs_o));
    }
  }

  std::string _name;
  std::string _file_name;
  const alba::Checksum *_cs_o;
};

class UpdateUploadObject final : public Update {
public:
  /* creates an upload from supplied buffer.
   * The data buffer needs to be kept alive by the user until
   * Proxy_client::apply_sequence is called.
   *
   * performance note:
   *    when this update is serialized, there will be a copy of the data.
   *
   */
  UpdateUploadObject(const std::string &name, const uint8_t *data,
                     const uint32_t size, const alba::Checksum *cs_o)
      : _name(name), _data(data), _size(size), _cs_o(cs_o){};

  void to(llio::message_builder &mb) const override {
    mb.add_type(2);
    llio::to(mb, _name);
    llio::to(mb, _size);
    mb.add_raw((const char *)_data, _size); // copies
    if (_cs_o == nullptr) {
      llio::to<boost::optional<const Checksum *>>(mb, boost::none);
    } else {
      llio::to(mb, boost::optional<const Checksum *>(_cs_o));
    }
  }

  std::string _name;
  const uint8_t *_data;
  const uint32_t _size;
  const alba::Checksum *_cs_o;
};

class UpdateDeleteObject final : public Update {
public:
  UpdateDeleteObject(const std::string &name) : _name(name){};

  void to(llio::message_builder &mb) const override {
    mb.add_type(3);
    llio::to(mb, _name);
  }

  std::string _name;
};

BOOLEAN_ENUM(ObjectExists);

class Sequence {
public:
  Sequence(size_t assert_size_hint = 0, size_t update_size_hint = 0) {
    if (assert_size_hint)
      _asserts.reserve(assert_size_hint);
    if (update_size_hint)
      _updates.reserve(update_size_hint);
  }

  Sequence &add_assert(const std::string &name, ObjectExists should_exist) {
    if (should_exist == ObjectExists::T) {
      _asserts.push_back(std::shared_ptr<Assert>(new AssertObjectExists(name)));
    } else {
      _asserts.push_back(
          std::shared_ptr<Assert>(new AssertObjectDoesNotExist(name)));
    }
    return *this;
  }

  Sequence &add_assert_object_id(const std::string &name,
                                 const std::string &object_id) {
    _asserts.push_back(
        std::shared_ptr<Assert>(new AssertObjectHasId(name, object_id)));
    return *this;
  }

  Sequence &add_assert_checksum(const std::string &name,
                                std::unique_ptr<alba::Checksum> cs) {
    _asserts.push_back(std::shared_ptr<Assert>(
        new AssertObjectHasChecksum(name, std::move(cs))));
    return *this;
  }

  Sequence &add_upload_fs(const std::string &name, const std::string &path,
                          const alba::Checksum *cs_o) {
    _updates.push_back(std::shared_ptr<Update>(
        new UpdateUploadObjectFromFile(name, path, cs_o)));
    return *this;
  }

  Sequence &add_upload(const std::string &name, const uint8_t *data,
                       const uint32_t size, const alba::Checksum *cs_o) {
    _updates.push_back(
        std::make_shared<UpdateUploadObject>(name, data, size, cs_o));
    return *this;
  }
  Sequence &add_delete(const std::string &name) {
    _updates.push_back(std::shared_ptr<Update>(new UpdateDeleteObject(name)));
    return *this;
  }

  std::vector<std::shared_ptr<Assert>> _asserts;
  std::vector<std::shared_ptr<Update>> _updates;
};
}
}
}
