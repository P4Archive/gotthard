#define MAX_REG_INST 65000

#define GOTTHARD_PORT 9999

#define GOTTHARD_TYPE_REQ 0
#define GOTTHARD_TYPE_RES 1

#define GOTTHARD_STATUS_OK                  0
#define GOTTHARD_STATUS_ABORT               1
#define GOTTHARD_STATUS_OPTIMISTIC_ABORT    2

#define GOTTHARD_OP_READ    0
#define GOTTHARD_OP_WRITE   1
#define GOTTHARD_OP_VALUE   2
#define GOTTHARD_OP_UPDATE  3

#define GOTTHARD_MAX_OP 10

#include "header.p4"
#include "parser.p4"

metadata intrinsic_metadata_t intrinsic_metadata;


action _nop () {
}


action do_direction_swap (in bit<8> udp_payload_size) { // return the packet to the sender
    // Save old dst IP and port in tmp variable
    req_meta.tmp_ipv4_dstAddr = ipv4.dstAddr;
    req_meta.tmp_udp_dstPort = udp.dstPort;

    ipv4.dstAddr = ipv4.srcAddr;
    ipv4.srcAddr = req_meta.tmp_ipv4_dstAddr;
    ipv4.totalLen = IPV4_HDR_LEN + UDP_HDR_LEN + udp_payload_size;

    udp.dstPort = udp.srcPort;
    udp.srcPort = req_meta.tmp_udp_dstPort;
    udp.checksum = (bit<16>)0; // TODO: update the UDP checksum
    udp.length_ = UDP_HDR_LEN + udp_payload_size;
}

register is_cached_register {
    width: 1;
    instance_count: MAX_REG_INST;
}
register value_register {
    width: 800;
    instance_count: MAX_REG_INST;
}


register req_count_register {
    width: 32;
    instance_count: MAX_REG_INST;
}
register res_count_register {
    width: 32;
    instance_count: MAX_REG_INST;
}
register op_count_register {
    width: 32;
    instance_count: MAX_REG_INST;
}

register loop_count_register {
    width: 32;
    instance_count: MAX_REG_INST;
}

register remaining_register {
    width: 8;
    instance_count: MAX_REG_INST;
}

register req_check_count_register {
    width: 32;
    instance_count: MAX_REG_INST;
}

register resubmit_count_register {
    width: 32;
    instance_count: MAX_REG_INST;
}
metadata req_meta_t req_meta;
metadata res_meta_t res_meta;

action do_req_loop1_before() {
    req_count_register[0] = req_count_register[0] + 1;
    req_count_register[gotthard_hdr.req_id] = req_count_register[0];
    req_meta.loop1_remaining_cnt = gotthard_hdr.op_cnt;
    req_meta.in_loop1 = (bit<1>)1;
}
table t_req_loop1_before { actions { do_req_loop1_before; } size: 1; }

action do_req_loop1_pop() {
    push(gotthard_op2, 1);
    gotthard_op2[0].op_type = gotthard_op[0].op_type;
    gotthard_op2[0].key = gotthard_op[0].key;
    gotthard_op2[0].value = gotthard_op[0].value;
    remove_header(gotthard_op[0]);
    add_header(gotthard_op2[0]);
    pop(gotthard_op, 1);
    req_meta.loop1_remaining_cnt = req_meta.loop1_remaining_cnt - 1;
    udp.checksum = (bit<16>)0; // TODO: update the UDP checksum
}

action do_req_loop1_r() {
    req_meta.has_cache_miss = req_meta.has_cache_miss | (~(is_cached_register[gotthard_op[0].key]));
    do_req_loop1_pop();
}

action do_req_loop1_rb() {
    req_meta.has_cache_miss = req_meta.has_cache_miss | (~(is_cached_register[gotthard_op[0].key]));
    //req_meta.has_invalid_read = req_meta.has_invalid_read | ((bit<1>)(value_register[gotthard_op[0].key] != gotthard_op[0].value));
    do_req_loop1_pop();
}

table t_req_loop1 {
    reads {
        gotthard_op[0].op_type: exact;
    }
    actions {
        do_req_loop1_r;
        do_req_loop1_rb;
        do_req_loop1_pop;
    }
    size: 3;
}

field_list resubmit_req_FL { req_meta; }

action do_req_loop1_resubmit() {
    //resubmit_count_register[gotthard_hdr.req_id] = resubmit_count_register[gotthard_hdr.req_id] + 1;
    resubmit(resubmit_req_FL);
}
table t_req_loop1_resubmit { actions { do_req_loop1_resubmit; } size: 1; }

action do_abort() {
    do_direction_swap(GOTTHARD_HDR_LEN + (gotthard_hdr.op_cnt*GOTTHARD_OP_LEN));
}


