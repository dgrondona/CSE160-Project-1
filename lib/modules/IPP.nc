#include "../../includes/packet.h"

module IPP{
   provides interface IP;

   uses interface SimpleSend as Sender;
   uses interface Receive;
   uses interface DistanceVector;
}

implementation{
    pack sendPackage;
    uint16_t mySeq = 0;

    // Send msg to the next hop for its destination. If there's no route, drop it. Never fall back to flooding.
    error_t forward(pack msg) {
        uint16_t nextHop;
        uint8_t cost;

        if (!call DistanceVector.lookup(msg.dest, &nextHop, &cost)) {
            dbg(ROUTING_CHANNEL, "no route! packet dropped. src: %d, dest: %d, seq: %d\n", msg.src, msg.dest, msg.seq);
            return FAIL;
        }

        if (call Sender.send(msg, nextHop) != SUCCESS) {
            dbg(ROUTING_CHANNEL, "send failed! packet dropped. src: %d, dest: %d, seq: %d\n", msg.src, msg.dest, msg.seq);
            return FAIL;
        }

        dbg(ROUTING_CHANNEL, "Routing Packet - src: %d, dest: %d, seq: %d, next hop: %d, cost: %d\n", msg.src, msg.dest, msg.seq, nextHop, cost);
        return SUCCESS;
    }

    // The source sends with the TTL it was given. Only forwarders decrement it.
    command error_t IP.send(uint16_t dest, uint8_t protocol, uint8_t TTL, uint8_t *payload){
        if (TTL == 0) {
            dbg(ROUTING_CHANNEL, "TTL must be positive! packet dropped. dest: %d\n", dest);
            return FAIL;
        }

        makePack(&sendPackage, TOS_NODE_ID, dest, TTL, protocol, mySeq, payload, PACKET_MAX_PAYLOAD_SIZE);
        mySeq++;

        // The radio won't deliver to ourselves, so hand it straight up.
        if (dest == TOS_NODE_ID) {
            signal IP.receive(sendPackage);
            return SUCCESS;
        }

        return forward(sendPackage);
    }

    void handlePacket(pack msg){
        // If the packet is for us, hand it up to Ping.
        if (msg.dest == TOS_NODE_ID) {
            if (msg.TTL > 0) {
                signal IP.receive(msg);
            }
            return;
        }

        // A TTL of 1 means this was the packet's last allowed hop.
        if (msg.TTL <= 1) {
            dbg(ROUTING_CHANNEL, "TTL expired! packet dropped. src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return;
        }

        // Forwarders only change the TTL. src, dest, seq, protocol and payload stay as the source sent them.
        msg.TTL -= 1;
        forward(msg);
    }

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
        if (len == sizeof(pack)) {
            pack* myMsg = (pack*) payload;
            handlePacket(*myMsg);
            return msg;
        }
        dbg(ROUTING_CHANNEL, "Unknown Packet Type %d\n", len);
        return msg;
    }
}