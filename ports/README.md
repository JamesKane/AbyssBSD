# ports

A poudriere overlay: each directory replaces the port of the same origin in
the ports tree it is built against.

    poudriere ports -c -p abyss -m null -M $PWD/ports
    poudriere bulk -j <jail> -p default -O abyss <origins>

Taken from https://github.com/JamesKane/freebsd-ports, branch freedreno at
d80cb373e32b645d4d6a8347156c16b5011f65b6, over freebsd-ports 0766e9d7376671c8a404db90a2ac8f9ffdf099a4.
