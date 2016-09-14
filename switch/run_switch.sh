#!/bin/bash
# Source: https://github.com/usi-systems/p4benchmark/blob/master/vlan/run_switch.sh

PROG="simple_router"

THIS_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $THIS_DIR/env.sh

P4C_BM_SCRIPT=$P4C_BM_PATH/p4c_bm/__main__.py

set -m
$P4C_BM_SCRIPT p4src/$PROG.p4 --json $PROG.json --p4-v1.1

if [ $? -ne 0 ]; then
echo "p4 compilation failed"
exit 1
fi

SWITCH_PATH=$BMV2_PATH/targets/simple_switch/simple_switch

CLI_PATH=$BMV2_PATH/tools/runtime_CLI.py

sudo echo "sudo" > /dev/null
sudo $SWITCH_PATH >/dev/null 2>&1
sudo $SWITCH_PATH $PROG.json \
    -i 0@veth0 -i 1@veth2 -i 2@veth4 -i 3@veth6 -i 4@veth8 \
    --log-console \
    --pcap &
sleep 2
echo "**************************************"
echo "Sending commands to switch through CLI"
echo "**************************************"
$CLI_PATH --json $PROG.json < commands.txt
echo "READY!!!"
fg
