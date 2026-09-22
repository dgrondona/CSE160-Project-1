#include "../../includes/packet.h"

module FloodingP{
   provides interface Flooding;

   uses interface SimpleSend as Sender;
}

implementation{
    pack sendPackage;

    enum {
        SEEN_SIZE = 50
    };

    typedef struct packetId {
        uint16_t src;
        uint16_t seq;
    }packetId;

    packetId seenList[SEEN_SIZE];
    uint16_t seenIndex = 0;
    uint16_t mySeq = 1;

    bool seenPacket(uint16_t src, uint16_t seq) {
        int i;
        for (i = 0; i < SEEN_SIZE; i++) {
            if (seenList[i].src == src && seenList[i].seq == seq) {
                return TRUE;
            }
        }
        return FALSE;
    }

    void recordPacket (uint16_t src, uint16_t seq) {
        seenList[seenIndex].src = src;
        seenList[seenIndex].seq = seq;

        seenIndex = (seenIndex + 1) % SEEN_SIZE;
    }

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }

    command error_t Flooding.flood(uint16_t destination, uint8_t *payload){
        error_t result;

        dbg(FLOODING_CHANNEL, "flood called. dest: %d, seq: %d\n", destination, mySeq);

        makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, mySeq, payload, PACKET_MAX_PAYLOAD_SIZE);

        recordPacket(TOS_NODE_ID, mySeq);
        mySeq++;

        result = call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        return result;
    }

    command error_t Flooding.handlePacket(pack msg){
        error_t result;

        dbg(FLOODING_CHANNEL, "recieved src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);

        if (seenPacket(msg.src, msg.seq)) {
            dbg(FLOODING_CHANNEL, "duplicate packet dropped! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return SUCCESS;
        }

        recordPacket(msg.src, msg.seq);

        if (msg.dest == TOS_NODE_ID) {
            dbg(FLOODING_CHANNEL, "packet arrived! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return SUCCESS;
        }

        msg.TTL -= 1;

        if (msg.TTL == 0) {
            dbg(FLOODING_CHANNEL, "packet expired! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return SUCCESS;
        }

        result = call Sender.send(msg, AM_BROADCAST_ADDR);
        return result;
    }
}