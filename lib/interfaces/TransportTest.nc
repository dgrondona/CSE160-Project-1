interface TransportTest{
   command void startServer(uint8_t port);
   command void startClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transferBytes);
   command void closeClient(uint16_t dest, uint8_t srcPort, uint8_t destPort);
}
