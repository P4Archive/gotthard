#!/usr/bin/env python
import boto.ec2 as ec2
import argparse

from common import *

def get_args():
    parser = argparse.ArgumentParser(description='List ec2 vms')
    parser.add_argument('-d', '--dns-only', help='', action='store_true', default=False)
    args = parser.parse_args()
    return args

def instance_status(conn, instid):
    return conn.get_all_instance_status(instance_ids=[instid], include_all_instances=True)[0]

if __name__ == '__main__':
    args = get_args()

    for region in REGIONS:
        conn = ec2.connect_to_region(region)
        # for inst in conn.get_all_instance_status():
        #     print inst.instance_status
        for inst in conn.get_only_instances():
            if args.dns_only:
                dns = inst.public_dns_name
                if dns:
                    print '%s' % (inst.public_dns_name)
            else:
                print '%s: %s at %s is %s(%d)' % ((inst.tags['Name'] if 'Name' in inst.tags else 'unnamed'),
                                                  inst.id,
                                                  inst.region.name,
                                                  inst.state, inst.state_code)
                status = instance_status(conn, inst.id)
                print '  status:  %s' % (status.instance_status)
                print '  dns:     %s' % (inst.public_dns_name)
                print '  public:  %s' % (inst.ip_address)
                print '  private: %s' % (inst.private_ip_address)
