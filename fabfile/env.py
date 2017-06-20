'''
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
'''

import os

cwd = os.getcwd()

def env_or_default(key, default):
    if os.environ.has_key(key):
        return os.environ[key]
    else:
        return default

def is_true(tls):
    return tls == 'True' or tls == 'true' or tls == True

ARAKOON_HOME = env_or_default("ARAKOON_HOME",
                              "%s/workspace/ARAKOON" % os.environ['HOME'])
ARAKOON_BIN = env_or_default("ARAKOON_BIN",
                         "%s/arakoon/arakoon.native" % ARAKOON_HOME)

ALBA_BIN = env_or_default("ALBA_BIN",
                          "%s/ocaml/alba.native" % cwd)

ALBA_PLUGIN_HOME = env_or_default("ALBA_PLUGIN_HOME",
                                  "%s/ocaml" % cwd)

WORKSPACE = env_or_default("WORKSPACE", "")
ALBA_BASE_PATH = "%s/tmp/alba" % WORKSPACE
ALBA_ASD_PATH_T = env_or_default("ALBA_ASD_PATH_T", ALBA_BASE_PATH + "/asd/%02i")
ARAKOON_PATH = "%s/tmp/arakoon" % WORKSPACE

KINDS = ["ASD","KINETIC"]
env = {
    'alba_dev' : cwd,
    'alba_plugin_path' : ALBA_PLUGIN_HOME,
    'alba_bin' : ALBA_BIN,
    'kinetic_bin': '%s/bin/start_kinetic.sh' % cwd,
    'asd_path_t': ALBA_ASD_PATH_T,
    'arakoon_bin' : ARAKOON_BIN,
    'alba_tls' : env_or_default('ALBA_TLS', 'False'),
    'monitoring_file' : "%s/tmp/alba/monitor.txt" % WORKSPACE
}

arakoon_nodes = ["arakoon_0", "arakoon_1", "witness_0"]
arakoon_config_file = "%s/cfg/test.ini" % cwd

TLS = {
    'arakoon_config_file' : "%s/cfg/test_tls.ini" % cwd,
    'root_dir' : ARAKOON_PATH,
}

for node in arakoon_nodes:
    TLS[node] = '%s/%s' % (ARAKOON_PATH, node)


# 2 node cluster that can evolve into 3 node cluster above
arakoon_nodes_2 = ["arakoon_0", "witness_0"]
arakoon_config_file_2 = "%s/cfg/test_2.ini" % cwd


namespace = "demo"

N = 12
default_kind = "ASD"
