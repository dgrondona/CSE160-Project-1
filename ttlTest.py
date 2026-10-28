from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.ROUTING_CHANNEL);

    # ND finds neighbors in about 4-8 s, then routes spread about one hop per DV exchange
    # (~1.5 s triggered, at most ~6 s periodic). 60 s is plenty for a 4 node line.
    s.runSeconds(60);

    # TTL 2: 1 sends 2 to node 2, 2 forwards 1 to node 3, and 3 drops it.
    # Expected: "TTL expired! packet dropped." at node 3, no "ping received!" at node 4, no reply.
    s.mark("ping 1 -> 4 with TTL 2");
    s.pingTTL(1, 4, 2, "Too short"); s.runSeconds(5);

    # TTL 3 is just enough for 3 hops, so this one gets a reply.
    s.mark("ping 1 -> 4 with TTL 3");
    s.pingTTL(1, 4, 3, "Just enough"); s.runSeconds(5);

if __name__ == '__main__':
    main()
