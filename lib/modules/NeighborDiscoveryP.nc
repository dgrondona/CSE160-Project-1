#include "../../includes/packet.h"

module NeighborDiscoveryP{
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as discoveryTimer;
   uses interface Random;
   uses interface SimpleSend as Sender;
}

implementation{
    pack sendPackage;

    enum {
        MAX_NEIGHBORS = 32,
        MAX_MISSED = 4
    };

    typedef struct Neighbor {
        uint16_t addr;
        uint16_t missedCount;
    }Neighbor;

    Neighbor neighborList[MAX_NEIGHBORS];
    uint16_t neighborCount = 0;

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
    }

    command void NeighborDiscovery.startDiscovery(){
        dbg(NEIGHBOR_CHANNEL, "startDiscovery called!\n");
    }

    command void NeighborDiscovery.printNeighbors(){
        dbg(NEIGHBOR_CHANNEL, "printNeighbors called!\n");
    }

    command void NeighborDiscovery.handlePacket(pack msg){
        dbg(NEIGHBOR_CHANNEL, "handlePacket called! src: %d, protocol: %d\n", msg.src, msg.protocol);
    }

    event void discoveryTimer.fired(){
        dbg(NEIGHBOR_CHANNEL, "timer fired!\n");
    }
}