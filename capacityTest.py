from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("tuna-melt.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.ROUTING_CHANNEL);

    # 23 nodes, diameter 7. Give it 120 s to converge.
    s.runSeconds(120);

    # Expected: node 7 (one of the farthest nodes) has all 23 destinations VALID.
    s.mark("route table for 7");
    s.routeDMP(7); s.runSeconds(1);

    # Expected: destinations sent in the third packet (the highest IDs) stay VALID round after round,
    # and the routing channel shows no "route expired!" in between.
    s.runSeconds(60);
    s.mark("route table for 7, 60 s later");
    s.routeDMP(7); s.runSeconds(1);

    s.mark("ping 7 -> 21");
    s.ping(7, 21, "Far away"); s.runSeconds(5);

    # 23 destinations at 9 per packet means 3 packets per neighbor: 9, 9, then 5 entries.
    # Last, since this channel is very chatty.
    s.mark("dv adverts");
    s.addChannel(s.DV_CHANNEL);
    s.runSeconds(7);

if __name__ == '__main__':
    main()
