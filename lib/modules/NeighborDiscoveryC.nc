configuration NeighborDiscoveryC{
   provides interface NeighborDiscovery;
}

implementation{
   components NeighborDiscoveryP;
   NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery;

   components new SimpleSendC(AM_PACK);
   NeighborDiscoveryP.Sender -> SimpleSendC;

   components new TimerMilliC() as discoveryTimer;
   NeighborDiscoveryP.discoveryTimer -> discoveryTimer;

   components RandomC as Random;
   NeighborDiscoveryP.Random -> Random;
}