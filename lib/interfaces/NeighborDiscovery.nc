#include "../../includes/packet.h"

interface NeighborDiscovery{
   command void startDiscovery();
   command void printNeighbors();
   command bool isNeighbor(uint16_t id);
   command uint8_t getNeighbors(uint16_t* buf, uint8_t max);

   event void neighborAdded(uint16_t id);
   event void neighborRemoved(uint16_t id);
}