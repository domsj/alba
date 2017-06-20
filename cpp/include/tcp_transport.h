/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#pragma once
#include "transport.h"

namespace alba {
namespace transport {
class TCP_transport : public Transport {

public:
  TCP_transport(const std::string &ip, const std::string &port,
                const std::chrono::steady_clock::duration &timeout);

  void write_exact(const char *buf, int len) override;
  void read_exact(char *buf, int len) override;

  void
  expires_from_now(const std::chrono::steady_clock::duration &timeout) override;

  ~TCP_transport();

private:
  boost::asio::io_service _io_service;
  boost::asio::ip::tcp::socket _socket;
  boost::asio::deadline_timer _deadline;
  void output(llio::message_builder &mb);
  llio::message input();
  boost::posix_time::milliseconds _timeout;
  void _check_deadline();
};
}
}
