from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("alt.topo");

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

    # Expected: 1 reaches 4 through 2 at cost 2.
    s.mark("before removing 2-4");
    s.routeDMP(1); s.runSeconds(1);
    s.ping(1, 4, "Before"); s.runSeconds(5);

    # Keep node 2 running, just take away its link to 4.
    s.mark("removing 2-4");
    s.removeLink(2, 4);

    # ND takes up to ~16 s to drop the neighbor, then the withdrawal and the new route take a few exchanges.
    s.runSeconds(60);

    # Expected: 1 reaches 4 through 3 at cost 3.
    s.mark("after removing 2-4");
    s.routeDMP(1); s.runSeconds(1);
    s.ping(1, 4, "Alternative"); s.runSeconds(5);

    s.mark("restoring 2-4");
    s.addLink(2, 4);
    s.runSeconds(60);

    # Expected: back to 4 through 2 at cost 2.
    s.mark("after restoring 2-4");
    s.routeDMP(1); s.runSeconds(1);
    s.ping(1, 4, "Restored"); s.runSeconds(5);

if __name__ == '__main__':
    main()
