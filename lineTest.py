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
    s.addChannel(s.FLOODING_CHANNEL); # Should stay quiet, pings are routed now.

    # ND finds neighbors in about 4-8 s, then routes spread about one hop per DV exchange
    # (~1.5 s triggered, at most ~6 s periodic). 60 s is plenty for a 4 node line.
    s.runSeconds(60);

    # Expected: 1 reaches 4 through 2 at cost 3, and 4 reaches 1 through 3 at cost 3.
    s.mark("route tables");
    s.routeDMP(1); s.runSeconds(1);
    s.routeDMP(4); s.runSeconds(1);

    # Expected: only nodes 1, 2 and 3 log Routing Packet, and the reply comes back the same way.
    s.mark("ping 1 -> 4");
    s.ping(1, 4, "Line test");
    s.runSeconds(5);

if __name__ == '__main__':
    main()
