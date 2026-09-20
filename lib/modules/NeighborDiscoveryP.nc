#include "../../includes/packet.h"

module NeighborDiscoveryP{
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as discoveryTimer;
   uses interface Random;
   uses interface SimpleSend as sender;
}

implementation{
    command void NeighborDiscovery.startDiscovery(){
        dbg(NEIGHBOR_CHANNEL, "startDiscovery called!\n");
    }

    command void NeighborDiscovery.printNeighbors(){
        dbg(NEIGHBOR_CHANNEL, "printNeighbors called!\n");
    }

    event void descoveryTimer.fired(){
        dbg(NEIGHBOR_CHANNEL, "timer fired!\n");
    }
}