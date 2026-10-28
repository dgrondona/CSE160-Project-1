#include "../../includes/packet.h"

interface IP{
   command error_t send(uint16_t dest, uint8_t protocol, uint8_t TTL, uint8_t *payload);
   event void receive(pack msg);
}