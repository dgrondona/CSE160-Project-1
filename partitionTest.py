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
    s.addChannel(s.FLOODING_CHANNEL); # Should stay quiet, a ping with no route is dropped, not flooded.

    # ND finds neighbors in about 4-8 s, then routes spread about one hop per DV exchange
    # (~1.5 s triggered, at most ~6 s periodic). 60 s is plenty for a 4 node line.
    s.runSeconds(60);

    s.mark("before partition");
    s.routeDMP(1); s.runSeconds(1);

    s.mark("removing 2-3");
    s.removeLink(2, 3);

    # ND drop (~16 s) plus the withdrawal reaching node 1.
    s.runSeconds(60);

    # Expected: 3 and 4 are WITHDRAWN or gone on node 1, and the ping logs "no route! packet dropped." at node 1.
    s.mark("after partition");
    s.routeDMP(1); s.runSeconds(1);
    s.ping(1, 4, "Partition"); s.runSeconds(5);

    s.mark("restoring 2-3");
    s.addLink(2, 3);
    s.runSeconds(60);

    # Expected: 1 reaches 4 through 2 at cost 3 again, and the ping gets a reply.
    s.mark("after restoring 2-3");
    s.routeDMP(1); s.runSeconds(1);
    s.ping(1, 4, "Recovered"); s.runSeconds(5);

if __name__ == '__main__':
    main()
