# ALBA Proxy
The ALBA proxy sits between the [Volume Driver](https://github.com/openvstorage/volumedriver) and the [ALBA backend](README.md). It runs as a process on the Storage Router host and takes the SCOs coming from the Volume Driver and stores them according to a policy on the different OSDs of the backend.
There is an ALBA Proxy per vPool which is available on the Storage Router. The port on which a proxy is listening for a certain vPool can be found in the config file of the proxy (`/opt/OpenvStorage/config/storagedriver/storagedriver/<vpool_name>_alba.json`).


## ALBA Proxy Config files
There is an ALBA Proxy configuration file per vPool.  More info on the proxy config files can be found [here](https://openvstorage.gitbooks.io/framework/content/docs/etcd.html)

## ALBA Proxy Log files
The log files for the ALBA proxy can be found under `/var/log/upstart/ovs-albaproxy_<vpool_name>.log`.

## Basic commands
### List all ALBA proxies
All are running as a service with as name `ovs-albaproxy_<vpool_name>`.

```
ovs monitor services

...
ovs-albaproxy_poc01-vpool-ovs start/running, process 16268

```
In this case we have a proxy for the vPool `poc01-vpool-ovs`.


### Start a proxy
To start the proxy:

```
start ovs-albaproxy_<vpool_name>
```

### Restart a proxy
To restart a proxy:

```
restart ovs-albaproxy_<vpool_name>
```

### Stop a proxy
To stop a proxy
```
stop ovs-albaproxy_<vpool_name>
```

### Get the version of the ALBA proxy
To see the version of the proxy running, execute in the shell:
```
alba proxy-get-version -h 127.0.0.1 -p 26203
    (0, 7, 3, "0.7.3-0-gd2ea678")
```

### List all namespaces registered on the ALBA proxy
To list all namespaces, execute in the shell:
```
root@cmp02:~# alba proxy-list-namespaces -h 127.0.0.1 -p 26203
Found 3 namespaces: ["17c2b966-4e52-40fa-9f87-0d241a14157d";
 "dafa3036-d47e-4ebf-ba65-0cf46a0a9a1b";
 "fd-poc01-vpool-ovs-4d8fa3f7-3632-41db-b18f-6ecbe4782c51"]
```

### List objects of a namespace
To list the objects of a namespace, execute in the shell
```
root@cmp02:~# alba proxy-list-objects '183a2397-453a-4377-9537-53d591cd2a37'  -h 127.0.0.1 -p 26203
((100,
  ["00_00000001_00"; "00_00000002_00"; "00_00000003_00"; "00_00000004_00";
   "00_00000005_00"; "00_00000006_00"; "00_00000007_00"; "00_00000008_00";
   "00_00000009_00"; "00_0000000a_00"; "00_0000000b_00"; "00_0000000c_00";
   "00_0000000d_00"; "00_0000000e_00"; "00_0000000f_00"; "00_00000010_00";
   "00_00000011_00"; "00_00000012_00"; "00_00000013_00"; "00_00000014_00";
   "00_00000015_00"; "00_00000016_00"; "00_00000017_00"; "00_00000018_00";
   "00_00000019_00"; "00_0000001a_00"; "00_0000001b_00"; "00_0000001c_00";
   "00_0000001d_00"; "00_0000001e_00"; "00_0000001f_00"; "00_00000020_00";
   "00_00000021_00"; "00_00000022_00"; "00_00000023_00"; "00_00000024_00";
   "00_00000025_00"; "00_00000026_00"; "00_00000027_00"; "00_00000028_00";
   "00_00000029_00"; "00_0000002a_00"; "00_0000002b_00"; "00_0000002c_00";
   "00_0000002d_00"; "00_0000002e_00"; "00_0000002f_00"; "00_00000030_00";
   "00_00000031_00"; "00_00000032_00"; "00_00000033_00"; "00_00000034_00";
   "00_00000035_00"; "00_00000036_00"; "00_00000037_00"; "00_00000038_00";
   "00_00000039_00"; "00_0000003a_00"; "00_0000003b_00"; "00_0000003c_00";
   "00_0000003d_00"; "00_0000003e_00"; "00_0000003f_00"; "00_00000040_00";
   "00_00000041_00"; "00_00000042_00"; "00_00000043_00"; "00_00000044_00";
   "00_00000045_00"; "00_00000046_00"; "00_00000047_00"; "00_00000048_00";
   "00_00000049_00"; "00_0000004a_00"; "00_0000004b_00"; "00_0000004c_00";
   "00_0000004d_00"; "00_0000004e_00"; "00_0000004f_00"; "00_00000050_00";
   "00_00000051_00"; "00_00000052_00"; "00_00000053_00"; "00_00000054_00";
   "00_00000055_00"; "00_00000056_00"; "00_00000057_00"; "00_00000058_00";
   "00_00000059_00"; "00_0000005a_00"; "00_0000005b_00"; "00_0000005c_00";
   "00_0000005d_00"; "00_0000005e_00"; "00_0000005f_00"; "00_00000060_00";
   "00_00000061_00"; "00_00000062_00"; "00_00000063_00"; "00_00000064_00"]),
 true)
```

By default the first 100 objects will be returned. By passing additional arguments you can browse through all objects in the namespace.

### Upload an object to a namespace
To upload an object to a namespace, execute in the shell
```
root@cmp02:~# alba proxy-list-objects '<namespace>' '</path/to/file>' '<key in ALBA>'  -h 127.0.0.1 -p 26203
```
### Benchmark an ALBA proxy
To benchmark an ALBA proxy
```
root@perf-roub-01:~# alba proxy-bench -h 188.165.13.24 -p 26204 5ac4217e-54fb-4d93-a05f-e7ab77342d16 --scenario writes --file=/root/a.log
writes (robust=false):
             100             200             300             400             500             600             700             800             900            1000 (   51.18s; 19.54/s)
            1100            1200            1300            1400            1500            1600            1700            1800            1900            2000 (  106.91s; 18.71/s)
            2100            2200            2300            2400            2500            2600            2700            2800            2900            3000 (  160.17s; 18.73/s)
            3100            3200            3300            3400            3500            3600            3700            3800            3900            4000 (  214.19s; 18.68/s)
            4100            4200            4300            4400            4500            4600            4700            4800            4900            5000 (  269.93s; 18.52/s)
            5100            5200            5300            5400            5500            5600            5700            5800            5900            6000 (  325.21s; 18.45/s)
            6100            6200            6300            6400            6500            6600            6700            6800            6900            7000 (  381.53s; 18.35/s)
            7100            7200            7300            7400            7500            7600            7700            7800            7900            8000 (  436.24s; 18.34/s)
            8100            8200            8300            8400            8500            8600            8700            8800            8900            9000 (  492.31s; 18.28/s)
            9100            9200            9300            9400            9500            9600            9700            9800            9900           10000 (  548.66s; 18.23/s)

writes
 took: 548.656098s or (18.226354 /s)
 latency: 54.865610ms
 min: 32.439947ms
 max: 267.340899ms
 


```


## Use the OVS client to manage an ALBA proxy
The OVS python client allow to manage an ALBA proxy. In the below example we retrieve the proxy version.
```
from ovs.extensions.plugins.albacli import AlbaCLI
AlbaCLI.run('proxy-get-version', extra_params=['-h 127.0.0.1', '-p 2620
```
The output is the Proxy version:
```
'(0, 7, 3, "0.7.3-0-gd2ea678")'
```
