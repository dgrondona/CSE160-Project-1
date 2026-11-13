#ifndef TCP_H
#define TCP_H

#include "packet.h"

enum{
    TCP_HEADER_LENGTH = 8,
    TCP_MAX_DATA = PACKET_MAX_PAYLOAD_SIZE - TCP_HEADER_LENGTH // 20 - 8 = 12 data bytes per segment.
};

enum{
    TCP_SYN = 0x1,
    TCP_ACK = 0x2,
    TCP_FIN = 0x4
};

// Sits in the IP payload. Addresses come from the IP header, so only ports are here.
// flagsLen packs the flags into the high 4 bits and the data length (0 to 12) into the low 4.
typedef nx_struct tcpSegment{
    nx_uint8_t srcPort;
    nx_uint8_t destPort;
    nx_uint16_t seq;
    nx_uint16_t ack;
    nx_uint8_t window;
    nx_uint8_t flagsLen;
    nx_uint8_t data[TCP_MAX_DATA];
}tcpSegment;

// Fails to compile if the segment doesn't exactly fill the IP payload.
typedef char tcpSizeCheck[(sizeof(tcpSegment) == PACKET_MAX_PAYLOAD_SIZE) ? 1 : -1];

uint8_t tcpFlags(tcpSegment* seg){
    return seg->flagsLen >> 4;
}

uint8_t tcpLen(tcpSegment* seg){
    return seg->flagsLen & 0x0F;
}

// Sequence numbers are 16 bits and wrap, so compare by signed distance instead of < and >.
bool seqLT(uint16_t a, uint16_t b){
    return (int16_t)(a - b) < 0;
}

bool seqLEQ(uint16_t a, uint16_t b){
    return (int16_t)(a - b) <= 0;
}

#endif