table t_abort {
    actions {
        do_abort;
        _nop;
    }
    size: 1;
}


action do_res_check() {
    res_count_register[0] = res_count_register[0] + 1;
    res_count_register[gotthard_hdr.req_id] = res_count_register[gotthard_hdr.req_id] + 1;
    res_meta.remaining_cnt = gotthard_hdr.op_cnt;
    res_meta.index = (bit<8>)0;
    res_meta.loop_started = (bit<1>)1;
    loop_count_register[gotthard_hdr.req_id] = (bit<32>)0;
}

table t_new_res {
    actions {
        do_res_check;
        _drop;
    }
    size: 1;
}

field_list resubmit_res_FL {
    res_meta;
}

action do_loop_res() {
    value_register[gotthard_op[0].key] =
        gotthard_op[0].op_type == (bit<8>)GOTTHARD_OP_UPDATE ?
            gotthard_op[0].value : value_register[gotthard_op[0].key];
    is_cached_register[gotthard_op[0].key] =
        gotthard_op[0].op_type == (bit<8>)GOTTHARD_OP_UPDATE ?
            (bit<1>)1 : is_cached_register[gotthard_op[0].key];

    push(gotthard_op2, 1);
    gotthard_op2[0].op_type = gotthard_op[0].op_type;
    gotthard_op2[0].key = gotthard_op[0].key;
    gotthard_op2[0].value = gotthard_op[0].value;

    remove_header(gotthard_op[0]);
    add_header(gotthard_op2[0]);
    pop(gotthard_op, 1);
    udp.checksum = (bit<16>)0; // TODO: update the UDP checksum

    res_meta.remaining_cnt = res_meta.remaining_cnt - 1;
}

table t_loop_res {
    actions {
        do_loop_res;
    }
    size: 1;
}

action do_loop_res_end() {
    //parse_meta.new_header = (bit<1>)1;
}

table t_loop_res_end {
    actions {
        do_loop_res_end;
    }
    size: 1;
}

action do_resubmit_loop_res() {
    resubmit_count_register[gotthard_hdr.req_id] = resubmit_count_register[gotthard_hdr.req_id] + 1;
    resubmit(resubmit_res_FL);
}


table t_resubmit_loop_res {
    actions {
        do_resubmit_loop_res;
        _nop;
    }
    size: 1;
}



action _drop() {
    drop();
}

header_type routing_metadata_t {
    fields {
        bit<32> nhop_ipv4;
    }
}

metadata routing_metadata_t routing_metadata;


action set_nhop(in bit<32> nhop_ipv4, in bit<9> port) {
    routing_metadata.nhop_ipv4 = nhop_ipv4;
    standard_metadata.egress_spec = port;
    ipv4.ttl = ipv4.ttl - 1;
}

table ipv4_lpm {
    reads {
        ipv4.dstAddr : lpm;
    }
    actions {
        set_nhop;
        _drop;
    }
    size: 1024;
}

action set_dmac(in bit<48> dmac) {
    ethernet.dstAddr = dmac;
}

table forward {
    reads {
        routing_metadata.nhop_ipv4 : exact;
    }
    actions {
        set_dmac;
        _drop;
    }
    size: 512;
}

action rewrite_mac(in bit<48> smac) {
    ethernet.srcAddr = smac;
}

table send_frame {
    reads {
        standard_metadata.egress_port: exact;
    }
    actions {
        rewrite_mac;
        _drop;
    }
    size: 256;
}

control ingress {
    if (valid(ipv4)) {
        if (valid(gotthard_hdr)) {
            if (gotthard_hdr.msg_type == GOTTHARD_TYPE_REQ) {
                if (req_meta.in_loop1 == 0) {
                    apply(t_req_loop1_before);
                }

                if (req_meta.loop1_remaining_cnt > 0) {
                    apply(t_req_loop1);
                    if (req_meta.loop1_remaining_cnt > 0) {
                        apply(t_req_loop1_resubmit);
                    }
                }

                //if (req_meta.is_aborted == 1 and req_meta.loop1_remaining_cnt == 0) {
                //    apply(t_abort);
                //}
            }
            else {
                if (res_meta.loop_started == 0) {
                    apply(t_new_res);
                }
                if (res_meta.remaining_cnt > 0) {
                    apply(t_loop_res);
                    if (res_meta.remaining_cnt > 0) {
                        apply(t_resubmit_loop_res);
                    }
                    else {
                        apply(t_loop_res_end);
                    }
                }

            }

        }

        if(req_meta.loop1_remaining_cnt == 0 and res_meta.remaining_cnt == 0) {
            apply(ipv4_lpm);
            apply(forward);
        }
    }
}

control egress {
    apply(send_frame);
}
