#include "../../includes/packet.h"

interface Flooding{
   command error_t flood(uint16_t destination, uint8_t *payload);
   command error_t handlePacket(pack msg);
}