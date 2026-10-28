/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;

    Node -> MainC.Boot;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    components NeighborDiscoveryC;
    Node.NeighborDiscovery -> NeighborDiscoveryC;

    // Flooding stays its own Project 1 service on AM_FLOODING. Ping goes through IP now.
    components FloodingC;
    Node.Flooding -> FloodingC;

    components DistanceVectorC;
    Node.DistanceVector -> DistanceVectorC;

    components IPC;
    Node.IP -> IPC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;
}
