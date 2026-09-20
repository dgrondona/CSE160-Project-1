#include "../../includes/packet.h"

module NeighborDiscoveryP{
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as discoveryTimer;
   uses interface Random;
   uses interface SimpleSend as Sender;
}

implementation{
    command void NeighborDiscovery.startDiscovery(){
        dbg(NEIGHBOR_CHANNEL, "startDiscovery called!\n");
    }

    command void NeighborDiscovery.printNeighbors(){
        dbg(NEIGHBOR_CHANNEL, "printNeighbors called!\n");
    }

    event void discoveryTimer.fired(){
        dbg(NEIGHBOR_CHANNEL, "timer fired!\n");
    }
}