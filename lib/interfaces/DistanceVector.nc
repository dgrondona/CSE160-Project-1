#include "../../includes/packet.h"

interface DistanceVector{
   command void start();
   command bool lookup(uint16_t dest, uint16_t* nextHop, uint8_t* cost);
   command void printRouteTable();
}