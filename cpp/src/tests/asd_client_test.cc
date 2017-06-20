/*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*/

#include "asd_client.h"
#include "alba_common.h"
#include "asd_access.h"
#include "proxy_protocol.h"
#include "tcp_transport.h"
#include "gtest/gtest.h"
#include <chrono>

// setup cpp -> schiet key in nen asd
// liefst met data die ik gemakkelijk kan verifieren?
// hmm, mss alba binary (of iets random), en die file dan hier ook lezen...
// hier partial read doen en zien

using std::string;
using std::vector;
using alba::byte;
using alba::transport::Transport;
using alba::transport::TCP_transport;
using alba::asd_protocol::slice;
using alba::asd_client::Asd_client;
using namespace std::chrono;

std::unique_ptr<Asd_client> make_client(const steady_clock::duration &timeout) {
  string ip = getenv("ALBA_ASD_IP");
  string port = "8000";

  auto transport =
      std::unique_ptr<Transport>(new TCP_transport(ip, port, timeout));
  using namespace std;
  auto asd_p = std::unique_ptr<Asd_client>(
      new Asd_client(timeout, std::move(transport), boost::none));
  return asd_p;
}

TEST(asd_client, partial_read) {
  const steady_clock::duration timeout = seconds(1);
  auto asd = make_client(timeout);

  slice slice1;
  byte target[50];
  slice1.offset = 0;
  slice1.length = 50;
  slice1.target = target;
  auto slices = vector<slice>{slice1};
  string key = "key1";

  asd->partial_get(key, slices);

  byte expected_target[50];
  memset(expected_target, (int)'a', 50);
  EXPECT_EQ(0, memcmp(target, expected_target, 50));

  memset(target, (int)'b', 50);

  asd->partial_get(key, slices);
  EXPECT_EQ(0, memcmp(target, expected_target, 50));
}

void _dump_version(std::tuple<int32_t, int32_t, int32_t, std::string> &v) {
  int32_t major = std::get<0>(v);
  int32_t minor = std::get<1>(v);
  int32_t patch = std::get<2>(v);
  std::string hash = std::get<3>(v);
  ALBA_LOG(INFO, "version (" << major << ", " << minor << ", " << patch << ")-"
                             << hash);
}

TEST(asd_client, timeouts) {
  int timeout_s = 10;
  const steady_clock::duration timeout = seconds(timeout_s);
  auto asd = make_client(timeout);

  alba::asd_protocol::slowness_t fast{boost::none};
  asd->set_slowness(fast);
  ALBA_LOG(DEBUG, "asd should be fast again");
  auto r0 = asd->get_version();
  _dump_version(r0);
  r0 = asd->get_version();
  _dump_version(r0);
  auto s0 = std::make_pair<double, double>(20.0, 1.0);
  auto slowness = alba::asd_protocol::slowness_t{s0};
  asd->set_slowness(slowness);
  ALBA_LOG(DEBUG, "asd should be too slow for me");
  double t0 = alba::stuff::timestamp_millis();
  double delta;
  try {
    ALBA_LOG(INFO, "this should take a while... and fail");
    auto r = asd->get_version();
    _dump_version(r);
    EXPECT_EQ(true, false);
  } catch (std::exception &e) {
    ALBA_LOG(INFO, "EXPECTED EXCEPTION:" << e.what());
    double t1 = alba::stuff::timestamp_millis();
    delta = t1 - t0;
    std::cout << "t0:" << t0 << " t1:" << t1 << std::endl;
    std::cout << "delta:" << delta << std::endl;
    EXPECT_NEAR(delta, (double)timeout_s, 0.5);
  }
  // clean up
  make_client(timeout)->set_slowness(fast);
}

TEST(asd_access, get_connection) {
  // this one does not exist:
  string ip = "172.26.1.15";
  uint32_t port = 64000;
  using namespace alba::proxy_protocol;
  // const steady_clock::duration timeout = milliseconds(100);
  auto info = std::unique_ptr<OsdInfo>(new OsdInfo);
  info->ips = std::vector<string>{ip};
  info->port = port;
  info->use_rdma = false;

  alba::asd::ConnectionPool p(std::move(info), 5, std::chrono::seconds(1));
  auto c = p.get_connection();
  EXPECT_EQ(nullptr, c);
}
