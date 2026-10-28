#include "../../includes/packet.h"

module FloodingP{
   provides interface Flooding;

   uses interface SimpleSend as Sender;
   uses interface Receive;
}

implementation{
    pack sendPackage;

    // Size of the array of packets we've seen.
    enum {
        SEEN_SIZE = 50
    };

    // packetID contains the src and the seq of the packet.
    typedef struct packetId {
        uint16_t src;
        uint16_t seq;
    }packetId;

    // Array of packetIDs so we can track the packets that we've already seen.
    packetId seenList[SEEN_SIZE];
    uint16_t seenIndex = 0;
    uint16_t mySeq = 1; // Initialize at 1 to not collide with array initialized at 0.

    // Return true if a given packetID is in our seenList.
    bool seenPacket(uint16_t src, uint16_t seq) {
        int i;
        for (i = 0; i < SEEN_SIZE; i++) {
            if (seenList[i].src == src && seenList[i].seq == seq) {
                return TRUE;
            }
        }
        return FALSE;
    }

    // Record packet to the seenList.
    void recordPacket (uint16_t src, uint16_t seq) {
        seenList[seenIndex].src = src;
        seenList[seenIndex].seq = seq;

        seenIndex = (seenIndex + 1) % SEEN_SIZE; // Loop indexer back to beginning to overwrite from the start of the array.
    }

    // Record packet, then send flood.
    error_t sendFlood(uint16_t destination, uint16_t protocol, uint8_t *payload) {
        makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, protocol, mySeq, payload, PACKET_MAX_PAYLOAD_SIZE);

        recordPacket(TOS_NODE_ID, mySeq);
        mySeq++;

        return call Sender.send(sendPackage, AM_BROADCAST_ADDR);
    }

    // Send flood.
    command error_t Flooding.flood(uint16_t destination, uint8_t *payload){
        dbg(FLOODING_CHANNEL, "flood called. dest: %d, seq: %d\n", destination, mySeq);

        return sendFlood(destination, PROTOCOL_PING, payload);
    }

    error_t handlePacket(pack msg){
        dbg(FLOODING_CHANNEL, "received src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);

        // If we've already seen a packet, drop it.
        if (seenPacket(msg.src, msg.seq)) {
            dbg(FLOODING_CHANNEL, "duplicate packet dropped! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return SUCCESS;
        }

        // If we haven't seen a packet, we can record it.
        recordPacket(msg.src, msg.seq);

        // If the packet is for us.
        if (msg.dest == TOS_NODE_ID) {
            dbg(FLOODING_CHANNEL, "packet arrived! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return SUCCESS;
        }

        // Decrement TTL
        msg.TTL -= 1;

        // If the TTL is now 0, the packet has reached the end of its life and we drop it.
        if (msg.TTL == 0) {
            dbg(FLOODING_CHANNEL, "TTL exhausted! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return SUCCESS;
        }

        dbg(FLOODING_CHANNEL, "forwarding src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
        return call Sender.send(msg, AM_BROADCAST_ADDR);
    }

    // Flooding packets come in on their own AM type, so nothing else lands here.
    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
        if (len == sizeof(pack)) {
            pack* myMsg = (pack*) payload;
            handlePacket(*myMsg);
            return msg;
        }
        dbg(FLOODING_CHANNEL, "Unknown Packet Type %d\n", len);
        return msg;
    }
}