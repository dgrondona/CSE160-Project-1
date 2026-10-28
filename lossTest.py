from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("meyer-heavy.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.ROUTING_CHANNEL);

    # meyer-heavy drops some packets, so let it run long enough to miss and recover adverts.
    s.runSeconds(60);
    s.mark("route table for 1 at 60 s");
    s.routeDMP(1); s.runSeconds(1);

    s.runSeconds(240);

    # Expected: any "route expired!" or "route withdrawn!" during the run is followed by "route installed!"
    # once adverts get through again, and node 1 ends up with 4 through 2 at cost 3.
    s.mark("route table for 1 at 300 s");
    s.routeDMP(1); s.runSeconds(1);
    s.ping(1, 4, "Lossy"); s.runSeconds(5);

if __name__ == '__main__':
    main()
