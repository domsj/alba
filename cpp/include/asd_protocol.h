/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#pragma once

#include "alba_common.h"
#include "llio.h"

namespace alba {
namespace asd_protocol {

using std::string;
using std::vector;

using llio::message_builder;
using llio::message;

enum return_code : uint32_t {
  OK = 0,
  UNKNOWN = 1,
  ASSERT_FAILED = 2,
  UNKNOWN_OPERATION = 4,
  FULL = 6,
  PROTOCOL_VERSION_MISMATCH = 7
};

enum command : uint32_t { GET_VERSION = 7, PARTIAL_GET = 11, SLOWNESS = 14 };

struct Status {
  void set_rc(uint32_t return_code) { _return_code = return_code; }

  bool is_ok() const { return _return_code == (uint32_t)return_code::OK; }

  uint32_t _return_code;
};

struct slice {
  uint32_t offset;
  uint32_t length;
  byte *target;
};

extern const string _MAGIC;
extern const uint32_t _VERSION;

void make_prologue(message_builder &mb, boost::optional<string> long_id);

void write_partial_get_request(message_builder &mb, string &key,
                               vector<slice> &slices);
void read_partial_get_response(message &m, Status &status, bool &success);

typedef boost::optional<std::pair<double, double>> slowness_t;

void write_set_slowness_request(message_builder &, const slowness_t &);
void read_set_slowness_response(message &, Status &);

void write_get_version_request(message_builder &mb);

void read_get_version_response(message &m, Status &status, int32_t &major,
                               int32_t &minor, int32_t &patch,
                               std::string &hash);
}
}
