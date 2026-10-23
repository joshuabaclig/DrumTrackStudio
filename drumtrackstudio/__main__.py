"""python -m drumtrackstudio          -> GUI
python -m drumtrackstudio URL ...  -> command line (see cli.py, or --help)"""
import sys

if len(sys.argv) > 1:
    from .cli import main
else:
    from .gui import main

sys.exit(main())
