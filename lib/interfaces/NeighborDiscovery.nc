#include "../../includes/packet.h"

interface NeighborDiscovery{
   command void startDiscovery();
   command void printNeighbors();
   command void handlePacket(pack msg);
}