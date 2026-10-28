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

    s.mark("route table for 2");
    s.routeDMP(2); s.runSeconds(1);

    # Watch one full round of adverts. A DV period is at most 6 s.
    # Expected for DEBUG (2): "advertising to: 3, dest: 4, cost: 16" and "advertising to: 1, dest: 4, cost: 2".
    s.mark("dv adverts");
    s.addChannel(s.DV_CHANNEL);
    s.runSeconds(7);

if __name__ == '__main__':
    main()
