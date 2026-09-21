#include "../../includes/packet.h"

module FloodingP{
   provides interface Flooding;

   uses interface SimpleSend as Sender;
}

implementation{
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

    command error_t Flooding.flood(uint16_t destination, uint8_t *payload){
        dbg(FLOODING_CHANNEL, "flood called: %d\n", destination);
        return SUCCESS;
    }

    command error_t Flooding.handlePacket(pack msg){
        dbg(FLOODING_CHANNEL, "handlePacket called!\n");
        return SUCCESS;
    }
}