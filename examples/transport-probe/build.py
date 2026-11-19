"""Build the isolated transport probe from source on a Unix host."""

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from build_transport import TARGETS, run


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work", type=Path, help="directory for sources, tools and throwaway identities")
    parser.add_argument("target", choices=TARGETS)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--arena", dest="workload", action="store_const", const="arena", help="run headless flight")
    mode.add_argument("--six-beacons", dest="workload", action="store_const", const="six-beacons",
                      help="run the headless late join and drop test")
    args = parser.parse_args()
    run(args.work, args.target, args.workload)
