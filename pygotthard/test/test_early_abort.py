#!/usr/bin/env python2

# This tests that the switch is forwarding/shortcutting correctly

import argparse
from time import sleep
import sys
sys.path.insert(0, '..')
from pygotthard import *

parser = argparse.ArgumentParser()
parser.add_argument("--log", "-l", type=str, help="filename to write log to", default=None)
parser.add_argument("host", type=str, help="server hostname")
parser.add_argument("port", type=int, help="server port")
args = parser.parse_args()

R, W, RB = GotthardClient.R, GotthardClient.W, GotthardClient.RB

with GotthardClient(store_addr=(args.host, args.port), log_filename=args.log) as cl:

    # Populate the store with two keys:
    res = cl.req([W(1, 'a'), W(2, 'b')])
    assert(res.status == STATUS_OK)
    assert(res.flags.from_switch == 0) # should not have originated at the switch, but store
    assert(len(res.ops) == 2)
    assert(res.op(k=1).type == TXN_UPDATED)
    assert(res.op(k=1).value.rstrip('\0') == 'a')
    assert(res.op(k=2).type == TXN_UPDATED)
    assert(res.op(k=2).value.rstrip('\0') == 'b')

    # Check that reads are not cached
    res = cl.req(R(1))
    assert(res.status == STATUS_OK)
    assert(res.flags.from_switch == 0) # switch should not satisfy reads
    assert(res.ops[0].key == 1)
    assert(res.ops[0].value.rstrip('\0') == 'a')

    # But read-befores should be cached
    res = cl.req(RB(1, 'a'))
    assert(res.status == STATUS_OK)
    assert(res.flags.from_switch == 1) # switch should verify RB
    #assert(len(res.ops) == 0)
    # XXX is this ^^^ necessary? If the switch says OK, we don't care about the
    # value it returns, because we knew it

    # Also bad read-befores
    res = cl.req(RB(1, 'wrong'))
    assert(res.status == STATUS_ABORT)
    assert(res.flags.from_switch == 1) # switch should verify RB
    assert(res.ops[0].key == 1)
    assert(res.ops[0].value.rstrip('\0') == 'a')

    # Switch should abort bad RW transaction
    res = cl.req([RB(1, 'somethingelse'), W(1, 'x')])
    assert(res.status == STATUS_ABORT)
    assert(res.flags.from_switch == 1) # switch should do the abort
    assert(res.ops[0].key == 1) # and tell us current key state
    assert(res.ops[0].value.rstrip('\0') == 'a')

    # Concurrent requests; should only work for Optimistic Abort enabled switches
    t1_id = cl.reqAsync([RB(1, 'a'), W(1, 'b')]) # T1
    sleep(0.001)
    t2_id = cl.reqAsync([RB(1, 'b'), W(1, 'c')]) # T2
    t1res, t2res = cl.recvres(req_id=t1_id), cl.recvres(req_id=t2_id)
    assert(t1res.status == STATUS_OK)
    assert(t2res.status == STATUS_ABORT) # opti abort would accept this; early abort only should not

    # Try a bad RB to get their values from cache
    res = cl.req([RB(1, 'wrong'), RB(2, 'wrong')])
    assert(res.flags.from_switch == 1) # should be cached on switch
    assert(res.status == STATUS_ABORT)
    assert(len(res.ops) == 2)
    assert(res.op(k=1).value.rstrip('\0') == 'b')
    assert(res.op(k=2).value.rstrip('\0') == 'b')

    # If the first frag is OK, but not the second, the switch should not say OK
    res = cl.req([W(i+1, 'good') for i in xrange(GOTTHARD_MAX_OP+1)])
    assert res.status == STATUS_OK, "add some initial values"
    frag1 = [RB(i+1, 'good') for i in xrange(GOTTHARD_MAX_OP)] # OK
    frag2 = [RB(GOTTHARD_MAX_OP+1, 'bad')] # not OK
    ops = frag1 + frag2 # together, they should abort
    res = cl.req(ops)
    assert res.status == STATUS_ABORT
    assert res.op(k=GOTTHARD_MAX_OP+1).value.rstrip('\0') == 'good'

    # Cleanup: send reset flag to store
    res = cl.reset()
    assert res.status == STATUS_OK
    assert len(res.ops) == 0
    res = cl.req(R(1))
    assert res.status == STATUS_OK
    assert res.op(k=1).value.rstrip('\0') == ''
